# herdr-remote build orchestration.
#
#   make install      build Herdi.app and copy it into /Applications  (the one install target)
#   make app          build herdi-mac/dist/Herdi.app                  (alias: make bundle)
#   make dmg          build the distributable .dmg
#   make relay        run the WebSocket relay
#   make help         list every target
#
# The Python components use PEP 723 inline metadata, so `uv run` resolves their dependencies on the
# fly — there is nothing to install first.

APP_NAME   := Herdi
MAC_DIR    := herdi-mac
IOS_DIR    := herdi-ios
RELAY_DIR  := relay
APP_BUNDLE := $(MAC_DIR)/dist/$(APP_NAME).app

# Single source of truth for the version: the VERSION file at the repo root. build.sh/dmg.sh read
# the same file when run directly, and `scripts/bump-version.cjs` is the only thing that writes it
# (semantic-release calls it). Override for a one-off build with `make dmg VERSION=0.7.0`.
VERSION ?= $(shell cat VERSION 2>/dev/null || echo 0.0.0)
export VERSION

UNAME_S := $(shell uname -s)
UV      := uv

.DEFAULT_GOAL := help

.PHONY: help app bundle dmg install uninstall run relay start tui telegram plugin ios web check version-check clean distclean

help:
	@echo "herdr-remote — v$(VERSION)"
	@echo ""
	@echo "  macOS app"
	@echo "    make install      build the app and install it to /Applications"
	@echo "    make app          build $(APP_BUNDLE)  (alias: bundle)"
	@echo "    make dmg          build $(MAC_DIR)/dist/$(APP_NAME)-$(VERSION).dmg"
	@echo "    make run          build and launch from dist/ (no install)"
	@echo "    make uninstall    remove /Applications/$(APP_NAME).app"
	@echo ""
	@echo "  relay & clients"
	@echo "    make relay        run the relay on :8375"
	@echo "    make start        run relay/start.sh (relay + cloudflared tunnel)"
	@echo "    make tui          run the terminal dashboard"
	@echo "    make telegram     run the Telegram bot (needs HERDR_TG_TOKEN, HERDR_TG_CHAT_ID)"
	@echo "    make web          serve web/ on :8080 for standalone testing"
	@echo "    make plugin       register the local herdr push plugin"
	@echo ""
	@echo "  other"
	@echo "    make ios          regenerate the Xcode project (XcodeGen)"
	@echo "    make check        compile the Swift app, syntax-check Python and shell"
	@echo "    make clean        remove build output"
	@echo ""
	@echo "  Override the version with: make dmg VERSION=0.7.0"

# --- macOS app ---------------------------------------------------------------

# build.sh runs `swift build -c release`, assembles Contents/, writes Info.plist and ad-hoc signs.
app:
	@if [ "$(UNAME_S)" != "Darwin" ]; then echo "make app: macOS only (host is $(UNAME_S))"; exit 1; fi
	@cd $(MAC_DIR) && ./build.sh

bundle: app

# Wraps the .app in a DMG with an /Applications symlink. dmg.sh builds the app first if missing.
dmg:
	@if [ "$(UNAME_S)" != "Darwin" ]; then echo "make dmg: macOS only (host is $(UNAME_S))"; exit 1; fi
	@cd $(MAC_DIR) && ./dmg.sh

# Quits a running copy before replacing it: macOS keeps the old binary running off the open file
# handle otherwise, so the "new" install would not actually take effect until the next launch.
install: app
	@set -e; \
	if [ "$(UNAME_S)" != "Darwin" ]; then echo "make install: macOS only (host is $(UNAME_S))"; exit 1; fi; \
	if [ ! -d "$(APP_BUNDLE)" ]; then echo "no bundle at $(APP_BUNDLE) — run 'make app' first"; exit 1; fi; \
	if pgrep -x "$(APP_NAME)" >/dev/null 2>&1; then \
	  echo "▸ Quitting running $(APP_NAME)…"; \
	  osascript -e 'tell application "$(APP_NAME)" to quit' >/dev/null 2>&1 || true; \
	  for i in $$(seq 1 20); do pgrep -x "$(APP_NAME)" >/dev/null 2>&1 || break; sleep 0.25; done; \
	  pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true; \
	  for i in $$(seq 1 8); do pgrep -x "$(APP_NAME)" >/dev/null 2>&1 || break; sleep 0.25; done; \
	fi; \
	echo "▸ Installing $(APP_BUNDLE) → /Applications/$(APP_NAME).app"; \
	rm -rf "/Applications/$(APP_NAME).app"; \
	cp -R "$(APP_BUNDLE)" /Applications/; \
	echo "✓ Installed /Applications/$(APP_NAME).app (v$(VERSION))"; \
	echo ""; \
	echo "  To reach a relay on a LAN or Tailscale address, approve $(APP_NAME) under"; \
	echo "  System Settings ▸ Privacy & Security ▸ Local Network — macOS blocks those"; \
	echo "  connections silently otherwise, and replacing the bundle can reset the grant."

