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
  "meta": { "lastTouchedVersion": "2026.2.10" }
}
ENDCFG
fi

# Merge env-backed account tokens without deleting existing user config.
CONFIG_PATH="${CONFIG_PATH}" \
TELEGRAM_OPENCLAW_TOKEN="${TELEGRAM_OPENCLAW_TOKEN:-}" \
TELEGRAM_DEEPCLAW_TOKEN="${TELEGRAM_DEEPCLAW_TOKEN:-}" \
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}" \
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const configPath = process.env.CONFIG_PATH;
const TELEGRAM_BOT_TOKEN_PATTERN = /^\d+:[A-Za-z0-9_-]{20,}$/;
const MAIN_AGENT_DIR = "/data/.openclaw/agents/main/agent";
const MAIN_AGENT_AUTH_STORE = path.join(MAIN_AGENT_DIR, "auth-profiles.json");
const AUTH_STORE_VERSION = 1;

const normalizeTelegramToken = (raw) => {
  const value = String(raw || "").trim();
  if (!value) return "";
  if (!TELEGRAM_BOT_TOKEN_PATTERN.test(value)) {
    return "";
  }
  return value;
};

const firstValidTelegramToken = (entries) => {
  for (const [source, raw] of entries) {
    const normalized = normalizeTelegramToken(raw);
    if (normalized) return normalized;
    if (String(raw || "").trim()) {
      console.log(`[startup] ignoring ${source}: invalid telegram bot token format`);
    }
  }
  return "";
};

const openclawToken = firstValidTelegramToken([
  ["TELEGRAM_OPENCLAW_TOKEN", process.env.TELEGRAM_OPENCLAW_TOKEN],
  ["TELEGRAM_BOT_TOKEN", process.env.TELEGRAM_BOT_TOKEN],
]);
const deepclawToken = firstValidTelegramToken([
  ["TELEGRAM_DEEPCLAW_TOKEN", process.env.TELEGRAM_DEEPCLAW_TOKEN],
]);

const normalizeApiKey = (raw) =>
  String(raw || "")
    .replace(/\r?\n/g, "")
    .trim();

const sanitizeProviderKey = (raw) => {
  const value = normalizeApiKey(raw);
  if (!value) return "";
  if (value.includes("[REDACTED")) return "";
  return value;
};

const loadAuthStore = () => {
  try {
    const raw = fs.readFileSync(MAIN_AGENT_AUTH_STORE, "utf8");
    const parsed = raw.trim() ? JSON.parse(raw) : {};
    if (!parsed || typeof parsed !== "object") {
      return { version: AUTH_STORE_VERSION, profiles: {} };
    }
    const profiles =
      parsed.profiles && typeof parsed.profiles === "object" ? { ...parsed.profiles } : {};
    return {
      version:
        typeof parsed.version === "number" && Number.isFinite(parsed.version)
          ? parsed.version
          : AUTH_STORE_VERSION,
      profiles,
      order:
        parsed.order && typeof parsed.order === "object" ? { ...parsed.order } : undefined,
      lastGood:
        parsed.lastGood && typeof parsed.lastGood === "object" ? { ...parsed.lastGood } : undefined,
      usageStats:
        parsed.usageStats && typeof parsed.usageStats === "object"
          ? { ...parsed.usageStats }
          : undefined,
    };
  } catch {
    return { version: AUTH_STORE_VERSION, profiles: {} };
  }
};

const upsertApiKeyProfile = (store, provider, apiKey) => {
  const key = sanitizeProviderKey(apiKey);
  if (!key) return false;
  const profileId = `${provider}:default`;
  const current = store.profiles?.[profileId];
  if (
    current &&
    typeof current === "object" &&
    current.type === "api_key" &&
    String(current.provider || "") === provider &&
    String(current.key || "") === key
  ) {
    return false;
  }
  store.profiles[profileId] = {
    ...(current && typeof current === "object" ? current : {}),
    type: "api_key",
    provider,
    key,
  };
  return true;
};

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

const readBackupToken = (accountId) => {
  const backupPath = `${configPath}.bak`;
  try {
    const raw = fs.readFileSync(backupPath, "utf8");
    const backup = raw.trim() ? JSON.parse(raw) : {};
    const telegram = backup?.channels?.telegram ?? {};
    const accountToken = normalizeTelegramToken(telegram?.accounts?.[accountId]?.botToken);
    if (accountToken) {
      return accountToken;
    }
    if (accountId === "default") {
      const legacy = normalizeTelegramToken(telegram?.botToken);
      if (legacy) {
        return legacy;
      }
    }
  } catch {
    // ignore missing/invalid backup
  }
  return "";
};

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

const DEFAULT_PRIMARY_MODEL = "anthropic/claude-opus-4-6";
const DEFAULT_FALLBACK_MODEL = "deepseek/deepseek-chat";

const normalizeModelRef = (raw) => String(raw || "").trim();
const normalizeUniqueModelRefs = (values) => {
  const out = [];
  const seen = new Set();
  for (const raw of values) {
    const value = normalizeModelRef(raw);
    if (!value) continue;
    const key = value.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(value);
  }
  return out;
};

const rawDefaultsModel = cfg.agents.defaults.model;
const configuredPrimary =
  typeof rawDefaultsModel === "string"
    ? normalizeModelRef(rawDefaultsModel)
    : normalizeModelRef(rawDefaultsModel?.primary);
