# Work IQ for Claude: client app setup

Adding Microsoft's Work IQ MCP server to Claude as a custom connector fails with "failed to log in" because Claude has no client app it can sign in with in your tenant. Claude tries to register one automatically, and Microsoft Entra doesn't support that.

`New-ClaudeWorkIQClientApp.ps1` creates that client app. It registers a single-tenant public client (PKCE, no secret) with Claude's redirect URI, grants it the Work IQ permissions, and prints the client ID to put in Claude's connector settings.

For the full explanation, the manual portal steps, and troubleshooting, see the [blog post](blog-post.md).

## Prerequisites

- Microsoft's Work IQ tenant setup is done, including [`Enable-WorkIQToolsForTenant.ps1`](https://github.com/microsoft/work-iq/blob/main/scripts/Enable-WorkIQToolsForTenant.ps1). See Microsoft's [admin instructions](https://github.com/microsoft/work-iq/blob/main/ADMIN-INSTRUCTIONS.md).
- PowerShell 7 (`pwsh`). The script installs the `Microsoft.Graph` modules it needs if they're missing.
- An Entra role that can grant tenant-wide admin consent (Global Administrator, Privileged Role Administrator, Cloud Application Administrator, or Application Administrator).
- A Claude plan that lets you add a custom connector with your own OAuth client ID.

## Usage

```powershell
./New-ClaudeWorkIQClientApp.ps1 -TenantId <your-tenant-id>
```

| Parameter | Description |
|---|---|
| `-TenantId` | Required. The tenant to create the app in. |
| `-DisplayName` | Name for the app registration. Defaults to `Claude Work IQ Connector`. |
| `-UseDeviceCode` | Sign in with device code flow, for machines without a browser. |

The script:

1. Checks that the Work IQ resource apps from Microsoft's script exist in the tenant, and warns about any that are missing.
2. Creates the app registration with `https://claude.ai/api/mcp/auth_callback` as a redirect URI under the Mobile and desktop applications platform. It doesn't create a secret.
3. Creates the app's service principal.
4. Grants org-wide admin consent for every delegated permission on each Work IQ resource app.

It stops without changing anything if an app with the same display name already exists.

To leave a resource out (for example, Teams), delete its line from `$Resources` at the top of the script before running it.

## Connect Claude

Add a custom connector in Claude with:

| Field | Value |
|---|---|
| URL | `https://workiq.svc.cloud.microsoft/mcp` |
| OAuth client ID | the client ID the script printed |
| OAuth client secret | leave blank |

## Restrict who can connect

A client ID isn't a secret, so anyone in the tenant could use this connector until you restrict it. In the Entra admin center, go to **Enterprise applications**, open the app, set **Properties > Assignment required** to **Yes**, and add the users or groups who should have access under **Users and groups**. Turn the setting on and add the assignment at the same time, because Assignment required with nobody assigned blocks everyone.

## Removing it

```powershell
Connect-MgGraph -TenantId <your-tenant-id> -Scopes Application.ReadWrite.All
Get-MgApplication -Filter "appId eq '<client-id>'" | ForEach-Object { Remove-MgApplication -ApplicationId $_.Id }
```

Deleting the app registration also removes its service principal and the consent grants.
