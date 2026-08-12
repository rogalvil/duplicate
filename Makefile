# Single source of truth for the bundle identity. Resources/Info.plist is a template and
# these values get substituted into it, so nothing has to be kept in sync by hand.
APP_NAME     := Duplicate
BUNDLE_ID    := com.rogalvil.duplicate
VERSION      := 0.1.0
MIN_MACOS    := 15.0

CONFIG       ?= release
COVERAGE_MIN ?= 80
CORE_TARGET  := Sources/DuplicateCore

BUILD_DIR    := build
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS     := $(APP_BUNDLE)/Contents
COVERAGE_DIR := coverage

# /Applications, because that is what Finder's "Applications" shortcut shows and where anyone
# looks first. It is group-writable by admin users, so no sudo is needed on a normal Mac; the
# install target falls back to ~/Applications when it is not writable, which is the case on a
# non-admin account.
INSTALL_DIR  ?= $(shell [ -w /Applications ] && echo /Applications || echo $(HOME)/Applications)

# A self-signed "Duplicate Dev" certificate keeps the code signature stable across rebuilds,
# which is what lets TCC remember the Desktop/Documents/Downloads grants. Without one the build
# falls back to ad-hoc signing and macOS re-prompts after every rebuild, because it keys the
# grant on the binary hash. CONTRIBUTING.md explains how to create it for free.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -F '"$(APP_NAME) Dev"' | head -1 | sed -E 's/.*"(.*)".*/\1/')

# Stamped into Info.plist so the About panel can say which build is running. The commit gets a
# trailing `+` when the tree is dirty: such a build matches no commit, and a bug reported against
# it cannot be reproduced from the repository alone. Both fall back to empty, which the About
# panel reports as unknown -- a build from a tarball has no git metadata at all.
#
# `git status --porcelain` rather than `git diff --quiet`, because the latter ignores untracked
# files: a tree full of brand-new sources reports as clean, and a build made from it would claim to
# be exactly the named commit.
#
# CFBundleVersion is the commit count, not the marketing version. It is monotonic, never resets, and
# distinguishes two builds of 0.1.0 -- which matters to Launch Services, to crash reports, and to
# anyone reading a bug report. Falls back to 0 outside a git checkout.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
BUILD_DATE   := $(shell date +%Y-%m-%dT%H:%M:%S%z)
GIT_COMMIT   := $(shell git rev-parse --short HEAD 2>/dev/null)$(shell test -z "$$(git status --porcelain 2>/dev/null)" || echo +)

.DEFAULT_GOAL := all
.PHONY: all build bundle sign install uninstall run run-debug selftest selftest-all test \
	coverage fmt lint icon clean help

## all: build, assemble and sign the app bundle
all: sign

## build: compile every target (override with CONFIG=debug)
build:
	swift build -c $(CONFIG)

## bundle: assemble build/Duplicate.app around the compiled binary
bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp ".build/$(CONFIG)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@sed -e 's|__APP_NAME__|$(APP_NAME)|g' \
	     -e 's|__BUNDLE_ID__|$(BUNDLE_ID)|g' \
	     -e 's|__VERSION__|$(VERSION)|g' \
	     -e 's|__BUILD_NUMBER__|$(BUILD_NUMBER)|g' \
	     -e 's|__MIN_MACOS__|$(MIN_MACOS)|g' \
	     -e 's|__BUILD_DATE__|$(BUILD_DATE)|g' \
	     -e 's|__GIT_COMMIT__|$(GIT_COMMIT)|g' \
	     Resources/Info.plist > "$(CONTENTS)/Info.plist"
	@# The .lproj directories are copied verbatim rather than declared as SwiftPM resources.
	@# SwiftPM would bury them in a Duplicate_Duplicate.bundle, where Bundle.main cannot find
	@# them; the app bundle is assembled here, so localisation lives here too.
	@cp -R Resources/en.lproj Resources/es.lproj "$(CONTENTS)/Resources/"
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns" || true
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@echo "Assembled $(APP_BUNDLE)"

## sign: code sign the bundle, preferring the stable self-signed certificate
sign: bundle
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "Signing with '$(SIGN_IDENTITY)'"; \
		codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP_BUNDLE)"; \
	else \
		echo "No '$(APP_NAME) Dev' certificate found -- signing ad-hoc."; \
		echo "macOS will re-ask for folder access after every rebuild."; \
		echo "Run ./scripts/make-signing-cert.sh once to fix this. See CONTRIBUTING.md."; \
		codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_BUNDLE)"; \
	fi

## install: copy the signed app to /Applications so it survives `make clean`
##          override the destination with INSTALL_DIR=...
install: all
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Folder grants carry over: the designated requirement is the bundle identifier plus"
	@echo "the signing certificate, with no path in it."

## uninstall: remove the installed copy
uninstall:
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Removed $(INSTALL_DIR)/$(APP_NAME).app"

## run: launch the signed bundle through Launch Services
run: all
	@open "$(APP_BUNDLE)"

## run-debug: run the binary in the foreground so stdout and crashes are visible
run-debug: all
	@"$(CONTENTS)/MacOS/$(APP_NAME)"

## selftest: drive a real code path headlessly and fail when the result is wrong
##           MODE=state-dir  resolve and check the six state subdirectories
##           ARGS=...        extra flags passed through verbatim
selftest: all
	@"$(CONTENTS)/MacOS/$(APP_NAME)" --selftest $(if $(MODE),--mode $(MODE),) $(ARGS)

## selftest-all: run every selftest mode, stopping at the first failure
selftest-all: all
	@"$(CONTENTS)/MacOS/$(APP_NAME)" --selftest --mode all

## test: run the DuplicateCore test suite
test:
	swift test

## coverage: run tests and enforce the line-coverage floor over DuplicateCore
coverage:
	swift test --enable-code-coverage
	@mkdir -p "$(COVERAGE_DIR)"
	@set -eu; \
	bin_path="$$(swift build --show-bin-path)"; \
	profdata="$$bin_path/codecov/default.profdata"; \
	xctest="$$(ls -d "$$bin_path"/*.xctest | head -1)"; \
	binary="$$xctest/Contents/MacOS/$$(basename "$$xctest" .xctest)"; \
	if [ ! -f "$$profdata" ]; then echo "No profile data at $$profdata" >&2; exit 1; fi; \
	xcrun llvm-cov export "$$binary" -instr-profile "$$profdata" -summary-only \
		> "$(COVERAGE_DIR)/summary.json"; \
	python3 scripts/coverage_gate.py "$(COVERAGE_DIR)/summary.json" \
		--prefix "$(CORE_TARGET)" --min "$(COVERAGE_MIN)"

## fmt: rewrite sources in place with swift-format
fmt:
	xcrun swift-format format --in-place --recursive --parallel Sources Tests

## lint: fail on any formatting deviation, without rewriting
lint:
	xcrun swift-format lint --recursive --parallel --strict Sources Tests

## icon: regenerate Resources/AppIcon.icns from scripts/make-app-icon.swift
icon:
	swift scripts/make-app-icon.swift

## clean: remove build products and coverage output
clean:
	rm -rf .build "$(BUILD_DIR)" "$(COVERAGE_DIR)"

## help: list the available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -e 's/## /  /' | sort
