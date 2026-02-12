#!/usr/bin/env node
/**
 * Minimal OpenResponses (/v1/responses) mock server for testing OpenClaw tool calling.
 *
 * Behavior:
 * - First request: returns a function_call for TOOL_NAME (default: nexus_get_integration_status)
 * - Follow-up request (contains function_call_output): returns an assistant message echoing the tool output.
 *
 * This lets you validate end-to-end flow:
 * OpenClaw chat -> model tool_call -> OpenClaw executes tool -> model sees tool result -> assistant reply.
 */

const http = require("node:http");
const { randomUUID } = require("node:crypto");
const fs = require("node:fs");

const PORT = Number(process.env.PORT || process.env.MOCK_OPENRESPONSES_PORT || 18080);
const TOOL_NAME = String(process.env.TOOL_NAME || "nexus_get_integration_status").trim();
const MODE = String(process.env.MOCK_MODE || "tool").trim().toLowerCase(); // "tool" | "message"

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-cache",
  });
  res.end(body);
}

function sendText(res, status, body) {
  res.writeHead(status, {
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-cache",
  });
  res.end(body);
}

async function readJsonBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw.trim()) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return { __parseError: true, raw };
  }
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function buildUsage() {
  return { input_tokens: 0, output_tokens: 0, total_tokens: 0 };
}

function buildResponseResource({ id, model, status, output, outputText }) {
  return {
    id,
    object: "response",
    created_at: nowSeconds(),
    status,
    model,
    output,
    usage: buildUsage(),
    ...(typeof outputText === "string" ? { output_text: outputText } : {}),
  };
}

function firstFunctionCallResponse({ model }) {
  const responseId = `resp_${randomUUID().replace(/-/g, "")}`;
  const callId = `call_${randomUUID().replace(/-/g, "")}`;
  const itemId = `fc_${randomUUID().replace(/-/g, "")}`;

  return buildResponseResource({
    id: responseId,
    model,
    status: "completed",
    output: [
      {
        type: "function_call",
        id: itemId,
        call_id: callId,
        name: TOOL_NAME,
        arguments: "{}",
        status: "completed",
      },
    ],
  });
}

function finalMessageResponse({ model, toolOutputText }) {
  const responseId = `resp_${randomUUID().replace(/-/g, "")}`;
  const msgId = `msg_${randomUUID().replace(/-/g, "")}`;

  const text =
    `I used ${TOOL_NAME} and got this result:\\n\\n` +
    (toolOutputText && String(toolOutputText).trim()
      ? String(toolOutputText).trim()
      : "(empty tool output)");

  return buildResponseResource({
    id: responseId,
    model,
    status: "completed",
    output: [
      {
        type: "message",
        id: msgId,
        role: "assistant",
        content: [{ type: "output_text", text }],
        status: "completed",
      },
    ],
    outputText: text,
  });
}

function extractFunctionCallOutputs(input) {
  if (!Array.isArray(input)) return [];
  return input.filter((item) => item && typeof item === "object" && item.type === "function_call_output");
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);

  if (req.method === "GET" && url.pathname === "/health") {
    return sendJson(res, 200, { ok: true });
  }

  const isResponsesEndpoint = req.method === "POST" && url.pathname.toLowerCase().endsWith("/responses");
  if (!isResponsesEndpoint) {
    return sendText(res, 404, "not found");
  }

  const body = await readJsonBody(req);
  if (body && body.__parseError) {
    return sendJson(res, 400, { error: "invalid_json", message: "Request body must be valid JSON." });
  }

  const model = String(body?.model || "mock/mock-nexus-toolbridge").trim();
  try {
    fs.writeFileSync("/tmp/mock-openresponses-last.json", JSON.stringify(body ?? null, null, 2));
  } catch {
    // Best-effort debug dump; ignore failures (e.g., permissions).
  }
  const input = body?.input;
  const outputs = extractFunctionCallOutputs(input);
  const toolsCount = Array.isArray(body?.tools) ? body.tools.length : 0;
  const toolNames = Array.isArray(body?.tools)
    ? body.tools
        .map((tool) => {
          if (!tool || typeof tool !== "object") return null;
          // OpenClaw sends OpenAI-style tool defs: { type:"function", name, description, parameters }.
          // Some providers (OpenResponses spec) nest this under { function: { name } }.
          if (tool.type === "function" && typeof tool.name === "string") return tool.name;
          if (tool.type === "function" && tool.function && typeof tool.function.name === "string") return tool.function.name;
          return null;
        })
        .filter(Boolean)
    : [];
  const hasTool = (name) => toolNames.includes(name);
  const hasNexusTools = toolNames.some((name) => String(name).startsWith("nexus_"));
  const toolChoice = body?.tool_choice ? JSON.stringify(body.tool_choice) : "";

  const correlation = String(req.headers["x-correlation-id"] || "").trim() || null;
  const stage = outputs.length ? "final" : "tool_call";
  process.stdout.write(
    `[mock-openresponses] ${new Date().toISOString()} ${stage} model=${model} tools=${toolsCount}` +
      (toolsCount ? ` has_nexus=${hasNexusTools ? "yes" : "no"}` : "") +
      (toolsCount && hasTool(TOOL_NAME) ? " has_target_tool=yes" : toolsCount ? " has_target_tool=no" : "") +
      (toolsCount ? ` tool_names=${toolNames.join(",")}` : "") +
      (toolChoice ? ` tool_choice=${toolChoice}` : "") +
      (correlation ? ` corr=${correlation}` : "") +
      "\\n"
  );

  if (!outputs.length) {
    if (MODE === "message") {
      return sendJson(res, 200, finalMessageResponse({ model, toolOutputText: "hello from mock model" }));
    }
    return sendJson(res, 200, firstFunctionCallResponse({ model }));
  }

  // If multiple tool outputs are present, just echo the first one for readability.
  const toolOutputText = outputs[0]?.output;
  return sendJson(res, 200, finalMessageResponse({ model, toolOutputText }));
});

server.listen(PORT, "0.0.0.0", () => {
  // Keep startup log one-line so it stays readable in docker/CI logs.
  process.stdout.write(`[mock-openresponses] listening on http://0.0.0.0:${PORT}\\n`);
});
