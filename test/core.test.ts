import { mkdir, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, win32 } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { afterEach, describe, expect, it } from "vitest";
import {
  buildCase,
  collectLiveCase,
  collectionRowsSchema,
  decodeDisplayDriverCollectorPayload,
  decodeEventCollectorPayload,
  decodeOsCollectorPayload,
  defaultStorageRoot,
  exportSupportReport,
  fixtureSchema,
  IncidentDocketError,
  inspectEvidence,
  normalizePlan,
  renderTimeline,
  runProcess,
  sanitizeText,
  saveCase,
  symbolicCaseLocation,
  TEMPORAL_PROXIMITY_WARNING,
  validateNormalizedPlan,
  validateReportInput,
} from "../src/core.js";
import { createMcpServer } from "../src/index.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function temporaryDirectory() {
  const directory = await mkdtemp(join(tmpdir(), "incident-docket-test-"));
  temporaryDirectories.push(directory);
  return directory;
}

async function fixture() {
  return fixtureSchema.parse(
    JSON.parse(await readFile(new URL("../samples/gpu-driver-reset.json", import.meta.url), "utf8")),
  );
}

function fixtureRows(value: Awaited<ReturnType<typeof fixture>>) {
  return collectionRowsSchema.parse({
    system_events: value.system_events,
    application_events: value.application_events,
    os: value.os,
    display_drivers: value.display_drivers,
  });
}

const osItem = {
  Caption: "Example Windows 日本語",
  Version: "10.0.26100",
  BuildNumber: "26100",
  OSArchitecture: "64-bit",
  LastBootUpTime: "2026-07-16T00:00:00.000Z",
};

const windows11Product = () => "Windows 11 Pro";

const driverItem = {
  DeviceName: "Example Display Adapter 日本語",
  Manufacturer: "Example Manufacturer",
  DriverProviderName: "Example Provider",
  DriverVersion: "32.0.1.1000",
  DriverDate: "2026-06-30T00:00:00.000Z",
  IsSigned: true,
  Status: "OK",
};

function encodedCollectorPayload(value: unknown) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64");
}

function eventItem(overrides: Record<string, unknown> = {}) {
  return {
    TimeCreated: "2026-07-16T00:30:00.000Z",
    LogName: "System",
    ProviderName: "Example Provider",
    Id: 100,
    Level: 2,
    RecordId: "1",
    Message: "Example event",
    ...overrides,
  };
}

function eventPayload(items: unknown[], overrides: Record<string, unknown> = {}) {
  return encodedCollectorPayload({
    status: items.length > 0 ? "ok" : "no_data",
    items,
    truncated_before: false,
    truncated_after: false,
    ...overrides,
  });
}

function eventPlan(sources: Array<"system_events" | "application_events"> = ["system_events"]) {
  return normalizePlan({
    problem: "Live event window",
    incident_time: "2026-07-16T09:30:00+09:00",
    before_minutes: 5,
    after_minutes: 5,
    sources,
  }).plan;
}

function rowsWithEvents(system: unknown[] = [], application: unknown[] = []) {
  return collectionRowsSchema.parse({
    system_events: system,
    application_events: application,
    os: [],
    display_drivers: [],
  });
}

function osPlan() {
  return normalizePlan({
    problem: "Live OS snapshot",
    incident_time: "2026-07-16T09:30:00+09:00",
    before_minutes: 5,
    after_minutes: 5,
    sources: ["os"],
  }).plan;
}

function driverPlan() {
  return normalizePlan({
    problem: "Live display driver snapshot",
    incident_time: "2026-07-16T09:30:00+09:00",
    before_minutes: 5,
    after_minutes: 5,
    sources: ["display_drivers"],
  }).plan;
}

function forgedPlanCases(base: ReturnType<typeof eventPlan>): Array<[string, Record<string, unknown>]> {
  return [
    ["raw username", { ...base, problem: "fixture-user" }],
    ["2,001 character problem", { ...base, problem: "x".repeat(2_001) }],
    ["offset-free incident", { ...base, incident_time_utc: "2026-07-16T00:30:00.000" }],
    ["before over limit", { ...base, before_minutes: 31 }],
    ["after over limit", { ...base, after_minutes: 31 }],
    ["both sides zero", { ...base, before_minutes: 0, after_minutes: 0 }],
    ["unrelated start", { ...base, window_start_utc: "2020-01-01T00:00:00.000Z" }],
    ["unrelated end", { ...base, window_end_utc: "2020-01-01T00:05:00.000Z" }],
    ["start after incident", { ...base, window_start_utc: "2026-07-16T00:40:00.000Z" }],
    ["end before incident", { ...base, window_end_utc: "2026-07-16T00:20:00.000Z" }],
    ["non-canonical UTC", { ...base, incident_time_utc: "2026-07-16T00:30:00Z" }],
    ["duplicate source", { ...base, sources: ["system_events", "system_events"] }],
    ["unknown source", { ...base, sources: ["unknown"] }],
    ["unknown field", { ...base, unexpected: true }],
    ["forged 2020 window", {
      ...base,
      window_start_utc: "2020-01-01T00:00:00.000Z",
      window_end_utc: "2020-01-01T00:05:00.000Z",
    }],
    ["arithmetic mismatch", { ...base, window_end_utc: "2026-07-16T00:36:00.000Z" }],
  ];
}

