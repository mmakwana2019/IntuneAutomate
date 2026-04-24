#Requires -Version 7.0
<#
.SYNOPSIS
One-time setup: Ensure UTCM and M365 Admin Services service principals exist

.DESCRIPTION
Creates the Microsoft Unified Tenant Configuration Management (UTCM) service
principal and the Microsoft 365 Admin Services service principal if missing.

Safe to run multiple times. Does not create UTCM snapshots or monitors and should be run as a One off.
#>

$ErrorActionPreference = 'Stop'

# Fixed Microsoft app IDs (do not change)
$UTCMAppId     = '03b07b79-c5bc-4b5e-9bfa-13acf4a99998'  # Unified Tenant Configuration Management
$M365AdminSPId = '6b91db1b-f05b-405a-a0b2-e3f60b28d645'  # Microsoft 365 Admin Services

# Connect with required permissions
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications

Connect-MgGraph -Scopes @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All'
) -NoWelcome

# Ensure UTCM service principal exists
$utcm = Get-MgServicePrincipal -Filter "appId eq '$UTCMAppId'" -ErrorAction SilentlyContinue
if (-not $utcm) {
    New-MgServicePrincipal -AppId $UTCMAppId | Out-Null
    Write-Host "UTCM service principal created." -ForegroundColor Green
} else {
    Write-Host "UTCM service principal already exists." -ForegroundColor Green
}

# Ensure M365 Admin Services service principal exists
$m365 = Get-MgServicePrincipal -Filter "appId eq '$M365AdminSPId'" -ErrorAction SilentlyContinue
if (-not $m365) {
    New-MgServicePrincipal -AppId $M365AdminSPId | Out-Null
    Write-Host "M365 Admin Services service principal created." -ForegroundColor Green
} else {
    Write-Host "M365 Admin Services service principal already exists." -ForegroundColor Green
}
