# IncidentDocket Design

`DESIGN.md` is the product design source of truth. `README.md` is the user-facing guide.

## 1. Product definition

IncidentDocket is a privacy-bounded Windows evidence collector for developers. It narrows an incident window, masks known sensitive identifiers, and exposes an evidence-linked reporting workflow through MCP.

The primary users are developers and first-line technical support who maintain Windows applications or drivers.

### Supported scope

- Four MCP tools: `plan_collection`, `collect_incident_window`, `inspect_evidence`, and `export_support_report`.
- One synthetic fixture: `gpu-driver-reset`.
- Windows 11 live collection from System Event Log, Application Event Log, OS snapshot, and display-driver snapshot.
- Markdown evidence timelines and support reports.
- Node.js 22 or later for runtime; Node.js 24 for development and CI.
- npm as the package manager.

### Explicit exclusions

Security and Defender logs, WER, Reliability Monitor data, services, ETW/WPR, arbitrary files, arbitrary PowerShell, packet capture, registry dumps, browser history, GUI, HTML, RAG, automatic repair, and direct OpenAI API integration are outside the supported scope.

## 2. Implementation

- ESM TypeScript and Windows PowerShell 5.1.
- Main implementation: `src/index.ts`, `src/core.ts`, and `collectors/windows.ps1`.
- Synthetic data: `samples/gpu-driver-reset.json`.
- Tests: `test/core.test.ts`.
- Runtime dependencies: `@modelcontextprotocol/sdk@1.29.0` and `zod@4.4.3` only.
- Hashing, UUIDs, paths, process execution, storage, and Markdown rendering use Node.js standard libraries.
- The MCP server communicates over stdio and IncidentDocket implements no network client.

## 3. Data flow

```text
MCP client
  -> plan_collection
  -> collect_incident_window
  -> inspect_evidence
  -> client-generated bounded hypotheses or insufficient evidence
  -> export_support_report
  -> privacy-reviewed Markdown
```

IncidentDocket owns collection, validation, masking, evidence identity, storage, and report-input validation. It does not generate a fixed hypothesis or completed report.

## 4. MCP tools

### `plan_collection`

Input:

- Problem text: 1–2,000 characters.
- Incident time: offset-bearing RFC 3339 timestamp.
- Before and after windows: 0–30 minutes each; both cannot be zero.
- Sources: unique non-empty subset of the four supported sources.

Behavior:

- Masks the problem text.
- Normalizes the incident time and window to UTC.
- Rejects offset-free timestamps, unknown sources, unknown fields, and invalid windows.
- Holds no server-side plan state.

Annotations: read-only, non-destructive, idempotent, and closed-world.

### `collect_incident_window`

Input:

- A normalized plan.
- Mode: `fixture` or `live`.
- Fixture name `gpu-driver-reset` only when fixture mode is selected.

Behavior:

- Rejects live mode outside Windows 11.
- Applies a 12-second timeout per live source.
- Normalizes denied, unavailable, failed, timeout, and no-data outcomes into source coverage.
- Continues other sources when one source fails.
- Clips a future window end to collection time and records the incomplete window.
- Creates a UUID case with at most 200 evidence items.
- Saves only the processed case.

### `inspect_evidence`

Input:

- UUID case ID.
- One to twenty unique evidence IDs.

Behavior:

- Revalidates the saved case with a strict schema.
- Rejects unknown IDs and path traversal.
- Reapplies masking before return.
- Limits each details field to 2,000 characters.

Annotations: read-only, non-destructive, idempotent, and closed-world.

### `export_support_report`

Input:

- Case ID.
- Outcome: `hypotheses` or `insufficient_evidence`.
- Summary, up to three ranked hypotheses, missing evidence, and next steps.

Hypothesis contract:

- Consecutive ranks.
- `low` or `medium` confidence only.
- One or more existing evidence IDs.
- One or more `not_proven` statements.
- A hypothesis cannot rely only on collection-time snapshots.

Insufficient-evidence contract:

- No hypotheses.
- At least one missing-evidence statement.

Behavior:

- Rejects unknown evidence IDs and invalid hypothesis structure.
- Creates a new UUID report without overwriting an existing file.
- Returns Markdown, collection coverage, and a privacy-review warning.

All successful tools return a schema-valid object as `structuredContent` and the same minified JSON as text content. Errors expose bounded error codes and messages, never raw stderr or stack traces.

## 5. Case and evidence model

```text
case:
  schema_version
  case_id
  mode
  plan
  collected_at_utc
  coverage[]
  privacy
  evidence[]

evidence:
  id
  kind
  temporal_kind: incident_event | collection_snapshot
  timestamp_utc
  source
  summary
  details
```

