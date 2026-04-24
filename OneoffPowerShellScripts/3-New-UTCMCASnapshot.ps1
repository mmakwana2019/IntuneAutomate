#Requires -Version 7.2

<#
.SYNOPSIS
    Check for an existing UTCM CA snapshot job and create one if absent.
    move2modern.co.uk

.DESCRIPTION
    Connects to Microsoft Graph interactively, checks whether a recent succeeded
    snapshot job exists for the CA policy resource type, and creates a new one
    if not found. Polls until the snapshot job completes and reports the result.

    CORRECT ENDPOINTS (confirmed April 2026 public preview):
        List jobs : GET  /beta/admin/configurationManagement/configurationSnapshotJobs
        Create    : POST /beta/admin/configurationManagement/configurationSnapshots/createSnapshot
        Poll job  : GET  /beta/admin/configurationManagement/configurationSnapshotJobs/{id}

    NOTE: configurationSnapshots (GET list) does not exist in the current preview.
    configurationSnapshotJobs is the correct collection to query.

    SNAPSHOT DISPLAY NAME CONSTRAINT (undocumented UTCM requirement):
        8-32 characters, alphanumeric and spaces only.

    PERMISSIONS REQUIRED (delegated, for the signed-in user):
        ConfigurationMonitoring.ReadWrite.All
        Policy.Read.All

    IMPORTANT — WAM TOKEN CACHING:
        On Windows, WAM (Web Account Manager) caches tokens at the OS level.
        Disconnect-MgGraph alone does not force a new token. This script uses
        -ContextScope Process on Connect-MgGraph to ensure a fresh process-scoped
        token is always requested with the correct scopes.

    EMPTY BASELINE NOTE:
        If the snapshot job completes with 0 CA policies captured, this indicates
        the UTCM service principal (app ID: 03b07b79-c5bc-4b5e-9bfa-13acf4a99998)
        does not have Policy.Read.All and Policy.Read.ConditionalAccess permissions
        in your tenant. The snapshot runs as the UTCM SP, not as your user account.
        Run the UTCM setup script to provision these permissions if not already done.
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

# Display name for new snapshot if one needs to be created
# Must be 8-32 chars, alphanumeric and spaces only
$SnapshotDisplayName = "CA Baseline $(Get-Date -Format 'yyyyMMdd')"

# CA resource type to check/create
$CaResourceType = 'microsoft.entra.conditionalaccesspolicy'

# How many days back to look for a recent succeeded job before creating a new one
$RecentDays = 7

# Poll settings for new job creation
$PollIntervalSeconds = 10
$PollTimeoutSeconds  = 300

# UTCM base URI
$UtmcBase = 'https://graph.microsoft.com/beta/admin/configurationManagement'

# Required scopes
$RequiredScopes = @(
    'ConfigurationMonitoring.ReadWrite.All'
    'Policy.Read.All'
)

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Ok   ($Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green  }
function Write-Warn ($Msg) { Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }
function Write-Err  ($Msg) { Write-Host "  ❌ $Msg" -ForegroundColor Red    }
function Write-Info ($Msg) { Write-Host "     $Msg"                          }
function Write-Step ($Msg) { Write-Host "`n  ── $Msg" -ForegroundColor Cyan  }

function Invoke-GraphPaged {
    param([string]$Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    $next  = $Uri
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($resp.value) { foreach ($v in $resp.value) { $items.Add($v) } }
        $next = $resp.'@odata.nextLink'
    } while ($next)
    return $items
}

# ─────────────────────────────────────────────────────────────────────────────
# VALIDATE DISPLAY NAME
# ─────────────────────────────────────────────────────────────────────────────

