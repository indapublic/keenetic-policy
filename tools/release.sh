#!/bin/bash
# Releases KeeneticPolicy <version>: builds a universal KeeneticPolicy.app
# signed with the Developer ID and notarized, tags v<version>, publishes it as
# a GitHub release (a zip for Homebrew and KeeneticPolicy.dmg) and points
# Formula/keenetic-policy.rb at the zip (commit + push).
#
# One-time setup:
#   - "Developer ID Application" certificate in the login keychain;
#   - notarization credentials saved under a keychain profile:
#       xcrun notarytool store-credentials <profile> --apple-id <apple id> \
#         --team-id 4WSCP7LMZQ
#
# Usage: tools/release.sh <x.y.z>
#   DRY_RUN=1  build, sign and notarize only; nothing is committed or published
#   IDENTITY, NOTARY_PROFILE, GH_REPO override the defaults below.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
IDENTITY=${IDENTITY:-"Developer ID Application: Vasilii Zolotukhin (4WSCP7LMZQ)"}
NOTARY_PROFILE=${NOTARY_PROFILE:-plurium}
GH_REPO=${GH_REPO:-indapublic/keenetic-policy}
DRY_RUN=${DRY_RUN:-0}
APP=KeeneticPolicy.app
BINARY=$APP/Contents/MacOS/KeeneticPolicy
VERSION=${1:-}
TAG=v$VERSION

step() { echo; echo "=== $*"; }

# Apple's timestamp server and GitHub occasionally do not answer.
retry() {
  local attempt
  for attempt in 1 2 3; do
    "$@" && return 0
    echo "Attempt $attempt failed: $*"
    sleep 10
  done
  return 1
}

# Submits $1 to Apple's notary service, waits, fails with the log unless
# accepted.
notarize() {
  local result status id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format plist)
  status=$(plutil -extract status raw -o - - <<< "$result")
  echo "Notarization: $status"
  if [ "$status" != Accepted ]; then
    id=$(plutil -extract id raw -o - - <<< "$result")
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
  fi
}

if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: tools/release.sh <x.y.z>"
  exit 2
fi
cd "$REPO_DIR"

step "Check the working tree and the signing setup"
if [ "$(git branch --show-current)" != main ]; then echo "Not on main"; exit 1; fi
if [ -n "$(git status --porcelain)" ]; then echo "Uncommitted changes"; exit 1; fi
git fetch -q origin main --tags
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "main is not in sync with origin/main"
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "$TAG already exists"
  exit 1
fi
security find-identity -v -p codesigning | grep -qF "$IDENTITY" ||
  { echo "Signing identity not found: $IDENTITY"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null ||
  { echo "No notarization credentials in keychain profile '$NOTARY_PROFILE' (see the header)"; exit 1; }

step "Build and test"
make $APP test
make clean

WORK=$(mktemp -d)
COMMITTED=0
cleanup() {
  rm -rf "$WORK"
  # Until the release commit exists, leave the tree as it was.
  if [ "$COMMITTED" -eq 0 ]; then git checkout -q -- Info.plist; make -s clean; fi
}
trap cleanup EXIT

step "Build, sign and notarize KeeneticPolicy $VERSION"
BUILD=$(( $(plutil -extract CFBundleVersion raw Info.plist) + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Info.plist

# A universal binary: swiftc has one -target per run, so build twice and lipo.
retry make -B $APP SIGN="$IDENTITY" SWIFTFLAGS="-O -target arm64-apple-macos13.0"
cp "$BINARY" "$WORK/arm64"
retry make -B $APP SIGN="$IDENTITY" SWIFTFLAGS="-O -target x86_64-apple-macos13.0"
cp "$BINARY" "$WORK/x86_64"
lipo -create "$WORK/arm64" "$WORK/x86_64" -output "$BINARY"
codesign --force --sign "$IDENTITY" --options runtime --timestamp $APP
codesign --verify --strict $APP
lipo -archs "$BINARY"
codesign -d -r- $APP 2>/dev/null

ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent $APP "$WORK/notarize.zip"
notarize "$WORK/notarize.zip"
retry xcrun stapler staple $APP
spctl --assess --type execute -vv $APP

# Homebrew steps into an archive's lone top-level directory, so the app sits
# one level down.
PKG=keenetic-policy-$VERSION
ZIP=$WORK/KeeneticPolicy-$VERSION.zip
mkdir "$WORK/$PKG"
ditto $APP "$WORK/$PKG/$APP"
cp LICENSE README.md "$WORK/$PKG/"
# Without these flags ditto stores extended attributes as ._ AppleDouble
# entries, which unzip writes out as plain files inside the bundle: that
# breaks the signature seal and Gatekeeper calls the app damaged.
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$WORK/$PKG" "$ZIP"

# Unpack the way Homebrew does and check the result.
mkdir "$WORK/check"
unzip -q "$ZIP" -d "$WORK/check"
if find "$WORK/check" -name '._*' | grep -q .; then
  echo "The archive contains AppleDouble files"
  exit 1
fi
codesign --verify --strict "$WORK/check/$PKG/$APP"
spctl --assess --type execute "$WORK/check/$PKG/$APP"
SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "sha256 $SHA256"

step "DMG"
# One name for every release, so releases/latest/download/KeeneticPolicy.dmg
# always points at the newest one.
DMG=$WORK/KeeneticPolicy.dmg
mkdir "$WORK/dmg"
ditto --norsrc --noextattr --noqtn $APP "$WORK/dmg/$APP"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Keenetic Policy" -srcfolder "$WORK/dmg" -fs APFS -format ULFO -ov "$DMG" >/dev/null
retry codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
retry xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "Dry run: nothing committed or published."
  exit 0
fi

step "Tag $TAG"
git add Info.plist
git commit -q -m "KeeneticPolicy $VERSION"
COMMITTED=1
git tag "$TAG"
retry git push -q origin main "$TAG"

step "Publish $TAG to $GH_REPO"
# gh deletes the half-created release when the upload fails, so a retry
# starts clean.
retry gh release create "$TAG" "$ZIP" "$DMG" --repo "$GH_REPO" --title "KeeneticPolicy $VERSION" \
  --notes "Universal build, signed with a Developer ID and notarized.

With Homebrew: \`brew upgrade keenetic-policy\` (see README). Or download
KeeneticPolicy.dmg, drag the app to Applications and open it once."

step "Point the formula at $TAG"
URL=https://github.com/$GH_REPO/releases/download/$TAG/KeeneticPolicy-$VERSION.zip
sed -i '' -E "s|^  url \".*\"|  url \"$URL\"|; s|^  sha256 \".*\"|  sha256 \"$SHA256\"|" Formula/keenetic-policy.rb
git add Formula/keenetic-policy.rb
git commit -q -m "keenetic-policy $VERSION"
retry git push -q origin main
make -s clean
echo "Released. Users update with: brew update && brew upgrade keenetic-policy"
