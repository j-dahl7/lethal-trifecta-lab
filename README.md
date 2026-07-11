# Lethal Trifecta Gate for AI Agents

> **Lab status:** the original “Breaking and Defending the Lethal Trifecta” draft is no longer published on the website. For current agent-security context, see the [Agent 365 Defender playbook](https://nineliveszerotrust.com/blog/agent-365-defender-playbook/).

A serverless gate that enforces the **Rule of Two** — blocking AI agent tool calls that would complete all 3 conditions required for data exfiltration. Implements the lethal trifecta defense pattern: any 2 of 3 conditions are allowed, but the 3rd (which would complete the trifecta) is blocked.

## Verification status

**Last reviewed: 2026-07-10 — local policy and static infrastructure validation; no live deployment.** Python compilation/unit tests, JSON, PowerShell parsing, Bicep compilation, requirement resolution, tool mappings, documentation links, and the local attack demo were reviewed. The Azure deployment, Flex Consumption publish path, Cosmos REST seeding, Data Collection Rule ingestion, and live smoke test were not executed against a subscription during this review.

## The Problem

AI agents with tool access can be manipulated via prompt injection to exfiltrate sensitive data. The attack requires three conditions (the "Lethal Trifecta"):

| # | Condition | Example Tools |
|---|-----------|---------------|
| 1 | **Private Data** | `read_db`, `read_keyvault` |
| 2 | **Untrusted Content** | `process_document`, `search_web` |
| 3 | **Exfiltration Vector** | `send_http`, `send_email` |

Any single condition is harmless. Even two are safe. But when all three are satisfied in the same session, an agent can read private data, get poisoned by untrusted content, and send data to an attacker.

## The Solution

A centralized gate that evaluates every tool call:

```
Agent Tool Call → Trifecta Gate → ALLOW (200) or BLOCK (403)
                       │
                       ├── Session Tracker (per-session condition state)
                       ├── Policy Engine (Rule of Two enforcement)
                       └── Log Analytics (audit trail)
```

The gate tracks which trifecta conditions have been satisfied per session. It allows any combination of 2 conditions but blocks the 3rd call that would complete the trifecta.

Tools not present in `function/tools.json` are blocked by default. This fail-closed behavior prevents a newly introduced or misspelled tool from bypassing condition mapping.

---

## Prerequisites

- Disposable Azure subscription with Owner access (subscription deployment plus RBAC assignment); use a narrower custom role only if it includes equivalent deployment and role-assignment permissions
- Azure CLI configured (`az login`)
- PowerShell 7+ (`pwsh`)
- Azure Functions Core Tools for the primary publish path; the script attempts Azure CLI zip deployment when Core Tools is absent

No Entra ID setup, Graph API permissions, or directory roles required.

## Cost and safety checkpoint

The lab creates a Flex Consumption Function App, Cosmos DB serverless account, Log Analytics workspace, Application Insights, Storage account, Key Vault, Data Collection Endpoint, and custom log-ingestion resources. Usage can incur charges, and the anonymous endpoint can be abused to generate Function, Cosmos, and logging consumption. The template caps scale at five instances, but you should still deploy only in a disposable subscription, add an Azure budget/alert, and delete the resource group after testing.

---

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/j-dahl7/lethal-trifecta-lab.git
cd lethal-trifecta-lab
```

### 2. Run the Attack Demo (No Azure Required)

See the unprotected attack path locally:

```powershell
./scripts/Attack-Demo.ps1
```

### 3. Deploy the Gate

```powershell
./scripts/Deploy-Lab.ps1
```

Or with custom settings:

```powershell
./scripts/Deploy-Lab.ps1 -ProjectName "my-trifecta" -Location "westus2"
```

The script will:
1. Deploy Azure resources via Bicep (Resource Group, Cosmos DB, Key Vault, Function App, Log Analytics, DCE)
2. Create the `TrifectaAudit_CL` custom table and Data Collection Rule
3. Grant Monitoring Metrics Publisher to the Function App managed identity
4. Configure Function App settings (DCR, Cosmos DB)
5. Deploy Function code
6. Seed Cosmos DB with fake employee records
7. Run smoke tests

### 4. Run the Defense Demo

```powershell
./scripts/Defense-Demo.ps1 -FunctionAppUrl "https://trifecta-lab-gate-XXXXXX.azurewebsites.net"
```

---

## API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/evaluate` | POST | Core gate — evaluates tool call, returns ALLOW (200) or BLOCK (403) |
| `/api/session/{id}` | GET | Returns session state (active conditions, count, missing) |
| `/api/tools` | GET | Returns full tool registry |
| `/api/health` | GET | Process liveness; does not claim dependency readiness |
| `/api/readiness` | GET | Verifies configured Cosmos DB session storage; returns 503 on failure |

### Evaluate a Tool Call

```bash
curl -X POST "$GATE_URL/api/evaluate" \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "session-123",
    "tool_name": "read_db"
  }'
```

Response (ALLOW):
```json
{
  "decision": "ALLOW",
  "tool_name": "read_db",
  "condition": "private_data",
  "reason": "Tool 'read_db' allowed. Condition 'private_data' recorded.",
  "session_id": "session-123",
  "conditions_before": [],
  "conditions_after": ["private_data"]
}
```

Response (BLOCK - 403):
```json
{
  "decision": "BLOCK",
  "tool_name": "send_http",
  "condition": "exfiltration_vector",
  "reason": "Tool 'send_http' would satisfy condition 'exfiltration_vector', completing all 3 trifecta conditions. Blocked by Rule of Two.",
  "session_id": "session-123",
  "conditions_before": ["private_data", "untrusted_content"],
  "conditions_after": ["private_data", "untrusted_content"]
}
```

---

## Tool Registry

7 tools mapped to 3 trifecta conditions:

| Tool | Condition | Category |
|------|-----------|----------|
| `read_db` | private_data | Data Access |
| `read_keyvault` | private_data | Data Access |
| `process_document` | untrusted_content | Content Processing |
| `process_user_message` | untrusted_content | Content Processing |
| `search_web` | untrusted_content | Content Processing |
| `send_http` | exfiltration_vector | External Communication |
| `send_email` | exfiltration_vector | External Communication |

---

## Architecture

**Components:**

- **Trifecta Gate** — Azure Function App with 5 HTTP endpoints
- **Session Tracker** — Cosmos DB-backed per-session state (persists across instances)
- **Policy Engine** — Evaluates Rule of Two, returns ALLOW/BLOCK
- **Log Analytics** — Custom `TrifectaAudit_CL` table for audit trail
- **Cosmos DB** — Serverless, stores fake employee records for demo
- **Key Vault** — Contains demo secret (represents private data)

---

## File Structure

```
lethal-trifecta-lab/
├── README.md
├── LICENSE
├── .gitignore
├── bicep/
│   ├── main.bicep               # Subscription-scoped orchestrator
│   ├── main.bicepparam
│   └── modules/
│       ├── monitoring.bicep     # Log Analytics + DCE
│       ├── core.bicep           # Cosmos DB (serverless) + Key Vault
│       └── function.bicep       # Function App (Flex Consumption, Python 3.11)
├── scripts/
│   ├── Deploy-Lab.ps1           # 7-step orchestrator
│   ├── Deploy-Azure.ps1         # az deployment sub create
│   ├── Grant-Permissions.ps1    # Monitoring Metrics Publisher on DCR
│   ├── Configure-Function.ps1   # Set app settings (DCR, Cosmos)
│   ├── Seed-Data.ps1            # Insert fake employee records
│   ├── Attack-Demo.ps1          # Local simulation — no gate
│   ├── Defense-Demo.ps1         # Live demo — gate blocks 3rd call
│   └── Test-Lab.ps1             # Smoke tests
├── function/
│   ├── function_app.py          # HTTP triggers, including liveness/readiness
│   ├── tool_registry.py         # Load tools.json, get_tool_conditions()
│   ├── session_tracker.py       # Per-session state + readiness
│   ├── policy_engine.py         # evaluate() → GateResult (ALLOW/BLOCK)
│   ├── audit.py                 # Log to TrifectaAudit_CL via DCR
│   ├── tools.json               # 7 tools mapped to conditions
│   ├── requirements.txt
│   └── host.json
└── tests/
    ├── test_policy_engine.py    # Rule-of-Two + store failure tests
    └── test_function_app.py     # HTTP 503 + readiness tests
```

---

## Verification

### KQL Queries

After running the Defense Demo, verify the audit trail:

```kql
TrifectaAudit_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, SessionId, ToolName, Condition, Decision
| order by TimeGenerated asc
```

Expected output: 3 rows (ALLOW, ALLOW, BLOCK).

### Smoke Tests

```powershell
./scripts/Test-Lab.ps1 -FunctionAppUrl "https://trifecta-lab-gate-XXXXXX.azurewebsites.net"
```

Tests: process liveness, durable Cosmos DB readiness, tools list (7 tools), single allow, trifecta block, and session state.

---

## Limitations

- **AuthLevel.ANONYMOUS** — No authentication on endpoints (lab simplicity). Production should use Function keys or Entra ID auth.
- **Session TTL** — Sessions expire after 24 hours in Cosmos DB. Production implementations may need configurable TTL or explicit session cleanup.
- **Concurrency** — Session updates are read/modify/write operations without an application-level transaction. Concurrent calls for one session can race; a production gate needs optimistic concurrency or a transactional state machine.
- **State failure** — When Cosmos DB is configured but unavailable, evaluation/session requests and `/api/readiness` return `503` instead of silently allowing calls with fresh in-memory state. `/api/health` remains a process-liveness check. In-memory state is used only for an explicitly unconfigured local run.
- **Authorization and privacy** — The anonymous session endpoint exposes tool history to anyone who can guess a session ID. Never send production tool names, customer identifiers, or sensitive arguments to this lab deployment.
- **Demonstration scope** — The gate evaluates declared tool categories; it does not inspect tool arguments, destinations, response data, indirect exfiltration, or side effects. It is a policy-pattern demonstration, not a complete agent sandbox.

---

## Cleanup

```bash
az group delete --name trifecta-lab-rg --yes
```

Resource-group deletion does not immediately purge the soft-deleted Key Vault. Purge it only when the vault is disposable and your recovery requirements allow it. Then review subscription role assignments and cost analysis to confirm no lab resources remain.

---

## Resources

- [Agent 365 Defender playbook](https://nineliveszerotrust.com/blog/agent-365-defender-playbook/)
- [ZSP Azure Lab (companion)](https://github.com/j-dahl7/zsp-azure-lab)
- [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)

---

## License

MIT License - See [LICENSE](LICENSE) for details.
