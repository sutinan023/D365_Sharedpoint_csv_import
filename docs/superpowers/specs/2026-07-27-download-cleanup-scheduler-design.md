# Download Cleanup Scheduler Design

## Goal

Install and remove a separate Windows Scheduled Task for monthly download
cleanup without changing the existing five-minute import task.

## Behavior

- `install_task_scheduler.ps1` registers the existing import task named
  `D365 SharePoint CSV Import` unchanged.
- It also registers `D365 SharePoint CSV Download Cleanup` to execute
  `run_download_cleanup.bat` monthly on day 1 at 01:00.
- Both batch files and `C:\xampp\php\php.exe` are validated before task
  registration.
- The cleanup task uses a one-hour execution limit and ignores overlapping
  instances.
- `uninstall_task_scheduler.ps1` removes both task names if they exist and
  stops either task when it is running.

## Safety and Verification

- The installer creates or updates only the two named scheduled tasks.
- Tests validate the PowerShell scripts' task names, batch targets, monthly
  schedule, and removal behavior without registering Windows tasks.
