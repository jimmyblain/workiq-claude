# Connecting Microsoft Work IQ to Claude: fixing "failed to log in"

You've run Microsoft's Work IQ admin setup, GitHub Copilot connects to Work IQ without complaint, and then you add the Work IQ MCP server to Claude as a custom connector and get "failed to log in." Microsoft's docs don't cover this case, and I spent longer on it than I'd like to admit. Here's what's going on and how to fix it.

The short version: Claude needs an app registration of its own in your tenant. Create a single-tenant public client with Claude's redirect URI under the *Mobile and desktop applications* platform, give it the Work IQ permissions, and put its client ID in the connector.

## Before you start

This post picks up where Microsoft's [Work IQ admin instructions](https://github.com/microsoft/work-iq/blob/main/ADMIN-INSTRUCTIONS.md) leave off. Specifically, you need to have run Microsoft's [`Enable-WorkIQToolsForTenant.ps1`](https://github.com/microsoft/work-iq/blob/main/scripts/Enable-WorkIQToolsForTenant.ps1). The Quick Start admin consent link in that doc isn't enough on its own, because it doesn't create the Work IQ resource apps in your tenant, and the Claude setup needs them. Microsoft's [`Verify-WorkIQTenant.ps1`](https://github.com/microsoft/work-iq/blob/main/scripts/Verify-WorkIQTenant.ps1) will tell you whether they're there.

You'll also need:

- An Entra admin role that can grant tenant-wide consent (the same roles Microsoft's script requires).
- Microsoft 365 Copilot licenses for the people who will use it.
- A Claude plan where you can add a custom connector and enter your own OAuth client ID. I set this up on Claude Enterprise.

## Why Copilot connects and Claude doesn't

Entra only issues tokens to client apps that are registered ahead of time. Microsoft's enable script sets up two kinds of app in your tenant. The first is the set of Work IQ *resource* apps (Work IQ Tools, Mail, Calendar, Teams, SharePoint, and so on), which are the things being accessed. The second is a single *client* app, Microsoft's own Work IQ CLI (`ba081686-5d24-4bc6-a0d6-d034ecffed87`), which is what Copilot and the local Work IQ server sign in as.

Claude's custom connector signs in from claude.ai. If you only give it the server URL, it tries to register itself as a new client on the fly (dynamic client registration). Entra doesn't support that, so you get "failed to log in."

The obvious question is why Claude can't just use Microsoft's CLI client, since it's already in your tenant. What you have in your tenant is only that app's service principal, your tenant's copy of it. Redirect URIs live on the app registration, and Microsoft owns that in its own tenant. You can't add Claude's redirect URI to it, so Claude needs a client app you own.

## Step 1: register a client app for Claude

### Option A: the script

I wrote a PowerShell script that does the whole registration. It uses the same Microsoft Graph modules as Microsoft's scripts, so if you just ran theirs, you already have everything installed.

```powershell
git clone https://github.com/jimmyblain/workiq-claude.git
cd workiq-claude
./New-ClaudeWorkIQClientApp.ps1 -TenantId <your-tenant-id>
```

It creates a single-tenant public client named "Claude Work IQ Connector" with Claude's redirect URI under the Mobile and desktop applications platform. It then adds the delegated permissions from every Work IQ resource app, grants admin consent for the whole org, and prints the client ID. It never creates a secret. Add `-UseDeviceCode` if you're on a machine without a browser.

### Option B: the Entra portal

1. In the Entra admin center, go to **App registrations > New registration**. Give it a name and choose single tenant. Under Redirect URI, pick **Public client/native (mobile & desktop)** and enter `https://claude.ai/api/mcp/auth_callback`.
2. Go to **API permissions > Add a permission > APIs my organization uses**. Add the delegated permissions for each Work IQ resource app (Work IQ Tools, mcp_MeServer, mcp_MailTools, mcp_CalendarTools, mcp_TeamsServer, mcp_OneDriveRemoteServer, mcp_SharePointRemoteServer, mcp_AdminTools, mcp_WordServer, mcp_M365Copilot). If a name doesn't show up in search, search by its app ID. The IDs are in Microsoft's enable script.
3. Click **Grant admin consent**.
4. Don't create a client secret. Copy the **Application (client) ID** from the Overview page.

The platform choice is the part people get wrong. If you add the redirect URI under the **Web** platform, Entra treats the app as a confidential client and expects a secret when Claude exchanges the sign-in code for a token. Under Mobile and desktop applications, the app is a public client, and Claude proves itself with PKCE in place of a secret. That means there's no secret to store or rotate.

To leave out a resource (say you don't want Claude reading Teams), skip its permissions here, or remove the line from the `$Resources` list in the script before running it.

## Step 2: add the connector in Claude

Add a custom connector in Claude with these values:

| Field | Value |
|---|---|
| URL | `https://workiq.svc.cloud.microsoft/mcp` |
| OAuth client ID | the client ID from step 1 |
| OAuth client secret | leave blank |

That's the whole connector config. You don't need a scope or one connector per Work IQ server. Connect as one test user first and make sure it signs in and returns data before you roll it out.

## Step 3: control who can connect

Sign-in is delegated, so every request runs as the signed-in person, and nobody can reach data they couldn't already open in Microsoft 365. Who can turn it on is a separate question. A client ID isn't a secret, so without anything else in place, anyone in your tenant could connect.

Entra's "Assignment required" setting fixes that. In **Enterprise applications**, open your Claude client app, set **Properties > Assignment required** to **Yes**, then add your pilot group under **Users and groups**. Do the same on Microsoft's Work IQ CLI app (`ba081686-…`) if you also want to control who can use Work IQ through Copilot or the local server.

Assign the group in the same sitting that you turn the setting on. Assignment required with nobody assigned locks everyone out, including you.

## Troubleshooting

| What you see | What it means |
|---|---|
| "failed to log in" with no Entra error | The connector has no client ID, so Claude tried to register itself. Add the client ID from step 1. |
| `AADSTS650052` | The Work IQ resource apps aren't in your tenant. Run Microsoft's `Enable-WorkIQToolsForTenant.ps1`. |
| `AADSTS50011` | The redirect URI doesn't match. It has to be exactly `https://claude.ai/api/mcp/auth_callback`. |
| `AADSTS7000218` | The redirect URI is under the Web platform, so Entra wants a secret. Move it to Mobile and desktop applications. |
| `AADSTS65001` | Admin consent hasn't been granted for the client app. |
| `AADSTS50105` | Assignment required is on and this user isn't in an assigned group. |
