import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { isIP } from "node:net";
import { homedir, release, tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

export const SOURCES = [
  "system_events",
  "application_events",
  "os",
  "display_drivers",
] as const;

export const sourceSchema = z.enum(SOURCES);
export const coverageStatusSchema = z.enum([
  "ok",
  "no_data",
  "denied",
  "unavailable",
  "failed",
  "timeout",
]);
export const warningSchema = z.enum([
  "snapshot_is_collection_time",
  "future_window_clipped",
  "source_partial",
  "evidence_limit_reached",
  "privacy_review_required",
]);

export const TEMPORAL_PROXIMITY_WARNING = "Temporal proximity does not prove causation.";

const RFC3339 = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$/;
const uuidSchema = z.string().uuid();
const rfc3339Schema = z.string().refine(isValidRfc3339, "Expected an offset RFC3339 timestamp");

export const planInputSchema = z
  .object({
    problem: z.string().min(1).max(2_000),
    incident_time: rfc3339Schema,
    before_minutes: z.number().int().min(0).max(30).default(5),
    after_minutes: z.number().int().min(0).max(30).default(5),
    sources: z.array(sourceSchema).min(1).max(4).refine(isUnique, "Sources must be unique"),
  })
  .strict()
  .refine((value) => value.before_minutes > 0 || value.after_minutes > 0, {
    message: "before_minutes and after_minutes cannot both be zero",
  });

export const normalizedPlanSchema = z
  .object({
    problem: z.string().min(1).max(4_000),
    incident_time_utc: rfc3339Schema,
    original_utc_offset: z.string().regex(/^(?:Z|[+-]\d{2}:\d{2})$/),
    before_minutes: z.number().int().min(0).max(30),
    after_minutes: z.number().int().min(0).max(30),
    window_start_utc: rfc3339Schema,
    window_end_utc: rfc3339Schema,
    sources: z.array(sourceSchema).min(1).max(4).refine(isUnique),
  })
  .strict();

export const coverageSchema = z
  .object({
    source: sourceSchema,
    status: coverageStatusSchema,
    item_count: z.number().int().min(0).max(200),
    truncated_before: z.boolean(),
    truncated_after: z.boolean(),
  })
  .strict();

export const evidenceSchema = z
  .object({
    id: z.string().regex(/^(?:EV|OS|DR)-\d{3}$/),
    kind: z.enum(["windows_event", "operating_system", "display_driver"]),
    temporal_kind: z.enum(["incident_event", "collection_snapshot"]),
    timestamp_utc: rfc3339Schema,
    source: sourceSchema,
    summary: z.string().min(1).max(160),
    details: z.string().max(2_000),
  })
  .strict();

export const privacyStatsSchema = z
  .object({
    masked_values: z.number().int().min(0),
    unsafe_messages_replaced: z.number().int().min(0),
    dropped_evidence: z.number().int().min(0),
    review_required: z.literal(true),
    raw_artifact_written: z.literal(false),
  })
  .strict();

const casePlanSchema = normalizedPlanSchema.extend({
  effective_window_start_utc: rfc3339Schema,
  effective_window_end_utc: rfc3339Schema,
  window_incomplete_after: z.boolean(),
});

export const caseSchema = z
  .object({
    schema_version: z.literal("1"),
    case_id: uuidSchema,
    mode: z.enum(["live", "fixture"]),
    plan: casePlanSchema,
    collected_at_utc: rfc3339Schema,
    coverage: z.array(coverageSchema).min(1).max(4),
    privacy: privacyStatsSchema,
    evidence: z.array(evidenceSchema).max(200),
  })
  .strict();

export const eventRowSchema = z
  .object({
    TimeCreated: rfc3339Schema,
    LogName: z.enum(["System", "Application"]),
    ProviderName: z.string().min(1).max(300),
    Id: z.number().int().nonnegative(),
    Level: z.number().int().min(1).max(3),
    RecordId: z.union([z.string().min(1).max(100), z.number().int().nonnegative()]),
    Message: z.string().max(10_000).nullable().transform((value) => value ?? ""),
  })
  .strict();

export const eventCollectorPayloadSchema = z
  .object({
    status: z.enum(["ok", "no_data", "denied", "unavailable", "failed"]),
    items: z.array(eventRowSchema).max(50),
    truncated_before: z.boolean(),
    truncated_after: z.boolean(),
  })
  .strict()
  .superRefine((value, context) => {
    if ((value.status === "ok") !== (value.items.length > 0)) {
      context.addIssue({ code: "custom", message: "Collector status and item count do not match" });
    }
    if (value.status !== "ok" && (value.truncated_before || value.truncated_after)) {
      context.addIssue({ code: "custom", message: "Empty collector output cannot be truncated" });
    }
  });

export const osRowSchema = z
  .object({
    Caption: z.string().max(300),
    Version: z.string().max(100),
    BuildNumber: z.string().max(100),
    OSArchitecture: z.string().max(100),
    LastBootUpTime: z.string().max(100),
  })
  .strict();

export const osCollectorPayloadSchema = z
  .object({
    status: z.enum(["ok", "no_data", "denied", "unavailable", "failed"]),
    items: z.array(osRowSchema).max(1),
  })
  .strict()
  .superRefine((value, context) => {
    if ((value.status === "ok") !== (value.items.length === 1)) {
      context.addIssue({ code: "custom", message: "Collector status and item count do not match" });
    }
  });

export const driverRowSchema = z
  .object({
    DeviceName: z.string().max(300),
    Manufacturer: z.string().max(300),
    DriverProviderName: z.string().max(300),
    DriverVersion: z.string().max(100),
    DriverDate: z.union([rfc3339Schema, z.literal("")]),
    IsSigned: z.boolean(),
    Status: z.string().max(100),
  })
  .strict();

export const driverCollectorPayloadSchema = z
  .object({
    status: z.enum(["ok", "no_data", "denied", "unavailable", "failed"]),
    items: z.array(driverRowSchema).max(20),
  })
  .strict()
  .superRefine((value, context) => {
    if ((value.status === "ok") !== (value.items.length > 0)) {
      context.addIssue({ code: "custom", message: "Collector status and item count do not match" });
    }
  });

export const collectionRowsSchema = z
  .object({
    system_events: z.array(eventRowSchema).max(60),
    application_events: z.array(eventRowSchema).max(60),
    os: z.array(osRowSchema).max(1),
    display_drivers: z.array(driverRowSchema).max(20),
  })
  .strict();

export const fixtureSchema = collectionRowsSchema.extend({
  fixture_name: z.literal("gpu-driver-reset"),
  default_plan: planInputSchema,
});

const hypothesisSchema = z
  .object({
    rank: z.number().int().min(1).max(3),
    title: z.string().min(1).max(120),
    confidence: z.enum(["low", "medium"]),
    explanation: z.string().min(1).max(1_200),
    evidence_ids: z
      .array(z.string().regex(/^(?:EV|OS|DR)-\d{3}$/))
      .min(1)
      .max(10)
      .refine(isUnique),
    not_proven: z.array(z.string().min(1).max(300)).min(1).max(5),
  })
  .strict();

export const reportInputSchema = z
  .object({
    case_id: uuidSchema,
    outcome: z.enum(["hypotheses", "insufficient_evidence"]),
    summary: z.string().min(1).max(2_000),
    hypotheses: z.array(hypothesisSchema).max(3).default([]),
    missing_evidence: z.array(z.string().min(1).max(300)).max(10).default([]),
    next_steps: z.array(z.string().min(1).max(300)).max(5).default([]),
  })
  .strict();

export type Source = z.infer<typeof sourceSchema>;
export type NormalizedPlan = z.infer<typeof normalizedPlanSchema>;
export type Coverage = z.infer<typeof coverageSchema>;
export type Evidence = z.infer<typeof evidenceSchema>;
export type IncidentCase = z.infer<typeof caseSchema>;
export type CollectionRows = z.infer<typeof collectionRowsSchema>;
export type ReportInput = z.infer<typeof reportInputSchema>;
export type WarningCode = z.infer<typeof warningSchema>;
export type ProcessOutput = { stdout: string; stderr: string };

export class IncidentDocketError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "IncidentDocketError";
  }
}

