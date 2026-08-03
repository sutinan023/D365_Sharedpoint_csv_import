# Remove DEFINER Identity from Rehearsal Dumps

**Date:** 2026-08-04  
**Status:** Approved design, pending written-spec approval

## Problem

The Production checkpoint dump contains two view clauses in this form:

```sql
DEFINER=`d365_finance_prod_migrator`@`%` SQL SECURITY INVOKER
```

The current sanitizer recognizes only an identity followed by `SQL SECURITY DEFINER`. It therefore leaves the identities above unchanged, and its final fail-closed check correctly stops with `Sanitized dump retained a definer security clause.`

The checkpoint is retained as a backup, but no restore rehearsal, Production migration, or Production code deployment occurred after this failure.

## Selected Approach

Treat the account identity and the view security mode as separate SQL constructs:

- recognize `DEFINER=<user>@<host>` independently of `SQL SECURITY DEFINER|INVOKER`;
- remove the identity only when it is inside a recognized `VIEW` DDL block;
- convert `SQL SECURITY DEFINER` to `SQL SECURITY INVOKER`;
- preserve an existing `SQL SECURITY INVOKER` clause;
- reject an executable identity or definer-security clause outside a recognized view block;
- continue ignoring matching text inside SQL strings and non-executable comments.

This supports both MySQL dump representations without weakening the existing fail-closed boundary.

## Counts and Audit

`definer_count` continues to mean the number of executable `SQL SECURITY DEFINER` clauses in the live database and bound dump, not the number of account identities.

Therefore an `INVOKER` view may legitimately have:

- one removable `DEFINER=<user>@<host>` identity;
- zero entries in `definer_count`.

The sanitizer must validate identities and security clauses independently. Its output must contain neither an executable `DEFINER=` identity nor an executable `SQL SECURITY DEFINER` clause. Existing checkpoint hashes, source/dump qualified-reference counts, and audit binding remain unchanged.

## Scope

Modify only:

- `tools/prepare_restore_rehearsal.ps1`;
- `tests/test_prepare_restore_rehearsal.ps1`;
- a directly affected adapter fixture or test only if required for regression coverage.

Do not change the migration SQL, checkpoint contents, application database credentials, import logic, Scheduled Task state, SharePoint data, UAT data, or Production data.

The failed `2026-08-03.7` release remains immutable. The fix will use the next release ID generated for 2026-08-04 and must create a fresh Production checkpoint.

## Verification

Tests must prove:

- an identity followed by `SQL SECURITY INVOKER` is removed while INVOKER is preserved;
- the case above succeeds with `ExpectedDefinerCount=0`;
- an identity followed by `SQL SECURITY DEFINER` is removed and the security mode becomes INVOKER;
- an executable identity or `SQL SECURITY DEFINER` outside a recognized view block fails before output creation;
- identity-like text inside strings and non-executable comments is preserved and not counted;
- the sanitized result contains no executable identity or definer-security clause;
- existing count, hash, and qualified-reference guards still pass;
- the full PowerShell and PHP regression suites pass.

## Deployment Sequence

After implementation and local verification:

1. commit and push the next immutable release;
2. deploy to UAT and update its `APP_RELEASE`;
3. compare UAT with local and perform the focused UAT smoke test;
4. obtain explicit Production cutover approval for that exact release;
5. create a fresh checkpoint and complete the restore rehearsal;
6. apply migration `006_expand_stg_payment_before_post_invoice_number.sql` only after rehearsal passes;
7. deploy and verify Production before retrying the single failed queue item.

Production Scheduled Tasks remain disabled unless the user explicitly enables them after verification.