const configuredFallbacks =
  rawDefaultsModel && typeof rawDefaultsModel === "object" && !Array.isArray(rawDefaultsModel)
    ? normalizeUniqueModelRefs(
        Array.isArray(rawDefaultsModel.fallbacks) ? rawDefaultsModel.fallbacks : [],
      )
    : [];

const normalizedPrimary = configuredPrimary || DEFAULT_PRIMARY_MODEL;
const primaryKey = normalizedPrimary.toLowerCase();
const defaultFallbackKey = DEFAULT_FALLBACK_MODEL.toLowerCase();

let normalizedFallbacks = configuredFallbacks.filter((ref) => ref.toLowerCase() !== primaryKey);
const hasDefaultFallback = normalizedFallbacks.some((ref) => ref.toLowerCase() === defaultFallbackKey);
if (primaryKey !== defaultFallbackKey && !hasDefaultFallback) {
  normalizedFallbacks.push(DEFAULT_FALLBACK_MODEL);
  console.log(`[startup] ensured model fallback ${DEFAULT_FALLBACK_MODEL}`);
}

cfg.agents.defaults.model = {
  primary: normalizedPrimary,
  fallbacks: normalizedFallbacks,
};

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

const tokenLooksValid = (raw) => normalizeTelegramToken(raw).length > 0;

const accountHasToken = (accountId) => {
  const token = accounts?.[accountId]?.botToken;
  return tokenLooksValid(token);
};

for (const accountId of Object.keys(accounts)) {
  const entry = accounts[accountId];
  if (!entry || typeof entry !== "object") continue;
  if ("agentId" in entry) delete entry.agentId;
  if ("model" in entry) delete entry.model;
  if ("botToken" in entry && !tokenLooksValid(entry.botToken)) {
    delete entry.botToken;
    console.log(`[startup] removed invalid telegram bot token from account "${accountId}"`);
  }
}

const legacyRawToken =
  typeof cfg.channels.telegram.botToken === "string" ? cfg.channels.telegram.botToken : "";
const legacyBotToken = normalizeTelegramToken(legacyRawToken);
if (legacyRawToken.trim() && !legacyBotToken) {
  console.log("[startup] ignoring channels.telegram.botToken: invalid telegram bot token format");
}
if (legacyBotToken && !accountHasToken("default")) {
  const current = accounts.default && typeof accounts.default === "object" ? accounts.default : {};
  accounts.default = { ...current, enabled: true, botToken: legacyBotToken };
}

const upsertAccount = (accountId, token) => {
  const current = accounts[accountId] && typeof accounts[accountId] === "object" ? accounts[accountId] : {};
  const next = { ...current };
  if ("agentId" in next) delete next.agentId;
  if ("model" in next) delete next.model;
  accounts[accountId] = {
    ...next,
    ...(token ? { botToken: token } : {}),
    enabled: true,
  };
};

const resolvedOpenclawToken =
  openclawToken || (accountHasToken("default") ? "" : readBackupToken("default"));
const resolvedDeepclawToken =
  deepclawToken || (accountHasToken("deepseek") ? "" : readBackupToken("deepseek"));

upsertAccount("default", resolvedOpenclawToken);
upsertAccount("deepseek", resolvedDeepclawToken);

console.log(
  `[startup] telegram tokens openclaw=${accountHasToken("default") ? "present" : "missing"} deepclaw=${accountHasToken("deepseek") ? "present" : "missing"}`,
);

const deepseekApiKey =
  sanitizeProviderKey(process.env.DEEPSEEK_API_KEY) ||
  sanitizeProviderKey(cfg?.models?.providers?.deepseek?.apiKey);
const anthropicApiKey =
  sanitizeProviderKey(process.env.ANTHROPIC_API_KEY) ||
  sanitizeProviderKey(cfg?.models?.providers?.anthropic?.apiKey);

console.log(
  `[startup] model key env anthropic=${anthropicApiKey ? "present" : "missing"} deepseek=${deepseekApiKey ? "present" : "missing"}`,
);

try {
  fs.mkdirSync(MAIN_AGENT_DIR, { recursive: true });
  const authStore = loadAuthStore();
  authStore.version = AUTH_STORE_VERSION;
  if (!authStore.profiles || typeof authStore.profiles !== "object") {
    authStore.profiles = {};
  }

  const changedProviders = [];
  if (upsertApiKeyProfile(authStore, "anthropic", anthropicApiKey)) {
    changedProviders.push("anthropic");
  }
  if (upsertApiKeyProfile(authStore, "deepseek", deepseekApiKey)) {
    changedProviders.push("deepseek");
  }

  if (changedProviders.length > 0) {
    fs.writeFileSync(MAIN_AGENT_AUTH_STORE, `${JSON.stringify(authStore, null, 2)}\n`, "utf8");
    console.log(`[startup] synced auth profiles: ${changedProviders.join(", ")}`);
  }
} catch (err) {
  console.log(`[startup] failed to sync model auth profiles: ${String(err)}`);
}

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
cfg.meta.lastTouchedVersion = "2026.2.10";

fs.writeFileSync(configPath, `${JSON.stringify(cfg, null, 2)}\n`, "utf8");
NODE

mkdir -p "${STATE_DIR}/workspace" "${STATE_DIR}/memory" "${STATE_DIR}/agents/main/sessions"
chmod 700 "${STATE_DIR}" 2>/dev/null || true
chmod 600 "${CONFIG_PATH}" 2>/dev/null || true

exec node openclaw.mjs gateway --allow-unconfigured --bind lan