if ($SnapshotDisplayName -notmatch '^[a-zA-Z0-9 ]{8,32}$') {
    $SnapshotDisplayName = "CA Baseline $(Get-Date -Format 'yyyyMMdd')"
    Write-Warn "SnapshotDisplayName adjusted to meet 8-32 alphanumeric constraint: $SnapshotDisplayName"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONNECT
# ─────────────────────────────────────────────────────────────────────────────

Write-Step 'Connecting to Microsoft Graph'

# Always disconnect first to clear any existing session
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

try {
    # -ContextScope Process forces a fresh process-scoped token.
    # This bypasses WAM's OS-level token cache which would otherwise reuse
    # a cached token with different scopes from a previous session.
    Connect-MgGraph -Scopes $RequiredScopes -ContextScope Process -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext
    Write-Ok "Connected as : $($ctx.Account)"
    Write-Info "Tenant       : $($ctx.TenantId)"

    # Verify the required scopes were actually granted
    $grantedScopes  = @($ctx.Scopes)
    $missingScopes  = $RequiredScopes | Where-Object { $grantedScopes -notcontains $_ }
    if ($missingScopes.Count -gt 0) {
        Write-Warn "The following scopes were not granted — results may be incomplete:"
        foreach ($s in $missingScopes) { Write-Info "  Missing: $s" }
    } else {
        Write-Ok "All required scopes granted"
    }
} catch {
    Write-Err "Graph connection failed: $($_.Exception.Message)"
    throw
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — CHECK FOR EXISTING CA SNAPSHOT JOB
# ─────────────────────────────────────────────────────────────────────────────

Write-Step 'Step 1 — Checking for existing CA snapshot jobs'

try {
    $jobsUri      = "$UtmcBase/configurationSnapshotJobs?`$select=id,displayName,status,resources,resourceLocation,createdDateTime,completedDateTime"
    $allJobs      = @(Invoke-GraphPaged -Uri $jobsUri)
    $recentCutoff = (Get-Date).AddDays(-$RecentDays)

    Write-Info "Total snapshot jobs visible: $($allJobs.Count)"
} catch {
    Write-Err "Failed to retrieve snapshot jobs: $($_.Exception.Message)"
    Disconnect-MgGraph
    throw
}

# Filter to CA resource type jobs that succeeded within the recent window
$caJobs = @($allJobs | Where-Object {
    $_.status -in @('succeeded', 'partiallySuccessful') -and
    $_.resources -and ($_.resources -contains $CaResourceType) -and
    (try { [datetime]$_.createdDateTime -ge $recentCutoff } catch { $false })
} | Sort-Object createdDateTime -Descending)

if ($caJobs.Count -gt 0) {
    $latest = $caJobs[0]
    Write-Ok "Recent CA snapshot job found — no action needed."
    Write-Host ''
    Write-Info "  Job ID       : $($latest.id)"
    Write-Info "  Display Name : $($latest.displayName)"
    Write-Info "  Status       : $($latest.status)"
    Write-Info "  Created      : $($latest.createdDateTime)"
    Write-Info "  Completed    : $($latest.completedDateTime)"
    if ($latest.resourceLocation) {
        Write-Info "  Snapshot URL : $($latest.resourceLocation)"
    }
    Write-Host ''
    Write-Warn "Snapshot jobs are retained for $RecentDays days. A new one will be created on the next run after expiry."

    if ($caJobs.Count -gt 1) {
        Write-Info "  ($($caJobs.Count - 1) older CA snapshot job(s) also found — showing most recent only)"
    }

    Disconnect-MgGraph
    return
}

Write-Info "No recent CA snapshot job found — proceeding to create one."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — SUBMIT SNAPSHOT JOB
# ─────────────────────────────────────────────────────────────────────────────

Write-Step 'Step 2 — Submitting snapshot creation job'

Write-Info "Display name  : $SnapshotDisplayName"
Write-Info "Resource type : $CaResourceType"

$snapshotBody = @{
    displayName = $SnapshotDisplayName
    resources   = @( $CaResourceType )
} | ConvertTo-Json

try {
    $snapshotJob = Invoke-MgGraphRequest `
        -Uri         "$UtmcBase/configurationSnapshots/createSnapshot" `
        -Method      POST `
        -Body        $snapshotBody `
        -ContentType 'application/json' `
        -ErrorAction Stop

    Write-Ok "Snapshot job submitted"
    Write-Info "Job ID : $($snapshotJob.id)"
    Write-Info "Status : $($snapshotJob.status)"
} catch {
    # Handle 409 displayName conflict — retry once with timestamp suffix
    if ($_.Exception.Message -match '409' -or $_.Exception.Message -match 'Conflict') {
        Write-Warn "displayName conflict (409) — retrying with unique name"
        $SnapshotDisplayName = "CA Base $(Get-Date -Format 'MMddHHmm')"
        $snapshotBody = @{
            displayName = $SnapshotDisplayName
            resources   = @( $CaResourceType )
        } | ConvertTo-Json

        try {
            $snapshotJob = Invoke-MgGraphRequest `
                -Uri         "$UtmcBase/configurationSnapshots/createSnapshot" `
                -Method      POST `
                -Body        $snapshotBody `
                -ContentType 'application/json' `
                -ErrorAction Stop

            Write-Ok "Snapshot job submitted (retry)"
            Write-Info "Job ID       : $($snapshotJob.id)"
            Write-Info "Display name : $SnapshotDisplayName"
        } catch {
            Write-Err "Snapshot job submission failed after retry: $($_.Exception.Message)"
            Disconnect-MgGraph
            throw
        }
    } else {
        Write-Err "Snapshot job submission failed: $($_.Exception.Message)"
        Disconnect-MgGraph
        throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — POLL FOR COMPLETION
# ─────────────────────────────────────────────────────────────────────────────

Write-Step 'Step 3 — Waiting for snapshot job to complete'

$elapsed   = 0
$jobStatus = $null
$jobId     = $snapshotJob.id

do {
    Start-Sleep -Seconds $PollIntervalSeconds
    $elapsed += $PollIntervalSeconds
    Write-Info "Polling... ($elapsed s elapsed)"

    try {
        $jobStatus = Invoke-MgGraphRequest `
            -Uri    "$UtmcBase/configurationSnapshotJobs/$jobId" `
            -Method GET `
            -ErrorAction Stop
    } catch {
        Write-Err "Poll failed: $($_.Exception.Message)"
        Disconnect-MgGraph
        throw
    }

    Write-Info "Job status: $($jobStatus.status)"

    if ($elapsed -ge $PollTimeoutSeconds -and
        $jobStatus.status -notin @('succeeded','partiallySuccessful','failed')) {
        Write-Err "Timed out after $PollTimeoutSeconds seconds. Job ID: $jobId"
        Write-Info "The job may still be running. Re-run this script to check."
        Disconnect-MgGraph
        throw "Snapshot job timed out after $PollTimeoutSeconds seconds."
    }

} while ($jobStatus.status -notin @('succeeded', 'partiallySuccessful', 'failed'))

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — REPORT RESULT
# ─────────────────────────────────────────────────────────────────────────────

Write-Step 'Step 4 — Result'

switch ($jobStatus.status) {
    'succeeded' {
        Write-Ok 'Snapshot job completed successfully.'
    }
    'partiallySuccessful' {
        Write-Warn 'Snapshot job partially succeeded.'
        Write-Info 'This is normal when requesting a single resource type.'
        Write-Info 'CA policies should still be captured — check the resource count below.'
    }
    'failed' {
        Write-Err 'Snapshot job failed.'
        Write-Info ($jobStatus | ConvertTo-Json -Depth 5)
        Disconnect-MgGraph
        throw 'Snapshot job reported status: failed'
    }
}

if ($jobStatus.resourceLocation) {
    try {
        $snapshot = Invoke-MgGraphRequest `
            -Uri    $jobStatus.resourceLocation `
            -Method GET `
            -ErrorAction Stop

        Write-Host ''
        Write-Info "  Snapshot ID  : $($snapshot.id)"
        Write-Info "  Display Name : $($snapshot.displayName)"
        Write-Info "  Created      : $($snapshot.createdDateTime)"
        Write-Info "  Expires      : $($snapshot.expirationDateTime)"

        # The snapshot resource count is in the 'resources' property (not 'value')
        # This is the array of captured policy objects used as the monitor baseline
        $resourceCount = if ($snapshot.resources) { @($snapshot.resources).Count } else { 0 }
        Write-Info "  CA policies captured : $resourceCount"

        if ($resourceCount -eq 0) {
            Write-Host ''
            Write-Warn 'Snapshot baseline contains 0 CA policy resources.'
            Write-Warn 'This snapshot cannot be used for a monitor baseline.'
            Write-Host ''
            Write-Info 'Most likely cause: the UTCM service principal does not have the'
            Write-Info 'required Graph permissions to read CA policies in your tenant.'
            Write-Info 'The snapshot runs as the UTCM SP (not your user account).'
            Write-Host ''
            Write-Info 'To fix: ensure the UTCM SP has these app role assignments:'
            Write-Info '  App ID : 03b07b79-c5bc-4b5e-9bfa-13acf4a99998'
            Write-Info '  Roles  : Policy.Read.All, Policy.Read.ConditionalAccess'
            Write-Info ''
            Write-Info 'Run the UTCM setup script to provision these if not already done,'
            Write-Info 'then re-run this script to create a new snapshot.'
        } else {
            Write-Host ''
            Write-Ok "$resourceCount CA policy/policies captured in baseline."
            Write-Warn 'Snapshot expires in 7 days. Use this snapshot when creating or refreshing your UTCM monitor.'
            Write-Info "  Job ID: $jobId"
        }
    } catch {
        Write-Warn "Could not retrieve snapshot detail (non-fatal): $($_.Exception.Message)"
        Write-Info "Job ID $jobId completed — use this ID for monitor creation."
    }
}

Disconnect-MgGraph
Write-Host ''
Write-Ok 'Done.'
