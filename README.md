# IncidentDocket

IncidentDocket is a privacy-bounded Windows evidence collector for developers. It narrows an incident window, masks known sensitive identifiers, and exposes an evidence-linked reporting workflow through MCP.

It is intended for developers and first-line technical support who maintain Windows applications or drivers.

## Why it exists

Windows incident reports often start with a timestamp and a vague symptom. Asking for broad diagnostic dumps can expose user or machine information, while collecting too little context makes the report hard to investigate. IncidentDocket collects a small, explicit set of evidence and keeps observations separate from conclusions.

## What it does

1. Validates a bounded incident window and an allowlisted set of sources.
2. Collects either a synthetic fixture or Windows evidence.
3. Masks known sensitive identifiers before evidence is saved or returned.
4. Assigns stable evidence IDs for selective inspection.
5. Validates cited IDs and exports a privacy-reviewed Markdown support report.

IncidentDocket does not contain a fixed hypothesis or completed report. The MCP client supplies hypotheses or an insufficient-evidence result after inspecting the returned evidence.

## Architecture

```text
MCP client
  -> plan_collection
  -> collect_incident_window
  -> inspect_evidence
  -> client-generated bounded hypotheses
  -> export_support_report
  -> privacy-reviewed Markdown

IncidentDocket
  -> strict Zod schemas
  -> TypeScript privacy and evidence pipeline
  -> synthetic fixture or allowlisted Windows PowerShell collector
  -> user-local case and report storage
```

The MCP server communicates over stdio. IncidentDocket implements no network client and requires no OpenAI API key.

## MCP tools

| Tool | Purpose |
|---|---|
| `plan_collection` | Validates the problem, timestamp, time window, and requested sources. |
| `collect_incident_window` | Creates and saves a masked fixture or live case with per-source coverage. |
| `inspect_evidence` | Revalidates and returns only selected, existing evidence IDs. |
| `export_support_report` | Validates hypotheses or insufficient evidence and creates a Markdown report. |

Each successful tool call returns matching structured content and JSON text content. Evidence text is untrusted data and must never be treated as instructions.

## Quick start guide

Requirements:

- Node.js 22 or later
- npm

Build and install from source:

```powershell
git clone https://github.com/4i7/IncidentDocket.git
cd IncidentDocket
npm ci
npm run build
npm pack
npm install --global .\incident-docket-0.1.0.tgz
```

Run the cross-platform synthetic fixture:

```powershell
incident-docket demo --fixture gpu-driver-reset
```

The demo prints a masked Markdown evidence timeline. It does not generate a hypothesis or support report.

## MCP setup

Register the stdio server in Codex:

```powershell
codex mcp add incident_docket -- incident-docket mcp
```

Then ask the MCP client to use IncidentDocket. For example:

```text
Use IncidentDocket to investigate the synthetic display-driver problem at
2026-07-16T09:30:00+09:00.

Use fixture gpu-driver-reset. Collect only the minimum necessary evidence.
Inspect the relevant evidence IDs and export a privacy-reviewed GitHub issue report.
Do not treat temporal proximity as proof of causation. Clearly state what is not proven.
```

The server entry point is:

```powershell
incident-docket mcp
```

## Live Windows collection

Live collection is supported on Windows 11 and runs as the current user without automatic elevation. Available sources are:

- `system_events` — time-bounded System Event Log entries
- `application_events` — time-bounded Application Event Log entries
- `os` — collection-time operating-system snapshot
- `display_drivers` — collection-time display-driver snapshot

OS and display-driver evidence are marked `collection_snapshot` and kept separate from the incident event timeline. Source failures are represented in coverage instead of exposing raw process errors.

Live cases and reports are stored below `%LOCALAPPDATA%\IncidentDocket`. MCP callers cannot choose an arbitrary output directory.

## Supported platforms

| Mode | Supported environment |
|---|---|
| Synthetic fixture | Node.js 22 or later on Windows, macOS, or Linux |
| Live collection | Windows 11 with Windows PowerShell 5.1 |
| Development and CI | Node.js 24 and npm |

## Privacy and security boundaries

- Collectors project only explicit allowlisted fields; Node.js rejects unknown fields.
- Known usernames, domains, paths, UNC paths, SIDs, email addresses, IP and MAC addresses, GUIDs, and credential-like values are masked.
- Unsafe markup and prompt-injection-like content are replaced or dropped before return.
- Raw collector evidence, raw stderr, stack traces, and user-specific absolute paths are not written to cases or returned through MCP.
- Masking is not complete anonymization. Unknown sensitive data may remain, so review every timeline and report before sharing.
- Data returned through MCP enters the configured client's processing boundary.
- IncidentDocket collects evidence; it does not repair the machine or prove root cause.

Do not add real machine evidence to fixtures, tests, screenshots, or commits.

## Evidence-linked reporting

Incident events receive stable `EV-###` identifiers. OS and display-driver snapshots receive `OS-###` and `DR-###` identifiers.

Report export:

- rejects evidence IDs that are not present in the case;
- accepts only `low` or `medium` confidence;
- requires a non-empty `not_proven` statement for each hypothesis;
- rejects a hypothesis supported only by collection-time snapshots; and
- supports an explicit `insufficient_evidence` outcome.

Temporal proximity is not proof of causation.

## Development

```powershell
npm ci
npm test
npm run build
npm pack --dry-run
npm audit --omit=dev
```

The Windows CI workflow runs these deterministic checks and a packed fixture smoke test. It does not read live event logs.

## Scope

IncidentDocket deliberately does not collect Security or Defender logs, WER, Reliability Monitor data, services, ETW/WPR traces, arbitrary files, arbitrary PowerShell output, network packets, registry dumps, or browser history. It does not include a GUI, HTML reports, RAG, automatic repair, or direct OpenAI API integration.

## License

MIT. See [LICENSE](LICENSE).