describe("schema and deterministic core", () => {
  it("normalizes offsets and rejects invalid windows", () => {
    const normalized = normalizePlan({
      problem: "Display reset",
      incident_time: "2026-07-16T09:30:00+09:00",
      before_minutes: 5,
      after_minutes: 10,
      sources: ["system_events", "os"],
    });
    expect(normalized.plan.incident_time_utc).toBe("2026-07-16T00:30:00.000Z");
    expect(normalized.plan.window_start_utc).toBe("2026-07-16T00:25:00.000Z");
    expect(normalized.plan.window_end_utc).toBe("2026-07-16T00:40:00.000Z");
    for (const [incident_time, before_minutes, after_minutes] of [
      ["2026-07-16T00:30:00Z", 0, 5],
      ["2026-07-16T09:30:00+09:00", 5, 0],
      ["2026-07-16T09:30:00+09:00", 5, 5],
    ] as const) {
      const positive = normalizePlan({
        problem: "Valid collection window",
        incident_time,
        before_minutes,
        after_minutes,
        sources: ["system_events"],
      }).plan;
      expect(validateNormalizedPlan(positive)).toEqual(positive);
    }
    expect(() =>
      normalizePlan({
        problem: "x",
        incident_time: "2026-02-30T00:00:00Z",
        before_minutes: 5,
        after_minutes: 5,
        sources: ["os"],
      }),
    ).toThrow();
    expect(() =>
      normalizePlan({
        problem: "x",
        incident_time: "2026-07-16T00:00:00",
        before_minutes: 0,
        after_minutes: 0,
        sources: ["os", "os"],
      }),
    ).toThrow();
  });

  it("masks compressed IPv6 and standalone credential formats", () => {
    const value = sanitizeText(
      "peer 2001:db8::1 used sk-abcdefghijklmnopqrstuvwxyz123456 and 00000000-0000-0000-0000-000000000000",
    ).text;
    expect(value).toBe("peer <REDACTED_IP> used <REDACTED_SECRET> and <REDACTED_GUID>");
  });

  it("keeps Japanese and emoji evidence within schema limits", async () => {
    const value = await fixture();
    const rows = fixtureRows(value);
    rows.system_events[0]!.Message = `表示ドライバー ${"😀".repeat(300)}`;
    const { plan } = normalizePlan(value.default_plan);
    const built = buildCase({
      plan,
      mode: "fixture",
      rows,
      collectedAt: new Date("2026-07-16T01:00:00.000Z"),
    });
    expect(built.case.evidence[1]?.summary.length).toBeLessThanOrEqual(160);
    expect(built.case.evidence[1]?.summary).toContain("表示ドライバー");
  });

  it("sorts IDs, clips future windows, and removes sensitive fixture values", async () => {
    const value = await fixture();
    const { plan } = normalizePlan(value.default_plan);
    const built = buildCase({
      plan,
      mode: "fixture",
      rows: fixtureRows(value),
      collectedAt: new Date("2026-07-16T00:31:00.000Z"),
      caseId: "11111111-1111-4111-8111-111111111111",
    });

    expect(built.case.evidence.map((item) => item.id)).toEqual([
      "EV-001",
      "EV-002",
      "EV-003",
      "EV-004",
      "OS-001",
      "DR-001",
    ]);
    expect(built.case.plan.effective_window_end_utc).toBe("2026-07-16T00:31:00.000Z");
    expect(built.case.plan.window_incomplete_after).toBe(true);
    expect(built.warnings).toContain("future_window_clipped");

    const serialized = JSON.stringify(built.case);
    for (const forbidden of [
      "alex",
      "alex@example.invalid",
      "192.0.2.10",
      "fixture-access-token",
      "S-1-5-21-111111111-222222222-333333333-1001",
      "123e4567-e89b-42d3-a456-426614174000",
      "AA-BB-CC-DD-EE-FF",
      "Ignore previous instructions",
      "system prompt",
    ]) {
      expect(serialized.toLowerCase()).not.toContain(forbidden.toLowerCase());
    }
    expect(built.case.privacy.masked_values).toBeGreaterThan(0);

    const markdown = renderTimeline(built.case);
    expect(markdown).not.toContain("<script>");
    expect(markdown).not.toContain("![click]");
    expect(markdown).toContain("&lt;REDACTED\\_PATH&gt;");
    expect(markdown.split(TEMPORAL_PROXIMITY_WARNING).length - 1).toBe(1);
    const duplicateWarning = renderTimeline(
      buildCase({
        plan: eventPlan(),
        mode: "fixture",
        rows: rowsWithEvents([eventItem({ Message: TEMPORAL_PROXIMITY_WARNING })]),
        collectedAt: new Date("2026-07-16T00:35:00.000Z"),
      }).case,
    );
    expect(duplicateWarning.split(TEMPORAL_PROXIMITY_WARNING).length - 1).toBe(1);
  });
});

