# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

herdr-remote is a multi-client system for monitoring and approving [herdr](https://herdr.dev) AI agents remotely. It provides a WebSocket relay that bridges the herdr CLI with phone, desktop, Telegram, and terminal clients.

## Architecture

```
Clients (web/mac/ios/telegram/tui)
        │ WebSocket
        ▼
   relay (:8375)  ←── Cloudflare tunnel (public wss://)
        │
        ▼
   herdr CLI (local or SSH to HERDR_REMOTES)
```

The relay (`relay/herdr_relay.py`) is the central hub: it polls herdr for agent state, accepts push events via HTTP POST and UDP, and broadcasts to connected WebSocket clients. Clients send `respond`, `read_pane`, `send_keys`, and `send_text` messages back through the relay to control agents.

## Components

| Path | What | Language |
|------|------|----------|
| `relay/herdr_relay.py` | WebSocket+HTTP relay server | Python (websockets, zeroconf) |
| `relay/herdr_telegram.py` | Telegram bot client | Python (python-telegram-bot) |
| `relay/herdr_tui.py` | Terminal TUI client | Python (textual) |
| `web/index.html` | Mobile/desktop web app (single file) | HTML/CSS/JS |
| `demo-worker/` | Cloudflare Worker mock relay for demos | JS |
| `herdi-mac/` | macOS menu bar app | Swift (SPM) |
| `herdi-ios/` | iOS app with widgets + Live Activities | Swift (XcodeGen) |

## Running Components

Python scripts use [PEP 723 inline metadata](https://peps.python.org/pep-0723/) — `uv run` installs deps. Nothing to install first.

`make` (no args) lists every target. Preferred entry points:

| Target | Runs |
|--------|------|
| `make install` | build `Herdi.app` → copy to `/Applications` (quits running copy first) |
| `make app` / `make bundle` | `herdi-mac/build.sh` → `herdi-mac/dist/Herdi.app` |
| `make dmg` | `herdi-mac/dmg.sh` → `dist/Herdi-$(VERSION).dmg` |
| `make run` | build + launch from `dist/`, no install |
| `make relay` | `uv run relay/herdr_relay.py` |
| `make start` | `relay/start.sh` (relay + cloudflared) |
| `make tui` / `make telegram` | TUI / Telegram bot |
| `make ios` | `xcodegen generate` in `herdi-ios/` |
| `make check` | `swift build` + Python/shell syntax |
| `make clean` / `make distclean` | drop build output / also generated `.xcodeproj` |

Version lives in the Makefile (`VERSION ?= 0.6.3`), exported to both shell scripts. Override: `make dmg VERSION=0.7.0`.

Raw equivalents:

```bash
uv run relay/herdr_relay.py                    # relay
relay/start.sh                                 # relay + tunnel
HERDR_TG_TOKEN=… HERDR_TG_CHAT_ID=… uv run relay/herdr_telegram.py
uv run relay/herdr_tui.py                      # TUI
cd demo-worker && npx wrangler dev             # demo worker
cd herdi-mac && ./build.sh                     # macOS app
cd herdi-ios && xcodegen generate              # iOS project
```

## Key Environment Variables

| Variable | Purpose |
|----------|---------|
| `HERDR_RELAY_PORT` | Relay WebSocket port (default: 8375) |
| `HERDR_RELAY_TOKEN` | Optional shared secret for auth |
| `HERDR_REMOTES` | Comma-separated SSH targets to poll |
| `HERDR_BIN` | Path to herdr binary (default: `/opt/homebrew/bin/herdr`) |
| `HERDR_RELAY` | Relay URL used by clients (default: `ws://127.0.0.1:8375`) |
| `HERDR_TUNNEL_MODE` | `temp` (default), `named`, or `none` to skip cloudflared entirely |
| `HERDR_NTFY_TOPIC` | Enables opt-in ntfy notifications; see `relay/.env.example` for the rest |

## Web App

The web app is a single self-contained HTML file (`web/index.html`) with inline CSS and JS — no build step. It's deployed to Cloudflare Pages. It includes 11 color themes, a mobile terminal keyboard, PWA support, and agent-icon detection.

## WebSocket Protocol

Messages are JSON with a `type` field:

**Server → Client:** `agents` (state list), `blocked` (approval prompt), `pane_content` (terminal read)

**Client → Server:** `respond` (send text to agent), `read_pane` (request terminal content), `send_keys` (send key sequences), `send_text` (raw text without newline)

## Deployment

- Web app: Cloudflare Pages (push to main deploys `web/`)
- Demo worker: `npx wrangler deploy` from `demo-worker/`
- macOS app: `make dmg` → `herdi-mac/dist/Herdi-$(VERSION).dmg` for release; `make install` for local
