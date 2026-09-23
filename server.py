import asyncio, hmac, io, json, os, secrets, subprocess, sys, time
from pathlib import Path
from urllib.parse import unquote

import mss
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Header, Depends, Request
from fastapi.responses import FileResponse, JSONResponse
from PIL import Image

# ── Quartz.CoreGraphics per input nativo macOS (zero lag, avvio veloce) ──
from Quartz.CoreGraphics import (
    CGEventCreateMouseEvent, CGEventPost, CGEventCreateKeyboardEvent,
    CGEventSetFlags,
    kCGEventMouseMoved, kCGEventLeftMouseDown, kCGEventLeftMouseUp,
    kCGEventRightMouseDown, kCGEventRightMouseUp,
    kCGEventOtherMouseDown, kCGEventOtherMouseUp,
    CGEventCreateScrollWheelEvent, kCGScrollEventUnitLine,
    kCGHIDEventTap, kCGMouseButtonLeft, kCGMouseButtonRight, kCGMouseButtonCenter,
    kCGEventFlagMaskShift, kCGEventFlagMaskControl,
    kCGEventFlagMaskAlternate, kCGEventFlagMaskCommand,
    CGPoint, CGEventGetLocation, CGEventCreate,
    CGGetActiveDisplayList, CGDisplayBounds,
)


PASSWORD  = os.environ.get("ELSEWHERE_PASSWORD", "")
if PASSWORD in ("", "changeme") or len(PASSWORD) < 8:
    sys.exit("ELSEWHERE_PASSWORD missing, too short (min 8) or still 'changeme': edit ~/.elsewhere/.env")
TOKEN_TTL = 3600

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
_sessions: dict[str, float] = {}
_auth_lock = asyncio.Lock()

# L'URL del tunnel è di fatto un segreto: no-referrer evita che finisca nei log
# di altri siti. frame-ancestors/X-Frame-Options impediscono il clickjacking.
SECURITY_HEADERS = {
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
}

# Il body viene bufferizzato in memoria prima di qualsiasi controllo: senza
# tetto, una richiesta enorme fa fuori il processo (e con lui il Mac).
MAX_BODY = 1_000_000
MAX_UPLOAD = 2_000_000_000   # i file caricati vanno su disco a pezzi, non in memoria

@app.middleware("http")
async def limit_body(request, call_next):
    limit = MAX_UPLOAD if request.url.path == "/upload" else MAX_BODY
    if int(request.headers.get("content-length") or 0) > limit:
        return JSONResponse({"detail": "too large"}, 413)
    return await call_next(request)

def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {msg}", flush=True)

# ── Auth ──────────────────────────────────────────────────────────────────
def valid_token(t):
    exp = _sessions.get(t)
    if not exp or time.time() > exp: _sessions.pop(t, None); return False
    return True

def require_token(x_token: str = Header("")):
    if not valid_token(x_token): raise HTTPException(401, "Unauthorized")

@app.get("/")
@app.head("/")
async def index():
    return FileResponse(Path(__file__).parent / "static" / "index.html", headers=SECURITY_HEADERS)

@app.get("/health")
@app.head("/health")
async def health(): return {"status": "ok"}

@app.post("/auth")
async def auth(data: dict, request: Request):
    if not hmac.compare_digest(str(data.get("password", "")).encode(), PASSWORD.encode()):
        # Il lock serializza i tentativi falliti: anche con mille richieste in
        # parallelo si resta a un tentativo al secondo.
        # ponytail: limite globale, non per IP (dietro il tunnel l'IP è sempre 127.0.0.1)
        async with _auth_lock:
            await asyncio.sleep(1)
        log(f"login FAILED from {request.client.host if request.client else '?'}")
        raise HTTPException(401, "Wrong password")
    now = time.time()
    for t in [t for t, exp in _sessions.items() if exp < now]: del _sessions[t]
    tok = secrets.token_urlsafe(32)
    _sessions[tok] = now + TOKEN_TTL
    log(f"login OK from {request.client.host if request.client else '?'}")
    return {"token": tok}

