#!/bin/sh
set -eu

STATE_DIR="/data/.openclaw"
CONFIG_PATH="${STATE_DIR}/openclaw.json"
AUTH_CLEAN_MARKER="${STATE_DIR}/.auth-cleaned-v1"

mkdir -p "${STATE_DIR}"

# One-time cleanup of known-bad auth artifacts from older builds.
if [ ! -f "${AUTH_CLEAN_MARKER}" ]; then
  echo "[startup] clearing legacy auth artifacts (one-time)"
  rm -f "${STATE_DIR}"/agents/*/agent/auth-profiles.json 2>/dev/null || true
  rm -f "${STATE_DIR}/auth-profiles.json" 2>/dev/null || true
  rm -f "${STATE_DIR}/identity/device.json" 2>/dev/null || true
  touch "${AUTH_CLEAN_MARKER}"
fi

# Legacy TOML config is no longer used.
rm -f "${STATE_DIR}/config.toml" 2>/dev/null || true

# Keep bundled redaction hook assets in place.
mkdir -p "${STATE_DIR}/hooks/data-redaction" "${STATE_DIR}/scripts"

cat > "${STATE_DIR}/hooks/data-redaction/HOOK.md" <<'HOOKMD'
---
name: data-redaction
description: "Redacts sensitive data from chat sessions"
metadata:
  openclaw:
    emoji: "🔒"
    events: ["gateway:startup", "command:new"]
---
# Data Redaction Hook
Scans .jsonl and .md files only. Config files excluded.
HOOKMD

cat > "${STATE_DIR}/hooks/data-redaction/handler.js" <<'HOOKJS'
const fs = require("node:fs/promises");
const path = require("node:path");

const SENSITIVE_PATTERNS = [
  { pattern: /sk-[a-zA-Z0-9]{20,}/g, label: "OPENAI_KEY" },
  { pattern: /sk-ant-[a-zA-Z0-9-]{20,}/g, label: "ANTHROPIC_KEY" },
  { pattern: /sk-or-[a-zA-Z0-9-]{20,}/g, label: "OPENROUTER_KEY" },
  { pattern: /ghp_[a-zA-Z0-9]{36,}/g, label: "GITHUB_TOKEN" },
  { pattern: /AKIA[0-9A-Z]{16}/g, label: "AWS_ACCESS_KEY" },
  { pattern: /AIza[0-9A-Za-z-_]{35}/g, label: "GOOGLE_API_KEY" },
  {
    pattern: /-----BEGIN[^-]+PRIVATE KEY-----[\s\S]+?-----END[^-]+PRIVATE KEY-----/g,
    label: "PRIVATE_KEY",
  },
  { pattern: /bearer\s+[a-zA-Z0-9._-]{20,}/gi, label: "BEARER_TOKEN" },
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
      redacted = redacted.replace(pattern, `[REDACTED:${label}]`);
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
      console.log(`[redaction] Redacted ${count} from ${filePath}`);
    }
    return count;
  } catch {
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
  } catch {
    return 0;
  }
}

module.exports.scanDir = scanDir;
module.exports = async function handleEvent(event) {
  const dataDir = "/data/.openclaw";
  if (event.type === "gateway" && event.action === "startup") {
    console.log("[redaction] Startup scan...");
    const count = await scanDir(dataDir);
    console.log(`[redaction] Done: ${count} item(s)`);
  }
  if (event.type === "command" && event.action === "new") {
    const filePath = event.context?.sessionEntry?.sessionFile || event.context?.previousSessionEntry?.sessionFile;
    if (filePath) {
      await processFile(filePath);
    }
  }
};
HOOKJS

cat > "${STATE_DIR}/scripts/redact-cron.js" <<'CRONJS'
#!/usr/bin/env node
const { scanDir } = require("/data/.openclaw/hooks/data-redaction/handler.js");

(async () => {
  console.log(`[cron] ${new Date().toISOString()}`);
  const count = await scanDir("/data/.openclaw");
  console.log(`[cron] Done: ${count}`);
})();
CRONJS
chmod +x "${STATE_DIR}/scripts/redact-cron.js"

# Create a minimal config only when missing.
if [ ! -f "${CONFIG_PATH}" ]; then
  cat > "${CONFIG_PATH}" <<'ENDCFG'
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
      "accounts": {}
    }
  },
  "memory": {},
  "cron": { "enabled": true },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "session-memory": { "enabled": true },
        "data-redaction": { "enabled": true }
      }
    }
  },
  "plugins": {
    "allow": ["telegram", "memory-core"],
    "entries": {
      "telegram": { "enabled": true },
      "memory-core": { "enabled": true }
    }
  },
  "meta": { "lastTouchedVersion": "2026.2.16" }
}
ENDCFG
fi

# Merge env-backed account tokens without deleting existing user config.
CONFIG_PATH="${CONFIG_PATH}" \
TELEGRAM_OPENCLAW_TOKEN="${TELEGRAM_OPENCLAW_TOKEN:-}" \
TELEGRAM_DEEPCLAW_TOKEN="${TELEGRAM_DEEPCLAW_TOKEN:-}" \
node <<'NODE'
const fs = require("node:fs");

const configPath = process.env.CONFIG_PATH;
const openclawToken = String(process.env.TELEGRAM_OPENCLAW_TOKEN || "").trim();
const deepclawToken = String(process.env.TELEGRAM_DEEPCLAW_TOKEN || "").trim();

const readConfig = () => {
  try {
    const raw = fs.readFileSync(configPath, "utf8");
    return raw.trim() ? JSON.parse(raw) : {};
  } catch (err) {
    console.error(`[startup] failed to parse ${configPath}: ${String(err)}`);
    return null;
  }
};

const cfg = readConfig();
if (!cfg || typeof cfg !== "object") {
  process.exit(0);
}

cfg.gateway = cfg.gateway && typeof cfg.gateway === "object" ? cfg.gateway : {};
cfg.gateway.mode = "local";
if (!cfg.gateway.bind) cfg.gateway.bind = "lan";
if (typeof cfg.gateway.port !== "number") cfg.gateway.port = 18789;
cfg.gateway.auth = cfg.gateway.auth && typeof cfg.gateway.auth === "object" ? cfg.gateway.auth : {};
if (!cfg.gateway.auth.mode) cfg.gateway.auth.mode = "token";
cfg.gateway.trustedProxies =
  Array.isArray(cfg.gateway.trustedProxies) && cfg.gateway.trustedProxies.length > 0
    ? cfg.gateway.trustedProxies
    : ["10.0.0.0/8"];
cfg.gateway.controlUi =
  cfg.gateway.controlUi && typeof cfg.gateway.controlUi === "object" ? cfg.gateway.controlUi : {};
if (typeof cfg.gateway.controlUi.allowInsecureAuth !== "boolean") {
  cfg.gateway.controlUi.allowInsecureAuth = true;
}

cfg.agents = cfg.agents && typeof cfg.agents === "object" ? cfg.agents : {};
cfg.agents.defaults =
  cfg.agents.defaults && typeof cfg.agents.defaults === "object" ? cfg.agents.defaults : {};
if (!cfg.agents.defaults.workspace) {
  cfg.agents.defaults.workspace = "/data/.openclaw/workspace";
}

if (
  !cfg.agents.defaults.model ||
  typeof cfg.agents.defaults.model !== "object" ||
  !cfg.agents.defaults.model.primary
) {
  cfg.agents.defaults.model = {
    primary: "anthropic/claude-opus-4-6",
    fallbacks: ["deepseek/deepseek-chat"],
  };
}

if (!Array.isArray(cfg.agents.list) || cfg.agents.list.length === 0) {
  cfg.agents.list = [{ id: "main", default: true, workspace: "/data/.openclaw/workspace" }];
}

cfg.session = cfg.session && typeof cfg.session === "object" ? cfg.session : {};
if (!cfg.session.dmScope) cfg.session.dmScope = "main";

cfg.channels = cfg.channels && typeof cfg.channels === "object" ? cfg.channels : {};
cfg.channels.telegram =
  cfg.channels.telegram && typeof cfg.channels.telegram === "object" ? cfg.channels.telegram : {};
cfg.channels.telegram.enabled = true;

const accounts =
  cfg.channels.telegram.accounts && typeof cfg.channels.telegram.accounts === "object"
    ? cfg.channels.telegram.accounts
    : {};

const legacyBotToken =
  typeof cfg.channels.telegram.botToken === "string" ? cfg.channels.telegram.botToken.trim() : "";
if (!accounts.default && legacyBotToken) {
  accounts.default = { enabled: true, botToken: legacyBotToken };
}

const upsertAccount = (accountId, token, defaults) => {
  const current = accounts[accountId] && typeof accounts[accountId] === "object" ? accounts[accountId] : {};
  accounts[accountId] = {
    ...defaults,
    ...current,
    ...(token ? { botToken: token } : {}),
    enabled: true,
  };
};

upsertAccount("default", openclawToken, {
  agentId: "main",
  model: "anthropic/claude-opus-4-6",
});
upsertAccount("deepseek", deepclawToken, {
  agentId: "main",
  model: "deepseek/deepseek-chat",
});

cfg.channels.telegram.accounts = accounts;

cfg.memory = cfg.memory && typeof cfg.memory === "object" ? cfg.memory : {};
cfg.cron = cfg.cron && typeof cfg.cron === "object" ? cfg.cron : {};
if (typeof cfg.cron.enabled !== "boolean") cfg.cron.enabled = true;

cfg.hooks = cfg.hooks && typeof cfg.hooks === "object" ? cfg.hooks : {};
cfg.hooks.internal =
  cfg.hooks.internal && typeof cfg.hooks.internal === "object" ? cfg.hooks.internal : {};
if (typeof cfg.hooks.internal.enabled !== "boolean") cfg.hooks.internal.enabled = true;
cfg.hooks.internal.entries =
  cfg.hooks.internal.entries && typeof cfg.hooks.internal.entries === "object"
    ? cfg.hooks.internal.entries
    : {};
if (!cfg.hooks.internal.entries["session-memory"]) {
  cfg.hooks.internal.entries["session-memory"] = { enabled: true };
}
if (!cfg.hooks.internal.entries["data-redaction"]) {
  cfg.hooks.internal.entries["data-redaction"] = { enabled: true };
}

cfg.plugins = cfg.plugins && typeof cfg.plugins === "object" ? cfg.plugins : {};
cfg.plugins.allow = Array.isArray(cfg.plugins.allow) ? cfg.plugins.allow : [];
for (const pluginId of ["telegram", "memory-core"]) {
  if (!cfg.plugins.allow.includes(pluginId)) {
    cfg.plugins.allow.push(pluginId);
  }
}
cfg.plugins.entries =
  cfg.plugins.entries && typeof cfg.plugins.entries === "object" ? cfg.plugins.entries : {};
for (const pluginId of ["telegram", "memory-core"]) {
  cfg.plugins.entries[pluginId] =
    cfg.plugins.entries[pluginId] && typeof cfg.plugins.entries[pluginId] === "object"
      ? cfg.plugins.entries[pluginId]
      : {};
  cfg.plugins.entries[pluginId].enabled = true;
}

cfg.meta = cfg.meta && typeof cfg.meta === "object" ? cfg.meta : {};
cfg.meta.lastTouchedVersion = "2026.2.16";

fs.writeFileSync(configPath, `${JSON.stringify(cfg, null, 2)}\n`, "utf8");
NODE

mkdir -p "${STATE_DIR}/workspace" "${STATE_DIR}/memory" "${STATE_DIR}/agents/main/sessions"
chmod 700 "${STATE_DIR}" 2>/dev/null || true
chmod 600 "${CONFIG_PATH}" 2>/dev/null || true

exec node openclaw.mjs gateway --allow-unconfigured --bind lan
