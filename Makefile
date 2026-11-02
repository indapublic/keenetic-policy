# KeeneticPolicy. `make help` lists the commands.
SWIFTC ?= swiftc
SWIFTFLAGS ?= -O
SIGN ?= -
CODESIGN_FLAGS = $(if $(filter -,$(SIGN)),,--options runtime --timestamp)
TAP = indapublic/keenetic-policy
TAP_URL = https://github.com/indapublic/keenetic-policy
FORMULA = $(TAP)/keenetic-policy
APP = KeeneticPolicy.app
BIN = $(APP)/Contents/MacOS/KeeneticPolicy
LABEL = com.indapublic.keeneticpolicy

build: $(APP) ## Build KeeneticPolicy.app (default)

$(APP): sources/main.swift Info.plist LaunchAgent.plist AppIcon.icns \
        $(wildcard sources/*.lproj/Localizable.strings)
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources $@/Contents/Library/LaunchAgents
	cp Info.plist $@/Contents/Info.plist
	cp LaunchAgent.plist $@/Contents/Library/LaunchAgents/$(LABEL).plist
	cp AppIcon.icns $@/Contents/Resources/AppIcon.icns
	cp -R sources/en.lproj sources/ru.lproj $@/Contents/Resources/
	$(SWIFTC) $(SWIFTFLAGS) -o $(BIN) sources/main.swift
	codesign --force --sign "$(SIGN)" $(CODESIGN_FLAGS) $@

AppIcon.icns: $(wildcard assets/AppIcon.iconset/*.png)
	iconutil -c icns -o $@ assets/AppIcon.iconset

icon: ## Render the icon PNGs from the SVGs (needs Google Chrome)
	tools/render-icon.sh

test: $(APP) ## Run the tests against a mock router
	tests/run.sh

lint: ## Type-check the sources and run shellcheck
	$(SWIFTC) -typecheck -warnings-as-errors sources/main.swift
	@command -v shellcheck >/dev/null || { echo "shellcheck is missing: brew install shellcheck"; exit 1; }
	shellcheck tools/*.sh tests/*.sh

run: build ## Build and open the app
	open $(APP)

install: ## Install from the Homebrew tap and start the service
	brew tap $(TAP) $(TAP_URL)
	brew trust --formula $(FORMULA)
	brew install $(FORMULA)
	brew services start keenetic-policy
	@echo "Now run: keenetic-policy --setup"

install-local: build ## Install into ~/Applications and start at login, without Homebrew
	rm -rf "$(HOME)/Applications/$(APP)"
	mkdir -p "$(HOME)/Applications"
	ditto $(APP) "$(HOME)/Applications/$(APP)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(HOME)/Applications/$(APP)"
	mkdir -p "$(HOME)/.local/bin"
	ln -sfn "$(HOME)/Applications/$(APP)/Contents/MacOS/KeeneticPolicy" "$(HOME)/.local/bin/keenetic-policy"
	"$(HOME)/Applications/$(APP)/Contents/MacOS/KeeneticPolicy" --register
	-open "$(HOME)/Applications/$(APP)"

update: ## Upgrade to the latest release and restart the service
	brew update
	brew upgrade keenetic-policy
	brew services restart keenetic-policy

uninstall: ## Stop the service and uninstall
	-brew services stop keenetic-policy
	brew uninstall keenetic-policy

start: ## Start the service
	brew services start keenetic-policy

stop: ## Stop the service
	brew services stop keenetic-policy

restart: ## Restart the service
	brew services restart keenetic-policy

status: ## Show the service state and memory footprint
	@brew services info keenetic-policy
	@footprint KeeneticPolicy 2>/dev/null | grep -o 'Footprint: .*' || true

logs: ## Follow the log (~/Library/Logs/KeeneticPolicy.log)
	tail -f "$(HOME)/Library/Logs/KeeneticPolicy.log"

release: ## Release a new version: make release VERSION=x.y.z
	@test -n "$(VERSION)" || { echo "Usage: make release VERSION=x.y.z"; exit 2; }
	tools/release.sh $(VERSION)

clean: ## Remove build products
	rm -rf $(APP) AppIcon.icns

help: ## List the commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  make %-14s %s\n", $$1, $$2 }'

.PHONY: build icon test lint run install install-local update uninstall start stop restart status logs release clean help
