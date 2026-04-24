Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
# =====================================================================
# IntuneAutomate – Run Once Setup Script (Singleton SharePoint Record)
# =====================================================================

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# -------------------------------
# CONFIGURATION
# -------------------------------
$AppName  = "IntuneAutomateProd"
$ListName = "AutomateSettings"

$SiteHostname = "kumonixtech.sharepoint.com"
$SitePath     = "sites/IntuneAutomate"

$GraphBaseUri = "https://graph.microsoft.com/v1.0"
$GraphAppId   = "00000003-0000-0000-c000-000000000000"

# -------------------------------
# GRAPH APP ROLES
# -------------------------------
$Permissions = @(
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

# -------------------------------
# TENANT LOGIN
# -------------------------------
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

$TargetTenant = Read-Host "ENTER TARGET TENANT ID or DOMAIN"
if ([string]::IsNullOrWhiteSpace($TargetTenant)) {
    throw "Tenant is required."
}

Connect-MgGraph `
    -TenantId $TargetTenant `
    -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All","Directory.ReadWrite.All","Sites.ReadWrite.All" `
    -NoWelcome `
    -ErrorAction Stop

$TenantId = (Get-MgContext).TenantId
$OrgName  = (Get-MgOrganization | Select-Object -First 1).DisplayName
Write-Host "✅ Connected to $OrgName ($TenantId)" -ForegroundColor Green

# -------------------------------
# APP REGISTRATION
# -------------------------------
if (Get-MgApplication -Filter "displayName eq '$AppName'") {
    throw "App '$AppName' already exists."
}

$App = New-MgApplication -DisplayName $AppName -SignInAudience "AzureADMyOrg"
$SP  = New-MgServicePrincipal -AppId $App.AppId
$Secret = Add-MgApplicationPassword `
    -ApplicationId $App.Id `
    -PasswordCredential @{ displayName="IntuneAutomateSecret" }

# -------------------------------
# ASSIGN GRAPH PERMISSIONS
# -------------------------------
$GraphSP = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'"

foreach ($RoleId in $Permissions) {
    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $SP.Id `
        -PrincipalId        $SP.Id `
        -ResourceId         $GraphSP.Id `
        -AppRoleId          $RoleId | Out-Null
}

# -------------------------------
# SHAREPOINT – RESOLVE SITE
# -------------------------------
$Site = Invoke-MgGraphRequest `
    -Uri "$GraphBaseUri/sites/${SiteHostname}:/${SitePath}" `
    -Method GET `
    -ErrorAction Stop

# -------------------------------
# SHAREPOINT – RESOLVE LIST (FAIL FAST)
# -------------------------------
$ListResult = Invoke-MgGraphRequest `
    -Uri "$GraphBaseUri/sites/$($Site.id)/lists?`$filter=displayName eq '$ListName'" `
    -Method GET `
    -ErrorAction Stop

if (-not $ListResult.value -or $ListResult.value.Count -eq 0) {
    throw "SharePoint list '$ListName' not found on site '$SitePath'. Check display name exactly."
}

$ListId = $ListResult.value[0].id

# -------------------------------
# SHAREPOINT – GET ITEMS
# -------------------------------
$Items = Invoke-MgGraphRequest `
    -Uri "$GraphBaseUri/sites/$($Site.id)/lists/$ListId/items?`$expand=fields" `
    -Method GET `
    -ErrorAction Stop

# Fields object shared between both operations
$FieldValues = @{
    Title     = "IntuneAutomate"
    TenantID  = $TenantId
    ClientID  = $App.AppId
    AppSecret = $Secret.SecretText
}

# POST to /items requires a 'fields' wrapper
$PostBody = @{ fields = $FieldValues } | ConvertTo-Json -Depth 5

# PATCH to /items/{id}/fields expects the field values directly — no wrapper
$PatchBody = $FieldValues | ConvertTo-Json -Depth 5

switch ($Items.value.Count) {

    0 {
        Invoke-MgGraphRequest `
            -Uri "$GraphBaseUri/sites/$($Site.id)/lists/$ListId/items" `
            -Method POST `
            -Body $PostBody `
            -ContentType "application/json" `
            -ErrorAction Stop

        Write-Host "✅ SharePoint config item CREATED"
    }

    1 {
        Invoke-MgGraphRequest `
            -Uri "$GraphBaseUri/sites/$($Site.id)/lists/$ListId/items/$($Items.value[0].id)/fields" `
            -Method PATCH `
            -Body $PatchBody `
            -ContentType "application/json" `
            -ErrorAction Stop

        Write-Host "✅ SharePoint config item UPDATED"
    }

    default {
        throw "Multiple items found in '$ListName'. Expected a single config record."
    }
}

# -------------------------------
# DONE
# -------------------------------
Write-Host ""
Write-Host "🎉 SUCCESS – IntuneAutomate fully configured" -ForegroundColor Green
