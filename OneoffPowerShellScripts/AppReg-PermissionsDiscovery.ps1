# ============================================================
# App Registration Graph Permission DISCOVERY / AUDIT Script
# VS Code safe: tries Interactive auth first, then falls back to Device Code
# Read-only – does NOT modify anything
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------
# CONFIGURATION
# ---------------------------
$AppName = "IntuneAutomate"        # App Registration / Enterprise App display name
$CsvPath = ".\GraphPermissionAudit.csv"

# Permissions currently hard-coded in your setup script
$ScriptPermissionGuids = @(
    "1138cb37-bd11-4084-a2b7-9f71582aeddb"
    "884b599e-4d48-43a5-ba94-15c414d00588"
    "78145de6-330d-4800-a6ce-494ff2d33d07"
    "9241abd9-d0e6-425a-bd4f-47ba86e767a4"
    "5b07b0dd-2377-4e44-a38d-703f09a0dc3c"
    "243333ab-4d21-40cb-a475-36241daa0842"
    "5ac13192-7ace-4fcf-b828-1a26f28068ee"
    "19dbc75e-c2e2-444c-a770-ec69d8559fc7"
    "75359482-378d-4052-8f01-80520e7db3cd"
    "62a82d76-70ea-41e2-9197-370581804d09"
    "e2a3a72e-5f79-4c64-b1b1-878b674786c9"
    "b633e1c5-b582-4048-a93e-9f11b44c7e96"
    "6931bccd-447a-43d1-b442-00a195474933"
    "498476ce-e0fe-48b0-b801-37ba7e2685c6"
    "246dd0d5-5bd0-4def-940b-0421030a5b68"
    "01c0a623-fc9b-48e9-b794-0756f8e8f067"
    "a82116e5-55eb-4c41-a434-62fe8a61c773"
    "50483e42-d915-4231-9639-7fdb7fd190e5"
    "741f803b-c850-494e-b5df-cde7c675a1ca"
)

# Delegated scopes needed to read the app + app role assignments
$Scopes = @(
    "Application.Read.All",
    "AppRoleAssignment.Read.All"
)

# ---------------------------
# ENV / MODULE SANITY OUTPUT
# ---------------------------
Write-Host "PowerShell: $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
$mgAuth = Get-Module Microsoft.Graph.Authentication -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($mgAuth) {
    Write-Host "Microsoft.Graph.Authentication: $($mgAuth.Version)" -ForegroundColor DarkGray
}

# ---------------------------
# CONNECT TO MICROSOFT GRAPH
# ---------------------------
Write-Host "🔐 Connecting to Microsoft Graph..." -ForegroundColor Cyan
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

# NOTE:
# InteractiveBrowserCredential can fail in embedded terminals (VS Code) in some environments.
# Workarounds include using Device Code auth (still Authenticator-based) or non-embedded consoles. [2](https://o365reports.com/resolve-interactive-browser-authentication-failed-window-handle-error-in-ms-graph-powershell/)[1](https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/3489)

$connected = $false

try {
    # Attempt interactive (Authenticator push / browser)
    Connect-MgGraph `
        -TenantId "organizations" `
        -Scopes $Scopes `
        -ContextScope Process `
        -NoWelcome

    $ctx = Get-MgContext
    if ($ctx -and $ctx.TenantId) {
        $connected = $true
        Write-Host "✅ Connected (Interactive) to tenant $($ctx.TenantId)" -ForegroundColor Green
    }
}
catch {
    Write-Host "⚠ Interactive auth failed in this host (common in VS Code terminals). Falling back to Device Code..." -ForegroundColor Yellow
    Write-Host "   $($_.Exception.Message)" -ForegroundColor DarkYellow
}

if (-not $connected) {
    # Fallback: Device code flow (still uses Authenticator approval)
    # This is the most reliable workaround when InteractiveBrowserCredential fails. [2](https://o365reports.com/resolve-interactive-browser-authentication-failed-window-handle-error-in-ms-graph-powershell/)[1](https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/3489)
    Connect-MgGraph `
        -TenantId "organizations" `
        -Scopes $Scopes `
        -UseDeviceCode `
        -ContextScope Process `
        -NoWelcome

    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.TenantId) {
        throw "Failed to authenticate to Microsoft Graph (both interactive and device code)."
    }
    Write-Host "✅ Connected (Device Code) to tenant $($ctx.TenantId)" -ForegroundColor Green
}

# ---------------------------
# RESOLVE SERVICE PRINCIPALS
# ---------------------------
Write-Host "🔎 Resolving service principals..." -ForegroundColor Cyan

$GraphSP = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
if (-not $GraphSP) {
    throw "Microsoft Graph service principal not found."
}

$TargetSP = Get-MgServicePrincipal -Filter "displayName eq '$AppName'"
if (-not $TargetSP) {
    throw "Service principal '$AppName' not found. Check the display name exactly."
}

# Only Graph application permissions (app roles allowed for Application)
$GraphAppRoles = $GraphSP.AppRoles | Where-Object { $_.AllowedMemberTypes -contains "Application" }

# ---------------------------
# GET CURRENT APP ROLE ASSIGNMENTS (Graph)
# ---------------------------
Write-Host "📥 Reading assigned Graph app permissions..." -ForegroundColor Cyan

$Assignments = Get-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $TargetSP.Id `
    -All

$AssignedRoleIds = $Assignments.AppRoleId

# ---------------------------
# BUILD AUDIT REPORT
# ---------------------------
$AuditReport = @()

# Assigned to app (and whether missing from script)
foreach ($Role in $GraphAppRoles | Where-Object { $AssignedRoleIds -contains $_.Id }) {
    $AuditReport += [pscustomobject]@{
        PermissionName = $Role.Value
        PermissionId   = $Role.Id
        Status         = if ($ScriptPermissionGuids -contains $Role.Id) { "Assigned" } else { "MissingFromScript" }
        Source         = "ExistingApp"
    }
}

# In script but not assigned to app
foreach ($Guid in $ScriptPermissionGuids | Where-Object { $_ -notin $AssignedRoleIds }) {
    $Role = $GraphAppRoles | Where-Object { $_.Id -eq $Guid }
    $AuditReport += [pscustomobject]@{
        PermissionName = if ($Role) { $Role.Value } else { "UnknownPermissionId"
        }
        PermissionId   = $Guid
        Status         = "InScriptOnly"
        Source         = "SetupScript"
    }
}

# ---------------------------
# EXPORT CSV
# ---------------------------
$AuditReport |
    Sort-Object Status, PermissionName |
    Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "✅ Permission discovery complete" -ForegroundColor Green
Write-Host "📄 CSV exported to: $CsvPath" -ForegroundColor Cyan
Write-Host "➡ Filter CSV where Status = MissingFromScript to get GUIDs to add to your setup script." -ForegroundColor DarkGray
 
