import type { ChannelAccountHealthSummary, HealthSummary } from "../commands/health.js";

export type GatewayLivenessAccountStatus = {
  accountId: string;
  present: boolean;
  configured: boolean | null;
  probeOk: boolean | null;
  status: number | null;
  username: string | null;
  error: string | null;
  lastProbeAtMs: number | null;
};

export type GatewayLivenessResult = {
  ok: boolean;
  reasons: string[];
  requiredTelegramAccounts: string[];
  checkedAtMs: number | null;
  ageMs: number | null;
  stale: boolean;
  staleAfterMs: number;
  telegram: Record<string, GatewayLivenessAccountStatus>;
};

const DEFAULT_REQUIRED_TELEGRAM_ACCOUNTS = ["deepseek"];
const DEFAULT_STALE_AFTER_MS = 3 * 60_000;

const asRecord = (value: unknown): Record<string, unknown> | null =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : null;

const parsePositiveInt = (raw: unknown): number | null => {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    return null;
  }
  return Math.floor(value);
};

const normalizeAccountIdList = (values: string[]): string[] => {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const raw of values) {
    const value = String(raw || "").trim();
    if (!value) {
      continue;
    }
    const key = value.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(value);
  }
  return out;
};

const resolveRequiredTelegramAccounts = (raw?: string[] | null): string[] => {
  if (Array.isArray(raw)) {
    const normalized = normalizeAccountIdList(raw);
    if (normalized.length > 0) {
      return normalized;
    }
  }
  const fromEnv = String(process.env.OPENCLAW_HEALTH_REQUIRED_TELEGRAM_ACCOUNTS || "")
    .split(",")
    .map((entry) => entry.trim());
  const envNormalized = normalizeAccountIdList(fromEnv);
  if (envNormalized.length > 0) {
    return envNormalized;
  }
  return [...DEFAULT_REQUIRED_TELEGRAM_ACCOUNTS];
};

const resolveStaleAfterMs = (override?: number): number => {
  const explicit = parsePositiveInt(override);
  if (explicit != null) {
    return explicit;
  }
  const fromEnv = parsePositiveInt(process.env.OPENCLAW_HEALTH_STALE_MS);
  if (fromEnv != null) {
    return fromEnv;
  }
  return DEFAULT_STALE_AFTER_MS;
};

const describeProbeFailure = (status: GatewayLivenessAccountStatus): string => {
  let message = `telegram account "${status.accountId}" probe not ok`;
  if (status.status != null) {
    message += ` (status ${status.status})`;
  }
  if (status.error) {
    message += `: ${status.error}`;
  }
  return message;
};

const toAccountStatus = (
  accountId: string,
  summary: ChannelAccountHealthSummary | undefined,
): GatewayLivenessAccountStatus => {
  const probe = asRecord(summary?.probe);
  const bot = asRecord(probe?.bot);
  const probeOk = typeof probe?.ok === "boolean" ? probe.ok : null;
  const status = typeof probe?.status === "number" ? probe.status : null;
  const username = typeof bot?.username === "string" ? bot.username : null;
  const error = typeof probe?.error === "string" ? probe.error : null;
  const lastProbeAtMs = parsePositiveInt(summary?.lastProbeAt) ?? null;

  return {
    accountId,
    present: Boolean(summary),
    configured: summary ? summary.configured !== false : null,
    probeOk,
    status,
    username,
    error,
    lastProbeAtMs,
  };
};

export function evaluateGatewayLivenessFromHealth(
  health: HealthSummary | null | undefined,
  opts?: {
    requiredTelegramAccounts?: string[];
    staleAfterMs?: number;
    nowMs?: number;
  },
): GatewayLivenessResult {
  const reasons: string[] = [];
  const requiredTelegramAccounts = resolveRequiredTelegramAccounts(opts?.requiredTelegramAccounts);
  const staleAfterMs = resolveStaleAfterMs(opts?.staleAfterMs);
  const nowMs = parsePositiveInt(opts?.nowMs) ?? Date.now();

  const checkedAtMs =
    health && typeof health.ts === "number" && Number.isFinite(health.ts) ? health.ts : null;
  const ageMs = checkedAtMs == null ? null : Math.max(0, nowMs - checkedAtMs);
  const stale = checkedAtMs == null || ageMs == null || ageMs > staleAfterMs;
  if (health == null) {
    reasons.push("health snapshot unavailable");
  }
  if (stale) {
    if (ageMs == null) {
      reasons.push("health snapshot timestamp unavailable");
    } else {
      reasons.push(`health snapshot stale (${ageMs}ms > ${staleAfterMs}ms)`);
    }
  }

  const telegramChannel = asRecord(health?.channels?.telegram);
  const accountsRecord = asRecord(telegramChannel?.accounts) ?? {};
  const discoveredAccountIds = Object.keys(accountsRecord);
  const accountIds = normalizeAccountIdList([...requiredTelegramAccounts, ...discoveredAccountIds]);

  const telegram: Record<string, GatewayLivenessAccountStatus> = {};
  for (const accountId of accountIds) {
    const rawSummary = accountsRecord[accountId];
    const summary =
      rawSummary && typeof rawSummary === "object"
        ? (rawSummary as ChannelAccountHealthSummary)
        : undefined;
    const status = toAccountStatus(accountId, summary);
    telegram[accountId] = status;
  }

  for (const accountId of requiredTelegramAccounts) {
    const status = telegram[accountId] ?? toAccountStatus(accountId, undefined);
    telegram[accountId] = status;
    if (!status.present) {
      reasons.push(`telegram account "${accountId}" missing from health snapshot`);
      continue;
    }
    if (status.configured === false) {
      reasons.push(`telegram account "${accountId}" is not configured`);
      continue;
    }
    if (status.probeOk !== true) {
      reasons.push(describeProbeFailure(status));
    }
  }

  return {
    ok: reasons.length === 0,
    reasons,
    requiredTelegramAccounts,
    checkedAtMs,
    ageMs,
    stale,
    staleAfterMs,
    telegram,
  };
}
