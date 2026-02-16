#!/bin/sh

mkdir -p /data/.openclaw

# Check if Telegram is properly configured (botToken under channels.telegram)
# If not, recreate config with proper structure
if ! grep -q 'botToken' /data/.openclaw/openclaw.json 2>/dev/null && \
   ! grep -q 'botToken' /data/.openclaw/config.toml 2>/dev/null; then
  # Reset config with proper Telegram channel structure
  rm -f /data/.openclaw/config.toml /data/.openclaw/openclaw.json 2>/dev/null
  cat > /data/.openclaw/openclaw.json << ENDCFG
{
  "gateway": {
    "bind": "lan",
    "port": 18789,
    "auth": {
      "mode": "token"
    },
    "trustedProxies": ["10.0.0.0/8"],
    "controlUi": {
      "allowInsecureAuth": true
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace"
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "${TELEGRAM_OPENCLAW_TOKEN}",
      "accounts": {
        "deepseek": {
          "enabled": true,
          "botToken": "${TELEGRAM_DEEPCLAW_TOKEN}"
        }
      }
    }
  },
  "meta": {
    "lastTouchedVersion": "2026.2.10"
  }
}
ENDCFG
fi

exec node openclaw.mjs gateway --allow-unconfigured --bind lan