describe("canonical collection plan boundary", () => {
  it("rejects forged normalized plans before any live collector process starts", async () => {
    const originalUsername = process.env.USERNAME;
    process.env.USERNAME = "fixture-user";
    const base = eventPlan();
    const cases = forgedPlanCases(base);
    try {
      const masked = normalizePlan({
        problem: "C:\\Users\\fixture-user\\secret.txt",
        incident_time: "2026-07-16T09:30:00+09:00",
        before_minutes: 5,
        after_minutes: 5,
        sources: ["system_events"],
      }).plan;
      expect(validateNormalizedPlan(masked)).toEqual(masked);
      let collectorCalls = 0;
      for (const [name, forged] of cases) {
        await expect(
          collectLiveCase(forged, {
            platform: "win32",
            osRelease: "10.0.26100",
            osVersion: windows11Product,
            execute: async () => {
              collectorCalls += 1;
              return { stdout: "", stderr: "" };
            },
          }),
          name,
        ).rejects.toThrow();
        expect(() => buildCase({ plan: forged, mode: "fixture", rows: rowsWithEvents() }), name).toThrow();
      }
      expect(collectorCalls).toBe(0);
      expect(() => validateNormalizedPlan({ ...base, problem: "fixture-user" })).toThrow();
    } finally {
      if (originalUsername === undefined) delete process.env.USERNAME;
      else process.env.USERNAME = originalUsername;
    }
  });

  it("rejects forged plans through the MCP boundary without creating a case", async () => {
    const root = await temporaryDirectory();
    const originalUsername = process.env.USERNAME;
    process.env.USERNAME = "fixture-user";
    const server = createMcpServer(root);
    const client = new Client({ name: "incident-docket-plan-boundary-test", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    try {
      const planned = await client.callTool({
        name: "plan_collection",
        arguments: {
          problem: "Example render reset",
          incident_time: "2026-07-16T09:30:00+09:00",
          before_minutes: 5,
          after_minutes: 5,
          sources: ["system_events"],
        },
      });
      const plan = (planned.structuredContent as { plan: Record<string, unknown> }).plan;
      for (const [name, forged] of forgedPlanCases(plan as ReturnType<typeof eventPlan>)) {
        const beforeCwd = process.cwd();
        const result = await client.callTool({
          name: "collect_incident_window",
          arguments: { plan: forged, mode: "fixture", fixture_name: "gpu-driver-reset" },
        });
        expect(result.isError, name).toBe(true);
        expect(process.cwd(), name).toBe(beforeCwd);
        const serialized = JSON.stringify(result);
        expect(serialized, name).not.toContain("fixture-user");
        expect(serialized, name).not.toContain("2020-01-01");
        expect(serialized, name).not.toContain("at ");
        expect(serialized, name).not.toContain(root);
      }
      expect(await readdir(join(root, "cases")).catch(() => [])).toEqual([]);
    } finally {
      await client.close();
      await server.close();
      if (originalUsername === undefined) delete process.env.USERNAME;
      else process.env.USERNAME = originalUsername;
    }
  });
});

describe("inspection and report export", () => {
  it("rejects unknown evidence and snapshot-only hypotheses", async () => {
    const value = await fixture();
    const { plan } = normalizePlan(value.default_plan);
    const built = buildCase({
      plan,
      mode: "fixture",
      rows: fixtureRows(value),
      collectedAt: new Date("2026-07-16T01:00:00.000Z"),
      caseId: "22222222-2222-4222-8222-222222222222",
    });

    expect(() => inspectEvidence(built.case, ["EV-999"])).toThrow("not found");
    expect(() =>
      validateReportInput(built.case, {
        case_id: built.case.case_id,
        outcome: "hypotheses",
        summary: "Possible driver issue",
        hypotheses: [
          {
            rank: 1,
            title: "Installed driver",
            confidence: "low",
            explanation: "The current driver may be relevant.",
            evidence_ids: ["DR-001"],
            not_proven: ["The snapshot was collected after the incident."],
          },
        ],
        missing_evidence: [],
        next_steps: [],
      }),
    ).toThrow("snapshots");
    expect(() =>
      validateReportInput(built.case, {
        case_id: built.case.case_id,
        outcome: "hypotheses",
        summary: "Unknown evidence must fail",
        hypotheses: [
          {
            rank: 1,
            title: "Unknown evidence",
            confidence: "low",
            explanation: "This ID was not returned.",
            evidence_ids: ["EV-999"],
            not_proven: ["Nothing is proven."],
          },
        ],
        missing_evidence: [],
        next_steps: [],
      }),
    ).toThrow("not found");
  });

  it("creates distinct escaped Markdown reports without overwriting", async () => {
    const root = await temporaryDirectory();
    const value = await fixture();
    const { plan } = normalizePlan(value.default_plan);
    const built = buildCase({
      plan,
      mode: "fixture",
      rows: fixtureRows(value),
      collectedAt: new Date("2026-07-16T01:00:00.000Z"),
      caseId: "33333333-3333-4333-8333-333333333333",
    });
    const input = {
      case_id: built.case.case_id,
      outcome: "hypotheses",
      summary: `${TEMPORAL_PROXIMITY_WARNING} [click](https://example.invalid) <script>alert(1)</script>`,
      hypotheses: [
        {
          rank: 1,
          title: "Display reset",
          confidence: "medium",
          explanation: `EV-001 occurred near the incident. ${TEMPORAL_PROXIMITY_WARNING}`,
          evidence_ids: ["EV-001"],
          not_proven: ["Temporal proximity is not causation."],
        },
      ],
      missing_evidence: ["A vendor-specific dump was not collected."],
      next_steps: ["Reproduce with the same workload."],
    };

    const first = await exportSupportReport(built.case, input, root);
    const second = await exportSupportReport(built.case, input, root);
    expect(first.report_id).not.toBe(second.report_id);
    expect(first.markdown).not.toContain("<script>");
    expect(first.markdown).not.toContain("[click](https://example.invalid)");
    expect(first.markdown).toContain("EV-001");
    expect(first.markdown.split(TEMPORAL_PROXIMITY_WARNING).length - 1).toBe(1);
    expect(
      await readFile(join(root, "reports", `report-${first.report_id}.md`), "utf8"),
    ).toBe(first.markdown);
    const insufficient = await exportSupportReport(
      built.case,
      {
        case_id: built.case.case_id,
        outcome: "insufficient_evidence",
        summary: TEMPORAL_PROXIMITY_WARNING,
        hypotheses: [],
        missing_evidence: ["A bounded incident event is missing."],
        next_steps: [],
      },
      root,
    );
    expect(insufficient.markdown.split(TEMPORAL_PROXIMITY_WARNING).length - 1).toBe(1);
  });
});

describe("Windows event evidence boundary", () => {
  it("accepts only the seven event fields, fixed logs, and safe empty messages", () => {
    const parsed = decodeEventCollectorPayload(eventPayload([eventItem({ Message: null })]));
    expect(parsed.items[0]?.Message).toBe("");
    expect(decodeEventCollectorPayload(eventPayload([eventItem({ Message: "" })])).items[0]?.Message).toBe("");

    for (const field of ["MachineName", "UserId", "Properties", "Xml", "UnknownField"]) {
      expect(() =>
        decodeEventCollectorPayload(eventPayload([eventItem({ [field]: field === "Properties" ? [] : "forbidden" })])),
      ).toThrow("validation");
    }
    expect(() => decodeEventCollectorPayload(eventPayload([eventItem({ LogName: "Security" })]))).toThrow(
      "validation",
    );
    expect(() => decodeEventCollectorPayload(eventPayload([eventItem({ Level: 4 })]))).toThrow("validation");
    expect(() => decodeEventCollectorPayload(eventPayload([eventItem({ Level: 5 })]))).toThrow("validation");
    expect(() => decodeEventCollectorPayload("not base64!!")).toThrow("invalid");
    expect(() => decodeEventCollectorPayload(Buffer.from("{", "utf8").toString("base64"))).toThrow("invalid");
  });

  it("includes start, incident, and end boundaries and excludes outside or future events", () => {
    const system = [
      eventItem({ TimeCreated: "2026-07-16T00:24:59.999Z", RecordId: "outside-before" }),
      eventItem({ TimeCreated: "2026-07-16T00:25:00.000Z", RecordId: "start" }),
      eventItem({ TimeCreated: "2026-07-16T00:30:00.000Z", RecordId: "incident" }),
      eventItem({ TimeCreated: "2026-07-16T00:35:00.000Z", RecordId: "end" }),
      eventItem({ TimeCreated: "2026-07-16T00:35:00.001Z", RecordId: "outside-after" }),
    ];
    const built = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents(system),
      collectedAt: new Date("2026-07-16T00:40:00.000Z"),
    });
    expect(built.case.evidence.map((item) => item.timestamp_utc)).toEqual([
      "2026-07-16T00:25:00.000Z",
      "2026-07-16T00:30:00.000Z",
      "2026-07-16T00:35:00.000Z",
    ]);
    expect(built.case.evidence.map((item) => item.id)).toEqual(["EV-001", "EV-002", "EV-003"]);
    expect(built.case.evidence.every((item) => item.kind === "windows_event")).toBe(true);
    expect(built.case.evidence.every((item) => item.temporal_kind === "incident_event")).toBe(true);

    const clipped = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents(system),
      collectedAt: new Date("2026-07-16T00:32:00.000Z"),
    });
    expect(clipped.case.evidence.map((item) => item.timestamp_utc)).not.toContain("2026-07-16T00:35:00.000Z");
    expect(clipped.warnings).toContain("future_window_clipped");

    const beforeIncident = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents(system),
      collectedAt: new Date("2026-07-16T00:29:00.000Z"),
    });
    expect(beforeIncident.case.evidence.map((item) => item.timestamp_utc)).toEqual(["2026-07-16T00:25:00.000Z"]);
    expect(beforeIncident.case.coverage[0]).toMatchObject({ truncated_before: false, truncated_after: false });
  });

  it("handles empty sides and one event on each side", () => {
    const beforeOnly = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents([eventItem({ TimeCreated: "2026-07-16T00:29:59.000Z" })]),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(beforeOnly.case.evidence).toHaveLength(1);
    const afterOnly = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents([eventItem({ TimeCreated: "2026-07-16T00:30:01.000Z" })]),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(afterOnly.case.evidence).toHaveLength(1);
    const both = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents([
        eventItem({ TimeCreated: "2026-07-16T00:29:59.000Z", RecordId: "before" }),
        eventItem({ TimeCreated: "2026-07-16T00:30:01.000Z", RecordId: "after" }),
      ]),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(both.case.evidence).toHaveLength(2);
    const empty = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents(),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(empty.case.coverage[0]?.status).toBe("no_data");
  });

  it("keeps the nearest twenty-five events on each side and reports truncation", () => {
    const system = [
      ...Array.from({ length: 26 }, (_, index) =>
        eventItem({
          TimeCreated: new Date(Date.parse("2026-07-16T00:30:00.000Z") - (index + 1) * 1_000).toISOString(),
          RecordId: `before-${index + 1}`,
        }),
      ),
      ...Array.from({ length: 26 }, (_, index) =>
        eventItem({
          TimeCreated: new Date(Date.parse("2026-07-16T00:30:00.000Z") + (index + 1) * 1_000).toISOString(),
          RecordId: `after-${index + 1}`,
        }),
      ),
    ];
    const exact = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents(system.filter((item) => item.RecordId !== "before-26" && item.RecordId !== "after-26")),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(exact.case.evidence).toHaveLength(50);
    expect(exact.case.coverage[0]).toMatchObject({ truncated_before: false, truncated_after: false });

    const built = buildCase({
      plan: eventPlan(),
      mode: "live",
      rows: rowsWithEvents(system),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(built.case.evidence).toHaveLength(50);
    expect(built.case.coverage[0]).toMatchObject({ truncated_before: true, truncated_after: true });
    const details = built.case.evidence.map((item) => item.details).join("\n");
    expect(details).toContain("RecordId: before-25");
    expect(details).toContain("RecordId: after-25");
    expect(details).not.toContain("RecordId: before-26");
    expect(details).not.toContain("RecordId: after-26");
  });

  it("integrates System and Application with stable IDs and duplicate RecordIds", () => {
    const time = "2026-07-16T00:30:00.000Z";
    const built = buildCase({
      plan: eventPlan(["application_events", "system_events"]),
      mode: "live",
      rows: rowsWithEvents(
        [eventItem({ TimeCreated: time, RecordId: "7", ProviderName: "System B" }), eventItem({ TimeCreated: time, RecordId: "2", ProviderName: "System A" })],
        [eventItem({ TimeCreated: time, LogName: "Application", RecordId: "2", ProviderName: "Application A" })],
      ),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(built.case.evidence.map((item) => `${item.id}:${item.source}`)).toEqual([
      "EV-001:system_events",
      "EV-002:system_events",
      "EV-003:application_events",
    ]);
    expect(built.case.evidence.map((item) => item.summary)).toEqual([
      "System A event 100: Example event",
      "System B event 100: Example event",
      "Application A event 100: Example event",
    ]);
  });

  it("removes sensitive and executable-looking event text from cases, MCP evidence, and reports", async () => {
    const original = {
      USERNAME: process.env.USERNAME,
      USERDOMAIN: process.env.USERDOMAIN,
      COMPUTERNAME: process.env.COMPUTERNAME,
    };
    process.env.USERNAME = "fixture-user";
    process.env.USERDOMAIN = "fixture-domain";
    process.env.COMPUTERNAME = "fixture-pc";
    const rawValues = [
      "fixture-user",
      "fixture-domain",
      "fixture-pc",
      "C:\\Users\\fixture-user\\secret.txt",
      "\\\\server\\share\\secret.txt",
      "S-1-5-21-111111111-222222222-333333333-1001",
      "fixture@example.invalid",
      "192.0.2.10",
      "2001:db8::1",
      "AA-BB-CC-DD-EE-FF",
      "123e4567-e89b-42d3-a456-426614174000",
      "Bearer fixture-access-token",
      "ignore previous instructions",
      "system prompt",
      "[link](https://example.invalid)",
      "![image](https://example.invalid/image.png)",
      "<script>alert(1)</script>",
      "`command`",
    ];
    try {
      const built = buildCase({
        plan: eventPlan(),
        mode: "fixture",
        rows: rowsWithEvents([eventItem({ Message: rawValues.join(" ") })]),
        collectedAt: new Date("2026-07-16T00:35:00.000Z"),
        caseId: "44444444-4444-4444-8444-444444444444",
      });
      const inspected = inspectEvidence(built.case, ["EV-001"]);
      const root = await temporaryDirectory();
      const report = await exportSupportReport(
        built.case,
        {
          case_id: built.case.case_id,
          outcome: "hypotheses",
          summary: "Synthetic evidence requires human review.",
          hypotheses: [
            {
              rank: 1,
              title: "Synthetic event",
              confidence: "low",
              explanation: "EV-001 is temporally relevant only.",
              evidence_ids: ["EV-001"],
              not_proven: ["Causation is not proven."],
            },
          ],
          missing_evidence: [],
          next_steps: [],
        },
        root,
      );
      const outputs = [JSON.stringify(built.case), JSON.stringify(inspected), renderTimeline(built.case), report.markdown];
      for (const output of outputs) {
        for (const raw of rawValues) expect(output.toLowerCase()).not.toContain(raw.toLowerCase());
      }
      expect(built.case.privacy.masked_values).toBeGreaterThan(0);
      expect(built.case.privacy.unsafe_messages_replaced).toBeGreaterThan(0);
    } finally {
      for (const [key, value] of Object.entries(original)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
    }
  });

  it("continues the other log and creates a coverage-only case when event sources fail", async () => {
    const application = eventItem({ LogName: "Application", RecordId: "app" });
    const scenarios = [
      {
        execute: async (_command: string, args: string[]) => {
          if (args.includes("system_events")) throw new IncidentDocketError("collector_timeout", "private timeout");
          return { stdout: eventPayload([application]), stderr: "private stderr" };
        },
        statuses: ["timeout", "ok"],
        count: 1,
      },
      {
        execute: async (_command: string, args: string[]) => {
          if (args.includes("application_events")) throw new IncidentDocketError("collector_unavailable", "private path");
          return { stdout: eventPayload([eventItem()]), stderr: "" };
        },
        statuses: ["ok", "unavailable"],
        count: 1,
      },
      {
        execute: async () => {
          throw new IncidentDocketError("collector_failed", "private failure");
        },
        statuses: ["failed", "failed"],
        count: 0,
      },
    ];
    for (const scenario of scenarios) {
      const built = await collectLiveCase(eventPlan(["system_events", "application_events"]), {
        platform: "win32",
        osRelease: "10.0.26100",
        osVersion: windows11Product,
        execute: scenario.execute,
        collectedAt: new Date("2026-07-16T00:35:00.000Z"),
      });
      expect(built.case.coverage.map((item) => item.status)).toEqual(scenario.statuses);
      expect(built.case.evidence).toHaveLength(scenario.count);
      expect(JSON.stringify(built)).not.toContain("private");
    }
  });

  it("normalizes denied and no-data event coverage and forwards only fixed UTC arguments", async () => {
    const seen: string[][] = [];
    const built = await collectLiveCase(eventPlan(["system_events", "application_events"]), {
      platform: "win32",
      osRelease: "10.0.26100",
      osVersion: windows11Product,
      execute: async (_command, args) => {
        seen.push(args);
        return args.includes("system_events")
          ? { stdout: eventPayload([], { status: "denied" }), stderr: "private denied detail" }
          : { stdout: eventPayload([]), stderr: "" };
      },
      collectedAt: new Date("2026-07-16T00:32:00.000Z"),
    });
    expect(built.case.coverage.map((item) => item.status)).toEqual(["denied", "no_data"]);
    for (const args of seen) {
      expect(args).toContain("-WindowStartUtc");
      expect(args).toContain("2026-07-16T00:25:00.000Z");
      expect(args).toContain("-IncidentTimeUtc");
      expect(args).toContain("2026-07-16T00:30:00.000Z");
      expect(args).toContain("-WindowEndUtc");
      expect(args).toContain("2026-07-16T00:32:00.000Z");
    }
    expect(JSON.stringify(built)).not.toContain("private denied detail");

    const truncated = await collectLiveCase(eventPlan(), {
      platform: "win32",
      osRelease: "10.0.26100",
      osVersion: windows11Product,
      execute: async () => ({
        stdout: eventPayload([eventItem()], { truncated_before: true }),
        stderr: "",
      }),
      collectedAt: new Date("2026-07-16T00:35:00.000Z"),
    });
    expect(truncated.case.coverage[0]).toMatchObject({ truncated_before: true, truncated_after: false });
  });
});

describe("Windows collector boundary", () => {
  it("decodes Base64 UTF-8 JSON with only the OS allowlist", () => {
    expect(decodeOsCollectorPayload(encodedCollectorPayload({ status: "ok", items: [osItem] }))).toEqual({
      status: "ok",
      items: [osItem],
    });
    expect(() =>
      decodeOsCollectorPayload(
        encodedCollectorPayload({ status: "ok", items: [{ ...osItem, RegisteredUser: "forbidden" }] }),
      ),
    ).toThrow("validation");
  });

  it("rejects malformed Base64 and malformed JSON", () => {
    expect(() => decodeOsCollectorPayload("not base64!!")).toThrow("invalid");
    expect(() => decodeOsCollectorPayload(Buffer.from("{", "utf8").toString("base64"))).toThrow("invalid");
  });

  it("accepts only the seven display driver fields and valid Base64 UTF-8 JSON", () => {
    expect(
      decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "ok", items: [driverItem] })),
    ).toEqual({ status: "ok", items: [driverItem] });
    for (const field of ["DeviceID", "HardwareID", "CompatibleID", "PDO", "Location", "InfName", "SystemName"]) {
      expect(() =>
        decodeDisplayDriverCollectorPayload(
          encodedCollectorPayload({ status: "ok", items: [{ ...driverItem, [field]: "forbidden" }] }),
        ),
      ).toThrow("validation");
    }
    expect(() =>
      decodeDisplayDriverCollectorPayload(
        encodedCollectorPayload({ status: "ok", items: [{ ...driverItem, Caption: "undefined" }] }),
      ),
    ).toThrow("validation");
  });

  it("handles no, one, multiple, and at most twenty display drivers", () => {
    expect(decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "no_data", items: [] }))).toEqual({
      status: "no_data",
      items: [],
    });
    expect(
      decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "ok", items: [driverItem] })).items,
    ).toHaveLength(1);
    const twenty = Array.from({ length: 20 }, (_, index) => ({
      ...driverItem,
      DeviceName: `Example Adapter ${String(index).padStart(2, "0")}`,
    }));
    expect(decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "ok", items: twenty })).items).toHaveLength(
      20,
    );
    expect(() =>
      decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "ok", items: [...twenty, driverItem] })),
    ).toThrow("validation");
    expect(() => decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "ok", items: [] }))).toThrow(
      "validation",
    );
  });

  it("accepts present or empty DriverDate and rejects missing or malformed display payloads", () => {
    const emptyDate = { ...driverItem, DriverDate: "" };
    expect(
      decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "ok", items: [emptyDate] })).items[0]
        ?.DriverDate,
    ).toBe("");
    const { DriverDate: _driverDate, ...missingDate } = driverItem;
    expect(() =>
      decodeDisplayDriverCollectorPayload(encodedCollectorPayload({ status: "ok", items: [missingDate] })),
    ).toThrow("validation");
    expect(() =>
      decodeDisplayDriverCollectorPayload(
        encodedCollectorPayload({ status: "ok", items: [{ ...driverItem, DriverDate: "not-a-date" }] }),
      ),
    ).toThrow("validation");
    expect(() => decodeDisplayDriverCollectorPayload("not base64!!")).toThrow("invalid");
    expect(() => decodeDisplayDriverCollectorPayload(Buffer.from("{", "utf8").toString("base64"))).toThrow("invalid");
  });

  it("assigns stable DR IDs and keeps display snapshots out of the incident timeline", async () => {
    const second = { ...driverItem, DeviceName: "Zeta Adapter", DriverDate: "" };
    const first = { ...driverItem, DeviceName: "Alpha Adapter" };
    const built = await collectLiveCase(driverPlan(), {
      platform: "win32",
      osRelease: "10.0.26100",
      osVersion: windows11Product,
      execute: async (_command, args) => {
        expect(args.slice(-2)).toEqual(["-Action", "display_drivers"]);
        return { stdout: encodedCollectorPayload({ status: "ok", items: [second, first] }), stderr: "private diagnostic" };
      },
      collectedAt: new Date("2026-07-16T01:00:00.000Z"),
    });
    expect(built.case.evidence.map(({ id, summary }) => ({ id, summary }))).toEqual([
      { id: "DR-001", summary: "Display driver Alpha Adapter 32.0.1.1000" },
      { id: "DR-002", summary: "Display driver Zeta Adapter 32.0.1.1000" },
    ]);
    expect(built.case.evidence.every((item) => item.temporal_kind === "collection_snapshot")).toBe(true);
    const timeline = renderTimeline(built.case);
    const incidentSection = timeline.slice(timeline.indexOf("## Incident timeline"), timeline.indexOf("## Current state"));
    expect(incidentSection).not.toContain("DR-001");
    expect(timeline).toContain("## Current state at collection time");
    expect(JSON.stringify(built)).not.toContain("private diagnostic");
    expect(() =>
      validateReportInput(built.case, {
        case_id: built.case.case_id,
        outcome: "hypotheses",
        summary: "A snapshot may be relevant.",
        hypotheses: [
          {
            rank: 1,
            title: "Snapshot-only theory",
            confidence: "low",
            explanation: "Only collection-time state is available.",
            evidence_ids: ["DR-001"],
            not_proven: ["The snapshot does not prove incident-time causation."],
          },
        ],
        missing_evidence: [],
        next_steps: [],
      }),
    ).toThrow("snapshots");
  });

  it("normalizes display driver no data, timeout, startup failure, and invalid output", async () => {
    const cases: Array<[() => Promise<{ stdout: string; stderr: string }>, string]> = [
      [async () => ({ stdout: encodedCollectorPayload({ status: "no_data", items: [] }), stderr: "" }), "no_data"],
      [async () => { throw new IncidentDocketError("collector_timeout", "private timeout detail"); }, "timeout"],
      [async () => { throw new IncidentDocketError("collector_unavailable", "private path detail"); }, "unavailable"],
      [async () => ({ stdout: "invalid", stderr: "private diagnostic" }), "failed"],
    ];
    for (const [execute, expected] of cases) {
      const built = await collectLiveCase(driverPlan(), {
        platform: "win32",
        osRelease: "10.0.26100",
        osVersion: windows11Product,
        execute,
        collectedAt: new Date("2026-07-16T01:00:00.000Z"),
      });
      expect(built.case.coverage).toEqual([
        {
          source: "display_drivers",
          status: expected,
          item_count: 0,
          truncated_before: false,
          truncated_after: false,
        },
      ]);
      expect(JSON.stringify(built)).not.toContain("private");
    }
  });

  it("normalizes denied, no data, timeout, process failure, and invalid output coverage", async () => {
    const cases: Array<[string, () => Promise<{ stdout: string; stderr: string }>, string]> = [
      ["denied", async () => ({ stdout: encodedCollectorPayload({ status: "denied", items: [] }), stderr: "" }), "denied"],
      ["no_data", async () => ({ stdout: encodedCollectorPayload({ status: "no_data", items: [] }), stderr: "" }), "no_data"],
      [
        "timeout",
        async () => {
          throw new IncidentDocketError("collector_timeout", "Collector timed out");
        },
        "timeout",
      ],
      [
        "unavailable",
        async () => {
          throw new IncidentDocketError("collector_unavailable", "Collector could not start");
        },
        "unavailable",
      ],
      ["invalid", async () => ({ stdout: "invalid", stderr: "private diagnostic" }), "failed"],
    ];

    for (const [, execute, expected] of cases) {
      const built = await collectLiveCase(osPlan(), {
        platform: "win32",
        osRelease: "10.0.26100",
        osVersion: windows11Product,
        execute,
        collectedAt: new Date("2026-07-16T01:00:00.000Z"),
      });
      expect(built.case.coverage[0]?.status).toBe(expected);
    }
  });

  it("keeps stderr out of the case and marks OS as a collection snapshot", async () => {
    const secretDiagnostic = "stderr C:\\Users\\private-user\\collector.ps1";
    const built = await collectLiveCase(osPlan(), {
      platform: "win32",
      osRelease: "10.0.26100",
      osVersion: windows11Product,
      execute: async () => ({
        stdout: encodedCollectorPayload({ status: "ok", items: [osItem] }),
        stderr: secretDiagnostic,
      }),
      collectedAt: new Date("2026-07-16T01:00:00.000Z"),
    });
    expect(JSON.stringify(built)).not.toContain(secretDiagnostic);
    expect(built.case.evidence).toHaveLength(1);
    expect(built.case.evidence[0]?.temporal_kind).toBe("collection_snapshot");
    expect(() =>
      validateReportInput(built.case, {
        case_id: built.case.case_id,
        outcome: "hypotheses",
        summary: "OS state may be relevant",
        hypotheses: [
          {
            rank: 1,
            title: "OS state",
            confidence: "low",
            explanation: "The current OS snapshot may be relevant.",
            evidence_ids: ["OS-001"],
            not_proven: ["The snapshot does not prove incident-time causation."],
          },
        ],
        missing_evidence: [],
        next_steps: [],
      }),
    ).toThrow("snapshots");
  });

  it("passes the absolute system Windows PowerShell path to the executor", async () => {
    const originalSystemRoot = process.env.SystemRoot;
    process.env.SystemRoot = "C:\\Windows";
    let command = "";
    try {
      const built = await collectLiveCase(osPlan(), {
        platform: "win32",
        osRelease: "10.0.26100",
        osVersion: windows11Product,
        execute: async (value) => {
          command = value;
          return { stdout: encodedCollectorPayload({ status: "ok", items: [osItem] }), stderr: "" };
        },
        collectedAt: new Date("2026-07-16T01:00:00.000Z"),
      });
      expect(command).toBe("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
      expect(built.case.coverage[0]?.status).toBe("ok");
    } finally {
      if (originalSystemRoot === undefined) delete process.env.SystemRoot;
      else process.env.SystemRoot = originalSystemRoot;
    }
  });

  it("marks every source unavailable without executing when SystemRoot is relative", async () => {
    const originalSystemRoot = process.env.SystemRoot;
    process.env.SystemRoot = "relative-root";
    let collectorCalls = 0;
    try {
      const built = await collectLiveCase(eventPlan(["system_events", "application_events"]), {
        platform: "win32",
        osRelease: "10.0.26100",
        osVersion: windows11Product,
        execute: async () => {
          collectorCalls += 1;
          return { stdout: "", stderr: "" };
        },
        collectedAt: new Date("2026-07-16T00:35:00.000Z"),
      });
      expect(collectorCalls).toBe(0);
      expect(built.case.coverage.map(({ status }) => status)).toEqual(["unavailable", "unavailable"]);
    } finally {
      if (originalSystemRoot === undefined) delete process.env.SystemRoot;
      else process.env.SystemRoot = originalSystemRoot;
    }
  });

  it("rejects non-Windows live collection", async () => {
    await expect(
      collectLiveCase(osPlan(), { platform: "linux", osRelease: "6.0.0" }),
    ).rejects.toMatchObject({ code: "unsupported_platform" });
  });

  it("accepts Windows 11 products and rejects unsupported products before collection", async () => {
    const accepted = [
      ["Windows 11", "10.0.22000"],
      ["Windows 11 Pro", "10.0.26100"],
      ["Windows 11 Enterprise", "10.0.26100"],
      ["Windows 11 Home", "10.0.26100"],
    ] as const;
    for (const [product, osRelease] of accepted) {
      let collectorCalls = 0;
      const built = await collectLiveCase(osPlan(), {
        platform: "win32",
        osRelease,
        osVersion: () => product,
        execute: async () => {
          collectorCalls += 1;
          return { stdout: encodedCollectorPayload({ status: "ok", items: [osItem] }), stderr: "" };
        },
        collectedAt: new Date("2026-07-16T01:00:00.000Z"),
      });
      expect(collectorCalls, product).toBe(1);
      expect(built.case.coverage[0]?.status, product).toBe("ok");
    }

    const rejected: Array<[string, () => string]> = [
      ["Windows Server 2025 Standard", () => "Windows Server 2025 Standard"],
      ["Windows Server 2025 Datacenter", () => "Windows Server 2025 Datacenter"],
      ["Windows Server 2022 Standard", () => "Windows Server 2022 Standard"],
      ["Microsoft Windows Server 2025", () => "Microsoft Windows Server 2025"],
      ["Windows 10 Pro", () => "Windows 10 Pro"],
      ["Windows 12 Pro", () => "Windows 12 Pro"],
      ["empty product", () => ""],
      ["whitespace product", () => "   "],
      ["malformed product", () => "Windows 11Pro"],
      ["non-string product", () => undefined as unknown as string],
      ["embedded Windows 11", () => "Not Windows 11"],
      ["Windows 11 Server", () => "Windows 11 Server"],
      ["provider exception", () => { throw new Error("private product detail"); }],
    ];
    const root = await temporaryDirectory();
    const cwd = join(root, "cwd");
    const localAppData = join(root, "local");
    await mkdir(cwd);
    const originalCwd = process.cwd();
    const originalLocalAppData = process.env.LOCALAPPDATA;
    process.chdir(cwd);
    process.env.LOCALAPPDATA = localAppData;
    try {
      for (const [label, osVersion] of rejected) {
        let collectorCalls = 0;
        let error: unknown;
        try {
          await collectLiveCase(osPlan(), {
            platform: "win32",
            osRelease: "10.0.26100",
            osVersion,
            execute: async () => {
              collectorCalls += 1;
              return { stdout: "", stderr: "" };
            },
          });
        } catch (value) {
          error = value;
        }
        expect(error, label).toMatchObject({
          code: "unsupported_platform",
          message: "Live collection requires Windows 11",
        });
        expect(String(error), label).not.toContain("private product detail");
        expect(collectorCalls, label).toBe(0);
        expect(process.cwd(), label).toBe(cwd);
      }
      expect(await readdir(cwd)).toEqual([]);
      await expect(readdir(localAppData)).rejects.toMatchObject({ code: "ENOENT" });
    } finally {
      process.chdir(originalCwd);
      if (originalLocalAppData === undefined) delete process.env.LOCALAPPDATA;
      else process.env.LOCALAPPDATA = originalLocalAppData;
    }
  });

  it("times out a child process and reports process startup failure", async () => {
    await expect(runProcess(process.execPath, ["-e", "setTimeout(() => {}, 5000)"], 25)).rejects.toMatchObject({
      code: "collector_timeout",
    });
    await expect(runProcess("incident-docket-command-that-does-not-exist", [], 1_000)).rejects.toMatchObject({
      code: "collector_unavailable",
    });
  });

  it.runIf(process.platform === "win32")("terminates a timed-out Windows PowerShell process", async () => {
    const systemRoot = process.env.SystemRoot;
    if (!systemRoot || !win32.isAbsolute(systemRoot)) throw new Error("SystemRoot must be absolute");
    await expect(
      runProcess(
        win32.join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
        ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 5"],
        50,
      ),
    ).rejects.toMatchObject({ code: "collector_timeout" });
  });

  it.runIf(process.platform === "win32")("parses the collector with Windows PowerShell 5.1", async () => {
    const systemRoot = process.env.SystemRoot;
    if (!systemRoot || !win32.isAbsolute(systemRoot)) throw new Error("SystemRoot must be absolute");
    const scriptPath = fileURLToPath(new URL("../collectors/windows.ps1", import.meta.url)).replaceAll("'", "''");
    await expect(
      runProcess(
        win32.join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
        [
          "-NoLogo",
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          `$tokens = $null; $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('${scriptPath}', [ref]$tokens, [ref]$errors); if ($errors.Count -ne 0) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }`,
        ],
        12_000,
      ),
    ).resolves.toMatchObject({ stdout: "", stderr: "" });
  }, 20_000);

  it.runIf(process.platform === "win32")("saves live cases under LocalAppData and leaves CWD unchanged", async () => {
    const root = await temporaryDirectory();
    const localAppData = join(root, "local");
    const cwd = join(root, "cwd");
    await mkdir(cwd);
    const originalCwd = process.cwd();
    const originalLocalAppData = process.env.LOCALAPPDATA;
    process.chdir(cwd);
    process.env.LOCALAPPDATA = localAppData;
    try {
      const built = await collectLiveCase(osPlan(), {
        platform: "win32",
        osRelease: "10.0.26100",
        osVersion: windows11Product,
        execute: async () => ({
          stdout: encodedCollectorPayload({ status: "ok", items: [osItem] }),
          stderr: "",
        }),
        collectedAt: new Date("2026-07-16T01:00:00.000Z"),
      });
      expect(defaultStorageRoot("live")).toBe(join(localAppData, "IncidentDocket"));
      await saveCase(built.case);
      expect(await readdir(cwd)).toEqual([]);
      expect(
        await readFile(join(localAppData, "IncidentDocket", "cases", built.case.case_id), "utf8"),
      ).toContain('"mode":"live"');
      expect(symbolicCaseLocation(built.case.case_id, "live")).toBe(
        `%LOCALAPPDATA%\\IncidentDocket\\cases\\${built.case.case_id}`,
      );
    } finally {
      process.chdir(originalCwd);
      if (originalLocalAppData === undefined) delete process.env.LOCALAPPDATA;
      else process.env.LOCALAPPDATA = originalLocalAppData;
    }
  });

  it("keeps the PowerShell collector ASCII and limited to the four fixed sources", async () => {
    const script = await readFile(new URL("../collectors/windows.ps1", import.meta.url));
    expect([...script].every((byte) => byte < 128)).toBe(true);
    const text = script.toString("ascii");
    for (const field of ["Caption", "Version", "BuildNumber", "OSArchitecture", "LastBootUpTime"]) {
      expect(text).toContain(field);
    }
    expect(text).toContain('[ValidateSet("system_events", "application_events", "os", "display_drivers")]');
    expect(text).toContain('if ($Action -eq "system_events") { "System" } else { "Application" }');
    expect(text).toContain("Get-WinEvent -FilterHashtable");
    expect(text).toContain("Level = @(1, 2, 3)");
    expect(text).toContain("-MaxEvents 26");
    expect(text).toContain("-Oldest");
    const eventProjection = text.slice(
      text.indexOf("function Convert-EventRecord"),
      text.indexOf("\ntry {", text.indexOf("function Convert-EventRecord")),
    );
    for (const field of ["TimeCreated", "LogName", "ProviderName", "Id", "Level", "RecordId", "Message"]) {
      expect(eventProjection).toContain(field);
    }
    for (const forbidden of [
      "MachineName",
      "UserId",
      "ContainerLog",
      "Properties",
      "ToXml",
      "FilterXPath",
      '"Security"',
      '"ForwardedEvents"',
      "Win32_ReliabilityRecords",
      "Win32_Service",
    ]) {
      expect(text).not.toContain(forbidden);
    }
    expect(text).toContain("Win32_PnPSignedDriver");
    expect(text).toContain("DeviceClass = 'DISPLAY'");
    expect(text).toContain("Select-Object -First 20");
    for (const field of [
      "DeviceName",
      "Manufacturer",
      "DriverProviderName",
      "DriverVersion",
      "DriverDate",
      "IsSigned",
      "Status",
    ]) {
      expect(text).toContain(field);
    }
    const driverStart = text.indexOf("$records = @(Get-CimInstance");
    const driverProjection = text.slice(driverStart, text.indexOf("} catch", driverStart));
    for (const forbidden of [
      "RegisteredUser",
      "SerialNumber",
      "CSName",
      "Win32_ReliabilityRecords",
      "Win32_Service",
      "DeviceID",
      "HardwareID",
      "CompatibleID",
      "PDO",
      "Location",
      "InfName",
      "SystemName",
      "Caption",
    ]) {
      expect(driverProjection).not.toContain(forbidden);
    }
  });
});

