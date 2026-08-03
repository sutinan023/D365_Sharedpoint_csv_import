# Remote Scheduled Task Control Design

**Date:** 2026-08-03  
**Status:** Approved design, pending written-spec approval

## Problem

The release controller runs on `IT-SUTINAN`, while the Production Scheduled Tasks run on `100.1.1.166`. The migration adapter currently calls local ScheduledTasks cmdlets, so it cannot find the three Production tasks even though they exist and are disabled on the server.

The failed `2026-08-03.4` attempt stopped before checkpoint, restore rehearsal, migration, or deployment. Production remains unchanged.

## Selected Approach

Use Windows `schtasks.exe` with `/S <server>` from the local release controller. The server name is derived from the UNC `ProductionRoot` (`\\100.1.1.166\htdocs\prod`). This avoids enabling WinRM, changing TrustedHosts, copying source repositories to the server, or weakening the scheduled-task safety gate.

No password or credential parameter will be added. The command uses the Windows identity already running the elevated release PowerShell process.

## Task Discovery and Validation

For each configured Production task, the adapter will:

1. Query the exact full task name with `schtasks /Query /S <server> /TN <literal-name> /XML`.
2. Require a successful exit code and valid Task Scheduler XML.
3. Verify the XML task URI equals the requested task name using ordinal comparison. Brackets such as `[PROD]` are ordinary characters, never wildcard syntax.
4. Query the runtime state in CSV form and accept only the known server states `Running`, `Ready`, or `Disabled`.

All three tasks must validate before any task is stopped or disabled. A missing task, duplicate/incorrect URI, malformed response, inaccessible server, or unknown state stops the cutover before checkpoint or migration.

## State Changes

- A `Running` task is ended using the exact remote task name.
- A task that was enabled before cutover is disabled using the exact remote task name and recorded for restoration.
- A task already disabled remains disabled and is not recorded for restoration.
- At the restore stage, only tasks that were enabled before cutover are enabled again.
- Every `schtasks` state-changing command must return success; otherwise the release fails closed.

For the current cutover, all three Production tasks are already disabled, so successful validation performs no scheduler state change and they remain disabled after the migration flow.

## Integration

`release.ps1` will determine the task-scheduler computer from `ProductionRoot` and pass it to `New-D365ManualRestoreMigrationAdapter`. A local filesystem Production root resolves to the local computer; a UNC root resolves to the UNC host. Invalid UNC input fails closed.

The scheduler command execution will be behind a narrow injectable command adapter. Production uses `schtasks.exe`; tests use a fake adapter and never contact or modify a real Task Scheduler.

No changes are made to application imports, database migration SQL, SharePoint folders, database credentials, or Task definitions.

## Tests

Behavioral tests will prove that:

- the computer name is derived from `\\100.1.1.166\htdocs\prod`;
- the three literal `[PROD]` names are queried on `100.1.1.166`;
- every task is validated before the first state-changing command;
- missing tasks, malformed XML, mismatched URI, unknown state, and failed commands stop the flow;
- running tasks are ended and enabled tasks are disabled;
- pre-disabled tasks are never enabled during restoration;
- only previously enabled tasks are restored;
- tests do not invoke the real `schtasks.exe` or Task Scheduler.

The focused adapter test, all PowerShell tests, the PHP suite, parser checks, and `git diff --check` must pass before deployment.

## Release Handling

Release `2026-08-03.4` remains immutable. This scheduler-control fix will be committed and promoted through UAT as a new release, expected to be `2026-08-03.5`. Production promotion requires fresh UAT verification and explicit approval for the new release ID.