@app.get("/clipboard", dependencies=[Depends(require_token)])
async def get_clipboard():
    try:
        out = subprocess.check_output(["pbpaste"], timeout=2).decode("utf-8", errors="replace")
        return {"text": out}
    except: return {"text": ""}

@app.post("/clipboard", dependencies=[Depends(require_token)])
async def set_clipboard(data: dict):
    try:
        p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
        p.communicate(data.get("text", "").encode())
    except: pass
    return {}

_last_wake = 0.0

@app.post("/upload", dependencies=[Depends(require_token)])
async def upload(request: Request, x_filename: str = Header("")):
    # Percent-encoded dal client (gli header non reggono i caratteri non ASCII).
    # Solo il nome: "../../.ssh/authorized_keys" diventa "authorized_keys"
    name = Path(unquote(x_filename)).name or "file"
    dest = Path.home() / "Downloads" / name
    n = 1
    while dest.exists():   # mai sovrascrivere roba dell'utente
        dest = dest.with_name(f"{Path(name).stem} ({n}){Path(name).suffix}")
        n += 1
    size = 0
    with dest.open("wb") as f:          # a pezzi: un file grosso non deve stare in RAM
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_UPLOAD:
                f.close(); dest.unlink(missing_ok=True)
                raise HTTPException(413, "too large")
            f.write(chunk)
    log(f"file received: {dest.name} ({size/1024:.0f} KB)")
    return {"saved": dest.name}

def wake_display():
    # Ogni chiamata lancia un processo: senza freno un flood di "wake"
    # riempie la tabella dei processi del Mac
    global _last_wake
    if time.time() - _last_wake < 3: return
    _last_wake = time.time()
    try:
        subprocess.Popen(["caffeinate", "-u", "-t", "3"])
        loc = CGEventGetLocation(CGEventCreate(None))
        ev1 = CGEventCreateMouseEvent(None, kCGEventMouseMoved, CGPoint(x=loc.x + 1, y=loc.y), kCGMouseButtonLeft)
        CGEventPost(kCGHIDEventTap, ev1)
        ev2 = CGEventCreateMouseEvent(None, kCGEventMouseMoved, loc, kCGMouseButtonLeft)
        CGEventPost(kCGHIDEventTap, ev2)
    except Exception as e:
        print(f"Wake display error: {e}")

# ── Input nativo Quartz ───────────────────────────────────────────────────
def mouse_event(kind, x, y, btn=kCGMouseButtonLeft):
    pt = CGPoint(x=x, y=y)
    ev = CGEventCreateMouseEvent(None, kind, pt, btn)
    CGEventPost(kCGHIDEventTap, ev)

def mouse_move(x, y):
    pt = CGPoint(x=x, y=y)
    ev = CGEventCreateMouseEvent(None, kCGEventMouseMoved, pt, kCGMouseButtonLeft)
    CGEventPost(kCGHIDEventTap, ev)

def mouse_click(down, x, y, button="left"):
    mapping = {
        "left":   (kCGEventLeftMouseDown,  kCGEventLeftMouseUp,  kCGMouseButtonLeft),
        "right":  (kCGEventRightMouseDown, kCGEventRightMouseUp, kCGMouseButtonRight),
        "middle": (kCGEventOtherMouseDown, kCGEventOtherMouseUp, kCGMouseButtonCenter),
    }
    dn, up, btn = mapping.get(button, mapping["left"])
    kind = dn if down else up
    pt = CGPoint(x=x, y=y)
    ev = CGEventCreateMouseEvent(None, kind, pt, btn)
    CGEventPost(kCGHIDEventTap, ev)

def do_scroll(x, y, dy):
    pt = CGPoint(x=x, y=y)
    ev = CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitLine, 1, dy)
    CGEventPost(kCGHIDEventTap, ev)

