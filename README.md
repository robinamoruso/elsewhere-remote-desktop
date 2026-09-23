# Elsewhere Remote Desktop

**Your Mac, from anywhere else, including networks where remote desktop is blocked.**

RDP, VNC, VPNs and remote desktop apps all get stopped by the same things: closed ports, blocked UDP, firewalls that recognize their traffic. Elsewhere sends nothing unusual. To the network you're on, **it's an HTTPS website**, and most networks let websites through.

No account, not even a Cloudflare one. No ports to open, no VPN, no subscription.

```
📱 any browser  ──HTTPS :443──▶  Cloudflare  ◀──outbound tunnel──  your Mac
```

> The UI is in Italian for now. The code and this README are in English.

---

## The problem

You're at the office, a client's site, a hotel or an airport, and you need your Mac at home. You try:

- **RDP or VNC:** ports 3389 and 5900 are closed. Nothing connects.
- **VPN (WireGuard, OpenVPN, IPsec):** UDP is blocked, or VPN protocols are filtered, and the tunnel never comes up.
- **TeamViewer, AnyDesk & co.:** the firewall lists them as "remote access software" and drops the connection. Even when they get through, you need their account.
- **Chrome Remote Desktop:** it uses WebRTC, which relies on UDP, and it needs a Google account.

## The fix

**Elsewhere only uses the one kind of traffic that every usable network allows: a web page over HTTPS on port 443.**

- **From where you are:** a browser opening an HTTPS page, with a WebSocket on the same connection. That's the same traffic as a web chat or Google Docs.
- **From your Mac:** a single *outbound* TCP connection to Cloudflare. Nothing listens on your router, there's no port forwarding, and nothing to find with a scan.
- **Through Cloudflare:** the path runs on Cloudflare's network, so it's hard to block without also breaking a large part of the web.

| | Needs on the network you're on | Account |
|---|---|---|
| RDP | TCP/UDP 3389 open | — |
| VNC / Screen Sharing | TCP 5900 open, or a VPN | — |
| VPN + anything | UDP or VPN protocols allowed | usually |
| TeamViewer, AnyDesk & co. | their service not blocked as "remote access" | usually |
| Chrome Remote Desktop | WebRTC/UDP, or its relays reachable | Google |
| **Elsewhere** | **HTTPS, like any website** | **none** |

## No account. Anywhere.

There's no vendor account and no dashboard listing your devices. There's no third-party login that can be phished, no password that can leak in someone else's data breach, and no company that can change its pricing or close your account. The only credential is your password, stored on your Mac.

