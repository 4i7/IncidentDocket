# Development Process and Human Control

IncidentDocket was built through a human-controlled, phase-gated process rather than a single broad request to an AI system. This retrospective explains the decisions, verification gates, and audit-driven changes behind the project. Current product behavior is defined by [DESIGN.md](../DESIGN.md); [README.md](../README.md) is the user-facing guide, and the early options below are historical context, not supported features.

> **Language note:** The detailed planning and audit sessions were conducted primarily in Japanese, my first language, so I could examine technical, privacy, and release details with greater precision. I apologize for the language mismatch; this retrospective and the public project documentation are provided in English for reviewers.

## Problem and control model

Windows incident investigation creates a tension: broad diagnostic dumps can expose machine, user, path, and application information, while too little evidence leaves developers unable to investigate. I therefore fixed the product around a narrow, inspectable evidence layer placed before the reasoning model.

That boundary was not left to prompting alone. IncidentDocket encodes it through strict schemas, allowlisted sources and fields, bounded time windows, masking and residual scans, stable evidence IDs, and report-input validation. It never saves or returns raw collector evidence. Evidence text remains untrusted after masking, reports require human privacy review, and collection-time OS or driver snapshots cannot stand in for incident-time events. The product contract also states that temporal proximity is not proof of causation.

The human role was not limited to prompting for code. I defined the problem, boundaries, implementation order, acceptance gates, and release decisions. Codex and GPT-5.6 operated inside those constraints as implementation, verification, and adversarial-review tools.

## Scope evolution

The initial blueprint explored more options than the submission could safely implement and demonstrate. The final scope was deliberately reduced before those options became product commitments.

| Area | Initially considered | Final submission decision |
|---|---|---|
| Category | Work and Productivity was considered | Developer Tools |
| Package workflow | pnpm-based development was considered | npm with committed `package-lock.json` |
| Live evidence | Up to seven sources, including WER, Reliability, and services | Four sources: System, Application, OS, and display drivers |
| Reports | Markdown and HTML | Markdown only |
| Audience | Broader end-user/support framing | Developers and first-line technical support |
| Architecture | More optional capabilities | Four-tool stdio MCP with one synthetic fixture |

This was a deadline- and reviewability-driven scope reduction, not an attempt to merge incompatible specifications. The privacy pipeline, complete four-tool flow, evidence-ID validation, deterministic fixture, and no-rebuild installation path remained mandatory. WER, Reliability data, services, HTML reports, and pnpm are not current capabilities.

## Phase-gated implementation sequence

1. **Product contract and repository baseline.** I fixed the name, Developer Tools category, MIT license, audience, supported platforms, privacy boundary, and explicit exclusions. `DESIGN.md` became the sole product-design specification, while `AGENTS.md` became the execution contract. The gate was a coherent, reviewable scope with no unresolved legacy requirements.

2. **Deterministic fixture core.** Strict schemas, offset-bearing RFC 3339 handling, stable sorting, stable evidence IDs, and the `gpu-driver-reset` fixture came before PowerShell collection. The gate was repeatable tests and a build that needed no live machine evidence.

3. **Privacy, storage, and CLI.** Allowlist projection, masking, residual scanning, drop behavior, Markdown escaping, and non-overwrite storage were added around the fixture path. The CLI demo intentionally stopped at a masked evidence timeline instead of embedding a predetermined AI conclusion. The gate was that the fixture's synthetic sensitive values and recognized high-risk instruction patterns could not survive into saved or returned evidence.

4. **MCP and GPT-5.6 end-to-end flow.** The sequence `plan_collection -> collect_incident_window -> inspect_evidence -> export_support_report` connected collection to model-assisted analysis. A completed report requires client-generated hypotheses or an insufficient-evidence outcome, but the server constrains citations to existing evidence IDs, confidence to low or medium, and every hypothesis to explicit `not_proven` statements. The gate was a real four-tool fixture run without a fixed report.

5. **Windows live collectors.** Only after the deterministic path was stable did the project add System, Application, OS, and display-driver collection. Denied, timeout, unavailable, and no-data outcomes became bounded coverage records rather than raw-error fallbacks. The gate required fail-closed Windows 11 detection, source isolation, and no artifacts in the current working directory.

