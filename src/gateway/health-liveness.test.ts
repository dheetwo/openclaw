import { describe, expect, test } from "vitest";
import type { ChannelAccountHealthSummary, HealthSummary } from "../commands/health.js";
import { evaluateGatewayLivenessFromHealth } from "./health-liveness.js";

const buildHealthSnapshot = (
  nowMs: number,
  telegramAccounts: Record<string, ChannelAccountHealthSummary>,
): HealthSummary =>
  ({
    ok: true,
    ts: nowMs,
    durationMs: 12,
    channels: {
      telegram: {
        accountId: "deepseek",
        configured: true,
        accounts: telegramAccounts,
      },
    },
    channelOrder: ["telegram"],
    channelLabels: { telegram: "Telegram" },
    heartbeatSeconds: 0,
    defaultAgentId: "main",
    agents: [
      {
        agentId: "main",
        isDefault: true,
        heartbeat: {
          enabled: false,
          every: "disabled",
          everyMs: null,
          prompt: "",
          target: "last",
          ackMaxChars: 0,
        },
        sessions: {
          path: "/tmp/openclaw-sessions.json",
          count: 0,
          recent: [],
        },
      },
    ],
    sessions: {
      path: "/tmp/openclaw-sessions.json",
      count: 0,
      recent: [],
    },
  }) satisfies HealthSummary;

describe("evaluateGatewayLivenessFromHealth", () => {
  test("fails when health snapshot is unavailable", () => {
    const result = evaluateGatewayLivenessFromHealth(null, {
      nowMs: 1_000,
      staleAfterMs: 180_000,
      requiredTelegramAccounts: ["deepseek"],
    });

    expect(result.ok).toBe(false);
    expect(result.stale).toBe(true);
    expect(result.reasons).toContain("health snapshot unavailable");
  });

  test("passes when required deepseek account probe is healthy", () => {
    const snapshot = buildHealthSnapshot(10_000, {
      deepseek: {
        accountId: "deepseek",
        configured: true,
        probe: {
          ok: true,
          status: 200,
          bot: { username: "decaf_deepclaw_bot" },
        },
      },
    });

    const result = evaluateGatewayLivenessFromHealth(snapshot, {
      nowMs: 10_500,
      staleAfterMs: 180_000,
      requiredTelegramAccounts: ["deepseek"],
    });

    expect(result.ok).toBe(true);
    expect(result.reasons).toEqual([]);
    expect(result.telegram.deepseek.probeOk).toBe(true);
    expect(result.telegram.deepseek.username).toBe("decaf_deepclaw_bot");
  });

  test("fails when required deepseek account probe is unauthorized", () => {
    const snapshot = buildHealthSnapshot(20_000, {
      deepseek: {
        accountId: "deepseek",
        configured: true,
        probe: {
          ok: false,
          status: 401,
          error: "Unauthorized",
        },
      },
    });

    const result = evaluateGatewayLivenessFromHealth(snapshot, {
      nowMs: 20_500,
      staleAfterMs: 180_000,
      requiredTelegramAccounts: ["deepseek"],
    });

    expect(result.ok).toBe(false);
    expect(result.reasons.some((reason) => reason.includes("status 401"))).toBe(true);
  });

  test("fails when snapshot is stale even if probes were healthy", () => {
    const snapshot = buildHealthSnapshot(30_000, {
      deepseek: {
        accountId: "deepseek",
        configured: true,
        probe: {
          ok: true,
          status: 200,
        },
      },
    });

    const result = evaluateGatewayLivenessFromHealth(snapshot, {
      nowMs: 300_001,
      staleAfterMs: 180_000,
      requiredTelegramAccounts: ["deepseek"],
    });

    expect(result.ok).toBe(false);
    expect(result.stale).toBe(true);
    expect(result.reasons.some((reason) => reason.includes("snapshot stale"))).toBe(true);
  });
});