Even the tunnel doesn't need an account: Cloudflare quick tunnels are free and anonymous. If you prefer a permanent domain, that's optional (see [Configuration](#configuration)).

## What you get

- **A link that just works.** A free `trycloudflare.com` URL out of the box, or your own domain (`desk.yourname.com`).
- **It stays up on its own.** A watchdog checks every 30 seconds that the server responds *and* that the public URL answers from the outside, and restarts whichever part broke. It also rebuilds the tunnel after the Mac wakes from sleep.
- **The link comes to you.** When the URL changes, the new one lands in your Telegram, so you never need to know it in advance.
- **Links are disposable.** The URL is random. If you think it leaked, press *Rigenera* and the old one stops working within seconds.
- **No black screen.** Optional anti-sleep keeps the Mac and its display awake, and every connection wakes the screen. With the watchdog and *Avvia al login*, an always-on Mac mini stays reachable across reboots.
- **Made for phones.** The screen becomes a trackpad: drag to move, tap to click, long-press for right-click, two fingers to scroll, double-tap for the keyboard, plus a bar with ⌘C, ⌘V, ⌘Z, ⌘Space and the arrow keys.
- **Any keyboard layout.** Keys are sent by *physical position*, so Italian, German and French keyboards just work. *Win KB* mode maps Ctrl to ⌘ when you connect from a Windows PC.
- **Drag a file onto the page** and it lands in the Mac's `~/Downloads`.
- **Clipboard both ways**, multiple monitors, FPS, quality and scale sliders, a live fps/bandwidth readout, and a zoom that follows the cursor.
- **Nothing to install where you connect from.** A locked-down work laptop or a borrowed phone is enough.
- **No limits.** No session timeouts, no "commercial use detected" warning, no device cap.
- **Scriptable.** Anything that can open a WebSocket, such as a script, a bot or an AI agent, can see the screen and drive the Mac (see [Protocol](#protocol)).
- **Small enough to own.** About 2,000 lines and 5 Python dependencies. You can audit it in an afternoon.

## Design decisions (and why)

Each choice below trades something away on purpose.

**Cloudflare Tunnel instead of port forwarding or a VPN.**
`cloudflared` only makes *outbound* connections, so your router stays closed and nothing on your network is exposed. You get a valid HTTPS certificate for free, and it works behind carrier-grade NAT. The tradeoff: traffic passes through Cloudflare, which terminates TLS.

**The tunnel runs on HTTP/2 over TCP, not QUIC over UDP.**
`cloudflared` uses QUIC by default, and UDP is the first thing restrictive networks block. Elsewhere forces `--protocol http2`: it's a bit less fast in theory, but it connects in far more places.

**JPEG frames over a WebSocket instead of WebRTC or a video codec.**
WebRTC relies on UDP, STUN and TURN, and that's exactly what firewalls block. A WebSocket goes wherever HTTPS goes. Frames go down as raw binary and identical ones are skipped, so an idle screen costs almost nothing. The tradeoff: more bandwidth than H.264 when the screen is busy. The FPS, quality and scale sliders let you tune it on the fly.

**Native input with Quartz `CGEvent` instead of `pyautogui`.**
Events go straight into the macOS event system. That means no automation-library overhead, no cursor jumping, correct multi-monitor coordinates, and real modifier keys.

**A native Swift menu bar app instead of Electron.**
It's one Swift file of about 1,000 lines using only AppKit, Foundation and IOKit. It starts instantly, stays light, and uses real macOS APIs for anti-sleep (IOKit power assertions) and for sleep and wake events.

**Python for the server.**
`mss` captures the screen, `pyobjc` calls Quartz, and FastAPI handles HTTP and WebSockets in about 260 lines. There are 5 dependencies and no build step.

**One HTML file for the client.**
Vanilla JavaScript, no framework, no bundler, no `node_modules`. The server sends the page on connect, so it works in Safari on iOS, Chrome on Android, or a locked-down work laptop.

**Configuration in one `.env` file.**
Password, Telegram and an optional fixed domain. The file lives in `~/.elsewhere`, outside the repo, so you can't commit your secrets by accident.

## Install

**Requirements:** macOS 13+, Python 3.10+, Xcode Command Line Tools (`xcode-select --install`), and `brew install cloudflared`.

```bash
git clone https://github.com/robinamoruso/elsewhere-remote-desktop.git
cd elsewhere-remote-desktop
./install.sh
```

The installer:

- creates `~/.elsewhere` with a virtualenv
- **generates a random password** and prints it once
- builds `Elsewhere.app` and puts it in `/Applications`

Prefer a prebuilt app? Take `Elsewhere.zip` from [Releases](https://github.com/robinamoruso/elsewhere-remote-desktop/releases), unzip it into `/Applications` and run `xattr -dr com.apple.quarantine /Applications/Elsewhere.app`, since it isn't signed with a Developer ID. You still need `./install.sh` once, for the virtualenv and the password.

Open **Elsewhere**, then grant the two permissions macOS asks for in *System Settings → Privacy & Security*:

| Permission | Why |
|---|---|
| Screen Recording | to see the screen |
| Accessibility | to move the mouse and type |

Quit and reopen the app from the menu bar. Once the 🖥 icon stops showing `…`, the public link is in your clipboard.

> The app is signed ad hoc, so macOS may ask for the permissions again after a rebuild. If input stops working, remove Elsewhere from both lists and add it again.

**Without the app:** `./start.sh` runs the server and the tunnel in a terminal. It's handy while developing. In that case, grant the two permissions to your terminal app.

## Configuration

Everything is in `~/.elsewhere/.env`. [`.env.example`](.env.example) lists every variable, and environment variables take precedence.

| Variable | |
|---|---|
| `ELSEWHERE_PASSWORD` | **Required**, at least 8 characters. The server refuses to start without it or with `changeme`. |
| `ELSEWHERE_BIND` | Set to `0.0.0.0` to also answer on your LAN. Off by default: that link is plain HTTP. |
| `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID` | Send the link to Telegram. Get the token from [@BotFather](https://t.me/BotFather). |
| `ELSEWHERE_TUNNEL_NAME`, `ELSEWHERE_TUNNEL_HOST` | Use a fixed domain instead of a random link. |

### A permanent URL on your own domain

Quick tunnels get a new URL on every restart. If your domain is on Cloudflare, you can keep one address:

```bash
cloudflared tunnel login
cloudflared tunnel create elsewhere
cloudflared tunnel route dns elsewhere desk.example.com
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: elsewhere
credentials-file: /Users/<you>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: desk.example.com
    service: http://127.0.0.1:8765
  - service: http_status:404
```

Then add `ELSEWHERE_TUNNEL_NAME=elsewhere` and `ELSEWHERE_TUNNEL_HOST=desk.example.com` to your `.env`.

## Security

**The idea in short.** Elsewhere leaves no permanent way in. Your router stays closed, nothing listens on your network unless you ask, and the tunnel only exists while the app runs. What's reachable is a single page, behind a single password, at a random URL you can throw away whenever you like. That password is the whole perimeter, so everything else follows from protecting it: it's generated long and random, wrong guesses are slowed to one per second, sessions expire and get closed, and every attempt ends up in a log. And since the whole thing is about 2,000 lines, you don't have to take my word for any of it.

Concretely:

- **Random password** generated at install. The server refuses to start without one, or with `changeme`.
- **Random session tokens** (32 bytes), valid for one hour. Every endpoint that touches the Mac requires one, and when a session expires the live connection is closed, not just left idle.
- **Loopback only by default.** The server answers the tunnel and nothing else, so no device on your Wi-Fi can even reach the login page unless you set `ELSEWHERE_BIND=0.0.0.0`.
- **Request bodies are capped** at 1 MB, so an unauthenticated request can't exhaust memory.
- **Logins are logged** (success and failure, with the client address) to `~/.elsewhere/server.log`, and so is every session that opens.
- **Brute force is capped at one attempt per second**, globally: wrong passwords are serialized behind a lock, so firing a thousand requests in parallel doesn't help. The comparison itself is constant-time.
- **The page can't be framed** (`X-Frame-Options`, `frame-ancestors 'none'`) and doesn't leak your URL in a `Referer` header.
- **No inbound ports** on your router, and the tunnel only exists while the service runs.
- **Disposable links:** *Rigenera* kills the current URL and issues a new one.
- **Privacy screen:** the page blanks when the tab loses focus, so a taskbar thumbnail doesn't show your desktop.
- **Uploads are contained:** a dropped file needs a token, is streamed to disk instead of memory, is stripped to its bare filename (no `../`), never overwrites an existing file, and can only land in `~/Downloads`.
- **The password is never displayed** in the menu or panel unless you ask for it, and it's never sent to Telegram or written to a notification.
- **Secrets stay local:** `~/.elsewhere` is `700` and `.env` is `600`.

For a permanent domain, put [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/applications/) in front of it (email one-time code or SSO) as a free second factor.

Know the tradeoffs:

- **Cloudflare terminates TLS**, so the tunnel provider can technically see the traffic. Every clientless browser solution has this property, including Cloudflare's own and anything built on Guacamole; the alternative is a peer-to-peer design that stops working on restrictive networks. If that's unacceptable, use a fixed domain with Cloudflare Access, or reach the Mac over a VPN you control.
- **`ELSEWHERE_BIND=0.0.0.0` is plain HTTP.** It's off by default, and you rarely need it: the HTTPS tunnel works just as well while you're at home. Turn it on only if you want the Mac reachable with the internet down, and only on a network you trust.
- **The app is signed ad hoc.** Anything already running as your user could replace the bundled `server.py` and inherit Elsewhere's Screen Recording and Accessibility permissions. Closing that needs a Developer ID signature, which needs a paid Apple account.
- **Whoever gets in has your Mac**, with Screen Recording and Accessibility. There are no read-only or limited sessions.

## When to use something else

- **You need audio, or files coming back from the Mac:** not built in (you can only send files *to* it).
- **You manage many machines or several users:** use a fleet tool.
- **You're on a very slow connection:** a video codec (Parsec, RustDesk, Screen Sharing) will look better. Identical frames are skipped and the sliders go a long way, but a JPEG stream can't match H.264 on a busy screen.
- **You're not on macOS:** Elsewhere relies on Quartz, IOKit and `pbcopy`.

To be clear about the networks: a proxy that inspects TLS or filters by category can still block the `trycloudflare.com` domain. A [custom domain](#a-permanent-url-on-your-own-domain) looks like any other website. And respect the policies of the networks you use: Elsewhere is for reaching *your own* Mac.

## Protocol

1. `POST /auth` with `{"password": "..."}` returns `{"token": "..."}`, valid for one hour.
2. Open a WebSocket to `/ws/<token>`.

| Direction | Message |
|---|---|
| Mac → you | `{"type":"monitors","list":[{"index","width","height"}],"current":0}` |
| Mac → you | `{"type":"size","sw":1920,"sh":1080}` — only when the resolution changes |
| Mac → you | the JPEG frame itself, as a **binary** WebSocket message |
| you → Mac | `{"type":"config","fps":20,"quality":55,"scale":0.8,"monitor":0}` |
| you → Mac | `{"type":"mouse_move","x":0.5,"y":0.5}` (coordinates from 0 to 1) |
| you → Mac | `{"type":"mouse_down" / "mouse_up","x":…,"y":…,"button":"left"\|"right"\|"middle"}` |
| you → Mac | `{"type":"scroll","x":…,"y":…,"dy":-3}` |
| you → Mac | `{"type":"key_down" / "key_up","key":"a","mods":["command","shift"]}` |
| you → Mac | `{"type":"key_combo","key":"space","mods":["command"]}` |
| you → Mac | `{"type":"wake"}` |

`POST /upload`, with an `X-Token` header, a percent-encoded `X-Filename` and the file as the raw body, saves it to `~/Downloads`.

`GET` and `POST /clipboard`, with an `X-Token` header, read and write the Mac's clipboard.

```python
# open Spotlight on the Mac, from any script
import asyncio, json, requests, websockets
tok = requests.post("https://<your-link>/auth", json={"password": "..."}).json()["token"]
async def main():
    async with websockets.connect(f"wss://<your-link>/ws/{tok}") as ws:
        await ws.send(json.dumps({"type": "key_combo", "key": "space", "mods": ["command"]}))
asyncio.run(main())
```

## Under the hood

```
Browser ──HTTPS/WSS──▶ Cloudflare ──▶ cloudflared ──▶ server.py :8765
                                                        ├─ mss → JPEG frames (sent only when they change)
                                                        ├─ Quartz CGEvent ← mouse and keyboard
                                                        └─ pbcopy / pbpaste ← clipboard
Elsewhere.app (Swift) ── starts, watches and heals ──▶ server.py + cloudflared
```

| File | Lines | Role |
|---|---|---|
| `Elsewhere.swift` | ~1,000 | menu bar app, process supervision, watchdog, anti-sleep, Telegram |
| `server.py` | ~260 | auth, WebSocket streaming, native input, clipboard |
| `static/index.html` | ~560 | the whole web client |
| `create_app_bundle.py` | ~110 | icon, `Info.plist`, `swiftc`, codesign, install |
| `install.sh` / `start.sh` | ~90 | setup and terminal mode |

Logs are written to `~/.elsewhere/server.log` and `tunnel.log`.

## License

[Beerware](LICENSE). Do whatever you want with it: use it, fork it, sell it, print it on a T-shirt.

If it saved your day, you owe me a beer 🍺 — and a pull request tastes even better than the beer. A star works too.