- Incident events sort by timestamp, then source, native key, and content.
- Evidence IDs are assigned after masking and stable sorting.
- Incident events use `EV-###`; OS snapshots use `OS-###`; display-driver snapshots use `DR-###`.
- OS and display-driver evidence are collection-time snapshots and stay outside the incident timeline.
- Temporal proximity is not proof of causation.

Coverage status is one of `ok`, `no_data`, `denied`, `unavailable`, `failed`, or `timeout` and includes item count and truncation flags.

## 6. Windows collectors

The PowerShell script accepts only the fixed actions `system_events`, `application_events`, `os`, and `display_drivers`. It does not accept an arbitrary class, query, command, or output path and does not elevate privileges.

### Event logs

- Uses `Get-WinEvent -FilterHashtable`.
- Reads only System or Application.
- Includes levels 1–3.
- Applies the requested effective time window.
- Keeps at most 25 entries before and 25 entries after the incident for each log.
- Projects only time, log name, provider, event ID, level, record ID, and message.

### OS snapshot

Uses `Win32_OperatingSystem` and projects only:

- `Caption`
- `Version`
- `BuildNumber`
- `OSArchitecture`
- `LastBootUpTime`

### Display-driver snapshot

Uses `Win32_PnPSignedDriver`, filters `DeviceClass = 'DISPLAY'`, keeps at most 20 records, and projects only:

- `DeviceName`
- `Manufacturer`
- `DriverProviderName`
- `DriverVersion`
- `DriverDate`
- `IsSigned`
- `Status`

The collector serializes an explicit object to UTF-8 JSON, Base64-encodes it, and writes one ASCII line to stdout. Diagnostics go to stderr. Node.js decodes the payload and validates it with a strict schema; unknown fields fail validation.

## 7. Privacy boundary

- Mask known computer names, usernames, domains, absolute paths, UNC paths, SIDs, email addresses, IP and MAC addresses, GUIDs, and credential-like values.
- Replace unsafe markup and instruction-like content before return.
- Drop evidence that remains sensitive after sanitization.
- Do not save or return raw collector evidence, raw stderr, stack traces, or user-specific absolute paths.
- Escape dynamic Markdown content.
- Mark every case as requiring human privacy review.
- State in every timeline and report that automatic masking may miss unknown sensitive data.
- Treat all evidence text as untrusted data, never as instructions.

Masking is not complete anonymization. Users must review output before sharing it.

## 8. Storage and CLI

Storage roots:

- Windows: `%LOCALAPPDATA%\IncidentDocket`.
- Non-Windows fixture mode: the operating-system temporary directory.

MCP callers cannot provide an arbitrary storage path. Returned live locations use symbolic `%LOCALAPPDATA%` paths rather than usernames or absolute paths.

The CLI exposes two commands:

```text
incident-docket mcp
incident-docket demo --fixture gpu-driver-reset [--output <directory>]
```

Only the fixture demo accepts `--output`. Without it, the case uses the normal user-local storage root. The demo prints the masked timeline and does not create a fixed hypothesis or support report.

## 9. Package and CI

- Package name: `incident-docket`.
- ESM binary: `incident-docket` → `dist/index.js`.
- `dist/index.js` retains the Node.js shebang.
- `prepack` runs only the TypeScript build.
- No install lifecycle scripts.
- Package files are limited to `dist`, `collectors`, `samples`, `README.md`, `LICENSE`, and `package.json`.
- Source, tests, design documents, agent instructions, CI files, cases, reports, logs, and tarballs are excluded.
- Collector and fixture paths resolve relative to the installed package, not the current working directory.

The Windows CI workflow uses Node.js 24 and runs:

```text
npm ci
npm test
npm run build
npm pack --dry-run
npm audit --omit=dev
packed fixture CLI smoke
```

CI uses only synthetic fixture data and never performs live collection.

## 10. Verification

Required local checks:

```powershell
npm ci
npm test
npm run build
npm pack --dry-run
npm audit --omit=dev
```

The test suite covers:

- Strict schema and input limits.
- RFC 3339 offsets, time boundaries, and future clipping.
- Stable ordering and evidence IDs.
- Masking, unsafe-message replacement, and evidence dropping.
- Report rank, confidence, evidence-link, snapshot, and non-overwrite contracts.
- MCP tool count, annotations, stdio cleanliness, and structured/text equality.
- Windows success, denied, no-data, timeout, Unicode, and process-failure behavior.
- Package-relative resources and current-working-directory isolation.
- Clean packed fixture and MCP workflows.

Behavior changes require the smallest regression test that proves the contract.
