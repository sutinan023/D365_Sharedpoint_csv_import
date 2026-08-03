# Schtasks Three-Field CSV Parser Design

**Date:** 2026-08-03  
**Status:** Approved design, pending written-spec approval

## Problem

The read-only Production query:

```text
schtasks.exe /Query /S 100.1.1.166 /TN "\D365 SharePoint CSV Import [PROD]" /FO CSV /NH
```

returns exactly three CSV fields on the real server:

```text
"\D365 SharePoint CSV Import [PROD]","N/A","Disabled"
```

The release parser and its fake test fixture currently expect four fields, so release `2026-08-03.5` stopped with `Task Scheduler returned invalid CSV`. It stopped before database checkpoint, restore rehearsal, migration, or Production deployment. The Production tasks remain disabled.

## Selected Correction

Keep the existing non-verbose, read-only `schtasks /Query /FO CSV /NH` command and parse exactly these three fields in order:

1. full task name;
2. next run time;
3. runtime state.

The parser must consume the complete record, allowing only surrounding whitespace and a final line ending. It must continue to decode doubled CSV quotes, compare the returned task name with `StringComparison.Ordinal`, and accept only the states `Running`, `Ready`, or `Disabled`.

Malformed CSV, extra fields, a mismatched task name, or an unknown state remains a fail-closed error before checkpoint or migration.

## Scope

Modify only:

- `tools/manual_restore_migration_adapter.ps1` for the three-field parser;
- `tests/test_manual_restore_migration_adapter.ps1` for the corrected fake output and regression coverage using the exact real-server record.

Do not change scheduler command arguments, task names, remote server derivation, task state-change behavior, database code, migration SQL, import logic, credentials, or release-menu prompts.

## Verification

The focused test must prove:

- the exact real-server three-field record is accepted;
- the exact `[PROD]` name and `Disabled` state are extracted;
- a fourth field is rejected;
- missing fields, mismatched names, and unknown states are rejected;
- all scheduler tests remain hermetic and never call the real Task Scheduler.

After the focused RED/GREEN cycle, all 16 PowerShell test files, PHP 97 tests, parser checks, and `git diff --check` must pass. A separate live verification may use `/Query` only and must not issue `/End`, `/Change`, `/Enable`, or `/Disable`.

## Release Handling

Release `2026-08-03.5` remains immutable. This correction must be committed and promoted through UAT as the next release, expected to be `2026-08-03.6`. Production promotion requires fresh UAT verification and explicit approval for `.6`.
