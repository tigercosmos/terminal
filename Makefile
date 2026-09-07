# Terminal — everyday build, verification, and install tasks.
#
# Xcode 27 is required (see CONTRIBUTING.md). If it is not the selected
# toolchain, point make at it for the whole run:
#
#   make build DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer

PROJECT     := terminal.xcodeproj
SCHEME      := terminal
BRIDGE      := Vendor/alacritty-bridge/Cargo.toml
CORE        := TerminalCore
DESTINATION ?= platform=macOS,arch=$(shell uname -m)
INSTALL_DIR ?= /Applications
# The e2e suite runs once per backend: the two surfaces implement one protocol
# separately, so only driving the default hides where they disagree.
E2E_BACKENDS ?= alacritty libghostty

# xcodebuild reads DEVELOPER_DIR from the environment, not the command line.
ifdef DEVELOPER_DIR
export DEVELOPER_DIR
endif

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'

# Every target here builds unsigned, `install` included. Automatic signing falls
# back to an ad-hoc signature when there is no Developer ID, and an ad-hoc
# signature plus ENABLE_HARDENED_RUNTIME trips Library Validation: it demands a
# Team ID match that ad-hoc code can never satisfy, so dyld rejects the embedded
# Sparkle.framework and the app dies at launch. Unsigned builds carry no
# hardened runtime, so they run. Shipping builds are signed and notarized by
# scripts/release.ts (see RELEASING.md), never from here. To sign an install
# with your own identity anyway:
#
#   make install INSTALL_SIGNING=""
UNSIGNED        := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
BUILD_SIGNING   ?= $(UNSIGNED)
INSTALL_SIGNING ?= $(UNSIGNED)

# The product name differs per configuration ("Terminal Debug.app" vs
# "Terminal.app"), and derived data lives wherever Xcode put it, so the built
# bundle is resolved from the build settings rather than guessed.
define resolve_app
settings=$$($(XCODEBUILD) -configuration $(1) -showBuildSettings 2>/dev/null); \
dir=$$(printf '%s\n' "$$settings" | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p'); \
name=$$(printf '%s\n' "$$settings" | sed -n 's/^ *WRAPPER_NAME = //p'); \
if [ -z "$$dir" ] || [ -z "$$name" ]; then \
	echo "make: could not resolve the built app from xcodebuild settings" >&2; exit 1; \
fi; \
app="$$dir/$$name"
endef

.DEFAULT_GOAL := help
.PHONY: help deps build build-release run install uninstall \
        test test-swift test-rust test-web e2e lint fmt fmt-check \
        web web-build dist clean

help: ## Show this help
	@grep -hE '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Fetch submodules and JS dependencies
	git submodule update --init --recursive
	bun install

build: ## Build the app (Debug)
	$(XCODEBUILD) -configuration Debug $(BUILD_SIGNING) build

build-release: ## Build the app (Release)
	$(XCODEBUILD) -configuration Release $(BUILD_SIGNING) build

# `open` hands the calling shell's environment to the app it launches. A shell
# running inside Terminal exports the CLI bridge, and the app treats an inherited
# bridge for its own bundle as "I was invoked as the `terminal` CLI" — so
# launching a build from a shell inside that same build would open a project in
# the running instance instead of starting the app. Dropping the bridge here
# makes `make run` mean "launch the app" wherever it is typed.
run: build ## Build and launch the app (Debug)
	@$(call resolve_app,Debug); \
	echo "Launching $$app"; \
	env -u TERMINAL_CLI_STATE -u TERMINAL_CLI_TOKEN -u TERMINAL_CLI_BUNDLE open "$$app"

install: ## Build Release and install into /Applications
	$(XCODEBUILD) -configuration Release $(INSTALL_SIGNING) build
	@$(call resolve_app,Release); \
	echo "Installing $$app -> $(INSTALL_DIR)/$$name"; \
	rm -rf "$(INSTALL_DIR)/$$name"; \
	ditto "$$app" "$(INSTALL_DIR)/$$name"

uninstall: ## Remove the installed app from /Applications
	rm -rf "$(INSTALL_DIR)/Terminal.app"

test: test-swift test-rust test-web ## Run every test suite

# No Xcode, no signing, and no app launch: the package holds the app's logic
# that needs no window, so this is the suite to reach for first.
test-swift: ## Test the TerminalCore package
	swift test --package-path $(CORE)

# Needs a GUI session: it launches the app and drives it. Nothing is captured
# from the screen and no input is synthesized from outside the app, so neither
# Screen Recording nor Accessibility is ever requested.
e2e: build ## Drive a running Debug build over the CLI channel
	@$(call resolve_app,Debug); \
	for backend in $(E2E_BACKENDS); do \
		scripts/e2e.sh "$$app" "$$backend" || exit 1; \
	done

test-rust: ## Test the Alacritty backend's Rust bridge
	cargo test --locked --manifest-path $(BRIDGE)

test-web: ## Type-check the website
	cd web && bun run typecheck

lint: ## Lint the Rust bridge
	cargo clippy --locked --manifest-path $(BRIDGE) --all-targets -- -D warnings

fmt: ## Format the Rust bridge
	cargo fmt --manifest-path $(BRIDGE)

fmt-check: ## Check Rust formatting without writing
	cargo fmt --manifest-path $(BRIDGE) --check

web: ## Run the website dev server
	cd web && bun run dev

web-build: ## Build the website
	cd web && bun run build

dist: ## Cut a release (maintainers only — see RELEASING.md)
	bun scripts/release.ts

clean: ## Remove build products
	$(XCODEBUILD) -configuration Debug clean
	$(XCODEBUILD) -configuration Release clean
	cargo clean --manifest-path $(BRIDGE)
	rm -rf build
