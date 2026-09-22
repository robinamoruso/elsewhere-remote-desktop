# CLAUDE.md

Elsewhere Remote Desktop — remote desktop per macOS via browser: app Swift nella barra dei menu → server Python (FastAPI) → tunnel Cloudflare. Panoramica utente in [README.md](README.md).

## File

- `Elsewhere.swift` — app nella barra dei menu (singolo file, niente Xcode project/SwiftPM). Avvia `server.py` e `cloudflared` come `Process`, legge l'URL da `tunnel.log`, watchdog ogni 30s, asserzioni IOKit anti-sleep, Telegram, notifiche via `osascript`.
- `server.py` — FastAPI: `POST /auth` → token; `GET/POST /clipboard` (header `X-Token`); `WS /ws/{token}` per frame JPEG (mss + Pillow) e input (Quartz `CGEvent`).
- `static/index.html` — client web in un unico file, JS vanilla, nessuna build.
- `create_app_bundle.py` — genera icona, Info.plist, compila con `swiftc`, copia `server.py` + `static/` in `Contents/Resources`, firma ad hoc, installa in `/Applications`.
- `install.sh` — venv e `.env` in `~/.elsewhere`, poi build. `start.sh` — modalità terminale senza app.

## Runtime

- Dati fuori dal repo: `~/.elsewhere/{venv,.env,server.log,tunnel.log}`. L'app esegue il `server.py` **incluso nel bundle**, non quello del repo.
- Config: env var > `~/.elsewhere/.env` (`envValue()` in Swift, `source` in `start.sh`, env in `server.py`).
- Porta `8765` fissa in `Elsewhere.swift`, `start.sh`, `server.py` (default di `ELSEWHERE_PORT`).

## Comandi

```bash
./install.sh                                         # setup completo
~/.elsewhere/venv/bin/python3 create_app_bundle.py   # rebuild app dopo modifiche
swiftc -typecheck Elsewhere.swift                    # check veloce Swift
./start.sh                                           # server + tunnel da terminale
ELSEWHERE_PASSWORD=x ELSEWHERE_PORT=18765 ~/.elsewhere/venv/bin/python3 server.py   # solo server, porta di test
```

Non ci sono test automatici. Per verificare, smoke test con curl su `/health`, `/auth` e `/clipboard` (401 senza token), più una prova reale dal browser.

## Convenzioni e insidie

- Stringhe UI, commenti e log in **italiano**.
- Pochi file e zero dipendenze nuove: Swift solo AppKit/Foundation/IOKit, client senza framework.
- Dopo ogni modifica a `server.py` o `static/` bisogna **ricostruire l'app**, altrimenti gira la copia vecchia nel bundle.
- La firma è ad hoc, quindi un rebuild può invalidare i permessi TCC (Registrazione schermo, Accessibilità). Se input o cattura smettono di funzionare, rimuovi e riaggiungi l'app nelle impostazioni.
- Non uccidere processi generici: `pkill` solo su `tunnelProcessPattern` e `lsof -sTCP:LISTEN` sulla porta, per non chiudere altri tunnel o server dell'utente.
- Tastiera: il client invia la **posizione fisica** (`e.code`) e `KEYMAP` in `server.py` la traduce in keycode macOS (layout US). Nuovi tasti vanno aggiunti in entrambi.
- Coordinate mouse normalizzate 0–1 rispetto al monitor selezionato. Le dimensioni vengono corrette con `CGDisplayBounds` perché mss restituisce pixel Retina.
- Ogni endpoint nuovo che tocca il Mac deve richiedere il token (`Depends(require_token)`), perché il server è esposto su internet.
- Difese da non smontare per sbaglio: bind su loopback salvo `ELSEWHERE_BIND=0.0.0.0`, lock che serializza i login falliti, tetto di 1 MB sul body, token rivalidato a ogni frame (la sessione scaduta chiude con codice 4001, gestito dal client), clamp su fps/scale/quality, freno di 3s su `wake_display`.
- Niente segreti in notifiche, messaggi Telegram o argomenti di comandi (`ps` li mostra a tutti).
- Non committare `.env` né riferimenti a host, domini o MAC reali: la configurazione personale va solo in `~/.elsewhere/.env`.
