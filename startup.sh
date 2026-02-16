#!/bin/sh

mkdir -p /data/.openclaw

# Always recreate config with known-good structure
# This ensures gateway.mode is set and Telegram channels are properly configured
rm -f /data/.openclaw/config.toml /data/.openclaw/openclaw.json 2>/dev/null
cat > /data/.openclaw/openclaw.json << ENDCFG
{
  "gateway": {
    "mode": "local",
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
      "accounts": {
        "deepseek": {
          "enabled": true,
          "botToken": "${TELEGRAM_DEEPCLAW_TOKEN}"
        }
      }
    }
  },
  "plugins": {
    "allow": ["telegram"],
    "entries": {
      "telegram": {
        "enabled": true
      }
    }
  },
  "meta": {
    "lastTouchedVersion": "2026.2.10"
  }
}
ENDCFG

# Auto-enable configured channels
node openclaw.mjs doctor --fix --non-interactive 2>/dev/null || true

exec node openclaw.mjs gateway --allow-unconfigured --bind lan