uninstall:
	@if [ ! -d "/Applications/$(APP_NAME).app" ]; then echo "/Applications/$(APP_NAME).app is not installed"; exit 0; fi
	@pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true
	@rm -rf "/Applications/$(APP_NAME).app"
	@echo "✓ Removed /Applications/$(APP_NAME).app"

# Launch from dist/ — test a build without touching /Applications.
run: app
	@echo "▸ Launching $(APP_BUNDLE)"
	@open "$(APP_BUNDLE)"

# --- relay & clients ---------------------------------------------------------

relay:
	$(UV) run $(RELAY_DIR)/herdr_relay.py

# Relay plus a cloudflared tunnel. Set HERDR_TUNNEL_MODE=none for a private-network-only run.
start:
	@$(RELAY_DIR)/start.sh

tui:
	$(UV) run $(RELAY_DIR)/herdr_tui.py

telegram:
	@if [ -z "$$HERDR_TG_TOKEN" ] || [ -z "$$HERDR_TG_CHAT_ID" ]; then \
	  echo "set HERDR_TG_TOKEN and HERDR_TG_CHAT_ID first"; exit 1; \
	fi
	$(UV) run $(RELAY_DIR)/herdr_telegram.py

# Normally unnecessary: the relay already serves this app on :8375, and a page opened from the relay
# auto-connects back to it. Useful only for editing web/ without a relay running.
web:
	@echo "▸ Serving web/ on :8080 — the relay serves this same app on :8375"
	@cd web && python3 -m http.server 8080

# Registers the bundled UDP push plugin with herdr, so status changes arrive immediately instead of
# waiting for the next 2s poll.
plugin:
	herdr plugin link $(RELAY_DIR)/

# --- other -------------------------------------------------------------------

# herdi-ios is an XcodeGen project: project.yml is the source, Herdi.xcodeproj is generated.
ios:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found — brew install xcodegen"; exit 1; }
	@cd $(IOS_DIR) && xcodegen generate

check:
	@if [ "$(UNAME_S)" = "Darwin" ]; then \
	  echo "▸ swift build"; (cd $(MAC_DIR) && swift build) || exit 1; \
	else \
	  echo "▸ skipping swift build (host is $(UNAME_S))"; \
	fi
	@echo "▸ python syntax"
	@for f in $(RELAY_DIR)/*.py; do python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$$f" || exit 1; done
	@echo "▸ shell syntax"
	@for f in $(RELAY_DIR)/start.sh $(MAC_DIR)/build.sh $(MAC_DIR)/dmg.sh; do bash -n "$$f" || exit 1; done
	@$(MAKE) --no-print-directory version-check
	@echo "✓ checks passed"

# Catch a hand-edited manifest drifting from VERSION. Nothing syncs these at build time — the bump
# script writes them together at release time — so drift would otherwise ship silently.
version-check:
	@echo "▸ version consistency (VERSION = $(VERSION))"
	@fail=0; \
	for f in herdr-plugin.toml $(RELAY_DIR)/herdr-plugin.toml; do \
	  got=$$(sed -nE 's/^version = "(.*)"/\1/p' "$$f" | head -1); \
	  if [ "$$got" != "$(VERSION)" ]; then \
	    echo "  ✗ $$f has $$got, expected $(VERSION)"; fail=1; \
	  fi; \
	done; \
	if [ "$$fail" = "1" ]; then \
	  echo "  run: node scripts/bump-version.cjs $(VERSION)"; exit 1; \
	fi; \
	echo "  ✓ manifests match VERSION"

clean:
	rm -rf $(MAC_DIR)/.build $(MAC_DIR)/dist
	find $(RELAY_DIR) -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "✓ cleaned build output"

# Also drops the generated Xcode project (regenerate with `make ios`).
distclean: clean
	rm -rf $(IOS_DIR)/$(APP_NAME).xcodeproj
	@echo "✓ cleaned generated project files"
