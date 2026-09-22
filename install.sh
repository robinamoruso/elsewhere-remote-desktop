#!/bin/bash
# Installa Elsewhere: venv + config in ~/.elsewhere, app in /Applications
set -euo pipefail
cd "$(dirname "$0")"
DATA_DIR="$HOME/.elsewhere"

command -v python3 >/dev/null || { echo "❌ Serve python3 (brew install python)"; exit 1; }
command -v swiftc  >/dev/null || { echo "❌ Serve swiftc (xcode-select --install)"; exit 1; }
command -v cloudflared >/dev/null || echo "⚠️  cloudflared non trovato: senza, solo accesso in rete locale (brew install cloudflared)"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"   # log e .env non leggibili da altri utenti del Mac
[ -x "$DATA_DIR/venv/bin/python3" ] || python3 -m venv "$DATA_DIR/venv"
"$DATA_DIR/venv/bin/python3" -m pip install -q --upgrade pip
"$DATA_DIR/venv/bin/python3" -m pip install -q -r requirements.txt

if [ ! -f "$DATA_DIR/.env" ]; then
    PW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
    sed "s/^ELSEWHERE_PASSWORD=.*/ELSEWHERE_PASSWORD=$PW/" .env.example > "$DATA_DIR/.env"
    echo "🔑 Creato $DATA_DIR/.env con password generata: $PW"
fi

[ -f "$DATA_DIR/.env" ] && chmod 600 "$DATA_DIR/.env"

"$DATA_DIR/venv/bin/python3" create_app_bundle.py
echo ""
echo "✅ Fatto. Apri 'Elsewhere' da /Applications e concedi i permessi"
echo "   Registrazione schermo + Accessibilità (Impostazioni di Sistema → Privacy e sicurezza)."
