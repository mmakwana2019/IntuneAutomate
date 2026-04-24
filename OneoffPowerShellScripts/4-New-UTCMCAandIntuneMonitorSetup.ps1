#Requires -Version 7.2
<#
.SYNOPSIS
    Create UTCM monitors for all CA and Intune resource types where a usable
    snapshot exists but no monitor is currently active.

DESCRIPTION
    For each resource type in the list, the script:
      1. Finds the most recent usable snapshot job
      2. Downloads the baseline and confirms resources[] is populated
      3. Checks whether an active monitor already exists for that resource type
      4. Creates a monitor only if one is missing and the baseline is valid

    Failures are clearly attributed — empty baseline vs API rejection vs
    monitor already present.

RESOURCE TYPES COVERED
    Entra: Conditional Access
    Intune: Compliance (Windows 10, Android, Android WP, Android Device Owner, iOS, macOS)
    Intune: Endpoint Security (Antivirus, App Control, Account Protection x2)
    Intune: App Protection (Android, iOS) + App Config
    Intune: Device Management (Assignment Filter, Device Category)

PERMISSIONS
    ConfigurationMonitoring.ReadWrite.All
    DeviceManagementConfiguration.Read.All

NOTES
    - GET calls to snapshot/monitor APIs consume no quota.
    - Monitor creation will be skipped with a clear reason if baseline is empty.
    - If a monitor already exists for a resource type it will not be duplicated.
    - Display names for monitors must be 8-32 chars, no hyphens or underscores
      (UTCM API constraint confirmed in testing, March 2026).
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$BaseV1   = 'https://graph.microsoft.com/v1.0/admin/configurationManagement'
$BaseBeta = 'https://graph.microsoft.com/beta/admin/configurationManagement'