export function normalizePlan(input: unknown): { plan: NormalizedPlan; warnings: WarningCode[] } {
  const value = planInputSchema.parse(input);
  const offset = RFC3339.exec(value.incident_time)?.[8];
  if (!offset) throw new IncidentDocketError("invalid_input", "Incident time is invalid");

  return {
    plan: canonicalizePlan({
      problem: value.problem,
      incidentTime: value.incident_time,
      originalOffset: offset,
      beforeMinutes: value.before_minutes,
      afterMinutes: value.after_minutes,
      sources: value.sources,
    }),
    warnings: ["snapshot_is_collection_time", "privacy_review_required"],
  };
}

export function validateNormalizedPlan(input: unknown): NormalizedPlan {
  const supplied = normalizedPlanSchema.parse(input);
  if (
    !isCanonicalUtcTimestamp(supplied.incident_time_utc) ||
    !isCanonicalUtcTimestamp(supplied.window_start_utc) ||
    !isCanonicalUtcTimestamp(supplied.window_end_utc)
  ) {
    throw new IncidentDocketError("invalid_input", "Collection plan timestamps must be canonical UTC");
  }

  const canonical = canonicalizePlan({
    problem: supplied.problem,
    incidentTime: supplied.incident_time_utc,
    originalOffset: supplied.original_utc_offset,
    beforeMinutes: supplied.before_minutes,
    afterMinutes: supplied.after_minutes,
    sources: supplied.sources,
  });
  if (canonicalJson(canonical) !== canonicalJson(supplied)) {
    throw new IncidentDocketError("invalid_input", "Collection plan failed canonical validation");
  }
  return canonical;
}

type CanonicalPlanInput = {
  problem: string;
  incidentTime: string;
  originalOffset: string;
  beforeMinutes: number;
  afterMinutes: number;
  sources: Source[];
};

