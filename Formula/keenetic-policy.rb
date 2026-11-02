class KeeneticPolicy < Formula
  desc "Switch Keenetic access policies from the macOS menu bar"
  homepage "https://github.com/indapublic/keenetic-policy"
  url "https://github.com/indapublic/keenetic-policy/releases/download/v1.0.2/KeeneticPolicy-1.0.2.zip"
  sha256 "24b954d624a6d015858c20136a2c75410216159ecd17e14ee1aacc70e42d3dd1"
  license "MIT"
  head "https://github.com/indapublic/keenetic-policy.git", branch: "main"

  depends_on macos: :ventura

  def install
    # Release archives carry KeeneticPolicy.app signed with a Developer ID, so
    # the login item and the keychain entry survive updates. Source archives
    # and HEAD are built here and signed ad hoc.
    system "make", "KeeneticPolicy.app" unless File.exist?("KeeneticPolicy.app")
    prefix.install "KeeneticPolicy.app"
    bin.install_symlink prefix/"KeeneticPolicy.app/Contents/MacOS/KeeneticPolicy" => "keenetic-policy"
  end

  service do
    run opt_prefix/"KeeneticPolicy.app/Contents/MacOS/KeeneticPolicy"
    # A manual Quit should stay quit until the next login.
    keep_alive successful_exit: false
    process_type :interactive
  end

  def caveats
    <<~EOS
      Configure it once (the router address, the login, the password and this
      Mac's MAC address), then start the service:

        keenetic-policy --setup
        brew services start keenetic-policy

      The policy menu lives in the menu bar: a globe for the default policy,
      the policy name otherwise.
    EOS
  end

  test do
    assert_predicate prefix/"KeeneticPolicy.app/Contents/MacOS/KeeneticPolicy", :executable?
    assert_match "KeeneticPolicy", shell_output("#{bin}/keenetic-policy --version")
    system "codesign", "--verify", prefix/"KeeneticPolicy.app"
  end
end
