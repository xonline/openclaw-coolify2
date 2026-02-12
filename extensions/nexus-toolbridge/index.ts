import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { emptyPluginConfigSchema, jsonResult } from "openclaw/plugin-sdk";
import crypto from "node:crypto";

function normalizeBaseUrl(input: string | undefined | null): string {
  const raw = String(input ?? "").trim();
  return raw ? raw.replace(/\/+$/, "") : "";
}

function extractNexusUserFromSessionKey(
  sessionKey: string | undefined,
): { userId: string; conversationId: string | null } | null {
  const raw = String(sessionKey ?? "").trim();
  if (!raw) return null;

  // Nexus calls OpenClaw /v1/chat/completions with:
  //   user = "<nexusUserId>:<conversationId>"
  // OpenClaw maps that to a sessionKey like:
  //   agent:<agentId>:openai-user:<nexusUserId>:<conversationId>
  const lowered = raw.toLowerCase();
  const marker = "openai-user:";
  const idx = lowered.indexOf(marker);
  if (idx < 0) return null;

  const after = raw.slice(idx + marker.length);
  const parts = after.split(":").filter(Boolean);
  if (parts.length === 0) return null;

  return {
    userId: parts[0],
    conversationId: parts.length > 1 ? parts.slice(1).join(":") : null,
  };
}

function resolveNexusApiUrl(): string {
  return (
    normalizeBaseUrl(process.env.NEXUS_API_URL) ||
    normalizeBaseUrl(process.env.NEXUS_BASE_URL) ||
    "https://napi.marcoby.net"
  );
}

function resolveNexusOpenClawApiKey(): string {
  return (
    String(process.env.NEXUS_OPENCLAW_API_KEY || "").trim() ||
    String(process.env.OPENCLAW_API_KEY || "").trim() ||
    String(process.env.OPENCLAW_GATEWAY_TOKEN || "").trim() ||
    "sk-openclaw-local"
  );
}

async function callNexusTool(params: {
  api: OpenClawPluginApi;
  sessionKey: string | undefined;
  toolName: string;
  args: Record<string, unknown>;
  toolCallId: string;
  signal?: AbortSignal | undefined;
}): Promise<unknown> {
  const nexusApiUrl = resolveNexusApiUrl();
  const apiKey = resolveNexusOpenClawApiKey();

  const nexusUser = extractNexusUserFromSessionKey(params.sessionKey);
  if (!nexusUser?.userId) {
    throw new Error(
      "Cannot resolve Nexus user id for tool execution. " +
        "Expected sessionKey to contain `openai-user:<nexusUserId>:<conversationId>`.",
    );
  }

  const correlationId = params.toolCallId || crypto.randomUUID();
  const endpoint = `${nexusApiUrl}/api/openclaw/tools/execute`;

  params.api.logger.info(
    `[nexus-toolbridge] tool=${params.toolName} userId=${nexusUser.userId} corr=${correlationId}`,
  );

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-OpenClaw-Api-Key": apiKey,
      "X-Nexus-User-Id": nexusUser.userId,
      "X-Correlation-Id": correlationId,
    },
    body: JSON.stringify({ tool: params.toolName, args: params.args ?? {} }),
    signal: params.signal,
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const errMsg =
      (payload && typeof payload === "object" && "error" in payload && (payload as any).error) ||
      `Nexus tool execution failed (HTTP ${response.status})`;
    throw new Error(String(errMsg));
  }

  // Expected: { success: true, tool: "...", result: ... }
  if (payload && typeof payload === "object" && "result" in payload) {
    return (payload as any).result;
  }
  return payload;
}

const nexusToolbridgePlugin = {
  id: "nexus-toolbridge",
  name: "Nexus Tool Bridge",
  description: "Expose Nexus integration tools to OpenClaw by proxying Nexus /api/openclaw/tools/execute.",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    api.registerTool((ctx) => {
      const sessionKey = ctx.sessionKey;

      const makeTool = (toolName: string, description: string, parameters: Record<string, unknown>) => {
        return {
          name: toolName,
          description,
          parameters,
          execute: async (
            toolCallId: string,
            params: unknown,
            signal?: AbortSignal | undefined,
          ) => {
            const args =
              params && typeof params === "object" && !Array.isArray(params)
                ? (params as Record<string, unknown>)
                : {};

            const result = await callNexusTool({
              api,
              sessionKey,
              toolName,
              args,
              toolCallId,
              signal,
            });

            return jsonResult({
              tool: toolName,
              result,
            });
          },
        };
      };

      return [
        makeTool("nexus_get_integration_status", "Get current integration status for the signed-in Nexus user.", {
          type: "object",
          additionalProperties: false,
          properties: {},
        }),
        makeTool("nexus_resolve_email_provider", "Resolve email provider from MX records (Microsoft 365 vs Google Workspace).", {
          type: "object",
          additionalProperties: false,
          required: ["email"],
          properties: {
            email: { type: "string" },
          },
        }),
        makeTool("nexus_start_email_connection", "Start OAuth connection flow for an email provider.", {
          type: "object",
          additionalProperties: false,
          required: ["provider"],
          properties: {
            provider: { type: "string", description: 'Provider slug, e.g. "microsoft" or "google-workspace".' },
            redirectUri: { type: "string" },
          },
        }),
        makeTool("nexus_connect_imap", "Connect an IMAP inbox using host/port credentials (fallback when OAuth is unavailable).", {
          type: "object",
          additionalProperties: false,
          required: ["email", "host", "port", "username", "password"],
          properties: {
            email: { type: "string" },
            host: { type: "string" },
            port: { type: "number" },
            username: { type: "string" },
            password: { type: "string" },
            useSSL: { type: "boolean" },
            providerHint: { type: "string" },
          },
        }),
        makeTool("nexus_test_integration_connection", "Test saved OAuth connection health for a provider.", {
          type: "object",
          additionalProperties: false,
          required: ["provider"],
          properties: {
            provider: { type: "string" },
          },
        }),
        makeTool("nexus_search_emails", "Search connected inbox emails by date range, sender(s), and free-text query.", {
          type: "object",
          additionalProperties: false,
          properties: {
            provider: { type: "string", description: '"auto", "all", "microsoft", or "google-workspace".' },
            datePreset: { type: "string" },
            startDate: { type: "string" },
            endDate: { type: "string" },
            from: {
              oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
            },
            query: { type: "string" },
            unreadOnly: { type: "boolean" },
            limit: { type: "number" },
          },
        }),
        makeTool("nexus_disconnect_integration", "Disconnect an integration by ID or provider.", {
          type: "object",
          additionalProperties: false,
          properties: {
            integrationId: { type: "string" },
            provider: { type: "string" },
          },
        }),
      ];
    });
  },
};

export default nexusToolbridgePlugin;