# Mappa tasti browser → keycode macOS
KEYMAP: dict[str, int] = {
    # lettere
    "a":0x00,"s":0x01,"d":0x02,"f":0x03,"h":0x04,"g":0x05,"z":0x06,"x":0x07,
    "c":0x08,"v":0x09,"b":0x0B,"q":0x0C,"w":0x0D,"e":0x0E,"r":0x0F,"y":0x10,
    "t":0x11,"o":0x1F,"u":0x20,"i":0x22,"p":0x23,"l":0x25,"j":0x26,"k":0x28,
    "n":0x2D,"m":0x2E,
    # cifre (posizione fisica US)
    "1":0x12,"2":0x13,"3":0x14,"4":0x15,"6":0x16,"5":0x17,"9":0x19,"7":0x1A,"8":0x1C,"0":0x1D,
    # simboli per posizione fisica (indipendenti dal layout)
    "equal":0x18,"minus":0x1B,"]":0x1E,"[":0x21,"'":0x27,";":0x29,
    "\\":0x2A,",":0x2B,"/":0x2C,".":0x2F,"`":0x32,"=":0x18,"-":0x1B,
    # tasti speciali
    "enter":0x24,"tab":0x30,"space":0x31,"backspace":0x33,"esc":0x35,
    "command":0x37,"shift":0x38,"capslock":0x39,"alt":0x3A,"ctrl":0x3B,
    "right_shift":0x3C,"right_alt":0x3D,"right_ctrl":0x3E,
    # frecce e navigazione
    "left":0x7B,"right":0x7C,"down":0x7D,"up":0x7E,
    "home":0x73,"end":0x77,"pageup":0x74,"pagedown":0x79,"delete":0x75,
    # F keys
    "f1":0x7A,"f2":0x78,"f3":0x63,"f4":0x76,"f5":0x60,"f6":0x61,
    "f7":0x62,"f8":0x64,"f9":0x65,"f10":0x6D,"f11":0x67,"f12":0x6F,
    "f13":0x69,"f14":0x6B,"f15":0x71,"f16":0x6A,"f17":0x40,"f18":0x4F,
    "f19":0x50,"f20":0x5A,
}
# caratteri che richiedono shift
SHIFT_CHARS = set('ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+{}|:"<>?~')

def send_key(key: str, down: bool, flags: int = 0):
    needs_shift = key in SHIFT_CHARS
    k = key.lower() if len(key) == 1 else key
    if k not in KEYMAP:
        return
    code = KEYMAP[k]
    f = flags
    if needs_shift: f |= kCGEventFlagMaskShift
    ev = CGEventCreateKeyboardEvent(None, code, down)
    CGEventSetFlags(ev, f)
    CGEventPost(kCGHIDEventTap, ev)

def build_flags(mods: list) -> int:
    f = 0
    if "shift"   in mods: f |= kCGEventFlagMaskShift
    if "ctrl"    in mods: f |= kCGEventFlagMaskControl
    if "alt"     in mods: f |= kCGEventFlagMaskAlternate
    if "command" in mods: f |= kCGEventFlagMaskCommand
    return f