function canonicalizePlan(input: CanonicalPlanInput): NormalizedPlan {
  if (input.problem.length < 1 || input.problem.length > 2_000) {
    throw new IncidentDocketError("invalid_input", "Problem must be between 1 and 2,000 characters");
  }
  if (
    !Number.isInteger(input.beforeMinutes) ||
    input.beforeMinutes < 0 ||
    input.beforeMinutes > 30 ||
    !Number.isInteger(input.afterMinutes) ||
    input.afterMinutes < 0 ||
    input.afterMinutes > 30 ||
    (input.beforeMinutes === 0 && input.afterMinutes === 0)
  ) {
    throw new IncidentDocketError("invalid_input", "Collection window must be between 0 and 30 minutes on each side");
  }
  if (!isValidUtcOffset(input.originalOffset)) {
    throw new IncidentDocketError("invalid_input", "Original UTC offset is invalid");
  }
  const sources = z.array(sourceSchema).min(1).max(4).refine(isUnique, "Sources must be unique").parse(input.sources);
  const incident = new Date(input.incidentTime);
  const incidentMs = incident.getTime();
  if (!Number.isFinite(incidentMs)) throw new IncidentDocketError("invalid_input", "Incident time is invalid");

  const problem = truncate(sanitizeText(input.problem).text, 2_000);
  const start = new Date(incidentMs - input.beforeMinutes * 60_000);
  const end = new Date(incidentMs + input.afterMinutes * 60_000);
  const plan = normalizedPlanSchema.parse({
    problem,
    incident_time_utc: incident.toISOString(),
    original_utc_offset: input.originalOffset,
    before_minutes: input.beforeMinutes,
    after_minutes: input.afterMinutes,
    window_start_utc: start.toISOString(),
    window_end_utc: end.toISOString(),
    sources,
  });
  const startMs = new Date(plan.window_start_utc).getTime();
  const endMs = new Date(plan.window_end_utc).getTime();
  if (!(startMs <= incidentMs && incidentMs <= endMs)) {
    throw new IncidentDocketError("invalid_input", "Collection window does not contain the incident");
  }
  return plan;
}

type BuildCaseInput = {
  plan: unknown;
  mode: "live" | "fixture";
  rows: unknown;
  coverage?: Coverage[];
  collectedAt?: Date;
  caseId?: string;
};

type Draft = {
  source: Source;
  kind: Evidence["kind"];
  temporal_kind: Evidence["temporal_kind"];
  timestamp_utc: string;
  native_key: string;
  summary: string;
  details: string;
};

export function buildCase(input: BuildCaseInput): { case: IncidentCase; warnings: WarningCode[] } {
  const plan = validateNormalizedPlan(input.plan);
  const rows = collectionRowsSchema.parse(input.rows);
  const collectedAt = input.collectedAt ?? new Date();
  const collectedAtMs = collectedAt.getTime();
  if (!Number.isFinite(collectedAtMs)) throw new IncidentDocketError("invalid_input", "Collection time is invalid");

  const requestedStart = new Date(plan.window_start_utc).getTime();
  const requestedEnd = new Date(plan.window_end_utc).getTime();
  const effectiveEnd = Math.min(requestedEnd, collectedAtMs);
  const effectiveStart = Math.min(requestedStart, effectiveEnd);
  const incidentTime = new Date(plan.incident_time_utc).getTime();
  const eventSelections = {
    system_events: selectEventRows(rows.system_events, effectiveStart, incidentTime, effectiveEnd),
    application_events: selectEventRows(rows.application_events, effectiveStart, incidentTime, effectiveEnd),
  };
  const warnings: WarningCode[] = ["snapshot_is_collection_time", "privacy_review_required"];
  if (effectiveEnd !== requestedEnd) warnings.push("future_window_clipped");

  const drafts: Draft[] = [];
  if (plan.sources.includes("system_events")) {
    drafts.push(...eventDrafts(eventSelections.system_events.items, "system_events", effectiveStart, effectiveEnd));
  }
  if (plan.sources.includes("application_events")) {
    drafts.push(...eventDrafts(eventSelections.application_events.items, "application_events", effectiveStart, effectiveEnd));
  }
  if (plan.sources.includes("os")) {
    drafts.push(
      ...rows.os.map((row) => ({
        source: "os" as const,
        kind: "operating_system" as const,
        temporal_kind: "collection_snapshot" as const,
        timestamp_utc: collectedAt.toISOString(),
        native_key: "os",
        summary: `Operating system ${row.Caption} ${row.Version} build ${row.BuildNumber}`,
        details: details(row),
      })),
    );
  }
  if (plan.sources.includes("display_drivers")) {
    drafts.push(
      ...rows.display_drivers.map((row) => ({
        source: "display_drivers" as const,
        kind: "display_driver" as const,
        temporal_kind: "collection_snapshot" as const,
        timestamp_utc: collectedAt.toISOString(),
        native_key: `${row.DeviceName}\u0000${row.DriverVersion}\u0000${row.DriverDate}`,
        summary: `Display driver ${row.DeviceName} ${row.DriverVersion}`,
        details: details(row),
      })),
    );
  }

  let maskedValues = 0;
  let unsafeMessages = 0;
  let droppedEvidence = 0;
  const safeDrafts: Draft[] = [];
  for (const draft of drafts) {
    const summary = sanitizeText(draft.summary);
    const detail = sanitizeText(draft.details);
    maskedValues += summary.masked + detail.masked;
    unsafeMessages += summary.unsafe + detail.unsafe;
    const safe = {
      ...draft,
      native_key: sanitizeText(draft.native_key).text,
      summary: truncate(summary.text, 160),
      details: truncate(detail.text, 2_000),
    };
    if (containsSensitive(`${safe.summary}\n${safe.details}`)) {
      droppedEvidence += 1;
    } else {
      safeDrafts.push(safe);
    }
  }

  safeDrafts.sort(compareDrafts);
  const capped = safeDrafts.slice(0, 200);
  if (safeDrafts.length > capped.length) warnings.push("evidence_limit_reached");

  let eventNumber = 0;
  let osNumber = 0;
  let driverNumber = 0;
  const evidence = capped.map((draft) => {
    const id =
      draft.temporal_kind === "incident_event"
        ? `EV-${String(++eventNumber).padStart(3, "0")}`
        : draft.kind === "operating_system"
          ? `OS-${String(++osNumber).padStart(3, "0")}`
          : `DR-${String(++driverNumber).padStart(3, "0")}`;
    const { native_key: _nativeKey, ...item } = draft;
    return evidenceSchema.parse({ ...item, id });
  });

  const suppliedCoverage = input.coverage ? z.array(coverageSchema).parse(input.coverage) : [];
  const coverage = plan.sources.map((source) => {
    const supplied = suppliedCoverage.find((item) => item.source === source);
    const count = evidence.filter((item) => item.source === source).length;
    const selection =
      source === "system_events" || source === "application_events" ? eventSelections[source] : undefined;
    return coverageSchema.parse(
      supplied
        ? {
            ...supplied,
            item_count: count,
            truncated_before: supplied.truncated_before || selection?.truncated_before === true,
            truncated_after: supplied.truncated_after || selection?.truncated_after === true,
          }
        : {
            source,
            status: sourceRows(rows, source).length > 0 ? "ok" : "no_data",
            item_count: count,
            truncated_before: selection?.truncated_before ?? false,
            truncated_after: selection?.truncated_after ?? false,
          },
    );
  });
  if (coverage.some((item) => item.status !== "ok")) warnings.push("source_partial");

  return {
    case: caseSchema.parse({
      schema_version: "1",
      case_id: input.caseId ?? randomUUID(),
      mode: input.mode,
      plan: {
        ...plan,
        effective_window_start_utc: new Date(effectiveStart).toISOString(),
        effective_window_end_utc: new Date(effectiveEnd).toISOString(),
        window_incomplete_after: effectiveEnd !== requestedEnd,
      },
      collected_at_utc: collectedAt.toISOString(),
      coverage,
      privacy: {
        masked_values: maskedValues,
        unsafe_messages_replaced: unsafeMessages,
        dropped_evidence: droppedEvidence,
        review_required: true,
        raw_artifact_written: false,
      },
      evidence,
    }),
    warnings: dedupe(warnings),
  };
}