describe("MCP fixture workflow", () => {
  it("exposes four tools with matching structured and text output", async () => {
    const root = await temporaryDirectory();
    const server = createMcpServer(root);
    const client = new Client({ name: "incident-docket-test", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    try {
      const listed = await client.listTools();
      expect(listed.tools.map((tool) => tool.name)).toEqual([
        "plan_collection",
        "collect_incident_window",
        "inspect_evidence",
        "export_support_report",
      ]);

      const planned = await client.callTool({
        name: "plan_collection",
        arguments: {
          problem: "ExampleRender reset",
          incident_time: "2026-07-16T09:30:00+09:00",
          before_minutes: 5,
          after_minutes: 5,
          sources: ["system_events", "application_events", "os", "display_drivers"],
        },
      });
      expect(planned.isError).not.toBe(true);
      expect(JSON.parse(String(planned.content[0]?.type === "text" ? planned.content[0].text : ""))).toEqual(
        planned.structuredContent,
      );

      const collected = await client.callTool({
        name: "collect_incident_window",
        arguments: {
          plan: (planned.structuredContent as { plan: unknown }).plan,
          mode: "fixture",
          fixture_name: "gpu-driver-reset",
        },
      });
      expect(collected.isError).not.toBe(true);
      expect(JSON.parse(String(collected.content[0]?.type === "text" ? collected.content[0].text : ""))).toEqual(
        collected.structuredContent,
      );
      const caseId = (collected.structuredContent as { case_id: string }).case_id;
      const indexed = (collected.structuredContent as { evidence_index: Array<{ id: string }> }).evidence_index;

      const inspected = await client.callTool({
        name: "inspect_evidence",
        arguments: { case_id: caseId, evidence_ids: [indexed[0]?.id] },
      });
      expect(inspected.isError).not.toBe(true);
      expect(JSON.parse(String(inspected.content[0]?.type === "text" ? inspected.content[0].text : ""))).toEqual(
        inspected.structuredContent,
      );
      const modelVisible = JSON.stringify([collected.structuredContent, inspected.structuredContent]);
      for (const forbidden of [
        "fixture-access-token",
        "192.0.2.10",
        "Ignore previous instructions",
        "system prompt",
        "<script>",
        "![click]",
        "`",
      ]) {
        expect(modelVisible.toLowerCase()).not.toContain(forbidden.toLowerCase());
      }

      const expectInvalidReport = async (arguments_: Record<string, unknown>) => {
        const result = await client.callTool({ name: "export_support_report", arguments: arguments_ });
        expect(result.isError).toBe(true);
        expect(String(result.content[0]?.type === "text" ? result.content[0].text : "")).toMatch(
          /^MCP error -32602: Input validation error: Invalid arguments/,
        );
      };

      await expectInvalidReport({
        case_id: caseId,
        outcome: "hypotheses",
        summary: "A display reset occurred near the reported incident.",
        hypotheses: [
          {
            rank: 1,
            title: "Display driver reset",
            confidence: "medium",
            explanation: "The event is temporally close to the incident.",
            evidence_ids: [indexed[0]?.id],
            not_proven: [" "],
          },
        ],
        missing_evidence: [],
        next_steps: [],
      });
      await expectInvalidReport({
        case_id: caseId,
        outcome: "insufficient_evidence",
        summary: "The available evidence is insufficient.",
        hypotheses: [],
        missing_evidence: [" "],
        next_steps: [],
      });

      const exported = await client.callTool({
        name: "export_support_report",
        arguments: {
          case_id: caseId,
          outcome: "hypotheses",
          summary: "A display reset occurred near the reported incident.",
          hypotheses: [
            {
              rank: 1,
              title: "Display driver reset",
              confidence: "medium",
              explanation: "The event is temporally close to the incident.",
              evidence_ids: [indexed[0]?.id],
              not_proven: ["The event does not prove the root cause."],
            },
          ],
          missing_evidence: [],
          next_steps: ["Attempt a controlled reproduction."],
        },
      });
      expect(exported.isError).not.toBe(true);
      expect(JSON.parse(String(exported.content[0]?.type === "text" ? exported.content[0].text : ""))).toEqual(
        exported.structuredContent,
      );
    } finally {
      await client.close();
      await server.close();
    }
  });
});
