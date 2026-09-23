#!/bin/bash
# Installa Elsewhere: venv + config in ~/.elsewhere, app in /Applications
# --no-app: salta la compilazione (per chi ha scaricato l'app dalle release)
set -euo pipefail
cd "$(dirname "$0")"
DATA_DIR="$HOME/.elsewhere"
BUILD_APP=true
[ "${1:-}" = "--no-app" ] && BUILD_APP=false

command -v python3 >/dev/null || { echo "❌ Serve python3 (brew install python)"; exit 1; }
if $BUILD_APP && ! command -v swiftc >/dev/null; then
    echo "❌ Serve swiftc per compilare l'app (xcode-select --install)."
    echo "   Se hai già Elsewhere.app dalle release, usa: ./install.sh --no-app"
    exit 1
fi
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

if $BUILD_APP; then "$DATA_DIR/venv/bin/python3" create_app_bundle.py; fi
echo ""
echo "✅ Fatto. Apri 'Elsewhere' da /Applications e concedi i permessi"
echo "   Registrazione schermo + Accessibilità (Impostazioni di Sistema → Privacy e sicurezza)."
