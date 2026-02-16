#!/bin/sh

mkdir -p /data/.openclaw

# =============================================================================
# Create Data Redaction Hook + Cron Script
# =============================================================================
mkdir -p /data/.openclaw/hooks/data-redaction
mkdir -p /data/.openclaw/scripts

# Hook metadata
cat > /data/.openclaw/hooks/data-redaction/HOOK.md << 'HOOKMD'
---
name: data-redaction
description: "Redacts sensitive data from chat sessions (excludes config files)"
metadata:
  openclaw:
    emoji: "🔒"
    events: ["gateway:startup", "command:new"]
---
# Data Redaction Hook

Scans session logs and memory files for accidentally shared secrets.
Config files are excluded to keep bots functional.
HOOKMD

# Hook handler - only scans .jsonl and .md files
cat > /data/.openclaw/hooks/data-redaction/handler.js << 'HOOKJS'
const fs = require("node:fs/promises");
const path = require("node:path");

const SENSITIVE_PATTERNS = [
  { pattern: /sk-[a-zA-Z0-9]{20,}/g, label: "OPENAI_KEY" },
  { pattern: /sk-ant-[a-zA-Z0-9-]{20,}/g, label: "ANTHROPIC_KEY" },
  { pattern: /sk-or-[a-zA-Z0-9-]{20,}/g, label: "OPENROUTER_KEY" },
  { pattern: /xoxb-[a-zA-Z0-9-]+/g, label: "SLACK_TOKEN" },
  { pattern: /xapp-[a-zA-Z0-9-]+/g, label: "SLACK_APP_TOKEN" },
  { pattern: /ghp_[a-zA-Z0-9]{36,}/g, label: "GITHUB_TOKEN" },
  { pattern: /gho_[a-zA-Z0-9]{36,}/g, label: "GITHUB_OAUTH" },
  { pattern: /github_pat_[a-zA-Z0-9_]{22,}/g, label: "GITHUB_PAT" },
  { pattern: /glpat-[a-zA-Z0-9-_]{20,}/g, label: "GITLAB_TOKEN" },
  { pattern: /AKIA[0-9A-Z]{16}/g, label: "AWS_ACCESS_KEY" },
  { pattern: /AIza[0-9A-Za-z-_]{35}/g, label: "GOOGLE_API_KEY" },
  { pattern: /ya29\.[0-9A-Za-z_-]+/g, label: "GOOGLE_OAUTH" },
  { pattern: /[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27}/g, label: "DISCORD_TOKEN" },
  { pattern: /-----BEGIN[^-]+PRIVATE KEY-----[\s\S]+?-----END[^-]+PRIVATE KEY-----/g, label: "PRIVATE_KEY" },
  { pattern: /bearer\s+[a-zA-Z0-9._-]{20,}/gi, label: "BEARER_TOKEN" },
  { pattern: /mongodb(\+srv)?:\/\/[^:]+:[^@]+@[^\s"']+/g, label: "MONGODB_URI" },
  { pattern: /postgres(ql)?:\/\/[^:]+:[^@]+@[^\s"']+/g, label: "POSTGRES_URI" },
  { pattern: /mysql:\/\/[^:]+:[^@]+@[^\s"']+/g, label: "MYSQL_URI" },
  { pattern: /redis:\/\/[^:]+:[^@]+@[^\s"']+/g, label: "REDIS_URI" },
  { pattern: /\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13})\b/g, label: "CREDIT_CARD" },
  { pattern: /\b\d{3}-\d{2}-\d{4}\b/g, label: "SSN" },
];

function redactText(text) {
  let redacted = text;
  let count = 0;
  for (const { pattern, label } of SENSITIVE_PATTERNS) {
    pattern.lastIndex = 0;
    const matches = redacted.match(pattern);
    if (matches) {
      count += matches.length;
      pattern.lastIndex = 0;
      redacted = redacted.replace(pattern, "[REDACTED:" + label + "]");
    }
  }
  return { text: redacted, count };
}

async function processFile(filePath) {
  try {
    const content = await fs.readFile(filePath, "utf-8");
    const { text, count } = redactText(content);
    if (count > 0) {
      await fs.writeFile(filePath, text, "utf-8");
      console.log("[redaction] Redacted " + count + " item(s) from " + filePath);
    }
    return count;
  } catch (err) {
    return 0;
  }
}

async function scanDir(dir) {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    let total = 0;
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        total += await scanDir(full);
      } else if (entry.name.endsWith(".jsonl") || entry.name.endsWith(".md")) {
        // ONLY session logs and memory files - NOT config (.json)
        total += await processFile(full);
      }
    }
    return total;
  } catch { return 0; }
}

module.exports.scanDir = scanDir;
module.exports.redactText = redactText;

module.exports = async function(event) {
  const dataDir = process.env.OPENCLAW_STATE_DIR || "/data/.openclaw";
  
  if (event.type === "gateway" && event.action === "startup") {
    console.log("[redaction] Startup scan...");
    const count = await scanDir(dataDir);
    console.log("[redaction] Startup complete: " + count + " item(s) redacted");
  }
  
  if (event.type === "command" && event.action === "new") {
    const sessionFile = event.context?.sessionEntry?.sessionFile || 
                        event.context?.previousSessionEntry?.sessionFile;
    if (sessionFile) await processFile(sessionFile);
  }
};
HOOKJS

cat > /data/.openclaw/scripts/redact-cron.js << 'CRONJS'
#!/usr/bin/env node
const { scanDir } = require("/data/.openclaw/hooks/data-redaction/handler.js");
async function main() {
  const dataDir = process.env.OPENCLAW_STATE_DIR || "/data/.openclaw";
  console.log("[redaction-cron] " + new Date().toISOString());
  const count = await scanDir(dataDir);
  console.log("[redaction-cron] Done: " + count + " item(s) redacted");
}
main().catch(console.error);
CRONJS
chmod +x /data/.openclaw/scripts/redact-cron.js

# =============================================================================
# OpenClaw Config
# =============================================================================
rm -f /data/.openclaw/config.toml /data/.openclaw/openclaw.json 2>/dev/null
cat > /data/.openclaw/openclaw.json << ENDCFG
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "auth": { "mode": "token" },
    "trustedProxies": ["10.0.0.0/8"],
    "controlUi": { "allowInsecureAuth": true }
  },
  "agents": {
    "defaults": {
      "workspace": "/data/.openclaw/workspace",
      "model": {
        "primary": "anthropic/claude-opus-4-6",
        "fallbacks": ["deepseek/deepseek-chat"]
      },
      "models": {
        "anthropic/claude-opus-4-6": { "alias": "Claude" },
        "deepseek/deepseek-chat": { "alias": "Deepseek" }
      }
    },
    "list": [
      { "id": "main", "default": true, "workspace": "/data/.openclaw/workspace" }
    ]
  },
  "session": { "dmScope": "main" },
  "channels": {
    "telegram": {
      "enabled": true,
      "accounts": {
        "deepseek": {
          "enabled": true,
          "botToken": "\${TELEGRAM_DEEPCLAW_TOKEN}",
          "agentId": "main",
          "model": "deepseek/deepseek-chat"
        }
      }
    }
  },
  "memory": {
    "enabled": true,
    "workspace": "/data/.openclaw/workspace",
    "extraPaths": ["/data/.openclaw/memory"]
  },
  "memorySearch": {
    "enabled": true,
    "indexPath": "/data/.openclaw/memory/index"
  },
  "cron": {
    "enabled": true,
    "jobs": {
      "redaction-sweep": {
        "enabled": true,
        "schedule": "0 */6 * * *",
        "command": "node /data/.openclaw/scripts/redact-cron.js",
        "description": "Redaction sweep every 6 hours"
      }
    }
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "session-memory": { "enabled": true },
        "data-redaction": { "enabled": true }
      }
    },
    "workspaceDir": "/data/.openclaw/hooks"
  },
  "plugins": {
    "allow": ["telegram", "memory-core"],
    "entries": {
      "telegram": { "enabled": true },
      "memory-core": { "enabled": true, "memory": true }
    }
  },
  "meta": { "lastTouchedVersion": "2026.2.16" }
}
ENDCFG

mkdir -p /data/.openclaw/workspace /data/.openclaw/memory /data/.openclaw/agents/main/sessions
node openclaw.mjs doctor --fix --non-interactive 2>/dev/null || true
exec node openclaw.mjs gateway --allow-unconfigured --bind lan
