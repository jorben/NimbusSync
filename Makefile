# NimbusSync — top-level task runner.
#
# Primary targets:
#   make dev     Build + launch the real app via Scripts/build.sh.
#   make build   Unified build via Scripts/build.sh (secret/release scans, Dist/ artifacts).
#   make test    Full test suite (SwiftPM packages).
#   make clean   Remove all build artifacts (.build/, Dist/).
#
# Signing: the File Provider extension only loads from signed builds. When
# Config/build.local.sh provides signing defaults, `make dev`/`make build`
# inherit them; on a pristine checkout they fall back to build.sh defaults
# (unsigned Debug) and `make dev` prints a warning that the extension won't load.
#
# CONFIGURATION/SIGNING_MODE are forwarded to Scripts/build.sh only when set
# on the command line, e.g.:
#   make build CONFIGURATION=Release SIGNING_MODE=signed
#   make build SIGNING_MODE=unsigned CONFIGURATION=Debug

SHELL := /bin/sh

DIST_DIR ?= Dist

# Forward overrides to Scripts/build.sh only when the caller actually set them
# (command line or environment); otherwise build.local.sh / build.sh defaults win.
BUILD_ARGS := \
	$(if $(CONFIGURATION),CONFIGURATION='$(CONFIGURATION)') \
	$(if $(SIGNING_MODE),SIGNING_MODE='$(SIGNING_MODE)') \
	$(if $(filter-out default file,$(origin DIST_DIR)),DIST_DIR='$(DIST_DIR)')

# Optional passthroughs, e.g.:
#   make test-swift SWIFT_TEST_FLAGS='--filter DomainHealthReducerTests'
SWIFT_TEST_FLAGS ?=

# Fast unsigned iteration target (UI only — File Provider will NOT load).
DEV_UNSIGNED_BUILD_ROOT ?= .build/dev
DEV_UNSIGNED_APP := $(DEV_UNSIGNED_BUILD_ROOT)/Build/Products/Debug/NimbusSyncDev.app

XCODEBUILD := xcodebuild \
	-project NimbusSync.xcodeproj \
	-scheme NimbusSync \
	-destination platform=macOS

# Quit the copy being replaced, wait until it has really exited, then open the
# new build. Match by executable path, not process name, so relaunching one
# copy never kills another build of the same configuration elsewhere. Opening while the old instance is still terminating makes
# LaunchServices fail with -600 (procNotFound), so retry once after a pause.
RELAUNCH = relaunch() { \
		exe="$$(cd "$$1" && pwd)/Contents/MacOS/$$(basename "$$1" .app)"; \
		pkill -f "$$exe" 2>/dev/null || true; \
		i=0; while pgrep -f "$$exe" >/dev/null 2>&1 && [ $$i -lt 50 ]; do sleep 0.1; i=$$((i + 1)); done; \
		open "$$1" || { sleep 1; open "$$1"; }; \
	}; relaunch

.DEFAULT_GOAL := help
.PHONY: help dev dev-unsigned build dmg test test-swift lint \
	clean clean-swift clean-dist

help: ## Show available targets
	@printf 'NimbusSync tasks: make <target>\n\n'
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_-]+:.*## / \
		{ printf "  %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

dev: ## Build via Scripts/build.sh (signed per local config) and launch it
	$(BUILD_ARGS) ./Scripts/build.sh
	@app="$$($(BUILD_ARGS) ./Scripts/build.sh --print-app-path)"; \
	if ! codesign -dv "$$app" 2>&1 | grep -Eq '^TeamIdentifier=[A-Z0-9]+'; then \
		printf 'WARNING: unsigned/ad-hoc build — Finder will report the File Provider extension as unavailable.\n' >&2; \
	fi; \
	$(RELAUNCH) "$$app"; \
	printf 'launched: %s\n' "$$app"

dev-unsigned: ## Fast UI-only build; File Provider extension will NOT load
	$(XCODEBUILD) \
		-configuration Debug \
		-derivedDataPath $(DEV_UNSIGNED_BUILD_ROOT) \
		-quiet \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
	@printf 'WARNING: unsigned build — Finder will report the File Provider extension as unavailable.\n' >&2
	@$(RELAUNCH) '$(DEV_UNSIGNED_APP)'
	@printf 'launched: %s\n' '$(DEV_UNSIGNED_APP)'

build: ## Unified build via Scripts/build.sh (scans + Dist/ artifacts)
	$(BUILD_ARGS) ./Scripts/build.sh

dmg: ## Package the built app into a styled DMG (needs: pip install dmgbuild)
	@app="$$($(BUILD_ARGS) ./Scripts/build.sh --print-app-path)"; \
	./Scripts/make-dmg.sh "$$app" "$(DIST_DIR)/$$(basename "$$app" .app).dmg" NimbusSync

test: test-swift ## Run all tests

test-swift: ## Run SwiftPM package tests
	swift test --disable-sandbox $(SWIFT_TEST_FLAGS)

lint: ## Check formatting and whitespace (review gates)
	git --no-pager diff --check

clean: clean-swift clean-dist ## Remove all build artifacts

clean-swift: ## Remove SwiftPM and Xcode build outputs (.build/)
	rm -rf .build

clean-dist: ## Remove packaged artifacts (Dist/)
	rm -rf $(DIST_DIR)
