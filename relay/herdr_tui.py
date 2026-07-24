#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["textual>=3.0.0", "websockets>=14.0"]
# ///
"""herdr-remote-tui: terminal dashboard for herdr agents. Connects to herdr-remote-relay via WebSocket."""
import asyncio, json, os, sys
from urllib.parse import urlsplit, urlunsplit

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import Header, Footer, Static, Input, Button, Label
from textual.reactive import reactive
from textual.message import Message
from textual import work

AUTH_TOKEN = os.environ.get("HERDR_RELAY_TOKEN", "")


def relay_url() -> str:
    """Normalize HERDR_RELAY into a ws:// or wss:// URL, appending ?token= if configured.

    Accepts bare hosts ("127.0.0.1:8375", "my-mac.ts.net") and http(s):// URLs so the same
    value works for the web app and the TUI.
    """
    raw = (os.environ.get("HERDR_RELAY") or "ws://127.0.0.1:8375").strip()
    if "://" not in raw:
        raw = "ws://" + raw
    parts = urlsplit(raw)
    scheme = {"http": "ws", "https": "wss"}.get(parts.scheme, parts.scheme)
    netloc = parts.netloc
    if ":" not in netloc.rsplit("]", 1)[-1]:  # no port, and not a bare IPv6 literal
        netloc = f"{netloc}:{os.environ.get('HERDR_RELAY_PORT', '8375')}"
    query = parts.query
    if AUTH_TOKEN and "token=" not in query:
        query = f"{query}&token={AUTH_TOKEN}" if query else f"token={AUTH_TOKEN}"
    return urlunsplit((scheme, netloc, parts.path or "/", query, ""))


RELAY_WS = relay_url()
RELAY_DISPLAY = RELAY_WS.split("?")[0]  # keep the token out of the status bar


class AgentCard(Static):
    """A single agent card."""

    def __init__(self, agent: dict, **kw):
        super().__init__(**kw)
        self.agent = agent

    def compose(self) -> ComposeResult:
        status = self.agent.get("status", "unknown")
        color = {"blocked": "red", "working": "green", "idle": "dim"}.get(status, "dim")
        name = self.agent.get("agent", "?")
        label = self.agent.get("label", "") or self.agent.get("project", "")
        host = self.agent.get("host", "local")
        where = f" [dim]@{host}[/]" if host and host != "local" else ""
        yield Label(f"[{color}]●[/] {label}/{name}{where} [{color}]{status}[/]", markup=True)


class AgentColumn(Vertical):
    """A kanban column."""

    def __init__(self, title: str, color: str, **kw):
        super().__init__(**kw)
        self.border_title = title
        self.styles.border = ("round", color)
        self.styles.width = "1fr"
        self.styles.height = "100%"
        self.styles.padding = (0, 1)


class Board(Horizontal):
    """The three status columns. Recomposes itself only — never the whole App."""

    agents: reactive[list] = reactive(list, recompose=True)

    def compose(self) -> ComposeResult:
        with AgentColumn("🚨 Blocked", "red", id="col-blocked"):
            for a in self.agents:
                if a.get("status") == "blocked":
                    yield AgentCard(a)
        with AgentColumn("⚡ Working", "green", id="col-working"):
            for a in self.agents:
                if a.get("status") == "working":
                    yield AgentCard(a)
        with AgentColumn("💤 Idle", "grey", id="col-idle"):
            for a in self.agents:
                if a.get("status") in ("idle", "unknown"):
                    yield AgentCard(a)


class ApprovalPanel(Vertical):
    """Shows when an agent is blocked — prompt + buttons."""

    class Responded(Message):
        def __init__(self, pane_id: str, text: str):
            super().__init__()
            self.pane_id = pane_id
            self.text = text

    def __init__(self, agent: dict, **kw):
        super().__init__(**kw)
        self.agent = agent
        self.styles.height = "auto"
        self.styles.border = ("round", "red")
        self.border_title = f"⚠ {agent.get('agent', '?')} — {agent.get('label', '') or agent.get('project', '')}"

    def compose(self) -> ComposeResult:
        prompt = self.agent.get("prompt", "Waiting for input...")
        yield Static(prompt[:400], classes="prompt-text")
        options = self.agent.get("options") or []
        for i, opt in enumerate(options):
            color = "green" if "yes" in opt or "approve" in opt else "red" if "no" in opt or "cancel" in opt else "blue"
            yield Button(opt, id=f"opt-{i}", variant="success" if color == "green" else "error" if color == "red" else "primary")
        yield Input(placeholder="Custom response…", id="custom-input")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        idx = int(event.button.id.split("-")[1])
        options = self.agent.get("options") or []
        if idx < len(options):
            self.post_message(self.Responded(self.agent["pane_id"], options[idx]))

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.value.strip():
            self.post_message(self.Responded(self.agent["pane_id"], event.value.strip()))


class Approvals(VerticalScroll):
    """Stack of approval panels. Recomposes itself only."""

    blocked: reactive[list] = reactive(list, recompose=True)

    def compose(self) -> ComposeResult:
        for a in self.blocked:
            yield ApprovalPanel(a)


