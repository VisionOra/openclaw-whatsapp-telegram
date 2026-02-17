#!/usr/bin/env bash
#
# OpenClaw Backend — One-command setup
#
# Usage:
#   ./setup.sh          First-time setup (local or production)
#   ./setup.sh reset    Wipe runtime data and start fresh
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Handle "reset" subcommand ────────────────────────────────────────
if [[ "${1:-}" == "reset" ]]; then
    warn "This will delete ALL runtime data (WhatsApp link, sessions, devices)."
    read -rp "Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }
    docker compose down 2>/dev/null || true
    rm -rf data/openclaw
    ok "Runtime data wiped. Run ./setup.sh again to start fresh."
    exit 0
fi

echo ""
echo "========================================"
echo "   OpenClaw Backend Setup"
echo "========================================"
echo ""

# ── Step 1: Prerequisites ────────────────────────────────────────────
info "Checking prerequisites..."

command -v docker &>/dev/null || fail "Docker is not installed. Install: https://docs.docker.com/engine/install/"
docker compose version &>/dev/null || fail "Docker Compose v2 not found. Update Docker or install the Compose plugin."
ok "Docker and Docker Compose v2 available."

# ── Step 2: .env file ────────────────────────────────────────────────
info "Checking .env file..."

if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        fail ".env not found. Create it from the template:\n       cp .env.example .env\n       Then fill in OPENAI_API_KEY and re-run this script."
    else
        fail ".env not found. Create it with at minimum:\n       OPENAI_API_KEY=sk-proj-your-key-here"
    fi
fi

# Validate OPENAI_API_KEY is set
source .env 2>/dev/null || true
if [[ -z "${OPENAI_API_KEY:-}" ]] || [[ "$OPENAI_API_KEY" == *"your-openai"* ]]; then
    fail "OPENAI_API_KEY is missing or still a placeholder in .env"
fi
ok "OPENAI_API_KEY is set."

# Auto-generate gateway token if missing
if ! grep -q "^OPENCLAW_GATEWAY_TOKEN=" .env || [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    TOKEN=$(openssl rand -hex 32)
    # Remove any existing empty line and re-add cleanly
    grep -v "^OPENCLAW_GATEWAY_TOKEN" .env > .env.tmp || true
    mv .env.tmp .env
    echo "OPENCLAW_GATEWAY_TOKEN=$TOKEN" >> .env
    export OPENCLAW_GATEWAY_TOKEN="$TOKEN"
    ok "Generated gateway token."
else
    ok "Gateway token exists."
fi

# Re-source to pick up all values
set -a; source .env 2>/dev/null; set +a

# ── Step 3: Runtime data directory ────────────────────────────────────
info "Preparing runtime data directory..."

FIRST_RUN=false
if [[ ! -d data/openclaw ]]; then
    FIRST_RUN=true
    mkdir -p data/openclaw/workspace \
             data/openclaw/agents/main/sessions \
             data/openclaw/credentials \
             data/openclaw/devices

    # Copy the validated config template
    cp openclaw.template.json data/openclaw/openclaw.json

    # Set correct ownership (uid 1000 = node user inside container)
    # On macOS, Docker Desktop handles uid mapping automatically.
    # On Linux, the host user running Docker needs uid 1000 or:
    if [[ "$(uname)" == "Linux" ]]; then
        sudo chown -R 1000:1000 data/openclaw 2>/dev/null || warn "Could not chown data/openclaw to uid 1000. Run: sudo chown -R 1000:1000 data/openclaw"
    fi

    chmod 700 data/openclaw
    chmod 600 data/openclaw/openclaw.json

    ok "Created data/openclaw/ with config template."
else
    ok "data/openclaw/ already exists (preserving existing data)."
fi

# ── Step 4: Pull image ───────────────────────────────────────────────
info "Pulling OpenClaw Docker image..."
docker compose pull openclaw-gateway
ok "Image pulled."

# ── Step 5: Start gateway ────────────────────────────────────────────
info "Starting OpenClaw gateway..."
docker compose up -d openclaw-gateway

# Wait for gateway to be ready
info "Waiting for gateway to start..."
for i in $(seq 1 15); do
    if docker logs openclaw-gateway 2>&1 | grep -q "listening on ws://"; then
        ok "Gateway is running."
        break
    fi
    if [[ $i -eq 15 ]]; then
        fail "Gateway did not start in time. Check: docker logs openclaw-gateway"
    fi
    sleep 2
done

# ── Step 6: Run doctor (first run only) ──────────────────────────────
if [[ "$FIRST_RUN" == true ]]; then
    info "Running doctor to validate and finalize config..."
    docker compose run --rm openclaw-cli doctor --fix --yes 2>&1 | tail -5 || warn "Doctor had warnings (non-fatal)."
    ok "Config validated by doctor."

    # Restart gateway to pick up any doctor changes
    docker compose restart openclaw-gateway
    sleep 5
fi

# ── Done ──────────────────────────────────────────────────────────────
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}"
BIND_IP="${OPENCLAW_BIND_IP:-127.0.0.1}"
PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

echo ""
echo "========================================"
echo "   Setup Complete"
echo "========================================"
echo ""
echo "  Gateway:    http://${BIND_IP}:${PORT}"
echo "  Control UI: http://${BIND_IP}:${PORT}/#token=${GATEWAY_TOKEN}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Open the Control UI link above in your browser."
echo "     (The token is in the URL — the UI will auto-connect, no pairing needed.)"
echo ""
echo "  2. Link WhatsApp:"
echo "     docker exec -it openclaw-gateway node openclaw.mjs channels login --channel whatsapp"
echo "     Then scan the QR code: WhatsApp > Settings > Linked Devices > Link a Device"
echo ""
echo "  3. Verify everything:"
echo "     docker exec openclaw-gateway node openclaw.mjs status"
echo "     docker exec openclaw-gateway node openclaw.mjs channels status"
echo ""
echo "  Useful commands:"
echo "     docker compose logs -f openclaw-gateway     # Live logs"
echo "     docker compose restart openclaw-gateway      # Restart"
echo "     docker compose down                          # Stop"
echo "     ./setup.sh reset                             # Wipe and start over"
echo ""
