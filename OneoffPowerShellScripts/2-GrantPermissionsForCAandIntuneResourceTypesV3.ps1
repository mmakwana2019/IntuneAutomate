#Requires -Version 7.0
<#
.SYNOPSIS
Grant required Microsoft Graph application permissions to:
  1. The UTCM service principal (snapshot/monitor/drift operations)
  2. The UTCM-Automation Managed Identity (SharePoint list read/write + UTCM API access for runbook)

.DESCRIPTION
Safe to run multiple times. Only missing permissions are assigned.

Automation MI permission set confirmed by comparing a working move2modern tenant:
  - Sites.ReadWrite.All                  : SharePoint list read/write (UTCM_Drifts, UTCM_Monitors)
  - Policy.ReadWrite.ConditionalAccess   : Required for UTCM CA monitor API access
  - ConfigurationMonitoring.Read.All     : Read UTCM monitors and drift records
  - ConfigurationMonitoring.ReadWrite.All: Create/update UTCM monitors and baselines
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────
$UTCMAppId            = '03b07b79-c5bc-4b5e-9bfa-13acf4a99998'   # Unified Tenant Configuration Management
$GraphAppId           = '00000003-0000-0000-c000-000000000000'   # Microsoft Graph
$AutomationMIObjectId = '00967f3b-978d-47b8-8b84-ef4986448f69'   # UTCM-Automation Managed Identity

# Permissions for the UTCM SP (snapshot/monitor/drift API calls)
$UTCMGraphAppRoles = @(
    'Policy.Read.All',
    'Policy.Read.ConditionalAccess',
    'DeviceManagementConfiguration.Read.All',
    'DeviceManagementApps.Read.All',
    'DeviceManagementRBAC.Read.All',
    'Group.Read.All'
)

# Permissions for the Automation MI (runbook SharePoint + UTCM API access)
# Confirmed against working move2modern tenant — all are Microsoft Graph application permissions.
# ConfigurationMonitoring.* are Graph permissions, NOT UTCM SP roles despite the name.
$AutomationMIGraphAppRoles = @(
    'Sites.ReadWrite.All',
    'Policy.ReadWrite.ConditionalAccess',
    'ConfigurationMonitoring.Read.All',
    'ConfigurationMonitoring.ReadWrite.All'
)

# ─────────────────────────────────────────────────────────────
# MODULES + AUTH
# ─────────────────────────────────────────────────────────────
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications

Connect-MgGraph -Scopes @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All'
) -NoWelcome

# ─────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────
function Grant-MissingAppRoles {
    param(
        [Parameter(Mandatory)][string]$ServicePrincipalId,
        [Parameter(Mandatory)][string]$ServicePrincipalLabel,
        [Parameter(Mandatory)][object]$GraphSp,
        [Parameter(Mandatory)][string[]]$RequiredRoles
    )

    $existing = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ServicePrincipalId/appRoleAssignments"

    $existingRoleIds = @($existing.value | ForEach-Object { $_.appRoleId })

    $results = foreach ($perm in $RequiredRoles) {
        $appRole = $GraphSp.AppRoles |
            Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains 'Application' } |
            Select-Object -First 1

        if (-not $appRole) {
            [pscustomobject]@{ Permission = $perm; Status = 'Not found in Graph' }
            continue
        }

        if ($existingRoleIds -contains $appRole.Id) {
            [pscustomobject]@{ Permission = $perm; Status = 'Already assigned' }
            continue
        }

        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $ServicePrincipalId `
            -BodyParameter @{
                principalId = $ServicePrincipalId
                resourceId  = $GraphSp.Id
                appRoleId   = $appRole.Id
            } | Out-Null

        [pscustomobject]@{ Permission = $perm; Status = 'Assigned' }
    }

    Write-Host ""
    Write-Host "$ServicePrincipalLabel — Graph Permission Summary" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────────────"
    $results | Format-Table -AutoSize
}

# ─────────────────────────────────────────────────────────────
# LOAD SHARED SPs
# ─────────────────────────────────────────────────────────────
$utcmSp = Get-MgServicePrincipal -Filter "appId eq '$UTCMAppId'" -ErrorAction Stop
if (-not $utcmSp) { throw "UTCM service principal not found. Run the SP bootstrap script first." }

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -ErrorAction Stop

$automationMI = Get-MgServicePrincipal -ServicePrincipalId $AutomationMIObjectId -ErrorAction Stop
if (-not $automationMI) { throw "UTCM-Automation Managed Identity not found. Check the object ID." }

# ─────────────────────────────────────────────────────────────
# SECTION 1: UTCM SP permissions
# ─────────────────────────────────────────────────────────────
Grant-MissingAppRoles `
    -ServicePrincipalId    $utcmSp.Id `
    -ServicePrincipalLabel "UTCM SP ($UTCMAppId)" `
    -GraphSp               $graphSp `
    -RequiredRoles         $UTCMGraphAppRoles

# ─────────────────────────────────────────────────────────────
# SECTION 2: Automation MI permissions
# ─────────────────────────────────────────────────────────────
Grant-MissingAppRoles `
    -ServicePrincipalId    $automationMI.Id `
    -ServicePrincipalLabel "UTCM-Automation MI ($AutomationMIObjectId)" `
    -GraphSp               $graphSp `
    -RequiredRoles         $AutomationMIGraphAppRoles