export function evidenceIndex(value: IncidentCase) {
  return value.evidence.map(({ id, kind, temporal_kind, timestamp_utc, source, summary }) => ({
    id,
    kind,
    temporal_kind,
    timestamp_utc,
    source,
    summary,
  }));
}

export async function runProcess(command: string, args: string[], timeoutMs: number): Promise<ProcessOutput> {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let bytes = 0;
    let timedOut = false;
    let tooLarge = false;
    let settled = false;

    const reject = (error: IncidentDocketError) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      rejectPromise(error);
    };
    const collect = (target: Buffer[], chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > 1_048_576) {
        tooLarge = true;
        child.kill();
        return;
      }
      target.push(chunk);
    };

    child.stdout.on("data", (chunk: Buffer) => collect(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer) => collect(stderr, chunk));
    child.once("error", () => reject(new IncidentDocketError("collector_unavailable", "Collector process could not start")));
    child.once("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (timedOut) {
        rejectPromise(new IncidentDocketError("collector_timeout", "Collector timed out"));
      } else if (tooLarge || code !== 0) {
        rejectPromise(new IncidentDocketError("collector_failed", "Collector process failed"));
      } else {
        resolvePromise({ stdout: Buffer.concat(stdout).toString("utf8"), stderr: Buffer.concat(stderr).toString("utf8") });
      }
    });

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill();
    }, timeoutMs);
  });
}

function decodeCollectorPayload<T>(stdout: string, schema: z.ZodType<T>): T {
  const encoded = stdout.trim();
  if (
    encoded.length === 0 ||
    encoded.includes("\n") ||
    encoded.includes("\r") ||
    /[^\x00-\x7F]/.test(encoded) ||
    encoded.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)
  ) {
    throw new IncidentDocketError("collector_failed", "Collector output was invalid");
  }

  let parsed: unknown;
  try {
    const bytes = Buffer.from(encoded, "base64");
    const json = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    parsed = JSON.parse(json);
  } catch {
    throw new IncidentDocketError("collector_failed", "Collector output was invalid");
  }
  try {
    return schema.parse(parsed);
  } catch {
    throw new IncidentDocketError("collector_failed", "Collector output failed validation");
  }
}

export function decodeOsCollectorPayload(stdout: string): z.infer<typeof osCollectorPayloadSchema> {
  return decodeCollectorPayload(stdout, osCollectorPayloadSchema);
}

export function decodeDisplayDriverCollectorPayload(
  stdout: string,
): z.infer<typeof driverCollectorPayloadSchema> {
  return decodeCollectorPayload(stdout, driverCollectorPayloadSchema);
}

export function decodeEventCollectorPayload(stdout: string): z.infer<typeof eventCollectorPayloadSchema> {
  return decodeCollectorPayload(stdout, eventCollectorPayloadSchema);
}

type LiveCollectionOptions = {
  platform?: NodeJS.Platform;
  osRelease?: string;
  timeoutMs?: number;
  scriptPath?: string;
  execute?: typeof runProcess;
  collectedAt?: Date;
};

