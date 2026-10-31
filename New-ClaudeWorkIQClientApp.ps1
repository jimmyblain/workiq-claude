<#
.SYNOPSIS
  Registers the client app Claude uses to sign in to Work IQ.

.DESCRIPTION
  Run AFTER Microsoft's Enable-WorkIQToolsForTenant.ps1, which adds the Work IQ
  resource apps to the tenant:
  https://github.com/microsoft/work-iq/blob/main/ADMIN-INSTRUCTIONS.md

  Creates a single-tenant PUBLIC client (PKCE, no secret) with Claude's redirect URI under the "Mobile and desktop applications"
  platform, adds delegated permissions for every Work IQ resource, and grants
  org-wide admin consent.

  In Claude's custom connector, enter:
    URL        https://workiq.svc.cloud.microsoft/mcp
    Client ID  <the Client ID this script prints>
    Secret     (leave blank)

.PARAMETER TenantId
  The tenant to create the app in. The Graph sign-in is pinned to this tenant.

.PARAMETER DisplayName
  Name for the app registration.

.PARAMETER UseDeviceCode
  Use device code flow for authentication.

.NOTES
  Requires Global Admin or Privileged Role Admin (to grant admin consent).
#>

param(
    [Parameter(Mandatory)]
    [string]$TenantId,
    [string]$DisplayName = 'Claude Work IQ Connector',
    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'

$RedirectUri = 'https://claude.ai/api/mcp/auth_callback'

# Work IQ resource apps added by Enable-WorkIQToolsForTenant.ps1.
# Remove a line to withhold that resource from Claude.
$Resources = @(
    @{ Name = 'Work IQ Tools';              AppId = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1' }
    @{ Name = 'mcp_MeServer';               AppId = '147dc821-b413-44c0-8009-1a3098378012' }
    @{ Name = 'mcp_MailTools';              AppId = '16b1878d-62c7-4009-aa25-68989d63bbad' }
    @{ Name = 'mcp_CalendarTools';          AppId = '910333d2-47e9-43ca-981f-6df2f4531ef4' }
    @{ Name = 'mcp_TeamsServer';            AppId = 'ce5029ee-c1d3-45c0-bdcc-efb5a4245687' }
    @{ Name = 'mcp_OneDriveRemoteServer';   AppId = 'b0b2a2bb-6361-4549-a00c-a018417eb8e2' }
    @{ Name = 'mcp_SharePointRemoteServer'; AppId = '292cff14-c0e8-4116-9e3b-99934ae05766' }
    @{ Name = 'mcp_AdminTools';             AppId = '2dbeefeb-6462-48a4-abe6-1c4989699319' }
    @{ Name = 'mcp_WordServer';             AppId = 'c2d0c2b6-8013-4346-9f8b-b81d3b754a29' }
    @{ Name = 'mcp_M365Copilot';            AppId = 'ab7c82de-7946-4454-ac28-70249d17c95e' }
)

# Install Microsoft.Graph modules if missing
foreach ($mod in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Identity.SignIns')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing $mod..." -ForegroundColor Yellow
        Install-Module $mod -Scope CurrentUser -Force
    }
}

# Connect, pinned to the target tenant
$connectParams = @{
    TenantId  = $TenantId
    Scopes    = 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All'
    NoWelcome = $true
}
if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true }
Connect-MgGraph @connectParams
Write-Host "Connected to tenant: $((Get-MgContext).TenantId)" -ForegroundColor Green

try {

# 0. Don't create a duplicate
$existing = Get-MgApplication -Filter "displayName eq '$DisplayName'"
if ($existing) {
    throw "An app named '$DisplayName' already exists (Client ID $($existing[0].AppId)). Delete it or pass -DisplayName."
}

# 1. Look up each resource's service principal and delegated scopes
$resourceSps = @()
foreach ($r in $Resources) {
    $sp = Get-MgServicePrincipal -Filter "appId eq '$($r.AppId)'" | Select-Object -First 1
    if (-not $sp) {
        Write-Warning "$($r.Name) ($($r.AppId)) not found in tenant. Run Enable-WorkIQToolsForTenant.ps1 first."
        continue
    }
    if (-not $sp.Oauth2PermissionScopes) {
        Write-Warning "$($r.Name) exposes no delegated scopes. Skipping."
        continue
    }
    $resourceSps += [pscustomobject]@{ Name = $r.Name; AppId = $r.AppId; Sp = $sp }
}
if (-not $resourceSps) { throw 'No Work IQ resources found. Run Enable-WorkIQToolsForTenant.ps1 first.' }

$requiredAccess = foreach ($r in $resourceSps) {
    @{
        ResourceAppId  = $r.AppId
        ResourceAccess = @($r.Sp.Oauth2PermissionScopes | ForEach-Object { @{ Id = $_.Id; Type = 'Scope' } })
    }
}

# 2. App registration: single-tenant public client, Claude's redirect under the
#    Mobile and desktop applications platform, no secret
$app = New-MgApplication -DisplayName $DisplayName `
    -SignInAudience 'AzureADMyOrg' `
    -PublicClient @{ RedirectUris = @($RedirectUri) } `
    -IsFallbackPublicClient `
    -RequiredResourceAccess $requiredAccess
Write-Host "Created app registration (Client ID: $($app.AppId))" -ForegroundColor Green

# 3. Enterprise app (service principal)
$clientSp = New-MgServicePrincipal -AppId $app.AppId
Write-Host "Created service principal (Id: $($clientSp.Id))" -ForegroundColor Green

# 4. Org-wide admin consent, one grant per resource. Retries cover the delay
#    before a brand-new service principal is visible everywhere.
foreach ($r in $resourceSps) {
    $scopes = ($r.Sp.Oauth2PermissionScopes | Select-Object -ExpandProperty Value) -join ' '
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            New-MgOauth2PermissionGrant -BodyParameter @{
                ClientId    = $clientSp.Id
                ConsentType = 'AllPrincipals'
                ResourceId  = $r.Sp.Id
                Scope       = $scopes
            } | Out-Null
            Write-Host "  Consented: $($r.Name)" -ForegroundColor Green
            break
        } catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Seconds 10
        }
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "CLIENT ID:  $($app.AppId)"
Write-Host 'Secret:     none (public client + PKCE)'
Write-Host 'Connector:  https://workiq.svc.cloud.microsoft/mcp'
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "Next: set 'Assignment required' on this app and assign the group that should have access (see README)." -ForegroundColor Yellow

} finally {
    Disconnect-MgGraph | Out-Null
}
