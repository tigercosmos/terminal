# Terminal — everyday build, verification, and install tasks.
#
# Xcode 27 is required (see CONTRIBUTING.md). If it is not the selected
# toolchain, point make at it for the whole run:
#
#   make build DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer

PROJECT     := terminal.xcodeproj
SCHEME      := terminal
BRIDGE      := Vendor/alacritty-bridge/Cargo.toml
DESTINATION ?= platform=macOS,arch=$(shell uname -m)
INSTALL_DIR ?= /Applications

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
        test test-rust test-web lint fmt fmt-check \
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

run: build ## Build and launch the app (Debug)
	@$(call resolve_app,Debug); \
	echo "Launching $$app"; \
	open "$$app"

install: ## Build Release and install into /Applications
	$(XCODEBUILD) -configuration Release $(INSTALL_SIGNING) build
	@$(call resolve_app,Release); \
	echo "Installing $$app -> $(INSTALL_DIR)/$$name"; \
	rm -rf "$(INSTALL_DIR)/$$name"; \
	ditto "$$app" "$(INSTALL_DIR)/$$name"

uninstall: ## Remove the installed app from /Applications
	rm -rf "$(INSTALL_DIR)/Terminal.app"

test: test-rust test-web ## Run every test suite

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
