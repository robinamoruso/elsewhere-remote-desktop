#!/bin/bash
# Modalità terminale: avvia server + quick tunnel Cloudflare senza l'app nella barra dei menu.
# Usa la stessa configurazione dell'app: ~/.elsewhere/.env e ~/.elsewhere/venv
set -u
cd "$(dirname "$0")"

DATA_DIR="$HOME/.elsewhere"
set -a; [ -f "$DATA_DIR/.env" ] && . "$DATA_DIR/.env"; set +a
export ELSEWHERE_PORT=8765
PORT=$ELSEWHERE_PORT

PYTHON_BIN="$DATA_DIR/venv/bin/python3"
[ -x "$PYTHON_BIN" ] || { echo "  ❌ venv non trovato: esegui prima ./install.sh"; exit 1; }
command -v cloudflared >/dev/null || { echo "  ❌ cloudflared non trovato: brew install cloudflared"; exit 1; }

# Libera la porta (solo il processo in ascolto, non i client)
lsof -ti:"$PORT" -sTCP:LISTEN | xargs kill -9 2>/dev/null || true
LOG_DIR="$DATA_DIR"; rm -f "$LOG_DIR/tunnel.log" "$LOG_DIR/server.log"

echo "  [1/3] Avvio server Python..."
"$PYTHON_BIN" -u server.py > "$LOG_DIR/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 20); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
    kill -0 $SERVER_PID 2>/dev/null || break
    sleep 0.5
done
if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null; then
    echo "  ❌ Il server non è partito:"; cat "$LOG_DIR/server.log"; exit 1
fi

echo "  [2/3] Avvio tunnel Cloudflare..."
cloudflared tunnel --url "http://127.0.0.1:$PORT" --protocol http2 --no-autoupdate > "$LOG_DIR/tunnel.log" 2>&1 &
TUNNEL_PID=$!
trap 'kill $TUNNEL_PID $SERVER_PID 2>/dev/null; echo; echo "  ✅ Chiuso."' EXIT

echo "  [3/3] Attendo il link pubblico..."
TUNNEL_URL=""
for _ in $(seq 1 30); do
    TUNNEL_URL=$(grep -o 'https://[a-zA-Z0-9._-]*\.trycloudflare\.com' "$LOG_DIR/tunnel.log" | tail -1)
    [ -n "$TUNNEL_URL" ] && break
    sleep 1
done
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)

echo ""
echo "  🌐 Link pubblico : ${TUNNEL_URL:-(non disponibile, vedi $LOG_DIR/tunnel.log)}"
if [ "${ELSEWHERE_BIND:-}" = "0.0.0.0" ]; then
    echo "  🏠 Link locale   : http://$LOCAL_IP:$PORT  (HTTP in chiaro)"
else
    echo "  🏠 Rete locale   : disattivata (ELSEWHERE_BIND=0.0.0.0 per abilitarla)"
fi
echo ""

if [ -n "$TUNNEL_URL" ]; then
    echo -n "$TUNNEL_URL" | pbcopy && echo "  📋 Link copiato negli appunti"
    if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        # URL via --config: come argomento di curl il token sarebbe visibile con ps
        curl -s --config - <<CURLCFG >/dev/null && echo "  📲 Link inviato su Telegram"
url = "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage"
data-urlencode = "chat_id=$TELEGRAM_CHAT_ID"
data-urlencode = "text=🖥️ Elsewhere online
$TUNNEL_URL"
CURLCFG
    fi
fi

echo "  Ctrl+C per fermare."
wait $SERVER_PID
