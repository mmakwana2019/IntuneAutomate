# =====================================================================
# Get-UTCMInventory.ps1
# Lists all UTCM monitors, snapshot jobs, and latest drift results
# for a target Microsoft 365 tenant.
#
# PREREQUISITES:
#   PowerShell 7.2+
#   Microsoft.Graph.Authentication module:
#     Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
#
# USAGE:
#   Run the script, enter your tenant ID or domain when prompted.
#   Authentication is interactive (delegated) - a browser window will open.
#
# NOTE: UTCM is in public preview. Endpoint behaviour reflects testing
# from move2modern.co.uk in March 2026 and may vary across tenants.
# =====================================================================

#Requires -Version 7.2

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# PREREQ CHECK
# ---------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host ""
    Write-Host "  Microsoft.Graph.Authentication module not found." -ForegroundColor Red
    Write-Host "  Install it with:" -ForegroundColor Yellow
    Write-Host "    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "Press Enter to close"
    exit
}

# ---------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------
function Invoke-GraphPaged {
    param([string]$Uri)
    $results  = [System.Collections.Generic.List[object]]::new()
    $nextUri  = $Uri
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        if ($response.value) { $results.AddRange($response.value) }
        $nextUri  = $response.'@odata.nextLink'
    } while ($nextUri)
    return $results
}

function Format-Age {
    param([string]$DateString)
    if ([string]::IsNullOrWhiteSpace($DateString)) { return "N/A" }
    try {
        $date = [datetime]$DateString
        $age  = (Get-Date) - $date
        if ($age.TotalDays  -ge 1) { return "$([int]$age.TotalDays)d ago  ($($date.ToString('yyyy-MM-dd HH:mm')))" }
        if ($age.TotalHours -ge 1) { return "$([int]$age.TotalHours)h ago  ($($date.ToString('HH:mm')))" }
        return "$([int]$age.TotalMinutes)m ago"
    } catch { return $DateString }
}

function Write-Banner {
    param([string]$Text, [string]$Color = "Cyan")
    Write-Host ""
    Write-Host ("  " + ("─" * 50)) -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host ("  " + ("─" * 50)) -ForegroundColor $Color
    Write-Host ""
}