$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# ---------------------------------------------------------------
# RESOURCE TYPE DEFINITIONS
# Maps UTCM resource type string -> friendly name + monitor display name
# NOTE: Monitor display names must be 8-32 chars, no hyphens or underscores
# ---------------------------------------------------------------
$ResourceTypes = [ordered]@{

    "microsoft.entra.conditionalaccesspolicy" = @{
        FriendlyName = "Entra: Conditional Access Policy"
        MonitorName  = "CA Policy Monitor"
        Description  = "UTCM monitor for Entra Conditional Access Policies"
    }

    "microsoft.intune.devicecompliancepolicywindows10" = @{
        FriendlyName = "Intune: Compliance - Windows 10"
        MonitorName  = "Intune Compliance Win10"
        Description  = "UTCM monitor for Intune Windows 10 compliance policies"
    }

    "microsoft.intune.devicecompliancepolicyandroid" = @{
        FriendlyName = "Intune: Compliance - Android"
        MonitorName  = "Intune Compliance Android"
        Description  = "UTCM monitor for Intune Android compliance policies"
    }

    "microsoft.intune.devicecompliancepolicyandroidworkprofile" = @{
        FriendlyName = "Intune: Compliance - Android Work Profile"
        MonitorName  = "Intune Compliance AndWP"
        Description  = "UTCM monitor for Intune Android personally-owned work profile compliance"
    }

    "microsoft.intune.devicecompliancepolicyandroiddeviceowner" = @{
        FriendlyName = "Intune: Compliance - Android Device Owner"
        MonitorName  = "Intune Compliance AndDO"
        Description  = "UTCM monitor for Intune Android fully managed compliance policies"
    }

    "microsoft.intune.devicecompliancepolicyios" = @{
        FriendlyName = "Intune: Compliance - iOS"
        MonitorName  = "Intune Compliance iOS"
        Description  = "UTCM monitor for Intune iOS compliance policies"
    }

    "microsoft.intune.devicecompliancepolicymacos" = @{
        FriendlyName = "Intune: Compliance - macOS"
        MonitorName  = "Intune Compliance macOS"
        Description  = "UTCM monitor for Intune macOS compliance policies"
    }

    "microsoft.intune.antiviruspolicywindows10settingcatalog" = @{
        FriendlyName = "Intune: Antivirus - Windows 10"
        MonitorName  = "Intune Antivirus Win10"
        Description  = "UTCM monitor for Intune Windows 10 antivirus endpoint security policies"
    }

    "microsoft.intune.applicationcontrolpolicywindows10" = @{
        FriendlyName = "Intune: Application Control - Windows 10"
        MonitorName  = "Intune AppControl Win10"
        Description  = "UTCM monitor for Intune Windows 10 application control policies"
    }

    "microsoft.intune.accountprotectionpolicy" = @{
        FriendlyName = "Intune: Account Protection Policy"
        MonitorName  = "Intune AcctProtection"
        Description  = "UTCM monitor for Intune account protection endpoint security policies"
    }

    "microsoft.intune.accountprotectionlocalusergroupmembershippolicy" = @{
        FriendlyName = "Intune: Account Protection - Local User Group"
        MonitorName  = "Intune AcctProt LUG"
        Description  = "UTCM monitor for Intune account protection local user group membership policies"
    }

    "microsoft.intune.appprotectionpolicyandroid" = @{
        FriendlyName = "Intune: App Protection - Android"
        MonitorName  = "Intune AppProt Android"
        Description  = "UTCM monitor for Intune Android app protection policies"
    }

    "microsoft.intune.appprotectionpolicyios" = @{
        FriendlyName = "Intune: App Protection - iOS"
        MonitorName  = "Intune AppProt iOS"
        Description  = "UTCM monitor for Intune iOS app protection policies"
    }

    "microsoft.intune.appconfigurationpolicy" = @{
        FriendlyName = "Intune: App Configuration Policy"
        MonitorName  = "Intune AppConfig"
        Description  = "UTCM monitor for Intune app configuration policies"
    }

    "microsoft.intune.deviceandappmanagementassignmentfilter" = @{
        FriendlyName = "Intune: Assignment Filter"
        MonitorName  = "Intune Assign Filter"
        Description  = "UTCM monitor for Intune assignment filters"
    }

    "microsoft.intune.devicecategory" = @{
        FriendlyName = "Intune: Device Category"
        MonitorName  = "Intune Device Category"
        Description  = "UTCM monitor for Intune device categories"
    }
}

# ---------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------
function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host (" " + ("─" * 64)) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host (" " + ("─" * 64)) -ForegroundColor Cyan
    Write-Host ""
}
function Write-Pass   { param([string]$Msg) Write-Host "     ✔  $Msg" -ForegroundColor Green  }
function Write-Fail   { param([string]$Msg) Write-Host "     ✘  $Msg" -ForegroundColor Red    }
function Write-Warn   { param([string]$Msg) Write-Host "     ⚠  $Msg" -ForegroundColor Yellow }
function Write-Skip   { param([string]$Msg) Write-Host "     ↩  $Msg" -ForegroundColor DarkGray }
function Write-Detail { param([string]$Msg) Write-Host "        $Msg" -ForegroundColor Gray   }
function Write-Info   { param([string]$Msg) Write-Host "     ℹ  $Msg" -ForegroundColor White  }

function Invoke-GraphPaged {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        if ($response.value) { $results.AddRange($response.value) }
        $nextUri = $response.'@odata.nextLink'
    } while ($nextUri)
    return @($results)
}

function Normalize-Baseline {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    try {
        $obj = $InputObject | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    } catch { return $null }
    foreach ($name in @('@odata.context','@odata.etag','@microsoft.graph.tips')) {
        try { $null = $obj.PSObject.Properties.Remove($name) } catch {}
    }
    foreach ($p in @($obj.PSObject.Properties.Name)) {
        if ($p -like '@odata.*') {
            try { $null = $obj.PSObject.Properties.Remove($p) } catch {}
        }
    }
    return $obj
}

