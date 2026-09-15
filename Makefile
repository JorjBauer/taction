# Taction build entry points. Everything here delegates to swift build and the scripts/ helpers.
#
#   make              debug build of every target
#   make test         unit tests (Xcode toolchain, via scripts/test.sh)
#   make app          dist/Taction.app for arm64 and x86_64, signed (what you distribute)
#   make app-native   dist/Taction.app for this Mac's architecture only (faster; local testing)
#   make release      dist/Taction-<version>.zip and .dmg, notarized with TACTION_NOTARY_PROFILE
#   make publish      release, then upload both artifacts to a draft GitHub release for v<version>;
#                     needs GH_TOKEN (see below). Review the draft on GitHub and publish it there.
#   make publish-upload
#                     upload (or repair) the draft from dist/ without rebuilding
#   make publish DRY_RUN=1
#                     say what publish would do, without a token
#   make run          build a native app bundle and open it
#   make install      build native, copy dist/Taction.app into /Applications (or ~/Applications), open it
#   make replay       run every synthetic gesture through the pipeline and print the actions
#   make icon         regenerate Resources/AppIcon.icns
#   make clean        remove build products
#
# Signing comes from the keychain (the first Developer ID Application identity, or
# TACTION_SIGN_IDENTITY). Notarization uses the notarytool keychain profile named by
# TACTION_NOTARY_PROFILE; the default is the profile shared with the other apps on this machine.
# Set TACTION_NOTARY_PROFILE= (empty) to skip notarization for a local build.
#
# GH_TOKEN for publishing is found in this order: the environment; the file PUBLISH_ENV (default
# ~/.config/taction/publish.env), a shell file that sets GH_TOKEN; then 1Password at OP_GH_TOKEN_REF
# through `op read`, which asks for Touch ID and so only works at the keyboard. The repository is
# TactionUpdateRepo in Resources/Taction-Info.plist. A version with a hyphen (0.2.0-beta.1) is
# published as a prerelease.

SHELL := /bin/bash
.DEFAULT_GOAL := build

VERSION := $(shell tr -d '[:space:]' < VERSION)
TACTION_NOTARY_PROFILE ?= yarr-notarize
export TACTION_NOTARY_PROFILE
PUBLISH_ENV ?= $(HOME)/.config/taction/publish.env
OP_GH_TOKEN_REF ?= op://automatons/taction/token
export PUBLISH_ENV OP_GH_TOKEN_REF
DRY_RUN ?= 0
APP := dist/Taction.app
ZIP := dist/Taction-$(VERSION).zip
DMG := dist/Taction-$(VERSION).dmg
SYNTHETIC := tap slow-press long-press drag two-finger-tap two-finger-scroll flick pinch-out pinch-in \
             three-finger-swipe-left three-finger-swipe-up palm edge late-second-finger

.PHONY: build test app app-native universal release publish publish-preflight publish-upload run install replay icon clean version help

build:
	swift build

test:
	scripts/test.sh

# Both write dist/Taction.app, so neither can be a timestamp rule: a native bundle would otherwise
# satisfy a later "make app" and ship arm64-only. Always rebuild; the Swift build cache keeps it quick.
app:
	scripts/bundle.sh

app-native:
	scripts/bundle.sh --native

# Kept for muscle memory; same as app.
universal: app

release:
	scripts/release.sh
	@ls -la $(ZIP) $(DMG)

# A publish needs a clean tree at the version being published, pushed to the GitHub remote, so the
# tag GitHub creates on publish lands on the commit that was built.
publish-preflight:
	@if [ -n "$$(git status --porcelain --untracked-files=no)" ]; then \
	  echo "working tree is not clean; commit first"; git status --short --untracked-files=no; exit 2; fi
	@remote="$$(git remote -v | awk '/github.com[:\/]$(subst /,\/,$(shell plutil -extract TactionUpdateRepo raw Resources/Taction-Info.plist))(\.git)? \(push\)/ {print $$1; exit}')"; \
	if [ -z "$$remote" ]; then echo "no git remote points at github.com/$(shell plutil -extract TactionUpdateRepo raw Resources/Taction-Info.plist)"; exit 2; fi; \
	git fetch -q "$$remote"; \
	if [ "$$(git rev-parse HEAD)" != "$$(git rev-parse "$$remote/main")" ]; then \
	  echo "HEAD is not what $$remote/main has; push first (git push $$remote main)"; exit 2; fi
	@echo "publishing v$(VERSION) from $$(git rev-parse --short HEAD)"

publish: publish-preflight release
	scripts/publish.sh $(if $(filter 1,$(DRY_RUN)),--dry-run,)

publish-upload:
	scripts/publish.sh $(if $(filter 1,$(DRY_RUN)),--dry-run,)

run: app-native
	open $(APP)

install: app-native
	@dest=/Applications; [ -w /Applications ] || { dest="$$HOME/Applications"; mkdir -p "$$dest"; }; \
	pkill -x Taction 2>/dev/null || true; \
	rm -rf "$$dest/Taction.app"; \
	cp -R $(APP) "$$dest/Taction.app"; \
	echo "installed $$dest/Taction.app"; \
	open "$$dest/Taction.app"

replay: build
	@for g in $(SYNTHETIC); do \
	  printf '%-26s ' "$$g"; \
	  .build/debug/taction-replay --synthetic $$g | grep -- '->' | grep -v -E 'moveTo|scroll changed|momentumChanged' \
	    | sed -E 's/^ *[0-9.]+ +-> //; s/ at \(.*//; s/ dx=.*//' | tr '\n' ',' | sed 's/,$$//'; \
	  echo "  | $$(.build/debug/taction-replay --synthetic $$g | tail -1 | sed -E 's/.*final state //')"; \
	done
	@echo "real capture:"; .build/debug/taction-replay Tests/TactionKitTests/Fixtures/real-session-2026-09-15.bin | tail -1

icon:
	rm -f Resources/AppIcon.icns
	scripts/bundle.sh --native

version:
	@echo $(VERSION)

clean:
	rm -rf .build dist

help:
	@sed -n '2,15p' Makefile | sed 's/^# \{0,1\}//'