export async function collectLiveCase(
  inputPlan: unknown,
  options: LiveCollectionOptions = {},
): Promise<{ case: IncidentCase; warnings: WarningCode[] }> {
  const plan = validateNormalizedPlan(inputPlan);
  const platform = options.platform ?? process.platform;
  const osRelease = options.osRelease ?? release();
  const windowsBuild = Number(osRelease.split(".")[2]);
  if (platform !== "win32" || !Number.isInteger(windowsBuild) || windowsBuild < 22_000) {
    throw new IncidentDocketError("unsupported_platform", "Live collection requires Windows 11");
  }
  const collectedAt = options.collectedAt ?? new Date();
  const collectedAtMs = collectedAt.getTime();
  if (!Number.isFinite(collectedAtMs)) throw new IncidentDocketError("invalid_input", "Collection time is invalid");
  const effectiveStart = Math.min(new Date(plan.window_start_utc).getTime(), collectedAtMs);
  const effectiveEnd = Math.min(new Date(plan.window_end_utc).getTime(), collectedAtMs);

  const rows: CollectionRows = {
    system_events: [],
    application_events: [],
    os: [],
    display_drivers: [],
  };
  const coverage: Coverage[] = plan.sources.map((source) => ({
    source,
    status: "unavailable",
    item_count: 0,
    truncated_before: false,
    truncated_after: false,
  }));

  for (const source of plan.sources) {
    let status: Coverage["status"] = "failed";
    try {
      const execute = options.execute ?? runProcess;
      const args = [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        options.scriptPath ?? fileURLToPath(new URL("../collectors/windows.ps1", import.meta.url)),
        "-Action",
        source,
      ];
      if (source === "system_events" || source === "application_events") {
        args.push(
          "-WindowStartUtc",
          new Date(effectiveStart).toISOString(),
          "-IncidentTimeUtc",
          plan.incident_time_utc,
          "-WindowEndUtc",
          new Date(effectiveEnd).toISOString(),
        );
      }
      const result = await execute(
        "powershell.exe",
        args,
        options.timeoutMs ?? 12_000,
      );
      if (source === "system_events" || source === "application_events") {
        const payload = decodeEventCollectorPayload(result.stdout);
        rows[source] = payload.items;
        status = payload.status;
        coverage[plan.sources.indexOf(source)]!.truncated_before = payload.truncated_before;
        coverage[plan.sources.indexOf(source)]!.truncated_after = payload.truncated_after;
      } else if (source === "os") {
        const payload = decodeOsCollectorPayload(result.stdout);
        rows.os = payload.items;
        status = payload.status;
      } else {
        const payload = decodeDisplayDriverCollectorPayload(result.stdout);
        rows.display_drivers = payload.items;
        status = payload.status;
      }
    } catch (error) {
      status =
        error instanceof IncidentDocketError && error.code === "collector_timeout"
          ? "timeout"
          : error instanceof IncidentDocketError && error.code === "collector_unavailable"
            ? "unavailable"
            : "failed";
    }
    coverage[plan.sources.indexOf(source)]!.status = status;
  }

  return buildCase({
    plan,
    mode: "live",
    rows,
    coverage,
    collectedAt,
  });
}

export function symbolicCaseLocation(caseId: string, mode: "live" | "fixture"): string {
  const id = uuidSchema.parse(caseId);
  return process.platform === "win32" || mode === "live"
    ? `%LOCALAPPDATA%\\IncidentDocket\\cases\\${id}`
    : `$TMPDIR/IncidentDocket/cases/${id}`;
}

export function defaultStorageRoot(mode: "live" | "fixture"): string {
  if (process.platform === "win32") {
    const local = process.env.LOCALAPPDATA;
    if (!local) throw new IncidentDocketError("storage_unavailable", "Local application storage is unavailable");
    return join(local, "IncidentDocket");
  }
  if (mode === "live") throw new IncidentDocketError("unsupported_platform", "Live collection requires Windows 11");
  return join(tmpdir(), "IncidentDocket");
}

export async function saveCase(value: IncidentCase, root = defaultStorageRoot(value.mode)): Promise<void> {
  const parsed = caseSchema.parse(value);
  const directory = join(resolve(root), "cases");
  await mkdir(directory, { recursive: true });
  await writeFile(containedPath(directory, parsed.case_id), JSON.stringify(parsed), {
    encoding: "utf8",
    flag: "wx",
  });
}

export async function loadCase(caseId: string, root: string): Promise<IncidentCase> {
  const id = uuidSchema.parse(caseId);
  const directory = join(resolve(root), "cases");
  let raw: string;
  try {
    raw = await readFile(containedPath(directory, id), "utf8");
  } catch {
    throw new IncidentDocketError("case_not_found", "Case was not found");
  }
  try {
    return caseSchema.parse(JSON.parse(raw));
  } catch {
    throw new IncidentDocketError("case_invalid", "Stored case failed validation");
  }
}

export async function saveDemoFiles(root: string, value: IncidentCase, markdown: string): Promise<void> {
  const directory = resolve(root);
  await mkdir(directory, { recursive: true });
  await writeFile(containedPath(directory, `case-${value.case_id}.json`), JSON.stringify(caseSchema.parse(value), null, 2), {
    encoding: "utf8",
    flag: "wx",
  });
  await writeFile(containedPath(directory, `timeline-${value.case_id}.md`), markdown, {
    encoding: "utf8",
    flag: "wx",
  });
}

export function inspectEvidence(value: IncidentCase, ids: string[]) {
  const requested = z.array(z.string().regex(/^(?:EV|OS|DR)-\d{3}$/)).min(1).max(20).refine(isUnique).parse(ids);
  const byId = new Map(value.evidence.map((item) => [item.id, item]));
  const evidence = requested.map((id) => {
    const item = byId.get(id);
    if (!item) throw new IncidentDocketError("evidence_not_found", "One or more evidence IDs were not found");
    const summary = sanitizeText(item.summary).text;
    const detail = sanitizeText(item.details).text;
    if (containsSensitive(`${summary}\n${detail}`)) {
      throw new IncidentDocketError("unsafe_output", "Evidence could not be returned safely");
    }
    return evidenceSchema.parse({ ...item, summary: truncate(summary, 160), details: truncate(detail, 2_000) });
  });
  return {
    case_id: value.case_id,
    evidence,
    coverage: value.coverage,
    warnings: ["snapshot_is_collection_time", "privacy_review_required"] as WarningCode[],
  };
}

