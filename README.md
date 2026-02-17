# OpenClaw Backend — Taxim Bot

AI-powered WhatsApp (and Telegram) bot using [OpenClaw](https://docs.openclaw.ai) as the gateway and OpenAI GPT-4o as the brain.

**Architecture:**

```
WhatsApp / Telegram  ←→  OpenClaw Gateway (Docker)  ←→  OpenAI GPT-4o
```

OpenClaw runs as a single Docker container. It connects to WhatsApp via the Web protocol (Baileys), receives messages, sends them to OpenAI, and replies back.

---

## Project Structure

```
openclaw-backend/
├── docker-compose.yml        # Gateway + CLI services
├── openclaw.template.json    # Config template (committed to git)
├── setup.sh                  # One-command setup script
├── .env.example              # Environment variable template
├── .env                      # Your secrets (NOT in git)
├── .gitignore
├── README.md
└── data/
    └── openclaw/             # Runtime data (NOT in git)
        ├── openclaw.json     # Live config (generated from template)
        ├── credentials/      # WhatsApp auth keys
        ├── devices/          # Paired devices
        ├── agents/           # Session history
        └── workspace/        # Agent workspace
```

**What goes in git:** `docker-compose.yml`, `openclaw.template.json`, `setup.sh`, `.env.example`, `.gitignore`, `README.md`

**What stays out of git:** `.env`, `data/openclaw/` (secrets, credentials, session data)

---

## Local Setup (macOS / Linux)

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS) or [Docker Engine](https://docs.docker.com/engine/install/) (Linux)
- An [OpenAI API key](https://platform.openai.com/api-keys)

### Step 1: Clone and Configure

```bash
git clone <your-repo-url> openclaw-backend
cd openclaw-backend
cp .env.example .env
```

Open `.env` and set your OpenAI API key:

```env
OPENAI_API_KEY=sk-proj-your-actual-key-here
```

Leave `OPENCLAW_GATEWAY_TOKEN` empty — the setup script generates it automatically.

### Step 2: Run Setup

```bash
./setup.sh
```

This single command will:
1. Validate Docker and `.env`
2. Generate a gateway auth token (if missing)
3. Create `data/openclaw/` with the correct config
4. Pull the official OpenClaw Docker image
5. Start the gateway
6. Run `doctor --fix` to validate and finalize the config
7. Bootstrap CLI device pairing

### Step 3: Link WhatsApp

```bash
docker exec -it openclaw-gateway node openclaw.mjs channels login --channel whatsapp
```

A QR code will appear in your terminal. On your phone:

1. Open **WhatsApp**
2. Go to **Settings > Linked Devices > Link a Device**
3. Scan the QR code

The terminal will confirm: `Listening for personal WhatsApp inbound messages.`

### Step 4: Open the Control UI

The setup script prints a URL like:

```
http://127.0.0.1:18789/#token=your-gateway-token
```

Open it in your browser. The token in the URL auto-authenticates the dashboard.

If the UI shows **"pairing required"**, approve your browser device:

```bash
docker exec openclaw-gateway node openclaw.mjs devices list
docker exec openclaw-gateway node openclaw.mjs devices approve <requestId>
```

### Step 5: Verify

```bash
docker exec openclaw-gateway node openclaw.mjs channels status
```

Expected output:

```
- WhatsApp default: enabled, configured, linked, running, connected, dm:pairing, allow:*
```

Send a WhatsApp message to the linked number from another phone — the bot responds with GPT-4o.

---

## Adding Telegram

### Step 1: Create a Telegram Bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot`, follow the prompts
3. Copy the **bot token** (e.g. `123456:ABC-DEF...`)

### Step 2: Add Telegram Channel

```bash
docker exec openclaw-gateway node openclaw.mjs channels add --channel telegram --token "YOUR_BOT_TOKEN"
```

Or edit `data/openclaw/openclaw.json` and add under `channels`:

```json
"telegram": {
  "botToken": "YOUR_BOT_TOKEN",
  "dmPolicy": "pairing",
  "allowFrom": ["*"]
}
```

The gateway hot-reloads config changes — no restart needed.

---

## CLI Reference

All CLI commands run inside the gateway container. Use `docker exec`:

| Command | Purpose |
|---------|---------|
| `docker exec openclaw-gateway node openclaw.mjs channels status` | Check all channel status |
| `docker exec -it openclaw-gateway node openclaw.mjs channels login --channel whatsapp` | Link/re-link WhatsApp (QR) |
| `docker exec openclaw-gateway node openclaw.mjs devices list` | List device pairing requests |
| `docker exec openclaw-gateway node openclaw.mjs devices approve <id>` | Approve a device |
| `docker exec openclaw-gateway node openclaw.mjs doctor --fix --yes` | Fix config issues |
| `docker exec openclaw-gateway node openclaw.mjs health` | Health check |
| `docker exec openclaw-gateway node openclaw.mjs dashboard --no-open` | Get Control UI URL with token |
| `docker compose logs -f openclaw-gateway` | Live gateway logs |
| `docker compose restart openclaw-gateway` | Restart gateway |
| `docker compose down` | Stop everything |
| `./setup.sh reset` | Wipe runtime data and start over |

---

## Production Deployment on GCP VM

### 1. Create a GCP VM

- **Machine type:** e2-small (2 vCPU, 2 GB RAM) or higher
- **OS:** Ubuntu 22.04 LTS or Debian 12
- **Disk:** 20 GB SSD minimum
- **Firewall:** Allow ports 22 (SSH), 80, 443

Create via `gcloud`:

```bash
gcloud compute instances create openclaw-bot \
  --zone=us-central1-a \
  --machine-type=e2-small \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --tags=http-server,https-server
```

Allow HTTP/HTTPS:

```bash
gcloud compute firewall-rules create allow-http --allow tcp:80 --target-tags http-server
gcloud compute firewall-rules create allow-https --allow tcp:443 --target-tags https-server
```

### 2. SSH into the VM

```bash
gcloud compute ssh openclaw-bot --zone=us-central1-a
```

### 3. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker --version
docker compose version
```

### 4. Deploy the Application

```bash
# Clone your repo
git clone <your-repo-url> /opt/openclaw-backend
cd /opt/openclaw-backend

# Create .env from template
cp .env.example .env
```

Edit `.env` with your production values:

```bash
nano .env
```

```env
OPENAI_API_KEY=sk-proj-your-production-key
OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:main
OPENCLAW_BIND_IP=127.0.0.1
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790
```

**Important:** Keep `OPENCLAW_BIND_IP=127.0.0.1`. The gateway will only be accessible through the Nginx reverse proxy, not directly from the internet.

Leave `OPENCLAW_GATEWAY_TOKEN` empty — setup.sh generates it.

### 5. Run Setup

```bash
chmod +x setup.sh
./setup.sh
```

Save the gateway token from the output — you'll need it for the Control UI.

### 6. Link WhatsApp on the VM

```bash
docker exec -it openclaw-gateway node openclaw.mjs channels login --channel whatsapp
```

Scan the QR code from your phone.

### 7. Set Up Nginx Reverse Proxy with SSL

Install Nginx and Certbot:

```bash
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx
```

Create Nginx config:

```bash
sudo tee /etc/nginx/sites-available/openclaw <<'NGINX'
server {
    listen 80;
    server_name bot.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:18789;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Get SSL certificate:

```bash
sudo certbot --nginx -d bot.yourdomain.com
```

### 8. Auto-Start on Reboot

Docker's `restart: unless-stopped` handles container restarts. Ensure Docker starts on boot:

```bash
sudo systemctl enable docker
```

### 9. Verify Production Deployment

```bash
# Check gateway is running
docker exec openclaw-gateway node openclaw.mjs channels status

# Check from outside
curl -s https://bot.yourdomain.com | head -5
```

### 10. Access Control UI Remotely

From your local machine, use SSH tunnel (recommended):

```bash
gcloud compute ssh openclaw-bot --zone=us-central1-a -- -L 18789:127.0.0.1:18789
```

Then open in your browser:

```
http://localhost:18789/#token=your-gateway-token
```

Or access via the Nginx proxy at `https://bot.yourdomain.com/#token=your-gateway-token`.

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENAI_API_KEY` | Yes | — | OpenAI API key for GPT-4o |
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Auto-generated | 256-bit auth token for gateway |
| `OPENCLAW_IMAGE` | No | `ghcr.io/openclaw/openclaw:main` | Docker image to use |
| `OPENCLAW_BIND_IP` | No | `127.0.0.1` | IP to bind ports to |
| `OPENCLAW_GATEWAY_PORT` | No | `18789` | Gateway HTTP/WS port |
| `OPENCLAW_BRIDGE_PORT` | No | `18790` | Bridge port |

---

## Configuration

The bot configuration lives in `openclaw.template.json` (committed to git) and gets copied to `data/openclaw/openclaw.json` on first setup.

### Key Settings

| Setting | Current Value | Purpose |
|---------|---------------|---------|
| `agents.defaults.model.primary` | `openai/gpt-4o` | Primary AI model |
| `agents.defaults.model.fallbacks` | `openai/gpt-4o-mini` | Fallback if primary fails |
| `agents.list[0].identity.name` | `Taxim Bot` | Bot display name |
| `channels.whatsapp.dmPolicy` | `pairing` | How new users connect |
| `channels.whatsapp.allowFrom` | `["*"]` | Who can DM the bot |
| `session.reset.idleMinutes` | `120` | Reset session after 2h idle |

### Editing Config After Setup

Edit the live config directly:

```bash
nano data/openclaw/openclaw.json
```

The gateway hot-reloads changes automatically — no restart needed for most settings.

---

## Troubleshooting

### Gateway crash-loops

```bash
docker logs --tail 50 openclaw-gateway
```

Common cause: invalid config. Fix with:

```bash
docker exec openclaw-gateway node openclaw.mjs doctor --fix --yes
docker compose restart openclaw-gateway
```

### "pairing required" in Control UI

Your browser device needs approval:

```bash
docker exec openclaw-gateway node openclaw.mjs devices list
docker exec openclaw-gateway node openclaw.mjs devices approve <requestId>
```

### WhatsApp disconnected

Re-link by scanning a new QR code:

```bash
docker exec -it openclaw-gateway node openclaw.mjs channels login --channel whatsapp
```

### Permission denied errors

On Linux, ensure `data/openclaw` is owned by uid 1000:

```bash
sudo chown -R 1000:1000 data/openclaw
```

### Start completely fresh

```bash
./setup.sh reset
./setup.sh
```

This wipes all runtime data (WhatsApp link, sessions, devices) and starts over.

---

## Updating

Pull the latest image and restart:

```bash
docker compose pull openclaw-gateway
docker compose up -d openclaw-gateway
```

Your config, WhatsApp link, and session data are preserved in `data/openclaw/`.
