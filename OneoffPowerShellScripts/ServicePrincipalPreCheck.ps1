<#
.SYNOPSIS
    Pre-flight check for existing UTCM-related Service Principals and App Registrations.

.DESCRIPTION
    - Prompts for interactive Microsoft Graph authentication
    - Runs read-only discovery queries
    - Identifies any existing UTCM-related Service Principals or App Registrations
    - Designed for PowerShell 7 (pwsh)
    - Safe to run before UTCM creation scripts

.REQUIRES
    - PowerShell 7
    - Microsoft.Graph module
    - Directory.Read.All / Application.Read.All (delegated)
#>

Write-Host ""
Write-Host "=== UTCM Pre-flight Check ===" -ForegroundColor Cyan
Write-Host ""

# ----------------------------
# 1. Connect to Microsoft Graph
# ----------------------------
$requiredScopes = @(
    "Application.Read.All",
    "Directory.Read.All"
)

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow

try {
    Connect-MgGraph -Scopes $requiredScopes -ContextScope Process -ErrorAction Stop
    Write-Host "✅ Connected to Microsoft Graph." -ForegroundColor Green
}
catch {
    Write-Error "❌ Failed to connect to Microsoft Graph. $_"
    return
}

# ----------------------------
# 2. Define UTCM search terms
# ----------------------------
$searchTerms = @(
    "UTCM",
    "Unified Tenant Configuration",
    "Tenant Configuration",
    "Intune Automate"
)

# ----------------------------
# 3. Check Service Principals
# ----------------------------
Write-Host ""
Write-Host "Checking Service Principals..." -ForegroundColor Cyan

$servicePrincipals = Get-MgServicePrincipal -All

$utcmServicePrincipals = $servicePrincipals | Where-Object {
    $sp = $_
    $searchTerms | Where-Object {
        ($sp.DisplayName -and $sp.DisplayName -match $_) -or
        ($sp.Notes -and $sp.Notes -match $_)
    }
}

if (-not $utcmServicePrincipals) {
    Write-Host "✅ No UTCM-related Service Principals found." -ForegroundColor Green
}
else {
    Write-Host "⚠️ UTCM-related Service Principals detected:" -ForegroundColor Yellow
    $utcmServicePrincipals |
        Select-Object DisplayName, AppId, Id, AccountEnabled |
        Sort-Object DisplayName |
        Format-Table -AutoSize
}

# ----------------------------
# 4. Check App Registrations
# ----------------------------
Write-Host ""
Write-Host "Checking App Registrations..." -ForegroundColor Cyan

$appRegistrations = Get-MgApplication -All

$utcmAppRegistrations = $appRegistrations | Where-Object {
    $app = $_
    $searchTerms | Where-Object {
        ($app.DisplayName -and $app.DisplayName -match $_)
    }
}

if (-not $utcmAppRegistrations) {
    Write-Host "✅ No UTCM-related App Registrations found." -ForegroundColor Green
}
else {
    Write-Host "⚠️ UTCM-related App Registrations detected:" -ForegroundColor Yellow
    $utcmAppRegistrations |
        Select-Object DisplayName, AppId, Id |
        Sort-Object DisplayName |
        Format-Table -AutoSize
}

# ----------------------------
# 5. Final status
# ----------------------------
Write-Host ""
if (-not $utcmServicePrincipals -and -not $utcmAppRegistrations) {
    Write-Host "✅ Pre-flight check passed. Safe to proceed with UTCM creation." -ForegroundColor Green
}
else {
    Write-Host "❌ Pre-flight check detected existing UTCM objects." -ForegroundColor Red
    Write-Host "   Review before running any UTCM creation scripts." -ForegroundColor Red
}

Write-Host ""
Write-Host "=== UTCM Pre-flight Check Complete ===" -ForegroundColor Cyan
Write-Host ""

   
   