# Taction build entry points. Everything here delegates to swift build and the scripts/ helpers.
#
#   make              debug build of every target
#   make test         unit tests (Xcode toolchain, via scripts/test.sh)
#   make app          dist/Taction.app for arm64 and x86_64, signed (what you distribute)
#   make app-native   dist/Taction.app for this Mac's architecture only (faster; local testing)
#   make release      dist/Taction-<version>.zip and .dmg (notarized when TACTION_NOTARY_PROFILE is set)
#   make run          build a native app bundle and open it
#   make install      build native, copy dist/Taction.app into /Applications (or ~/Applications), open it
#   make replay       run every synthetic gesture through the pipeline and print the actions
#   make icon         regenerate Resources/AppIcon.icns
#   make clean        remove build products
#
# Variables: VERSION (read from the VERSION file), TACTION_SIGN_IDENTITY, TACTION_NOTARY_PROFILE.

SHELL := /bin/bash
.DEFAULT_GOAL := build

VERSION := $(shell tr -d '[:space:]' < VERSION)
APP := dist/Taction.app
ZIP := dist/Taction-$(VERSION).zip
DMG := dist/Taction-$(VERSION).dmg
SYNTHETIC := tap slow-press long-press drag two-finger-tap two-finger-scroll flick pinch-out pinch-in \
             three-finger-swipe-left three-finger-swipe-up palm edge late-second-finger

.PHONY: build test app app-native universal release run install replay icon clean version help

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
