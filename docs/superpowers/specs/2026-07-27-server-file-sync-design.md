# Server File Sync Design

## Goal

Provide a Windows batch script that mirrors this project directory to:

`\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import`

After a successful run, the destination must contain the same files and
directories as the source, except for the excluded `.git` directory.

## Behavior

- The script is named `sync_to_server.bat` and is stored in the project root.
- The source directory is resolved from the script's own location so the
  script works regardless of the current command prompt directory.
- `robocopy /MIR` performs the synchronization.
- Files and directories that exist only at the destination are deleted.
- The `.git` directory is excluded from the synchronization.
- The script displays the source, destination, and a deletion warning before
  asking the operator to confirm.
- Any response other than `Y` cancels the operation without changing the
  destination.
- The script checks that the destination network path is reachable before
  running `robocopy`.

## Result Handling

Robocopy exit codes from 0 through 7 indicate success, including cases where
files were copied or destination-only files were removed. Exit codes 8 and
above indicate failure. The batch script converts these values into a normal
process result:

- Exit code `0`: synchronization succeeded.
- Exit code `1`: synchronization failed, was cancelled, or the destination
  could not be reached.

The original Robocopy exit code is printed for troubleshooting.

## Verification

The script will be checked without changing the network destination by:

- confirming its source and destination path handling;
- confirming `/MIR` and the `.git` exclusion are present;
- confirming cancellation happens before `robocopy`;
- confirming Robocopy exit codes 0-7 are treated as success and 8+ as failure.

An actual synchronization is intentionally not run during implementation
because `/MIR` can delete files from the destination.
