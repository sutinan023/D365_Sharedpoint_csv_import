# Live and Dump Qualified-Reference Count Design

**Date:** 2026-08-03  
**Status:** Approved design, pending written-spec approval

## Problem

Production checkpoint `2026-08-03.6` captured `qualified_reference_count=24` from live `information_schema.VIEWS`, while the bound `mysqldump` file contains 22 qualified references. The difference is deterministic:

- `v_tbpayin_from_payment_outbound` contributes 22 qualified references in both live metadata and the dump;
- `vw_import_report` contributes two qualified references in live metadata, but `mysqldump` emits its two source tables as unqualified `stg_payment_outbound` and `stg_received_outbound` names.

Both required views are present in the dump. The current sanitizer incorrectly compares the dump representation with the live representation, so it stops before restore rehearsal.

## Selected Approach

Keep two separately named counts in `verification_baseline`:

- `qualified_reference_count`: the existing live database count, unchanged;
- `dump_qualified_reference_count`: the count measured from the exact backup file after `mysqldump` succeeds.

`database_checkpoint.ps1` will read the completed dump as strict UTF-8 and count case-insensitive occurrences of the exact backtick-qualified source database pattern. The dump hash, size, live baseline, and dump count are written together to the immutable checkpoint manifest.

The raw dump count is intentionally conservative. If the source database qualifier occurs inside a string or non-executable comment, the checkpoint count will exceed the sanitizer's executable-reference count and rehearsal preparation will fail closed rather than silently accepting ambiguous SQL.

## Sanitizer Behavior

When `-UseCheckpointBaseline` is selected, `prepare_restore_rehearsal.ps1` must require all three native nonnegative integer fields:

- `definer_count`;
- `qualified_reference_count`;
- `dump_qualified_reference_count`.

The live count remains preserved for audit. Only `dump_qualified_reference_count` is used as `ExpectedQualifiedReferenceCount` when validating and rewriting the backup file.

The sanitizer continues to require:

- every executable source qualifier is inside a recognized view block;
- the dump executable-reference count equals the bound dump count;
- no Production qualifier remains after sanitization;
- the sanitized dump contains the same number of rehearsal qualifiers;
- definers are converted to invoker security;
- the checkpoint hash binds the exact backup and audit artifacts.

Manually editing a checkpoint manifest or replacing live count 24 with dump count 22 is not allowed.

## Compatibility and Scope

Checkpoint manifests without `dump_qualified_reference_count` fail closed. The existing `.6` checkpoint remains a valid retained backup but cannot authorize rehearsal or migration. A new checkpoint must be created under the next immutable release.

Modify only the checkpoint/sanitizer path and its fixtures:

- `tools/database_checkpoint.ps1`;
- `tools/prepare_restore_rehearsal.ps1`;
- `tests/test_database_checkpoint.ps1`;
- `tests/test_prepare_restore_rehearsal.ps1`;
- checkpoint fixtures in `tests/test_manual_restore_migration_adapter.ps1`.

Do not change migration SQL, database application credentials, import behavior, Scheduled Task control, SharePoint paths, or report code.

## Verification

Tests must prove:

- a live count of 24 and dump count of 22 is accepted when both are immutably bound;
- the sanitizer rewrites exactly 22 dump qualifiers and leaves zero Production qualifiers;
- a missing, negative, string-valued, or incorrect dump count fails before output creation;
- a legacy checkpoint without the new field fails closed;
- the existing explicit-count mode remains unchanged;
- full PowerShell and PHP regression suites pass.

## Release Handling

Release `2026-08-03.6` remains immutable. This correction is promoted as the next release, expected to be `2026-08-03.7`, followed by fresh UAT verification and explicit Production cutover approval.