# ── WebSocket ─────────────────────────────────────────────────────────────
@app.websocket("/ws/{token}")
async def ws_endpoint(websocket: WebSocket, token: str):
    if not valid_token(token):
        await websocket.close(code=4001); return
    await websocket.accept()
    log("session OPENED")
    wake_display()

    quality, scale, fps = 55, 0.8, 20

    with mss.MSS() as sct:
        monitors = sct.monitors[1:]  # esclude indice 0 (desktop virtuale combinato)
        try:
            active_displays = CGGetActiveDisplayList(10, None, None)[1]
            for m in monitors:
                for d in active_displays:
                    bounds = CGDisplayBounds(d)
                    if int(bounds.origin.x) == m["left"] and int(bounds.origin.y) == m["top"]:
                        m["width"] = int(bounds.size.width)
                        m["height"] = int(bounds.size.height)
        except Exception as e:
            print(f"Error correcting monitor dimensions: {e}")
        mon = monitors[0]

        await websocket.send_text(json.dumps({
            "type": "monitors",
            "list": [{"index": i, "width": m["width"], "height": m["height"]} for i, m in enumerate(monitors)],
            "current": 0,
        }))

        async def send_frames():
            nonlocal quality, scale, fps, mon
            prev_bytes = None
            prev_mon = None
            prev_size = None
            while True:
                # La sessione scade anche a WebSocket aperto: chiudi, altrimenti
                # i frame si fermano ma mouse e tastiera resterebbero attivi
                if not valid_token(token):
                    await websocket.close(code=4001)
                    break
                t0 = time.perf_counter()
                try:
                    cur_mon = mon
                    sw, sh = cur_mon["width"], cur_mon["height"]
                    raw = sct.grab(cur_mon)
                    img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
                    if scale < 1.0:
                        img = img.resize((int(sw * scale), int(sh * scale)), Image.BILINEAR)
                    buf = io.BytesIO()
                    img.save(buf, "JPEG", quality=quality, optimize=False)
                    frame_bytes = buf.getvalue()
                    if frame_bytes != prev_bytes or cur_mon is not prev_mon:
                        # Il JPEG va giù binario: in base64 dentro un JSON pesava un terzo in più.
                        # Le dimensioni cambiano solo cambiando monitor o scala, quindi a parte.
                        if (sw, sh) != prev_size:
                            await websocket.send_text(json.dumps({"type": "size", "sw": sw, "sh": sh}))
                            prev_size = (sw, sh)
                        await websocket.send_bytes(frame_bytes)
                        prev_bytes = frame_bytes
                        prev_mon = cur_mon
                except Exception:
                    break
                elapsed = time.perf_counter() - t0
                await asyncio.sleep(max(0, 1 / fps - elapsed))

        async def recv_events():
            nonlocal quality, scale, fps, mon
            async for raw in websocket.iter_text():
                try:
                    ev = json.loads(raw)
                    t  = ev.get("type")
                    if t == "wake":
                        wake_display()
                        continue
                    if t == "config":
                        # Valori fuori scala bloccherebbero lo streaming (fps 0) o
                        # farebbero esplodere la memoria (scale enorme)
                        quality = min(95, max(5, int(ev.get("quality", quality))))
                        scale   = min(1.0, max(0.1, float(ev.get("scale", scale))))
                        fps     = min(60, max(1, int(ev.get("fps", fps))))
                        idx     = ev.get("monitor")
                        if idx is not None and 0 <= idx < len(monitors):
                            mon = monitors[idx]
                        continue
                    x = mon["left"] + int(ev.get("x", 0) * mon["width"])
                    y = mon["top"]  + int(ev.get("y", 0) * mon["height"])
                    if   t == "mouse_move":  mouse_move(x, y)
                    elif t == "mouse_down":  mouse_click(True,  x, y, ev.get("button","left"))
                    elif t == "mouse_up":    mouse_click(False, x, y, ev.get("button","left"))
                    elif t == "scroll":      do_scroll(x, y, int(ev.get("dy", 0)))
                    elif t == "key_down":    send_key(ev["key"], True,  build_flags(ev.get("mods",[])))
                    elif t == "key_up":      send_key(ev["key"], False, build_flags(ev.get("mods",[])))
                    elif t == "key_combo":   # es. cmd+c
                        mods = ev.get("mods", [])
                        key  = ev["key"]
                        f    = build_flags(mods)
                        send_key(key, True,  f)
                        send_key(key, False, f)
                except Exception as e:
                    print(f"Event error: {e}")

        try:
            await asyncio.gather(send_frames(), recv_events())
        except (WebSocketDisconnect, Exception):
            pass

if __name__ == "__main__":
    import uvicorn
    sys.stdout.reconfigure(line_buffering=True)
    port = int(os.environ.get("ELSEWHERE_PORT", 8765))
    # Di default solo loopback: il tunnel arriva da 127.0.0.1. Aprire alla LAN
    # (ELSEWHERE_BIND=0.0.0.0) espone login e stream in HTTP non cifrato.
    host = os.environ.get("ELSEWHERE_BIND", "127.0.0.1")
    log(f"Elsewhere — {host}:{port}")
    uvicorn.run(app, host=host, port=port, loop="asyncio", lifespan="off", log_level="warning")
