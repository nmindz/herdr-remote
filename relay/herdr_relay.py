#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["websockets>=14.0", "zeroconf>=0.80.0", "pywebpush>=2.0.0", "py-vapid>=1.9.0"]
# ///
"""herdr-remote relay — polls herdr, accepts push events (HTTP POST + WebSocket + UDP), broadcasts to clients."""
import asyncio, json, logging, os, re, shutil, signal, socket, subprocess, time

try:
    from websockets.asyncio.server import serve
except ImportError:
    from websockets.server import serve
from websockets.exceptions import ConnectionClosedError, ConnectionClosedOK

from logging.handlers import RotatingFileHandler
import sys

def _get_log_dir():
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Logs/herdr-remote")
    if os.path.isdir("/var/log") and os.access("/var/log", os.W_OK):
        return "/var/log/herdr-remote"
    return os.path.expanduser("~/.local/state/herdr-remote/log")

LOG_DIR = os.environ.get("HERDR_LOG_DIR", _get_log_dir())
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "relay.log")
AUDIT_FILE = os.path.join(LOG_DIR, "audit.log")

_formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
_file_handler = RotatingFileHandler(LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=3)
_file_handler.setFormatter(_formatter)
_console_handler = logging.StreamHandler()
_console_handler.setFormatter(_formatter)

log = logging.getLogger("herdr-relay")
log.setLevel(logging.INFO)
log.addHandler(_file_handler)
log.addHandler(_console_handler)
logging.getLogger("websockets").setLevel(logging.WARNING)

HERDR = os.environ.get("HERDR_BIN") or shutil.which("herdr") or "/opt/homebrew/bin/herdr"
WS_PORT = int(os.environ.get("HERDR_RELAY_PORT", "8375"))
POLL_INTERVAL = 2
AUTH_TOKEN = os.environ.get("HERDR_RELAY_TOKEN", "")  # Optional: shared secret for relay auth

# VAPID Web Push — the default notification path
VAPID_PUBLIC_KEY = os.environ.get("HERDR_VAPID_PUBLIC", "")
VAPID_PRIVATE_KEY = os.environ.get("HERDR_VAPID_PRIVATE", "")
VAPID_SUBJECT = os.environ.get("HERDR_VAPID_SUBJECT", "mailto:herdr@localhost")
push_subscriptions = []  # list of PushSubscription dicts
PUSH_SUBS_FILE = os.path.join(LOG_DIR, "push_subs.json")

# ntfy (https://ntfy.sh) — opt-in, additive to Web Push. Setting a topic is all it takes.
# Unlike Web Push this needs no VAPID keys, no service worker and no HTTPS on the relay, so it works
# when the relay is only reachable over plain http on a private network.
NTFY_TOPIC = os.environ.get("HERDR_NTFY_TOPIC", "").strip()
NTFY_SERVER = os.environ.get("HERDR_NTFY_SERVER", "https://ntfy.sh").strip().rstrip("/")
NTFY_TOKEN = os.environ.get("HERDR_NTFY_TOKEN", "").strip()
NTFY_USER = os.environ.get("HERDR_NTFY_USER", "").strip()
NTFY_PASSWORD = os.environ.get("HERDR_NTFY_PASSWORD", "")
NTFY_PRIORITY = os.environ.get("HERDR_NTFY_PRIORITY", "high").strip()
NTFY_TAGS = os.environ.get("HERDR_NTFY_TAGS", "sheep").strip()
NTFY_TITLE_PREFIX = os.environ.get("HERDR_NTFY_TITLE_PREFIX", "").strip()
# Public/tailnet base URL of the web app, used to make notifications tappable. Without it the
# notification still arrives, just without a click target.
NTFY_CLICK_BASE = os.environ.get("HERDR_NTFY_CLICK_BASE", "").strip().rstrip("/")
# ntfy has no notification-replace primitive, so "agent unblocked" would be pure noise for most
# people. Off unless asked for.
NTFY_NOTIFY_RESOLVED = os.environ.get("HERDR_NTFY_NOTIFY_RESOLVED", "").lower() in ("1", "true", "yes")
NTFY_RESOLVED_PRIORITY = os.environ.get("HERDR_NTFY_RESOLVED_PRIORITY", "low").strip()
NTFY_TIMEOUT = float(os.environ.get("HERDR_NTFY_TIMEOUT", "5"))
NTFY_ENABLED = bool(NTFY_TOPIC)

