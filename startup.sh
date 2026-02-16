#!/bin/sh

mkdir -p /data/.openclaw

# =============================================================================
# Create Data Redaction Hook
# =============================================================================
mkdir -p /data/.openclaw/hooks/data-redaction

# Hook metadata
cat > /data/.openclaw/hooks/data-redaction/HOOK.md << 'HOOKMD'
---
name: data-redaction
description: "Redacts sensitive data (API keys, passwords, tokens) from session files"
metadata:
  openclaw:
    emoji: "🔒"
    events: ["gateway:startup", "command:new"]
    install:
      - id: workspace
        kind: workspace
---
# Data Redaction Hook

Automatically detects and redacts sensitive information from session files and memory.

## Detected Patterns
- API keys (OpenAI, Anthropic, GitHub, AWS, Google, etc.)
- Tokens (Slack, Discord, Telegram, Bearer)
- Private keys and certificates
- Database connection strings
- Passwords and secrets in common formats
- Credit card numbers, SSNs

## When It Runs
- **Gateway startup**: Scans all existing `.jsonl` and `.md` files
- **On /new command**: Redacts current session before memory save
HOOKMD

# Hook handler
cat > /data/.openclaw/hooks/data-redaction/handler.js << 'HOOKJS'
const fs = require("node:fs/promises");
const path = require("node:path");

const SENSITIVE_PATTERNS = [
  // API Keys
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
  // Telegram/Discord tokens
  { pattern: /[0-9]{8,10}:[a-zA-Z0-9_-]{35}/g, label: "TELEGRAM_TOKEN" },
  { pattern: /[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27}/g, label: "DISCORD_TOKEN" },
  // Private keys
  { pattern: /-----BEGIN[^-]+PRIVATE KEY-----[\s\S]+?-----END[^-]+PRIVATE KEY-----/g, label: "PRIVATE_KEY" },
  // Passwords/secrets in common formats
  { pattern: /password[\s]*[=:]["']?[^\s"']{8,}["']?/gi, label: "PASSWORD" },
  { pattern: /passwd[\s]*[=:]["']?[^\s"']{8,}["']?/gi, label: "PASSWORD" },
  { pattern: /secret[\s]*[=:]["']?[^\s"']{8,}["']?/gi, label: "SECRET" },
  { pattern: /api[_-]?key[\s]*[=:]["']?[^\s"']{16,}["']?/gi, label: "API_KEY" },
  { pattern: /bearer\s+[a-zA-Z0-9._-]{20,}/gi, label: "BEARER_TOKEN" },
  // Database URIs
  { pattern: /mongodb(\+srv)?:\/\/[^\s"']+/g, label: "MONGODB_URI" },
  { pattern: /postgres(ql)?:\/\/[^\s"']+/g, label: "POSTGRES_URI" },
  { pattern: /mysql:\/\/[^\s"']+/g, label: "MYSQL_URI" },
  { pattern: /redis:\/\/[^\s"']+/g, label: "REDIS_URI" },
  // PII
  { pattern: /\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13})\b/g, label: "CREDIT_CARD" },
  { pattern: /\b\d{3}-\d{2}-\d{4}\b/g, label: "SSN" },
];

function redactText(text) {
  let redacted = text;
  let count = 0;
  for (const { pattern, label } of SENSITIVE_PATTERNS) {
    // Reset regex state
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
        total += await processFile(full);
      }
    }
    return total;
  } catch { return 0; }
}

module.exports = async function(event) {
  const dataDir = process.env.OPENCLAW_STATE_DIR || "/data/.openclaw";
  
  if (event.type === "gateway" && event.action === "startup") {
    console.log("[redaction] Scanning existing files...");
    const count = await scanDir(dataDir);
    if (count > 0) console.log("[redaction] Startup: " + count + " item(s) redacted");
  }
  
  if (event.type === "command" && event.action === "new") {
    const sessionFile = event.context?.sessionEntry?.sessionFile || 
                        event.context?.previousSessionEntry?.sessionFile;
    if (sessionFile) await processFile(sessionFile);
  }
};
HOOKJS

# =============================================================================
# Create OpenClaw Config with Shared Memory
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

# Create shared directories
mkdir -p /data/.openclaw/workspace
mkdir -p /data/.openclaw/memory
mkdir -p /data/.openclaw/agents/main/sessions

# Run doctor to auto-fix config
node openclaw.mjs doctor --fix --non-interactive 2>/dev/null || true

exec node openclaw.mjs gateway --allow-unconfigured --bind lan
