#!/bin/sh
cat > /data/.openclaw/openclaw.json << 'ENDCFG'
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
  "meta": {
    "lastTouchedVersion": "2026.2.10"
  }
}
ENDCFG

exec node openclaw.mjs gateway --allow-unconfigured --bind lan