# Remote hosts: comma-separated SSH targets
REMOTES = [r.strip() for r in os.environ.get("HERDR_REMOTES", "").split(",") if r.strip()]

TOOL_OPTIONS = ["yes, single permission", "trust, always allow", "no (tab to edit)"]
SUBAGENT_OPTIONS = ["approve all pending", "configure individually", "exit (cancel subagents)"]
CHROME_RE = re.compile(
    r"^[\s─━═_—│|◔◑◕●\s]+$"
    r"|Kiro\s[·•]"
    r"|esc to cancel"
    r"|type to queue"
    r"|^\s*[◔◑◕●]\s+(Shell|Bash)"
)

clients = set()
last_statuses = {}
event_queue = asyncio.Queue()
pane_remote_map = {}
known_panes = set()

SAFE_RESPONSES = {"y", "n", "a", "yes", "no", "trust", "yes, single permission", "trust, always allow", "no (tab to edit)", "approve all pending", "configure individually", "exit (cancel subagents)"}
SAFE_KEYS = {"y", "n", "a", "Enter", "Tab", "Escape", "C-c", "Up", "Down", "Left", "Right", "BSpace"}

# --- Audit logging ---
_audit_handler = RotatingFileHandler(AUDIT_FILE, maxBytes=5 * 1024 * 1024, backupCount=3)
_audit_handler.setFormatter(logging.Formatter("%(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S"))
audit_log = logging.getLogger("herdr-audit")
audit_log.setLevel(logging.INFO)
audit_log.addHandler(_audit_handler)
audit_log.propagate = False


def audit(action: str, ip: str, device: str, pane_id: str, detail: str = ""):
    """Append a write action to the audit log as structured JSONL."""
    import datetime
    entry = {
        "ts": datetime.datetime.utcnow().isoformat() + "Z",
        "action": action,
        "paneId": pane_id,
        "ip": ip,
        "device": device,
    }
    if detail:
        entry["detail"] = detail[:120]  # truncate like collie
    audit_log.info(json.dumps(entry, separators=(",", ":")))


# --- Web Push helpers ---
def _load_push_subs():
    global push_subscriptions
    if os.path.isfile(PUSH_SUBS_FILE):
        try:
            with open(PUSH_SUBS_FILE) as f:
                push_subscriptions = json.load(f)
        except Exception:
            push_subscriptions = []


def _save_push_subs():
    with open(PUSH_SUBS_FILE, "w") as f:
        json.dump(push_subscriptions, f)


async def send_web_push(title: str, body: str, url: str = "/", clear: bool = False):
    """Send push notification to all registered subscriptions.
    
    Uses collapse topic + TTL so offline devices get only the latest.
    If clear=True, sends a clear instruction instead of showing a notification.
    """
    if not VAPID_PUBLIC_KEY or not VAPID_PRIVATE_KEY:
        return
    try:
        from pywebpush import webpush, WebPushException
    except ImportError:
        log.warning("pywebpush not installed, skipping push")
        return
    if clear:
        payload = json.dumps({"type": "clear", "tag": "herdr-blocked"})
    else:
        payload = json.dumps({"title": title, "body": body, "url": url})
    headers = {"Topic": "herdr-herd", "TTL": "21600"}  # 6h TTL, collapse key
    dead = []
    for i, sub in enumerate(push_subscriptions):
        try:
            webpush(
                subscription_info=sub,
                data=payload,
                vapid_private_key=VAPID_PRIVATE_KEY,
                vapid_claims={"sub": VAPID_SUBJECT},
                headers=headers,
            )
        except Exception as e:
            log.warning("Push failed for sub %d: %s", i, e)
            if "410" in str(e) or "404" in str(e):
                dead.append(i)
    if dead:
        for i in reversed(dead):
            push_subscriptions.pop(i)
        _save_push_subs()