# ---------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------
try {

$base = "https://graph.microsoft.com/beta/admin/configurationManagement"

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║        UTCM Inventory  |  move2modern.co.uk  ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$tenant = Read-Host "  Enter tenant ID or domain"
if ([string]::IsNullOrWhiteSpace($tenant)) { throw "Tenant is required." }

Write-Host ""
Write-Host "  Authenticating — browser window will open..." -ForegroundColor Yellow

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -TenantId $tenant -Scopes "ConfigurationMonitoring.ReadWrite.All" -NoWelcome -ErrorAction Stop

$ctx     = Get-MgContext
$orgName = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization").value[0].displayName

Write-Host "  Connected: $orgName ($($ctx.TenantId))" -ForegroundColor Green

# ---------------------------------------------------------------
# MONITORS
# ---------------------------------------------------------------
Write-Banner "MONITORS"

$monitors = @()
try {
    $monitors = @(Invoke-GraphPaged -Uri "$base/configurationMonitors")
} catch {
    Write-Host "  Could not retrieve monitors: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Check UTCM is available in this tenant and the scope is consented." -ForegroundColor DarkGray
}

if ($monitors.Count -eq 0) {
    Write-Host "  No monitors found." -ForegroundColor Yellow
    Write-Host "  Create one using Setup-UTCMBaseline.ps1 from move2modern.co.uk" -ForegroundColor DarkGray
} else {
    Write-Host "  $($monitors.Count) monitor(s) found`n" -ForegroundColor Green

    foreach ($m in $monitors) {
        $statusColor = if ($m.status -eq 'active') { 'Green' } else { 'Yellow' }
        Write-Host "  ┌─ $($m.displayName)" -ForegroundColor White
        Write-Host "  │  ID          : $($m.id)" -ForegroundColor Gray
        Write-Host "  │  Status      : $($m.status)" -ForegroundColor $statusColor
        Write-Host "  │  Mode        : $($m.mode)" -ForegroundColor Gray
        Write-Host "  │  Frequency   : every $($m.monitorRunFrequencyInHours) hours" -ForegroundColor Gray
        Write-Host "  │  Created     : $(Format-Age $m.createdDateTime)" -ForegroundColor Gray
        Write-Host "  │  Modified    : $(Format-Age $m.lastModifiedDateTime)" -ForegroundColor Gray
        if ($m.description) {
        Write-Host "  │  Description : $($m.description)" -ForegroundColor DarkGray
        }
        Write-Host "  └─────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
    }
}

# ---------------------------------------------------------------
# SNAPSHOT JOBS
# ---------------------------------------------------------------
Write-Banner "SNAPSHOT JOBS"

$snapshotJobs = @()
try {
    $snapshotJobs = @(Invoke-GraphPaged -Uri "$base/configurationSnapshotJobs")
} catch {
    Write-Host "  Could not retrieve snapshot jobs: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  (Endpoint: $base/configurationSnapshotJobs)" -ForegroundColor DarkGray
}

if ($snapshotJobs.Count -eq 0) {
    Write-Host "  No snapshot jobs found." -ForegroundColor Yellow
} else {
    Write-Host "  $($snapshotJobs.Count) snapshot job(s) found`n" -ForegroundColor Green

    foreach ($s in $snapshotJobs) {
        $statusColor = switch ($s.status) {
            'succeeded'  { 'Green'  }
            'failed'     { 'Red'    }
            'inProgress' { 'Yellow' }
            default      { 'Gray'   }
        }
        Write-Host "  ┌─ $($s.displayName)" -ForegroundColor White
        Write-Host "  │  ID          : $($s.id)" -ForegroundColor Gray
        Write-Host "  │  Status      : $($s.status)" -ForegroundColor $statusColor
        Write-Host "  │  Created     : $(Format-Age $s.createdDateTime)" -ForegroundColor Gray
        Write-Host "  │  Completed   : $(Format-Age $s.completedDateTime)" -ForegroundColor Gray
        if ($s.resources) {
        Write-Host "  │  Resources   : $($s.resources -join ', ')" -ForegroundColor DarkGray
        }
        if ($s.resourceLocation) {
        Write-Host "  │  Download at : $($s.resourceLocation)" -ForegroundColor DarkGray
        }
        Write-Host "  └─────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
    }
}

# ---------------------------------------------------------------
# DRIFT RESULTS (latest per monitor)
# ---------------------------------------------------------------
if ($monitors.Count -gt 0) {

    Write-Banner "LATEST DRIFT RESULTS (per monitor)"

    foreach ($m in $monitors) {
        Write-Host "  Monitor: $($m.displayName)" -ForegroundColor White
        try {
            $uri      = "$base/configurationMonitoringResults?`$filter=monitorId eq '$($m.id)'&`$top=5&`$orderby=runCompletionDateTime desc"
            $results  = @((Invoke-MgGraphRequest -Method GET -Uri $uri).value)

            if ($results.Count -eq 0) {
                Write-Host "  No monitoring results found yet." -ForegroundColor DarkGray
            } else {
                Write-Host "  Showing last $($results.Count) run(s):`n" -ForegroundColor Gray
                foreach ($r in $results) {
                    $rc = if ($r.runStatus -eq 'successful') { 'Green' } else { 'Red' }
                    $dc = if ($r.driftsCount -gt 0) { 'Red' } else { 'Green' }
                    Write-Host ("    [{0}]  Status: {1,-12}  Drifts: {2,-4}  Completed: {3}" -f
                        $r.id.Substring(0,8),
                        $r.runStatus,
                        $r.driftsCount,
                        (Format-Age $r.runCompletionDateTime)
                    ) -ForegroundColor Gray
                }
            }
        } catch {
            Write-Host "  Could not retrieve results: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    # ---------------------------------------------------------------
    # ACTIVE DRIFTS
    # ---------------------------------------------------------------
    Write-Banner "ACTIVE DRIFTS"

    $allDrifts = @()
    try {
        $allDrifts = @(Invoke-GraphPaged -Uri "$base/configurationDrifts?`$filter=status eq 'active'")
    } catch {
        Write-Host "  Could not retrieve drifts: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($allDrifts.Count -eq 0) {
        Write-Host "  No active drifts detected." -ForegroundColor Green
    } else {
        Write-Host "  $($allDrifts.Count) active drift(s) found`n" -ForegroundColor Red

        foreach ($d in $allDrifts) {
            Write-Host "  ┌─ Resource: $($d.resourceType)" -ForegroundColor Yellow
            Write-Host "  │  Drift ID    : $($d.id)" -ForegroundColor Gray
            Write-Host "  │  Monitor ID  : $($d.monitorId)" -ForegroundColor Gray
            Write-Host "  │  First seen  : $(Format-Age $d.firstReportedDateTime)" -ForegroundColor Gray
            if ($d.resourceInstanceIdentifier) {
                $identifier = ($d.resourceInstanceIdentifier | ConvertTo-Json -Compress)
            Write-Host "  │  Instance    : $identifier" -ForegroundColor DarkGray
            }
            if ($d.driftedProperties) {
            Write-Host "  │  Drifted properties:" -ForegroundColor Gray
                foreach ($p in $d.driftedProperties) {
            Write-Host "  │    • $($p.propertyName)" -ForegroundColor Yellow
            Write-Host "  │        Current : $($p.currentValue)" -ForegroundColor Red
            Write-Host "  │        Desired : $($p.desiredValue)" -ForegroundColor Green
                }
            }
            Write-Host "  └─────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host ""
        }
    }
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║             Inventory complete               ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

} catch {
    Write-Host ""
    Write-Host "  Script terminated with an error:" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $($_ | Out-String)" -ForegroundColor DarkGray
} 

Write-Banner "CLEANUP SUMMARY (READ CAREFULLY)"

Write-Host "If you proceed, the following will be REMOVED:" -ForegroundColor Yellow
Write-Host " • All UTCM configuration monitors" -ForegroundColor Gray
Write-Host " • All UTCM snapshot jobs" -ForegroundColor Gray
Write-Host ""

Write-Host "The following will NOT be removed:" -ForegroundColor Green
Write-Host " • Any Intune or Entra configuration" -ForegroundColor Gray
Write-Host " • Historical drift results or monitoring history" -ForegroundColor Gray
Write-Host " • Any tenant settings" -ForegroundColor Gray
Write-Host ""

Write-Host "Notes:" -ForegroundColor Cyan
Write-Host " • Drift records and monitoring results cannot be deleted manually." -ForegroundColor DarkGray
Write-Host " • They become orphaned and expire automatically." -ForegroundColor DarkGray
Write-Host " • This operation is intended for test cleanup only." -ForegroundColor DarkGray
Write-Host ""

$confirm = Read-Host "Do you want to DELETE all UTCM monitors and snapshot jobs created during testing? (type DELETE to proceed)"

if ($confirm -ne "DELETE") {
    Write-Host "Cleanup cancelled." -ForegroundColor Yellow
    return
}

Write-Banner "DELETING UTCM MONITORS"

foreach ($m in $monitors) {
    Write-Host "Deleting monitor: $($m.displayName)" -ForegroundColor Yellow
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri "$base/configurationMonitors/$($m.id)"
        Write-Host " ✔ Deleted" -ForegroundColor Green
    } catch {
        Write-Host " ✖ Failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Banner "DELETING UTCM SNAPSHOT JOBS"

foreach ($s in $snapshotJobs) {
    Write-Host "Deleting snapshot job: $($s.displayName)" -ForegroundColor Yellow
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri "$base/configurationSnapshotJobs/$($s.id)"
        Write-Host " ✔ Deleted" -ForegroundColor Green
    } catch {
        Write-Host " ✖ Failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Cleanup complete." -ForegroundColor Green
Write-Host "UTCM monitors and snapshot jobs have been removed." -ForegroundColor Green
Write-Host "Tenant configuration remains unchanged." -ForegroundColor DarkGray

finally {
    Write-Host ""
    Read-Host "  Press Enter to close"
}