export function renderTimeline(value: IncidentCase): string {
  const events = value.evidence.filter((item) => item.temporal_kind === "incident_event");
  const snapshots = value.evidence.filter((item) => item.temporal_kind === "collection_snapshot");
  const lines = [
    "# IncidentDocket Evidence Timeline",
    "",
    `Case: ${value.case_id}`,
    `Incident: ${value.plan.incident_time_utc}`,
    "",
    "## Coverage",
    "",
    "| Source | Status | Items | Truncated before | Truncated after |",
    "|---|---:|---:|---:|---:|",
    ...value.coverage.map(
      (item) =>
        `| ${item.source} | ${item.status} | ${item.item_count} | ${item.truncated_before} | ${item.truncated_after} |`,
    ),
    "",
    "## Incident timeline",
    "",
    ...(events.length
      ? events.map((item) => `- ${item.timestamp_utc} **${item.id}** ${renderMarkdownText(item.summary)}`)
      : ["- No incident events were collected."]),
    "",
    "## Current state at collection time",
    "",
    ...(snapshots.length
      ? snapshots.map((item) => `- **${item.id}** ${renderMarkdownText(item.summary)}`)
      : ["- No collection snapshots were collected."]),
    "",
    "## Interpretation boundary",
    "",
    TEMPORAL_PROXIMITY_WARNING,
    "",
    "## Privacy review",
    "",
    "Automatically masked. Unknown sensitive data may remain. Review before sharing.",
    "",
  ];
  return lines.join("\n");
}

export async function exportSupportReport(
  value: IncidentCase,
  input: unknown,
  root = defaultStorageRoot(value.mode),
): Promise<{ report_id: string; markdown: string; coverage: Coverage[]; privacy_review_warning: string }> {
  const report = validateReportInput(value, input);
  const directory = join(resolve(root), "reports");
  await mkdir(directory, { recursive: true });
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const reportId = randomUUID();
    const markdown = renderSupportReport(value, report, reportId);
    try {
      await writeFile(containedPath(directory, `report-${reportId}.md`), markdown, {
        encoding: "utf8",
        flag: "wx",
      });
      return {
        report_id: reportId,
        markdown,
        coverage: value.coverage,
        privacy_review_warning:
          "Automatically masked. Unknown sensitive data may remain. Review before sharing.",
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
        throw new IncidentDocketError("report_create_failed", "Report could not be created");
      }
    }
  }
  throw new IncidentDocketError("report_create_failed", "Report could not be created");
}

export function validateReportInput(value: IncidentCase, input: unknown): ReportInput {
  const report = reportInputSchema.parse(input);
  if (report.case_id !== value.case_id) throw new IncidentDocketError("case_mismatch", "Report case does not match");
  if (report.outcome === "hypotheses" && report.hypotheses.length === 0) {
    throw new IncidentDocketError("report_invalid", "At least one hypothesis is required");
  }
  if (report.outcome === "insufficient_evidence") {
    if (report.hypotheses.length > 0 || report.missing_evidence.length === 0) {
      throw new IncidentDocketError("report_invalid", "Insufficient evidence requires missing evidence and no hypotheses");
    }
  }
  if (report.hypotheses.some((item, index) => item.rank !== index + 1)) {
    throw new IncidentDocketError("report_invalid", "Hypothesis ranks must be consecutive");
  }

  const evidence = new Map(value.evidence.map((item) => [item.id, item]));
  for (const hypothesis of report.hypotheses) {
    const cited = hypothesis.evidence_ids.map((id) => {
      const item = evidence.get(id);
      if (!item) throw new IncidentDocketError("evidence_not_found", "One or more evidence IDs were not found");
      return item;
    });
    if (cited.every((item) => item.temporal_kind === "collection_snapshot")) {
      throw new IncidentDocketError("report_invalid", "A hypothesis cannot rely only on collection snapshots");
    }
  }

  return reportInputSchema.parse({
    ...report,
    summary: truncate(sanitizeText(report.summary).text, 2_000),
    hypotheses: report.hypotheses.map((hypothesis) => ({
      ...hypothesis,
      title: truncate(sanitizeText(hypothesis.title).text, 120),
      explanation: truncate(sanitizeText(hypothesis.explanation).text, 1_200),
      not_proven: hypothesis.not_proven.map((item) => truncate(sanitizeText(item).text, 300)),
    })),
    missing_evidence: report.missing_evidence.map((item) => truncate(sanitizeText(item).text, 300)),
    next_steps: report.next_steps.map((item) => truncate(sanitizeText(item).text, 300)),
  });
}