6. **Package, CI, and clean installation.** The packed CLI and MCP server were tested without relying on the source tree or TypeScript compiler. Installer behavior, checksums, release-bundle contents, and temporary-prefix installation were treated as product controls. The gate combined test, build, pack, audit, packed MCP, fixture, and installer checks.

7. **Feature freeze and submission.** After the core flow was complete, only blockers in installation, privacy, demonstration, and submission paths were accepted. Each behavior fix required the smallest regression test that proved the contract. Release publication remained a separate, human-controlled decision.

## Audit and remediation loop

The project used repeated implementation and adversarial-review passes:

```text
Initial design
-> design critique
-> detailed phase design
-> implementation
-> architecture/privacy audit
-> remediation
-> pre-push gate
-> release-state verification
-> isolated-cache / clean-environment revalidation
-> MCP demo verification
-> README and submission consistency audit
```

GPT-5.6 Luna handled bounded implementation and remediation tasks. GPT-5.6 Sol was used for deeper architecture, privacy, platform-boundary, supply-chain, and release-readiness review. These were separate model/session reviews, not an independent external security audit. I triaged the findings, decided which changes were required, prevented scope expansion, and retained responsibility for release decisions.

## Material audit findings

The audit loop changed implementation and release controls rather than producing only commentary.

| Finding | Why it mattered | Resulting control |
|---|---|---|
| Caller-supplied collection plans were not fully revalidated | A caller could bypass assumptions made during planning | Revalidate the complete normalized plan before collection |
| Build-number-only platform detection admitted Windows Server | The Windows 11 boundary was not actually enforced | Fail closed on both NT build and Windows product family |
| Installer checksum trust boundaries were incomplete | Partial verification could install unintended bytes | Verify the downloaded setup ZIP and the bundled npm package |
| Manual workflow dispatch could reach publication | A validation run could become a release action | Publish only for the intended pushed version tag |
| Build and publish stages lacked sufficient artifact identity checks | Downloaded publish inputs could differ from validated build outputs | Carry and compare hashes across the build-to-publish boundary |
| Draft Releases were missed by the original state check | Automation could incorrectly report that a tag was clear to publish | Detect draft, prerelease, published, duplicate, and unverifiable states fail-closed |

Later v0.1.1 stabilization followed the same rule: blank report text was rejected with regression coverage, and CI was aligned with the documented Node.js 22 and 24 support matrix.

## Release verification as engineering

A push or tag was not considered sufficient evidence of completion. Verification covered the public Release state, the exact asset set, outer and inner checksums, installation from the bundled package, the fixture demo, MCP registration, and the four-tool handshake. Isolated-cache and temporary-prefix checks reduced reliance on the development machine's existing npm cache, global installation, or source checkout.

Release automation was reviewed as a supply-chain boundary: read permissions by default, write permission only in the publish job, immutable action pins, tag/package-version matching, artifact hash continuity, and refusal to overwrite an existing or ambiguous Release. Published tags and Release assets were kept outside this documentation change.

## What worked and what could improve

What worked well:

- a human-owned product contract and threat model;
- deliberate scope reduction before implementation expanded further;
- a deterministic fixture before live collection;
- explicit gates, negative tests, and fail-closed remediation;
- separation between bounded implementation and adversarial review; and
- clean-install and public-release verification.

What could improve:

- The initial blueprint was broader than necessary and created planning overhead.
- Multiple “final” reviews show that the release checklist was consolidated too late.
- Platform-family and release-state negative tests should have existed earlier.
- Model-to-model review reduces self-consistency risk but does not replace external human security review.
- Future projects should maintain one current plan, one decision log, and one release checklist instead of overlapping planning documents.

## Conclusion

The main lesson was that AI-assisted development became reliable only after I converted intent into explicit contracts, staged gates, negative tests, and release checks. The models accelerated implementation and review, but I remained responsible for scope, evidence standards, safety boundaries, remediation choices, and the decision to ship.