_load_push_subs()


# --- ntfy (opt-in) ---
def _ntfy_post_blocking(body: bytes, headers: dict):
    import urllib.request
    req = urllib.request.Request(f"{NTFY_SERVER}/{NTFY_TOPIC}", data=body, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    if NTFY_TOKEN:
        req.add_header("Authorization", f"Bearer {NTFY_TOKEN}")
    elif NTFY_USER:
        import base64
        cred = base64.b64encode(f"{NTFY_USER}:{NTFY_PASSWORD}".encode()).decode()
        req.add_header("Authorization", f"Basic {cred}")
    with urllib.request.urlopen(req, timeout=NTFY_TIMEOUT) as r:
        return r.status


async def send_ntfy(title: str, body: str, *, priority: str = "", tags: str = "", click: str = ""):
    """Publish one notification to ntfy. No-op unless HERDR_NTFY_TOPIC is set.

    Runs in a thread so a slow or unreachable ntfy server cannot stall the relay's event loop, and
    never raises: a failed notification must not break the poll cycle.
    """
    if not NTFY_ENABLED:
        return
    full_title = f"{NTFY_TITLE_PREFIX} {title}".strip() if NTFY_TITLE_PREFIX else title
    headers = {"Content-Type": "text/plain; charset=utf-8"}
    if full_title:
        # ntfy headers must be latin-1 safe; emoji belong in X-Tags, not the title.
        headers["X-Title"] = full_title.encode("latin-1", "replace").decode("latin-1")
    if priority or NTFY_PRIORITY:
        headers["X-Priority"] = priority or NTFY_PRIORITY
    if tags or NTFY_TAGS:
        headers["X-Tags"] = tags or NTFY_TAGS
    if click:
        headers["X-Click"] = click
    try:
        status = await asyncio.to_thread(_ntfy_post_blocking, body.encode("utf-8"), headers)
        log.debug("ntfy published (%s) to %s/%s", status, NTFY_SERVER, NTFY_TOPIC)
    except Exception as e:
        log.warning("ntfy publish failed (%s/%s): %s", NTFY_SERVER, NTFY_TOPIC, e)


def _click_url(pane_id: str) -> str:
    return f"{NTFY_CLICK_BASE}/?pane={pane_id}" if NTFY_CLICK_BASE else ""


_BOX_CHARS = "─━═│┃┆┇┊┋┌┏┐┓└┗┘┛├┣┤┫┬┳┴┻┼╋╭╮╯╰╱╲╳▏▕█▌▐░▒▓"
_BOX_TRANS = str.maketrans({c: " " for c in _BOX_CHARS})


def notification_body(text: str, limit: int = 350) -> str:
    """Flatten raw pane output into something readable on a lock screen.

    read_pane() only drops lines made *entirely* of box-drawing characters, so TUI table rows still
    arrive full of │ and ─. On a phone that is unreadable, so strip the glyphs and collapse runs of
    whitespace, keeping the last lines — the prompt an agent is waiting on is at the bottom.
    """
    lines = []
    for raw in text.translate(_BOX_TRANS).splitlines():
        cleaned = " ".join(raw.split())
        if cleaned:
            lines.append(cleaned)
    body = "\n".join(lines[-8:]).strip()
    return body[:limit]


# --- Notification dispatch ---
async def notify_blocked(project: str, agent: str, host: str, pane_id: str, prompt: str):
    """Fan out a 'needs you' notification over every configured channel."""
    await send_web_push(
        title=f"🐑 {project} blocked",
        body=prompt[:120],
        url=f"/?pane={pane_id}",
    )
    where = project or pane_id
    if host and host != "local":
        where = f"{where} @{host}"
    await send_ntfy(
        title=f"{where} needs you",
        body=(notification_body(prompt) or f"{agent or 'agent'} is waiting for input"),
        click=_click_url(pane_id),
    )


async def notify_resolved(project: str, pane_id: str):
    await send_web_push("", "", clear=True)
    if NTFY_NOTIFY_RESOLVED:
        await send_ntfy(
            title=f"{project or pane_id} unblocked",
            body="Agent is running again.",
            priority=NTFY_RESOLVED_PRIORITY,
            tags="white_check_mark",
            click=_click_url(pane_id),
        )


def _run_herdr_blocking(*args, remote=None):
    try:
        if remote:
            cmd = ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", remote, HERDR, *args]
        else:
            cmd = [HERDR, *args]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return r.stdout.strip()
    except Exception:
        return ""


async def run_herdr(*args, remote=None):
    """Run herdr off the event loop.

    subprocess.run blocks the calling thread. Called directly from a coroutine it would freeze the
    single-threaded event loop for up to its 15s timeout — long enough for websockets' keepalive to
    time out and drop every connected client at once (an unreachable SSH remote does this reliably).
    """
    return await asyncio.to_thread(_run_herdr_blocking, *args, remote=remote)


async def get_agents_from_host(remote=None):
    raw = await run_herdr("pane", "list", remote=remote)
    host_label = remote or "local"
    try:
        data = json.loads(raw)
        panes = data.get("result", {}).get("panes", [])
        return [
            {
                "pane_id": p["pane_id"],
                "agent": p.get("agent", ""),
                "label": p.get("label", ""),
                "status": p.get("agent_status", "unknown"),
                "cwd": p.get("cwd", ""),
                "project": os.path.basename(p.get("cwd", "")),
                "host": host_label,
                "remote": remote,
                "workspace_id": p.get("workspace_id", ""),
                "tab_id": p.get("tab_id", ""),
            }
            for p in panes if p.get("agent")
        ]
    except (json.JSONDecodeError, KeyError):
        return []


async def get_all_agents():
    # Poll every host concurrently: serially, one unreachable remote would add its full timeout to
    # every poll cycle and stall the whole relay.
    results = await asyncio.gather(
        get_agents_from_host(remote=None),
        *(get_agents_from_host(remote=r) for r in REMOTES),
        return_exceptions=True,
    )
    agents = []
    for host, res in zip(["local"] + REMOTES, results):
        if isinstance(res, BaseException):
            log.warning("Polling %s failed: %s", host, res)
            continue
        agents.extend(res)
    return agents


async def read_pane(pane_id, remote=None):
    raw = await run_herdr("pane", "read", pane_id, "--lines", "50", "--source", "recent", remote=remote)
    lines = [l for l in raw.splitlines() if l.strip() and not CHROME_RE.search(l)]
    return "\n".join(lines[-20:])


def detect_options(text):
    lower = text.lower()
    if "yes, single permission" in lower:
        return TOOL_OPTIONS
    if "approve all pending" in lower:
        return SUBAGENT_OPTIONS
    return None


async def broadcast(msg):
    data = json.dumps(msg)
    dead = set()
    for ws in list(clients):
        try:
            await ws.send(data)
        except (ConnectionClosedError, ConnectionClosedOK):
            dead.add(ws)
        except Exception:
            dead.add(ws)
    if dead:
        log.debug("Removed %d dead client(s)", len(dead))
    clients.difference_update(dead)


async def poll_loop():
    while True:
        try:
            await _poll_once()
        except Exception:
            log.exception("poll cycle failed; retrying")
        await asyncio.sleep(POLL_INTERVAL)


async def _poll_once():
        agents = await get_all_agents()
        # Always broadcast (even empty list) so clients stay in sync
        for a in agents:
            pane_remote_map[a["pane_id"]] = a.get("remote")
            known_panes.add(a["pane_id"])
        await broadcast({"type": "agents", "agents": agents})
        for a in agents:
            pid, status = a["pane_id"], a["status"]
            if status == "blocked" and last_statuses.get(pid) != "blocked":
                content = await read_pane(pid, remote=a.get("remote"))
                options = detect_options(content)
                await broadcast({
                    "type": "blocked", "pane_id": pid,
                    "agent": a["agent"], "project": a["project"],
                    "host": a.get("host", "local"),
                    "prompt": content[:500],
                    "options": options or TOOL_OPTIONS
                })
                await notify_blocked(
                    project=a["project"], agent=a["agent"],
                    host=a.get("host", "local"), pane_id=pid, prompt=content,
                )
            # Notify when the agent unblocks (clears the Web Push, optional ntfy note)
            if status != "blocked" and last_statuses.get(pid) == "blocked":
                await notify_resolved(a["project"], pid)
            last_statuses[pid] = status
        # Clean up panes that are no longer reported
        current_pane_ids = {a["pane_id"] for a in agents}
        stale = known_panes - current_pane_ids
        if stale:
            known_panes.difference_update(stale)
            for pid in stale:
                pane_remote_map.pop(pid, None)
                last_statuses.pop(pid, None)


async def event_push():
    while True:
        event = await event_queue.get()
        pane_id = event.get("pane_id", "")
        status = event.get("status", "")
        host = event.get("host", "local")

        if status == "blocked" and pane_id:
            remote = pane_remote_map.get(pane_id)
            if remote or host == "local":
                content = await read_pane(pane_id, remote=remote)
            else:
                content = event.get("prompt", "Agent is blocked")
            options = detect_options(content)
            await broadcast({
                "type": "blocked", "pane_id": pane_id,
                "agent": event.get("agent", ""),
                "project": event.get("project", ""),
                "host": host,
                "prompt": content[:500],
                "options": options or TOOL_OPTIONS
            })
            # Notify from here too — the plugin push is what makes this instant instead of waiting up
            # to POLL_INTERVAL. Record the status so poll_loop does not notify for the same
            # transition a second time.
            if last_statuses.get(pane_id) != "blocked":
                last_statuses[pane_id] = "blocked"
                await notify_blocked(
                    project=event.get("project", ""), agent=event.get("agent", ""),
                    host=host, pane_id=pane_id, prompt=content,
                )

        if pane_id and event.get("type") == "agent_event":
            await broadcast({
                "type": "agents", "agents": [{
                    "pane_id": pane_id,
                    "agent": event.get("agent", ""),
                    "status": status,
                    "cwd": event.get("cwd", ""),
                    "project": event.get("project", ""),
                    "host": host,
                }]
            })


async def process_request(connection, request):
    """Handle HTTP POST on the same port as WebSocket."""
    from websockets.http11 import Response
    from websockets.datastructures import Headers

    # Token auth (if configured)
    if AUTH_TOKEN:
        token = None
        for key, value in request.headers.raw_items():
            if key.lower() == "authorization":
                token = value.replace("Bearer ", "")
        # Also check query param ?token=
        if not token and "token=" in (request.path or ""):
            import urllib.parse
            _, qs = request.path.split("?", 1) if "?" in request.path else (request.path, "")
            params = urllib.parse.parse_qs(qs)
            token = params.get("token", [None])[0]
        if token != AUTH_TOKEN:
            headers = Headers([("Content-Type", "text/plain")])
            return Response(401, "Unauthorized", headers, b"Invalid token\n")

    # Check if this is a WebSocket upgrade
    upgrade = None
    for key, value in request.headers.raw_items():
        if key.lower() == "upgrade":
            upgrade = value.lower()
    if upgrade == "websocket":
        return None  # proceed with WebSocket handshake

    # NOTE: websockets' Request exposes only .path and .headers — there is no .method — so a CORS
    # preflight cannot be distinguished here. Instead of guessing, every response below carries
    # permissive CORS headers.
    path = (request.path or "/").split("?")[0]
    def _headers(*pairs):
        return Headers([*pairs, ("Access-Control-Allow-Origin", "*"),
                        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                        ("Access-Control-Allow-Headers", "Content-Type, Authorization")])

    # Event push (herdr-push POSTs to /push?d=<urlencoded json>). Checked before static routing so
    # it keeps working regardless of the path the plugin is configured with.
    import urllib.parse
    if "?" in (request.path or ""):
        _, qs = request.path.split("?", 1)
        params = urllib.parse.parse_qs(qs)
        if "d" in params:
            try:
                event = json.loads(urllib.parse.unquote(params["d"][0]))
                event_queue.put_nowait(event)
            except Exception:
                log.warning("Dropped malformed push event on %s", path)
                return Response(400, "Bad Request", _headers(), b"bad event\n")
            return Response(200, "OK", _headers(), b"ok\n")

    if path == "/api/vapid-public-key":
        body = json.dumps({"publicKey": VAPID_PUBLIC_KEY}).encode()
        return Response(200, "OK", _headers(("Content-Type", "application/json")), body)

    if path == "/healthz":
        body = json.dumps({
            "ok": True, "clients": len(clients), "agents": len(last_statuses),
            "hosts": ["local"] + REMOTES, "port": WS_PORT,
            # Booleans only — an ntfy topic is a shared secret (anyone who knows it can read and
            # publish to it), so it must never be served to clients.
            "ntfy": NTFY_ENABLED,
            "webPush": bool(VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY),
        }).encode()
        return Response(200, "OK", _headers(("Content-Type", "application/json")), body)

    # Static files out of ../web
    STATIC = {
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/sw.js": ("sw.js", "application/javascript"),
        "/logo.svg": ("logo.svg", "image/svg+xml"),
        # Browsers request /favicon.ico unprompted even when a <link rel=icon> is present.
        "/favicon.ico": ("logo.svg", "image/svg+xml"),
    }
    if path in STATIC:
        name, ctype = STATIC[path]
        web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web")
        file_path = os.path.join(web_dir, name)
        if os.path.isfile(file_path):
            with open(file_path, "rb") as f:
                body = f.read()
            extra = [("Content-Type", ctype), ("Cache-Control", "no-cache")]
            if path == "/sw.js":
                extra.append(("Service-Worker-Allowed", "/"))
            return Response(200, "OK", _headers(*extra), body)
        log.warning("Static file missing: %s", file_path)
        return Response(404, "Not Found", _headers(("Content-Type", "text/plain")), b"not found\n")

    # Anything else really is not found. Returning 200 "ok" here (the previous behaviour) made every
    # missing asset look like a success to browsers and hid real 404s.
    return Response(404, "Not Found", _headers(("Content-Type", "text/plain")), b"not found\n")


async def handle_client(ws):
    remote_addr = ws.remote_address
    ip = remote_addr[0] if remote_addr else "unknown"
    ua = ws.request.headers.get("User-Agent", "unknown") if ws.request else "unknown"
    origin = ws.request.headers.get("Origin", "") if ws.request else ""

    device = "unknown"
    ua_lower = ua.lower()
    if "iphone" in ua_lower or "ipad" in ua_lower:
        device = "iOS"
    elif "android" in ua_lower:
        device = "Android"
    elif "macintosh" in ua_lower or "mac os" in ua_lower:
        device = "macOS"
    elif "windows" in ua_lower:
        device = "Windows"
    elif "linux" in ua_lower:
        device = "Linux"
    elif "telegram" in ua_lower or "bot" in ua_lower:
        device = "bot"
    elif "python" in ua_lower:
        device = "script"

    log.info("Client connected: ip=%s device=%s origin=%s", ip, device, origin or "-")
    clients.add(ws)
    connected_at = time.monotonic()
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            msg_type = msg.get("type")
            if msg_type == "respond":
                pane_id = msg["pane_id"]
                if pane_id not in known_panes:
                    await ws.send(json.dumps({"type": "error", "message": "unknown pane_id"}))
                    continue
                text = msg.get("text", "")
                if text.strip().lower() not in SAFE_RESPONSES:
                    await ws.send(json.dumps({"type": "error", "message": "response not in allowlist"}))
                    continue
                remote = pane_remote_map.get(pane_id)
                log.info("Response from %s (%s): pane=%s text=%r", ip, device, pane_id, text)
                audit("respond", ip, device, pane_id, f"text={text!r}")
                await run_herdr("pane", "send-text", pane_id, text + "\n", remote=remote)
            elif msg_type == "agent_event":
                event_queue.put_nowait(msg)
            elif msg_type == "read_pane":
                pane_id = msg["pane_id"]
                if pane_id not in known_panes:
                    await ws.send(json.dumps({"type": "error", "message": "unknown pane_id"}))
                    continue
                lines = msg.get("lines", "30")
                remote = pane_remote_map.get(pane_id)
                content = await run_herdr("pane", "read", pane_id, "--lines", str(lines), "--source", "recent", remote=remote)
                await ws.send(json.dumps({"type": "pane_content", "pane_id": pane_id, "content": content}))
            elif msg_type == "send_keys":
                pane_id = msg["pane_id"]
                if pane_id not in known_panes:
                    await ws.send(json.dumps({"type": "error", "message": "unknown pane_id"}))
                    continue
                keys = msg.get("keys", [])
                if not all(k in SAFE_KEYS for k in keys):
                    await ws.send(json.dumps({"type": "error", "message": "keys contain disallowed values"}))
                    continue
                remote = pane_remote_map.get(pane_id)
                log.info("Keys from %s (%s): pane=%s keys=%s", ip, device, pane_id, keys)
                audit("send_keys", ip, device, pane_id, f"keys={keys}")
                await run_herdr("pane", "send-keys", pane_id, *keys, remote=remote)
            elif msg_type == "send_text":
                pane_id = msg["pane_id"]
                if pane_id not in known_panes:
                    await ws.send(json.dumps({"type": "error", "message": "unknown pane_id"}))
                    continue
                text = msg.get("text", "")
                if not text or len(text) > 1000:
                    await ws.send(json.dumps({"type": "error", "message": "text empty or too long"}))
                    continue
                remote = pane_remote_map.get(pane_id)
                log.info("Text from %s (%s): pane=%s text=%r", ip, device, pane_id, text)
                audit("send_text", ip, device, pane_id, f"text={text!r}")
                await run_herdr("pane", "send-text", pane_id, text, remote=remote)
            elif msg_type == "create_tab":
                workspace_id = msg.get("workspace_id", "")
                if workspace_id:
                    log.info("Create tab from %s (%s): workspace=%s", ip, device, workspace_id)
                    audit("create_tab", ip, device, "", f"workspace={workspace_id}")
                    await run_herdr("tab", "create", "--workspace", workspace_id, "--focus")
                    await ws.send(json.dumps({"type": "tab_created", "ok": True}))
                else:
                    await ws.send(json.dumps({"type": "error", "message": "workspace_id required"}))
            elif msg_type == "push_subscribe":
                sub = msg.get("subscription")
                if sub and sub not in push_subscriptions:
                    push_subscriptions.append(sub)
                    _save_push_subs()
                    log.info("Push subscription added from %s (%s)", ip, device)
                await ws.send(json.dumps({"type": "push_subscribed", "ok": True}))
            elif msg_type == "push_unsubscribe":
                sub = msg.get("subscription")
                if sub and sub in push_subscriptions:
                    push_subscriptions.remove(sub)
                    _save_push_subs()
                await ws.send(json.dumps({"type": "push_unsubscribed", "ok": True}))
    except (ConnectionClosedError, ConnectionClosedOK):
        pass
    finally:
        duration = int(time.monotonic() - connected_at)
        log.info("Client disconnected: ip=%s device=%s duration=%ds", ip, device, duration)
        clients.discard(ws)


class UDPPlugin(asyncio.DatagramProtocol):
    def datagram_received(self, data, addr):
        try:
            event_queue.put_nowait(json.loads(data.decode()))
        except Exception:
            pass


def local_ips():
    """Best-effort list of this host's routable IPv4 addresses, most useful first.

    gethostbyname(gethostname()) is not usable for this: on macOS the machine's hostname often has no
    resolvable A record, which raises "nodename nor servname provided". Opening a UDP socket toward a
    peer instead asks the routing table which source address would be used — no DNS, no traffic sent.
    """
    ips = []

    def _probe(peer):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect((peer, 80))
            return s.getsockname()[0]
        except OSError:
            return None
        finally:
            s.close()

    for peer in ("100.100.100.100", "8.8.8.8"):  # Tailscale's MagicDNS anycast IP, then the internet
        ip = _probe(peer)
        if ip and ip not in ips and not ip.startswith("127."):
            ips.append(ip)
    return ips


def start_mdns():
    try:
        from zeroconf import Zeroconf, ServiceInfo
        import threading
        ips = local_ips()
        if not ips:
            log.warning("mDNS skipped: no routable IPv4 address found")
            return None, None
        info = ServiceInfo(
            "_herdr-remote._tcp.local.", "herdr-remote._herdr-remote._tcp.local.",
            addresses=[socket.inet_aton(ip) for ip in ips], port=WS_PORT,
        )
        zc = Zeroconf()
        threading.Thread(target=zc.register_service, args=(info,), daemon=True).start()
        log.info("mDNS registering at %s", ", ".join(ips))
        return zc, info
    except Exception as e:
        log.warning("mDNS skipped: %s", e)
        return None, None


async def main():
    zc, info = start_mdns()
    loop = asyncio.get_running_loop()
    try:
        await loop.create_datagram_endpoint(UDPPlugin, local_addr=("127.0.0.1", 8376))
    except OSError:
        log.warning("UDP 8376 in use, plugin push disabled")
    asyncio.create_task(poll_loop())
    asyncio.create_task(event_push())
    server = await serve(
        handle_client, "0.0.0.0", WS_PORT,
        process_request=process_request,
        # Keep clients alive across a slow herdr/ssh call rather than dropping them: a missed pong
        # used to tear down every connection at once and show up as connect/disconnect churn.
        ping_interval=20,
        ping_timeout=60,
        max_queue=64,
    )
    hosts = ["local"] + REMOTES
    log.info("herdr-remote relay on :%d (WebSocket + HTTP)", WS_PORT)
    log.info("Polling: %s", ", ".join(hosts))
    for ip in local_ips():
        log.info("Reachable at: http://%s:%d/  (ws://%s:%d)", ip, WS_PORT, ip, WS_PORT)
    if AUTH_TOKEN:
        log.info("Token auth enabled — clients must pass ?token=…")
    if NTFY_ENABLED:
        log.info("ntfy enabled: %s/%s (priority=%s tags=%s)", NTFY_SERVER, NTFY_TOPIC, NTFY_PRIORITY, NTFY_TAGS)
    else:
        log.info("ntfy disabled (set HERDR_NTFY_TOPIC to enable)")
    if VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY:
        log.info("Web Push enabled (%d subscription(s))", len(push_subscriptions))
    stop = loop.create_future()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set_result, None)
    await stop
    server.close()
    if zc and info:
        zc.unregister_service(info)
        zc.close()


if __name__ == "__main__":
    asyncio.run(main())
