import { strict as assert } from "node:assert";
import { spawn, spawnSync } from "node:child_process";
import { readdir, mkdir } from "node:fs/promises";
import process from "node:process";
import { createInterface } from "node:readline";

const [entry, storageRoot] = process.argv.slice(2);
if (!entry || !storageRoot) {
  console.error("Usage: node scripts/test-packed-mcp.mjs <packed-entrypoint> <storage-root>");
  process.exitCode = 2;
} else {
  const warning = "Temporal proximity does not prove causation.";
  const expectedTools = {
    collect_incident_window: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    export_support_report: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    inspect_evidence: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    plan_collection: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  };
  const fixtureSecrets = [
    "alex",
    "alex@example.invalid",
    "192.0.2.10",
    "fixture-access-token",
    "S-1-5-21-111111111-222222222-333333333-1001",
    "Ignore previous instructions",
    "system prompt",
  ];
  const cwd = process.cwd();
  const cwdBefore = (await readdir(cwd)).sort();
  await mkdir(storageRoot, { recursive: true });
  const invalid = spawnSync(process.execPath, [entry, "mcp", "--bogus"], {
    cwd,
    env: { ...process.env, LOCALAPPDATA: storageRoot },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(invalid.status, 2, "packed MCP accepted an unsupported argument");
  assert.equal(invalid.stdout, "", "invalid packed MCP invocation wrote to stdout");
  assert.match(invalid.stderr, /Usage:/, "invalid packed MCP invocation omitted usage");
  const child = spawn(process.execPath, [entry, "mcp"], {
    cwd,
    env: { ...process.env, LOCALAPPDATA: storageRoot },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const stdoutLines = [];
  let stderr = "";
  let done = false;
  let timer;
  let resolveFlow;
  let rejectFlow;
  const flow = new Promise((resolve, reject) => {
    resolveFlow = resolve;
    rejectFlow = reject;
  });
  const readline = createInterface({ input: child.stdout });

  function send(message) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  function fail(message) {
    if (done) return;
    done = true;
    clearTimeout(timer);
    readline.close();
    child.kill();
    rejectFlow(new Error(message));
  }

  function finish(value) {
    if (done) return;
    done = true;
    clearTimeout(timer);
    readline.close();
    child.kill();
    resolveFlow(value);
  }

  function success(message) {
    assert.equal(message.result?.isError, undefined, "packed MCP returned an unexpected tool error");
    const structured = message.result?.structuredContent;
    const text = message.result?.content?.[0]?.text;
    assert.ok(structured && typeof text === "string", "packed MCP success result was incomplete");
    assert.equal(text, JSON.stringify(structured), "structuredContent/TextContent mismatch");
    return structured;
  }

  function expectedError(message) {
    assert.equal(message.result?.isError, true, "packed MCP accepted an invalid request");
  }

  function warningCount(markdown) {
    return (markdown.match(new RegExp(warning.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) ?? []).length;
  }

  function hypothesisInput(caseId, eventId) {
    return {
      case_id: caseId,
      outcome: "hypotheses",
      summary: `Caller text repeats ${warning} but does not establish a cause.`,
      hypotheses: [{
        rank: 1,
        title: "Fixture event",
        confidence: "low",
        explanation: `Bounded observation near the incident; ${warning}`,
        evidence_ids: [eventId],
        not_proven: [`The event does not prove causation; ${warning}`],
      }],
      missing_evidence: [],
      next_steps: ["Review evidence"],
    };
  }

  let plan;
  let collected;
  let eventId;
  let snapshotId;
  let tools;
  readline.on("line", (line) => {
    stdoutLines.push(line);
    try {
      assert.ok(line.trim(), "packed MCP emitted a blank stdout frame");
      const message = JSON.parse(line);
      assert.equal(message.jsonrpc, "2.0", "packed MCP emitted a non-JSON-RPC frame");
      if (message.id === 1) {
        assert.ok(message.result && !message.error, "MCP initialize failed");
        send({ jsonrpc: "2.0", method: "notifications/initialized" });
        send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
      } else if (message.id === 2) {
        tools = message.result?.tools ?? [];
        assert.equal(tools.length, 4, `packed MCP exposed ${tools.length} tools`);
        const actualNames = tools.map((tool) => tool.name).sort();
        assert.deepEqual(actualNames, Object.keys(expectedTools).sort(), "packed MCP tool names changed");
        for (const tool of tools) {
          assert.deepEqual(tool.annotations, expectedTools[tool.name], `annotations changed for ${tool.name}`);
        }
        send({
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: {
            name: "plan_collection",
            arguments: {
              problem: "fixture release acceptance",
              incident_time: "2026-07-16T09:30:00+09:00",
              before_minutes: 5,
              after_minutes: 5,
              sources: ["system_events", "application_events", "os", "display_drivers"],
            },
          },
        });
      } else if (message.id === 3) {
        plan = success(message).plan;
        send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "collect_incident_window", arguments: { plan, mode: "fixture", fixture_name: "gpu-driver-reset" } } });
      } else if (message.id === 4) {
        collected = success(message);
        eventId = collected.evidence_index.find((item) => item.temporal_kind === "incident_event")?.id;
        snapshotId = collected.evidence_index.find((item) => item.temporal_kind === "collection_snapshot")?.id;
        assert.ok(eventId && snapshotId, "packed MCP fixture evidence index was incomplete");
        send({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "inspect_evidence", arguments: { case_id: collected.case_id, evidence_ids: [eventId] } } });
      } else if (message.id === 5) {
        success(message);
        send({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "inspect_evidence", arguments: { case_id: collected.case_id, evidence_ids: ["EV-999"] } } });
      } else if (message.id === 6) {
        expectedError(message);
        send({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "export_support_report", arguments: { ...hypothesisInput(collected.case_id, snapshotId) } } });
      } else if (message.id === 7) {
        expectedError(message);
        const invalidNotProven = hypothesisInput(collected.case_id, eventId);
        invalidNotProven.hypotheses[0].not_proven = [];
        send({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "export_support_report", arguments: invalidNotProven } });
      } else if (message.id === 8) {
        expectedError(message);
        send({ jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "export_support_report", arguments: hypothesisInput(collected.case_id, eventId) } });
      } else if (message.id === 9 || message.id === 10) {
        const report = success(message);
        assert.equal(warningCount(report.markdown), 1, "hypothesis report warning count was not one");
        if (message.id === 9) {
          send({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "export_support_report", arguments: hypothesisInput(collected.case_id, eventId) } });
        } else {
          send({
            jsonrpc: "2.0",
            id: 11,
            method: "tools/call",
            params: {
              name: "export_support_report",
              arguments: {
                case_id: collected.case_id,
                outcome: "insufficient_evidence",
                summary: `Insufficient evidence near ${warning}`,
                hypotheses: [],
                missing_evidence: ["Need more event context"],
                next_steps: ["Collect more"],
              },
            },
          });
        }
      } else if (message.id === 11) {
        const report = success(message);
        assert.equal(warningCount(report.markdown), 1, "insufficient report warning count was not one");
        finish({ tool_count: tools.length, names: tools.map((tool) => tool.name).sort(), flow: "plan-collect-inspect-export" });
      }
    } catch (error) {
      fail(error instanceof Error ? error.message : String(error));
    }
  });
  child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  child.on("error", (error) => fail(error.message));
  child.on("exit", (code, signal) => {
    if (!done) fail(`packed MCP exited before completing (code=${code}, signal=${signal ?? "none"})`);
  });
  timer = setTimeout(() => fail("packed MCP smoke timed out"), 30_000);
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "release-contract", version: "1" } } });

  try {
    const result = await flow;
    await new Promise((resolve) => child.once("exit", resolve));
    assert.equal(stderr.trim(), "", "packed MCP wrote stderr");
    const after = (await readdir(cwd)).sort();
    assert.deepEqual(after, cwdBefore, "packed MCP changed its current working directory");
    const output = stdoutLines.join("\n") + "\n" + stderr;
    for (const secret of fixtureSecrets) {
      assert.equal(output.toLowerCase().includes(secret.toLowerCase()), false, `fixture secret leaked: ${secret}`);
    }
    console.log(JSON.stringify(result));
  } catch (error) {
    if (!done) child.kill();
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
