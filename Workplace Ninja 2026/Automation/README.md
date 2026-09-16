# Daily Intune health check

**Every morning → read Intune → find exceptions → post one Teams card.**

An Azure Automation PowerShell 7.4 runbook authenticates with the account's system-assigned Managed Identity. It reads device compliance, last-sync age and optionally Apple push certificate expiry. Healthy runs stay quiet. Existing issues are reported daily; the runbook does not change devices.

## Files

- `Invoke-IntuneDailyHealth.ps1` — published runbook implementation, with public configuration placeholders.
- `Grant-IntuneHealthGraphRoles.ps1` — checks the target identity and previews the two Graph role assignments; writes only when explicitly activated.
- `daily-schedule.arm.json` — creates a daily 08:00 Berlin schedule and links an existing published runbook.
- `Test-IntuneDailyHealth.ps1` and `Test-GrantIntuneHealthGraphRoles.ps1` — offline fixture tests; no Azure, Graph or Teams requests.

## 1. Create the Automation account

Create an Azure Automation account, enable its **system-assigned Managed Identity**, and select a **PowerShell 7.4** runtime environment containing **Az.Accounts**. The examples use resource group `rg-intune-keynote-demo` and account `aa-intune-health-demo`; replace these if your names differ.

In `Invoke-IntuneDailyHealth.ps1`, configure:

| Setting | Value to supply |
| --- | --- |
| `$script:ExpectedTenantId` | Your Entra tenant ID instead of the zero GUID |
| `$script:AutomationUrl` | Your Automation account portal URL; replace tenant ID, subscription ID and resource names |

The expected tenant is deliberately checked before a Graph token is used. Do not remove that check. The card label can also be customized in `New-TeamsHealthPayload`.

## 2. Grant Graph application read permissions

| Permission | Purpose |
| --- | --- |
| `DeviceManagementManagedDevices.Read.All` | Read managed device compliance and sync timestamps |
| `DeviceManagementServiceConfig.Read.All` | Optional APNs certificate check; enabled by default |

An authorized administrator grants these **application roles** to the Automation account's Managed Identity. No Graph write permission or subscription Contributor role is required by the runbook.

To use the included helper, set `$script:GrantTenantId`, `$script:GrantSubscriptionId`, `$script:GrantAccountName`, and the resource group in `$script:GrantResourceId`. Use an existing Azure CLI login with sufficient administrative privileges. Preview first:

```powershell
./Grant-IntuneHealthGraphRoles.ps1
```

After reviewing and approving the exact permissions, explicitly activate them:

```powershell
./Grant-IntuneHealthGraphRoles.ps1 -ActivateApprovedGrants -ApprovedRoles DeviceManagementManagedDevices.Read.All,DeviceManagementServiceConfig.Read.All
```

The helper verifies the subscription, tenant, Managed Identity and Graph role definitions, grants only missing selected roles, and reads the result back. It does not switch the global Azure CLI context or change operator privileges.

## 3. Connect Teams

1. Create or select a Teams channel.
2. In **Workflows**, configure **Send webhook alerts to a channel** using **When a Teams webhook request is received** and an action that posts each Adaptive Card in `attachments[].content`.
3. This runbook uses the secret webhook URL with the trigger's **Anyone** caller setting. Tenant-authenticated caller modes need a different authentication flow.
4. Save the callback URL as an **encrypted String Automation variable** named `TeamsHealthWebhook`. Keep the URL out of code, parameters, screenshots and logs.
5. Maintain the workflow's owner account; add an appropriate co-owner if needed for your environment.

## 4. Import, publish and verify

Import `Invoke-IntuneDailyHealth.ps1` as **Invoke-IntuneDailyHealth**, assign the PowerShell 7.4 runtime, and publish it. Start a manual Azure job with the defaults:

| Parameter | Default |
| --- | --- |
| `StaleAfterDays` | `14` |
| `IncludeApplePushCheck` | `true` |
| `CertificateWarningDays` | `30` |

If the optional APNs permission is omitted, set `IncludeApplePushCheck=false`. Verify the Azure job output, the successful Teams Workflow run and the actual card in the channel. `AcceptedByWorkflow` is HTTP acceptance, not proof of downstream Teams delivery. A healthy inventory will intentionally produce no card.

## 5. Schedule daily at 08:00 Berlin

In the portal, link a recurring daily schedule using the Berlin time zone and a future 08:00 start time. Check the displayed **Next run** after saving.

Alternatively, deploy `daily-schedule.arm.json` into the Automation account's resource group. Required inputs are a future `startTime` (ISO 8601 with Berlin's applicable offset) and a `jobScheduleGuid`. Generate the GUID once with `[guid]::NewGuid()` and reuse it on subsequent deployments to avoid duplicate links. Supply the existing account and runbook names if different from the defaults.

The template creates only the schedule and link; it does not create the account, runtime, runbook, Graph roles or secret variable. It uses the runbook's default health-check parameters. To pause notifications, disable the schedule. No scheduled run is created by merely downloading these files.

## Scope and limitations

- Counts cover noncompliant/error/conflict/grace/unknown states, stale or invalid sync dates, and optional APNs expiry/upload status. Empty inventory is flagged for review.
- Affected-device counts are deduplicated. A stale noncompliant device counts once in the total.
- An old check-in means current device health is unknown. The last reported state is not proof of its current state.
- Other connectors, ABM/DEP and VPP tokens, app deployments, configuration-policy reports and service incidents are outside this runbook's scope.
- Graph reads handle pagination and transient errors. Notification POSTs are not replayed after ambiguous transport failures to avoid duplicate cards.
- Logs and cards contain counts and check status, without device names, UPNs, serial numbers, tokens or webhook URLs. If notification delivery fails, inspect the failed Automation job.

## Offline tests

From this directory, using PowerShell 7.4 or later:

```powershell
./Test-IntuneDailyHealth.ps1
./Test-GrantIntuneHealthGraphRoles.ps1
```

The suites contain 38 runbook tests and 10 permission-helper tests. HTTP, authentication, secret reads and Azure CLI calls are replaced by fixtures. Generated JSON reports are ignored by Git.

## References

- [Managed device read API](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-list?view=graph-rest-1.0)
- [APNs certificate read API](https://learn.microsoft.com/en-us/graph/api/intune-devices-applepushnotificationcertificate-get?view=graph-rest-1.0)
- [Automation Managed Identity](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation)
- [Teams webhook setup](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook)
- [Automation schedules](https://learn.microsoft.com/en-us/azure/automation/shared-resources/schedules)