class HerdrRemoteTUI(App):
    CSS = """
    #board { height: 1fr; }
    #approvals { height: auto; max-height: 40%; }
    .prompt-text { max-height: 6; overflow-y: auto; color: $text-muted; }
    #status-bar { height: 1; background: $surface; padding: 0 1; }
    """

    BINDINGS = [
        ("q", "quit", "Quit"),
        ("r", "reconnect", "Reconnect"),
        ("1", "approve_first", "Approve first"),
    ]

    def __init__(self):
        super().__init__()
        self._ws = None
        self._agents: list[dict] = []
        self._blocked: list[dict] = []

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Board(id="board")
        yield Approvals(id="approvals")
        yield Static("[yellow]●[/] Connecting…", id="status-bar", markup=True)
        yield Footer()

    def on_mount(self) -> None:
        self.title = "herdr-remote"
        self.sub_title = "agent dashboard"
        self.connect_relay()

    # --- rendering -------------------------------------------------------

    def _set_status(self, text: str) -> None:
        try:
            self.query_one("#status-bar", Static).update(text)
        except Exception:
            pass  # not mounted yet / shutting down

    def _push_agents(self) -> None:
        try:
            self.query_one("#board", Board).agents = list(self._agents)
        except Exception:
            pass

    def _push_blocked(self) -> None:
        try:
            self.query_one("#approvals", Approvals).blocked = list(self._blocked)
        except Exception:
            pass

    # --- relay connection ------------------------------------------------

    @work(exclusive=True, thread=False)
    async def connect_relay(self) -> None:
        import websockets

        backoff = 1.0
        while True:
            try:
                self._set_status(f"[yellow]●[/] Connecting to {RELAY_DISPLAY}…")
                async with websockets.connect(
                    RELAY_WS,
                    open_timeout=10,
                    ping_interval=20,
                    ping_timeout=60,  # the relay's herdr/ssh calls can stall its event loop
                    max_size=4 * 1024 * 1024,
                ) as ws:
                    self._ws = ws
                    backoff = 1.0
                    self._set_status(f"[green]●[/] Connected to {RELAY_DISPLAY}")
                    async for raw in ws:
                        try:
                            msg = json.loads(raw)
                        except json.JSONDecodeError:
                            continue
                        self._handle_msg(msg)
                self._ws = None
                self._set_status(f"[red]●[/] Relay closed the connection — retrying in {backoff:.0f}s")
            except asyncio.CancelledError:
                self._ws = None
                raise
            except Exception as e:
                self._ws = None
                detail = str(e)[:60] or RELAY_DISPLAY
                self._set_status(f"[red]●[/] {type(e).__name__}: {detail} — retrying in {backoff:.0f}s")
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 15.0)

    def _handle_msg(self, msg: dict) -> None:
        msg_type = msg.get("type")
        if msg_type == "agents":
            incoming = msg.get("agents", [])
            # poll_loop() sends the full list; event_push() sends a single-agent delta with a
            # reduced payload. Merge deltas so one never wipes the board.
            if len(incoming) == 1 and self._agents:
                delta = incoming[0]
                pid = delta.get("pane_id")
                for a in self._agents:
                    if a.get("pane_id") == pid:
                        a.update({k: v for k, v in delta.items() if v not in ("", None)})
                        break
                else:
                    self._agents.append(delta)
            else:
                self._agents = incoming
            self._push_agents()
            blocked_ids = {a.get("pane_id") for a in self._agents if a.get("status") == "blocked"}
            kept = [b for b in self._blocked if b.get("pane_id") in blocked_ids]
            if len(kept) != len(self._blocked):
                self._blocked = kept
                self._push_blocked()
        elif msg_type == "blocked":
            pid = msg.get("pane_id")
            self._blocked = [b for b in self._blocked if b.get("pane_id") != pid] + [msg]
            self._push_blocked()
        elif msg_type == "error":
            self.notify(msg.get("message", "relay error"), severity="error")

    # --- actions ---------------------------------------------------------

    def on_approval_panel_responded(self, event: ApprovalPanel.Responded) -> None:
        self._send_response(event.pane_id, event.text)

    @work(exclusive=False, thread=False)
    async def _send(self, payload: dict) -> None:
        ws = self._ws
        if ws is None:
            self.notify("Not connected to relay", severity="error")
            return
        try:
            await ws.send(json.dumps(payload))
        except Exception as e:
            self.notify(f"Send failed: {type(e).__name__}", severity="error")

    def _send_response(self, pane_id: str, text: str) -> None:
        self._send({"type": "respond", "pane_id": pane_id, "text": text})
        self._blocked = [b for b in self._blocked if b.get("pane_id") != pane_id]
        self._push_blocked()

    def action_reconnect(self) -> None:
        self.connect_relay()

    def action_approve_first(self) -> None:
        if self._blocked:
            a = self._blocked[0]
            options = a.get("options") or ["yes, single permission"]
            self._send_response(a["pane_id"], options[0])


if __name__ == "__main__":
    HerdrRemoteTUI().run()
