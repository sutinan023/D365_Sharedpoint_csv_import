param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('UAT', 'Production')]
    [string] $Environment,
    [switch] $PlanOnly
)

$suffix = if ($Environment -eq 'UAT') { 'UAT' } else { 'PROD' }
$taskNames = @(
    "D365 SharePoint CSV Import [$suffix]",
    "D365 SharePoint CSV Download Cleanup [$suffix]"
)

if ($PlanOnly) {
    $taskNames | ConvertTo-Json
    return
}

foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { continue }
    if ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