export function renderSupportReport(value: IncidentCase, report: ReportInput, reportId: string): string {
  const lines = [
    "# IncidentDocket Support Report",
    "",
    `Report: ${reportId}`,
    `Case: ${value.case_id}`,
    `Incident: ${value.plan.incident_time_utc}`,
    "",
    "## Summary",
    "",
    renderMarkdownText(report.summary),
    "",
    "## Interpretation boundary",
    "",
    TEMPORAL_PROXIMITY_WARNING,
    "",
    "## Collection coverage",
    "",
    "| Source | Status | Items |",
    "|---|---:|---:|",
    ...value.coverage.map((item) => `| ${item.source} | ${item.status} | ${item.item_count} |`),
    "",
  ];

  if (report.outcome === "hypotheses") {
    lines.push("## Hypotheses", "");
    for (const hypothesis of report.hypotheses) {
      lines.push(
        `### ${hypothesis.rank}. ${renderMarkdownText(hypothesis.title)}`,
        "",
        `Confidence: ${hypothesis.confidence}`,
        "",
        renderMarkdownText(hypothesis.explanation),
        "",
        `Evidence: ${hypothesis.evidence_ids.map((id) => `**${id}**`).join(", ")}`,
        "",
        "Not proven:",
        ...hypothesis.not_proven.map((item) => `- ${renderMarkdownText(item)}`),
        "",
      );
    }
  } else {
    lines.push("## Insufficient evidence", "", "The collected evidence does not support a bounded hypothesis.", "");
  }

  lines.push(
    "## Missing evidence",
    "",
    ...(report.missing_evidence.length
      ? report.missing_evidence.map((item) => `- ${renderMarkdownText(item)}`)
      : ["- None identified."]),
    "",
    "## Next steps",
    "",
    ...(report.next_steps.length
      ? report.next_steps.map((item) => `- ${renderMarkdownText(item)}`)
      : ["- No next steps supplied."]),
    "",
    "## Privacy review",
    "",
    "Automatically masked. Unknown sensitive data may remain. Review before sharing.",
    "",
  );
  return lines.join("\n");
}

