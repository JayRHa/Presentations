# Workplace Ninja 2026

## Intune AI Intelligence

Automation demo code from the session by **Jannik Reinhard and Niklas Tinner**.

| Demo | Material | What it does |
| --- | --- | --- |
| Community tools / daily health check | [Azure Automation runbook](Automation/) | Reads Intune with a Managed Identity and sends a Teams Adaptive Card when attention is needed. |
| Automation / visual workflow | [Logic App designer template](LogicApp/) | Shows the recurrence, Graph request, condition and notification outline. Deployed disabled; Teams is a placeholder. |

The runbook implementation was tested end to end in the conference demo tenant on **10 September 2026**, including a completed Azure job and an actual Teams card. This public copy replaces tenant/subscription identifiers with zero-GUID placeholders. Configure your own environment before use; no credentials or tenant execution logs are included.

Start with [Automation/README.md](Automation/README.md) for the working health check, or [LogicApp/README.md](LogicApp/README.md) for the visual designer demo.

Licensed under the repository's [MIT license](../LICENSE).