# ---------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   UTCM Monitor Setup — CA + Intune | move2modern.co.uk  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  For each resource type this script will:" -ForegroundColor DarkGray
    Write-Host "    1. Find the most recent usable snapshot" -ForegroundColor DarkGray
    Write-Host "    2. Validate the baseline resources[] is not empty" -ForegroundColor DarkGray
    Write-Host "    3. Check whether a monitor already exists" -ForegroundColor DarkGray
    Write-Host "    4. Create a monitor only if needed and baseline is valid" -ForegroundColor DarkGray
    Write-Host ""

    # ── CONNECT ────────────────────────────────────────────────
    Write-Banner "AUTHENTICATION"

    $tenant = Read-Host "  Enter tenant ID or domain"
    if (-not $tenant) { throw "Tenant is required." }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -TenantId $tenant -Scopes @(
        'ConfigurationMonitoring.ReadWrite.All',
        'DeviceManagementConfiguration.Read.All'
    ) -NoWelcome

    $orgName = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization").value[0].displayName
    Write-Pass "Connected: $orgName ($tenant)"

    # ── LOAD ALL SNAPSHOT JOBS ──────────────────────────────────
    Write-Banner "LOADING SNAPSHOT JOBS"

    $snapshotUri  = "$BaseBeta/configurationSnapshotJobs?`$select=id,displayName,status,resources,resourceLocation,createdDateTime"
    $allSnapshots = @(Invoke-GraphPaged -Uri $snapshotUri)
    Write-Detail "Snapshot jobs visible: $($allSnapshots.Count)"

    # Build lookup: resourceType (lowercase) -> most recent usable job
    $snapshotByRT = @{}
    foreach ($j in ($allSnapshots | Sort-Object createdDateTime -Descending)) {
        if ($j.status -notin @('succeeded','partiallySuccessful')) { continue }
        if (-not $j.resourceLocation) { continue }
        if (-not $j.resources) { continue }
        foreach ($rt in @($j.resources)) {
            $key = $rt.ToLower()
            if (-not $snapshotByRT.ContainsKey($key)) {
                $snapshotByRT[$key] = $j
            }
        }
    }

    Write-Detail "Usable snapshots indexed for $($snapshotByRT.Count) resource type(s)"

    # ── LOAD ALL EXISTING MONITORS ──────────────────────────────
    Write-Banner "LOADING EXISTING MONITORS"

    $monitorUri    = "$BaseV1/configurationMonitors?`$select=id,displayName,status,baseline"
    $allMonitors   = @(Invoke-GraphPaged -Uri $monitorUri)
    Write-Detail "Monitors currently active: $($allMonitors.Count)"

    # Build lookup: resourceType (lowercase) -> monitor
    # Monitors embed their baseline JSON — we extract resourceType from it
    $monitorByRT = @{}
    foreach ($m in $allMonitors) {
        if (-not $m.baseline) { continue }
        try {
            $bl = $m.baseline
            # baseline.resources is an array of objects with resourceType property
            if ($bl.resources) {
                foreach ($r in @($bl.resources)) {
                    if ($r.resourceType) {
                        $key = $r.resourceType.ToLower()
                        if (-not $monitorByRT.ContainsKey($key)) {
                            $monitorByRT[$key] = $m
                        }
                    }
                }
            }
        } catch { }
    }

    Write-Detail "Monitors indexed for $($monitorByRT.Count) resource type(s)"

    # ── PROCESS EACH RESOURCE TYPE ─────────────────────────────
    Write-Banner "PROCESSING RESOURCE TYPES"

    # Result tracking
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $index = 0
    foreach ($kvp in $ResourceTypes.GetEnumerator()) {

        $index++
        $rt         = $kvp.Key
        $def        = $kvp.Value
        $rtKey      = $rt.ToLower()

        Write-Host "  [$index/$($ResourceTypes.Count)] $($def.FriendlyName)" -ForegroundColor White
        Write-Host "         $rt" -ForegroundColor DarkGray

        $result = [PSCustomObject]@{
            Index          = $index
            ResourceType   = $rt
            FriendlyName   = $def.FriendlyName
            SnapshotFound  = $false
            SnapshotId     = $null
            ResourceCount  = 0
            MonitorExists  = $false
            MonitorId      = $null
            Outcome        = 'unknown'
            FailureReason  = $null
        }

        # ── STEP 1: Find snapshot ───────────────────────────────
        if (-not $snapshotByRT.ContainsKey($rtKey)) {
            Write-Warn "No usable snapshot found — run the probe script first"
            $result.Outcome       = 'noSnapshot'
            $result.FailureReason = 'No succeeded/partiallySuccessful snapshot job found for this resource type'
            $results.Add($result)
            Write-Host ""
            continue
        }

        $snap = $snapshotByRT[$rtKey]
        $result.SnapshotFound = $true
        $result.SnapshotId    = $snap.id
        Write-Detail "Snapshot : $($snap.displayName) | $($snap.status) | $($snap.createdDateTime)"

        # ── STEP 2: Download and validate baseline ──────────────
        $raw      = $null
        $baseline = $null

        try {
            $raw      = Invoke-MgGraphRequest -Method GET -Uri $snap.resourceLocation
            $baseline = Normalize-Baseline $raw
        } catch {
            Write-Fail "Failed to download baseline: $($_.Exception.Message)"
            $result.Outcome       = 'baselineDownloadFailed'
            $result.FailureReason = $_.Exception.Message
            $results.Add($result)
            Write-Host ""
            continue
        }

        # Check resources[] count
        $resourceCount = 0
        if ($baseline -and $baseline.resources) {
            $resourceCount = @($baseline.resources).Count
        }
        $result.ResourceCount = $resourceCount

        if ($resourceCount -eq 0) {
            # Empty baseline — the key diagnostic we're tracking
            Write-Warn "Snapshot succeeded but baseline resources[] is EMPTY"
            Write-Detail "This means no policies of this type exist in the tenant yet"
            Write-Detail "Create a policy in Intune/Entra, delete this snapshot, create a fresh one"
            $result.Outcome       = 'emptyBaseline'
            $result.FailureReason = 'Snapshot succeeded but resources[] is empty — no policies exist in tenant'
            $results.Add($result)
            Write-Host ""
            continue
        }

        Write-Pass "Baseline valid — $resourceCount resource(s) captured"

        # ── STEP 3: Check for existing monitor ──────────────────
        if ($monitorByRT.ContainsKey($rtKey)) {
            $existing = $monitorByRT[$rtKey]
            $result.MonitorExists = $true
            $result.MonitorId     = $existing.id
            $result.Outcome       = 'monitorExists'
            Write-Skip "Monitor already exists — skipping creation"
            Write-Detail "Monitor ID : $($existing.id)"
            Write-Detail "Name       : $($existing.displayName)"
            $results.Add($result)
            Write-Host ""
            continue
        }

        Write-Detail "No existing monitor found — will create"

        # ── STEP 4: Save baseline for reference ─────────────────
        $safeRTName = $rt -replace '[^a-zA-Z0-9]', '_'
        $bFile = Join-Path $outDir ("baseline_{0}_{1}.json" -f $safeRTName, (Get-Date -Format 'yyyyMMddHHmmss'))
        try {
            $baseline | ConvertTo-Json -Depth 80 | Set-Content -Path $bFile -Encoding utf8
            Write-Detail "Baseline saved: $bFile"
        } catch {
            Write-Detail "Could not save baseline to disk (non-fatal): $($_.Exception.Message)"
        }

        # ── STEP 5: Create monitor ───────────────────────────────
        $monBody = @{
            displayName = $def.MonitorName
            description = $def.Description
            baseline    = $baseline
        } | ConvertTo-Json -Depth 80

        try {
            $monitor = Invoke-MgGraphRequest `
                -Method POST `
                -Uri "$BaseV1/configurationMonitors" `
                -Body $monBody `
                -ContentType 'application/json'

            $result.MonitorId = $monitor.id
            $result.Outcome   = 'created'

            Write-Pass "Monitor created"
            Write-Detail "Monitor ID : $($monitor.id)"
            Write-Detail "Name       : $($monitor.displayName)"
            Write-Detail "Frequency  : every $($monitor.monitorRunFrequencyInHours)h"

        } catch {
            $errMsg = $_.Exception.Message
            # Try to extract body for richer error
            try {
                $errBody = ($_.ErrorDetails.Message | ConvertFrom-Json)
                $errMsg  = $errBody.error.message ?? $errMsg
            } catch { }

            Write-Fail "Monitor creation failed: $errMsg"
            $result.Outcome       = 'createFailed'
            $result.FailureReason = $errMsg
        }

        $results.Add($result)
        Write-Host ""
    }

    # ── SUMMARY ────────────────────────────────────────────────
    Write-Banner "SUMMARY"

    $created      = @($results | Where-Object { $_.Outcome -eq 'created' })
    $existed      = @($results | Where-Object { $_.Outcome -eq 'monitorExists' })
    $emptyBase    = @($results | Where-Object { $_.Outcome -eq 'emptyBaseline' })
    $noSnap       = @($results | Where-Object { $_.Outcome -eq 'noSnapshot' })
    $createFailed = @($results | Where-Object { $_.Outcome -eq 'createFailed' })
    $dlFailed     = @($results | Where-Object { $_.Outcome -eq 'baselineDownloadFailed' })

    Write-Host "  Total resource types    : $($ResourceTypes.Count)" -ForegroundColor White
    Write-Host "  ✔  Monitors created     : $($created.Count)"       -ForegroundColor Green
    Write-Host "  ↩  Already existed      : $($existed.Count)"       -ForegroundColor Gray
    Write-Host "  ⚠  Empty baseline       : $($emptyBase.Count)"     -ForegroundColor Yellow
    Write-Host "  ⚠  No snapshot found    : $($noSnap.Count)"        -ForegroundColor Yellow
    Write-Host "  ✘  Creation failed      : $($createFailed.Count)"  -ForegroundColor Red
    Write-Host "  ✘  Baseline dl failed   : $($dlFailed.Count)"      -ForegroundColor Red
    Write-Host ""

    if ($emptyBase.Count -gt 0) {
        Write-Host "  Empty baseline — no policies exist in tenant for:" -ForegroundColor Yellow
        foreach ($r in $emptyBase) {
            Write-Host "     • $($r.FriendlyName)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  ℹ  These are not failures. The snapshot accepted the resource type but" -ForegroundColor DarkGray
        Write-Host "     found nothing to capture. Create policies in Intune, delete the snapshot," -ForegroundColor DarkGray
        Write-Host "     run the probe script again, then re-run this script." -ForegroundColor DarkGray
        Write-Host ""
    }

    if ($noSnap.Count -gt 0) {
        Write-Host "  No snapshot found for:" -ForegroundColor Yellow
        foreach ($r in $noSnap) {
            Write-Host "     • $($r.FriendlyName)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  ℹ  Run New-UTCMSnapshotProbe-QuotaAware.ps1 to create snapshots first." -ForegroundColor DarkGray
        Write-Host ""
    }

    if ($createFailed.Count -gt 0) {
        Write-Host "  Monitor creation failures:" -ForegroundColor Red
        foreach ($r in $createFailed) {
            Write-Host "     • $($r.FriendlyName)" -ForegroundColor DarkGray
            Write-Host "       $($r.FailureReason)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # Export CSV
    $csvPath = Join-Path $PSScriptRoot ("UTCMMonitorSetup_{0}.csv" -f (Get-Date -Format 'yyyyMMdd HHmm'))
    try {
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "  Results exported: $csvPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Could not export CSV: $($_.Exception.Message)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                    Setup complete                        ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "  ── Script terminated with an error ──" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $($_ | Out-String)" -ForegroundColor DarkGray
} finally {
    Write-Host ""
    Read-Host "  Press Enter to close"
}
