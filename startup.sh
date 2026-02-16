#!/bin/sh

# Only create default config if no config exists yet
# This preserves channel configurations (Telegram, Gmail, etc.) made through the UI
if [ ! -f /data/.openclaw/openclaw.json ] && [ ! -f /data/.openclaw/config.toml ]; then
  mkdir -p /data/.openclaw
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
    "default": {
      "type": "telegram",
      "token": "${TELEGRAM_OPENCLAW_TOKEN}",
      "enabled": true
    },
    "deepseek": {
      "type": "telegram",
      "token": "${TELEGRAM_DEEPCLAW_TOKEN}",
      "enabled": true
    }
  },
  "meta": {
    "lastTouchedVersion": "2026.2.10"
  }
}
ENDCFG
fi

exec node openclaw.mjs gateway --allow-unconfigured --bind lan