export function escapeMarkdown(input: string): string {
  return input
    .replace(/[\r\n\t]+/g, " ")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/([\\`*_{}\[\]()!|#])/g, "\\$1");
}

function renderMarkdownText(input: string): string {
  return escapeMarkdown(input.replace(new RegExp(escapeRegExp(TEMPORAL_PROXIMITY_WARNING), "gi"), ""));
}

export function sanitizeText(input: string): { text: string; masked: number; unsafe: number } {
  let text = input.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, " ");
  let masked = 0;
  let unsafe = 0;
  text = text.replace(
    /!?\[[^\]\r\n]{0,300}\]\([^\)\r\n]{0,1000}\)|<(?!REDACTED_(?:COMPUTER|DOMAIN|EMAIL|GUID|IP|MAC|MARKUP|PATH|PROMPT_INJECTION|SECRET|SID|UNC|UNSAFE_MESSAGE|USER)>)[^>\r\n]{1,1000}>|`+/g,
    () => {
      unsafe += 1;
      return "REDACTED_MARKUP";
    },
  );
  text = text.replace(/[A-Fa-f0-9:]{2,}/g, (candidate) => {
    if (!candidate.includes(":") || isIP(candidate) !== 6) return candidate;
    masked += 1;
    return "<REDACTED_IP>";
  });
  for (const [pattern, replacement] of maskPatterns()) {
    text = text.replace(pattern, () => {
      masked += 1;
      return replacement;
    });
  }
  if (containsSensitive(text)) return { text: "<REDACTED_UNSAFE_MESSAGE>", masked, unsafe: unsafe + 1 };
  return { text, masked, unsafe };
}

function selectEventRows(
  rows: z.infer<typeof eventRowSchema>[],
  start: number,
  incident: number,
  end: number,
): { items: z.infer<typeof eventRowSchema>[]; truncated_before: boolean; truncated_after: boolean } {
  const compare = (direction: 1 | -1) => (a: z.infer<typeof eventRowSchema>, b: z.infer<typeof eventRowSchema>) =>
    direction * (new Date(a.TimeCreated).getTime() - new Date(b.TimeCreated).getTime()) ||
    a.LogName.localeCompare(b.LogName) ||
    String(a.RecordId).localeCompare(String(b.RecordId), "en", { numeric: true }) ||
    canonicalJson(a).localeCompare(canonicalJson(b));
  const before = rows
    .filter((row) => {
      const time = new Date(row.TimeCreated).getTime();
      return time >= start && time <= Math.min(incident, end);
    })
    .sort(compare(-1));
  const after = rows
    .filter((row) => {
      const time = new Date(row.TimeCreated).getTime();
      return time >= Math.max(incident, start) && time <= end;
    })
    .sort(compare(1));
  const selected = [...before.slice(0, 25), ...after.slice(0, 25)];
  const seen = new Set<string>();
  return {
    items: selected.filter((row) => {
      const key = `${row.LogName}\u0000${row.RecordId}\u0000${row.TimeCreated}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }),
    truncated_before: before.length > 25,
    truncated_after: after.length > 25,
  };
}

function eventDrafts(rows: z.infer<typeof eventRowSchema>[], source: Source, start: number, end: number): Draft[] {
  return rows
    .filter((row) => {
      const time = new Date(row.TimeCreated).getTime();
      return time >= start && time <= end;
    })
    .map((row) => ({
      source,
      kind: "windows_event",
      temporal_kind: "incident_event",
      timestamp_utc: new Date(row.TimeCreated).toISOString(),
      native_key: String(row.RecordId),
      summary: `${row.ProviderName} event ${row.Id}: ${row.Message}`,
      details: details(row),
    }));
}

function sourceRows(rows: CollectionRows, source: Source): readonly unknown[] {
  return rows[source];
}

function compareDrafts(a: Draft, b: Draft): number {
  const temporal = a.temporal_kind === b.temporal_kind ? 0 : a.temporal_kind === "incident_event" ? -1 : 1;
  return (
    temporal ||
    a.timestamp_utc.localeCompare(b.timestamp_utc) ||
    SOURCES.indexOf(a.source) - SOURCES.indexOf(b.source) ||
    a.native_key.localeCompare(b.native_key, "en", { numeric: true }) ||
    canonicalJson(a).localeCompare(canonicalJson(b))
  );
}

function details(value: Record<string, unknown>): string {
  return Object.entries(value)
    .map(([key, item]) => `${key}: ${String(item)}`)
    .join("\n");
}

function maskPatterns(): Array<[RegExp, string]> {
  const patterns: Array<[RegExp, string]> = [
    [/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, "<REDACTED_SECRET>"],
    [/\b(?:password|passwd|pwd|token|api[_-]?key|secret)\b\s*[:=]\s*[^\s,;]+/gi, "<REDACTED_SECRET>"],
    [/\\\\[^\\\s]+\\[^\s"'<>]+/g, "<REDACTED_UNC>"],
    [/[A-Za-z]:\\[^\r\n"'<>|]*/g, "<REDACTED_PATH>"],
    [/\/(?:Users|home|var|tmp|etc)\/[^\s"'<>]+/gi, "<REDACTED_PATH>"],
    [/\bS-1-\d+(?:-\d+){1,15}\b/gi, "<REDACTED_SID>"],
    [/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "<REDACTED_EMAIL>"],
    [/\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b/g, "<REDACTED_IP>"],
    [/\b(?:[A-F0-9]{1,4}:){2,7}[A-F0-9]{0,4}\b/gi, "<REDACTED_IP>"],
    [/\b(?:[A-F0-9]{2}[:-]){5}[A-F0-9]{2}\b/gi, "<REDACTED_MAC>"],
    [/\b[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\b/gi, "<REDACTED_GUID>"],
    [/\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b/g, "<REDACTED_SECRET>"],
    [/\b(?:ignore|disregard)\s+(?:all\s+)?(?:previous|prior)\s+instructions?\b/gi, "<REDACTED_PROMPT_INJECTION>"],
    [/\bsystem\s+prompt\b/gi, "<REDACTED_PROMPT_INJECTION>"],
  ];
  const known: Array<[string | undefined, string]> = [
    [process.env.COMPUTERNAME, "<REDACTED_COMPUTER>"],
    [process.env.USERNAME, "<REDACTED_USER>"],
    [process.env.USERDOMAIN, "<REDACTED_DOMAIN>"],
    [process.env.USERPROFILE, "<REDACTED_PATH>"],
    [homedir(), "<REDACTED_PATH>"],
  ];
  for (const [value, marker] of known) {
    if (value && value.length >= 3) patterns.push([new RegExp(escapeRegExp(value), "gi"), marker]);
  }
  return patterns;
}

function containsSensitive(value: string): boolean {
  return (
    maskPatterns().some(([pattern]) => pattern.test(value)) ||
    /-----BEGIN [A-Z ]*PRIVATE KEY-----|https?:\/\/[^\s/@:]+:[^\s/@]+@|[A-Za-z0-9+/_=-]{40,}/i.test(value) ||
    /[A-Fa-f0-9:]{2,}/g.test(value) &&
      [...value.matchAll(/[A-Fa-f0-9:]{2,}/g)].some((match) => match[0].includes(":") && isIP(match[0]) === 6)
  );
}

function containedPath(directory: string, name: string): string {
  const root = resolve(directory);
  const target = resolve(root, name);
  if (!target.startsWith(`${root}${sep}`)) throw new IncidentDocketError("invalid_path", "Path is outside storage");
  return target;
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalJson(item)}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function truncate(value: string, max: number): string {
  if (value.length <= max) return value;
  const end = /[\uD800-\uDBFF]/.test(value[max - 1] ?? "") ? max - 1 : max;
  return value.slice(0, end);
}

function isUnique<T>(values: T[]): boolean {
  return new Set(values).size === values.length;
}

function dedupe<T>(values: T[]): T[] {
  return [...new Set(values)];
}

function isValidRfc3339(value: string): boolean {
  const match = RFC3339.exec(value);
  if (!match) return false;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, fraction = "0", offset] = match;
  const parts = [yearText, monthText, dayText, hourText, minuteText, secondText];
  if (parts.some((part) => part === undefined)) return false;
  const [year, month, day, hour, minute, second] = parts.map(Number) as [number, number, number, number, number, number];
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59) return false;
  const local = new Date(Date.UTC(year, month - 1, day, hour, minute, second, Number(fraction.padEnd(3, "0"))));
  if (
    local.getUTCFullYear() !== year ||
    local.getUTCMonth() !== month - 1 ||
    local.getUTCDate() !== day ||
    local.getUTCHours() !== hour ||
    local.getUTCMinutes() !== minute ||
    local.getUTCSeconds() !== second
  ) {
    return false;
  }
  if (offset && offset !== "Z") {
    const [offsetHour, offsetMinute] = offset.slice(1).split(":").map(Number);
    if (offsetHour === undefined || offsetMinute === undefined || offsetHour > 23 || offsetMinute > 59) return false;
  }
  return Number.isFinite(Date.parse(value));
}

function isValidUtcOffset(value: string): boolean {
  if (value === "Z") return true;
  const match = /^(?:[+-])(\d{2}):(\d{2})$/.exec(value);
  return match !== null && Number(match[1]) <= 23 && Number(match[2]) <= 59;
}

function isCanonicalUtcTimestamp(value: string): boolean {
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString() === value;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
