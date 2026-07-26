# Lethal Trifecta Gate for AI Agents

An isolated research lab that demonstrates a **Rule of Two** gate: an agent may
accumulate at most two of the three conditions needed for data exfiltration.
The call that would complete all three is blocked and is not persisted.

This repository does **not** currently have a published companion article at
`/blog/lethal-trifecta/`; that route does not exist, so this repo is intentionally
not presented as a companion lab on the Nine Lives Zero Trust Labs page. Useful
related material remains linked under [Related resources](#related-resources).

> **Validation boundary (July 25, 2026):** this revision was validated with
> deterministic unit tests, Python compilation, PowerShell parsing, JSON parsing,
> and a local Bicep build. It was not deployed to an Azure tenant during this
> audit, so Azure role propagation, Function publication, Cosmos data-plane
> access, DCR ingestion, and live cost behavior still require tenant validation.

## Safety and cost

- The attack demo is local text-only simulation. It sends no data anywhere.
- Seed records are obviously synthetic (`example.invalid`, invalid `000` SSNs).
- Azure deployment creates billable Cosmos DB, Log Analytics, Functions, Storage,
  Application Insights, Key Vault, and monitoring resources.
- The gate is a teaching control, not a complete production agent-security system.
- Preview owned cleanup immediately after deployment and remove the lab when done.

## Threat model

| Condition | Example registered tools |
|---|---|
| Private data | `read_db`, `read_keyvault` |
| Untrusted content | `process_document`, `process_user_message`, `search_web` |
| Exfiltration vector | `send_http`, `send_email` |

The authoritative policy operation is atomic. Concurrent calls cannot each read
stale state and all become allowed: Cosmos updates use ETags and conditional
replacement, while the explicitly test-only memory store uses a process lock.

The gate fails closed:

- gate, session, and registry routes require a generated Function host key;
- unknown tools are blocked;
- missing or unavailable Cosmos state returns a blocking `503`, never an empty
  in-memory session;
- required audit failure converts an otherwise allowed response to blocking
  `503`;
- request bodies, identifiers, session counts, histories, retries, and local
  test-store cardinality are bounded.

## Prerequisites

- Azure CLI authenticated to the intended tenant and subscription
- PowerShell 7+
- Azure Functions Core Tools, recommended; the deployer has an authenticated zip
  fallback when Core Tools is unavailable
- Subscription-scope **Contributor** to create the owned resource group
- **Role Based Access Control Administrator** (or narrowly equivalent delegated
  role-assignment permission) for the lab's scoped role assignments

Owner is not required. No Graph permissions or Entra directory role is required.
The deployer receives Key Vault Secrets Officer on only the lab vault and Cosmos
data contributor on only the synthetic `employees` container. The Function
managed identity receives Cosmos data contributor on only `sessions` and
Monitoring Metrics Publisher on only the lab DCR.

## Local validation first

```powershell
python -m unittest discover -s tests -v
python -m compileall -q function

Get-ChildItem scripts -Filter '*.ps1' | ForEach-Object {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $_.FullName, [ref]$tokens, [ref]$errors
  ) | Out-Null
  if ($errors.Count) { throw ($errors.Message -join '; ') }
}

az bicep build --file bicep/main.bicep
```

CI repeats these checks on pushes and pull requests.

## Run the harmless local attack simulation

```powershell
./scripts/Attack-Demo.ps1
```

It prints the unprotected three-step sequence but performs no network, database,
email, Key Vault, or file exfiltration operation.

## Deploy

```powershell
./scripts/Deploy-Lab.ps1 -ProjectName 'trifecta-lab' -Location 'eastus'
```

The orchestrator:

1. deploys an ownership-tagged resource group and Bicep resources;
2. creates the audit table and ownership-tagged DCR;
3. grants only the required DCR-scoped ingestion role;
4. configures managed-identity Cosmos access and required audit settings;
5. publishes Function code and fails if both publication paths fail;
6. idempotently seeds six synthetic records using an Entra data-plane token;
7. obtains or generates a host key in memory and runs authenticated smoke tests.

Any failed required step stops deployment and reports that Azure may contain a
partial deployment. `-CleanupOnFailure` is an explicit destructive opt-in; it
still runs the ownership checks in `Remove-Lab.ps1` before deletion.

Use `-SkipFunctionDeploy`, `-SkipSeed`, or `-SkipTest` only deliberately. Skipped
steps are reported and are never described as completed.

## Use the authenticated API

Health is the sole anonymous route. Retrieve a host key without printing it:

```powershell
$functionKeyText = az functionapp keys list `
  --name '<function-app-name>' `
  --resource-group 'trifecta-lab-rg' `
  --query 'functionKeys.default' `
  --output tsv
$functionKey = ConvertTo-SecureString $functionKeyText -AsPlainText -Force
Remove-Variable functionKeyText
```

Run the live defense demo:

```powershell
./scripts/Defense-Demo.ps1 `
  -FunctionAppUrl 'https://<function-app-name>.azurewebsites.net' `
  -FunctionKey $functionKey
```

Or call the gate directly with the key header:

```powershell
$keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($functionKey)
try {
  $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
  $headers = @{ 'x-functions-key' = $plainKey }
  Invoke-RestMethod `
    -Uri 'https://<function-app-name>.azurewebsites.net/api/evaluate' `
    -Method Post `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body '{"session_id":"session-123","tool_name":"read_db"}'
}
finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
  $headers['x-functions-key'] = $null
  Remove-Variable plainKey, headers -ErrorAction SilentlyContinue
}
```

| Route | Auth | Purpose |
|---|---|---|
| `GET /api/health` | Anonymous | Non-secret readiness only |
| `POST /api/evaluate` | Function key | Atomic Rule-of-Two decision |
| `GET /api/session/{id}` | Function key | Existing bounded session state |
| `GET /api/tools` | Function key | Validated tool registry |

Unknown sessions return `404`. Invalid or oversized input returns `400`/`413`.
Session/store limits return `429`/`503` with `decision: BLOCK` where applicable.

## Architecture and ownership

```text
authenticated caller
        |
        v
Azure Function gate ---- required decision audit ----> DCR / Log Analytics
        |
        +---- managed identity, container-scoped ----> Cosmos sessions
```

Every top-level Azure resource receives these non-overridable tags:

- `nlzt-owner=lethal-trifecta-lab`
- `project=<ProjectName>`
- `environment=lab`
- `purpose=lethal-trifecta-demo`

Cosmos local/key authentication and Storage shared-key authentication are
disabled. The Function host and deployment container both use its system-assigned
identity. The fixed demo secret from the old revision was removed; Bicep generates
a secure synthetic value on deployment.
The in-memory session store requires both `SESSION_STORE=memory` and
`ALLOW_IN_MEMORY_SESSION_STORE=true` and exists solely for isolated local tests.

## Audit verification

After an authenticated defense demo, query:

```kql
TrifectaAudit_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, SessionId, ToolName, Condition, Decision
| order by TimeGenerated asc
```

Expect two `ALLOW` rows and one `BLOCK` row. Ingestion can be delayed. An HTTP
decision is not proof that the row is already queryable.

## Cleanup

Preview first:

```powershell
./scripts/Remove-Lab.ps1 -ProjectName 'trifecta-lab' -WhatIf
```

Then remove the exact owned deployment:

```powershell
./scripts/Remove-Lab.ps1 -ProjectName 'trifecta-lab'
```

Cleanup verifies the active subscription, exact resource-group name, complete
resource-group ownership identity, and ownership tags on every top-level resource
before issuing the resource-group delete. It refuses legacy, untagged, or foreign
resources. Do not replace it with an unverified `az group delete` command.

Older deployments made before ownership tags were introduced require manual
inventory and immutable-ID verification; the cleanup script intentionally refuses
to infer ownership from a name alone.

## Repository layout

```text
bicep/                 Azure resources and container-scoped data roles
function/              Authenticated Function gate and atomic session policy
scripts/Deploy-Lab.ps1 Fail-fast deployment orchestrator
scripts/Remove-Lab.ps1 Ownership-validated cleanup
scripts/Test-Lab.ps1   Authenticated live smoke tests
scripts/Attack-Demo.ps1 Harmless local simulation
scripts/Defense-Demo.ps1 Authenticated live defense demonstration
tests/                 Deterministic policy, race, bounds, and safety contracts
.github/workflows/     CI safety validation
```

## Remaining limitations

- A shared Function key authenticates the lab client but does not provide
  per-user identity, authorization, revocation policy, or network isolation.
- The Rule of Two depends on complete, correct tool registration and on every
  real tool execution being mediated by the gate.
- The three-condition model does not inspect payload sensitivity, destination
  trust, model output, indirect channels, or actions outside this registry.
- Cosmos and DCR are public endpoints protected by Entra/RBAC; private endpoints
  and VNet integration are outside this cost-conscious lab.
- Session TTL is 24 hours and no application route resets a session.
- Cleanup validates ARM-tracked top-level resources. It cannot prove that nobody
  added data-plane items inside an otherwise owned Cosmos account or Key Vault;
  keep unrelated data out of the dedicated lab resource group.

## Related resources

- [Nine Lives Zero Trust](https://nineliveszerotrust.com/)
- [ZSP Azure Lab](https://github.com/j-dahl7/zsp-azure-lab)
- [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
- [Azure Cosmos DB Python quickstart](https://learn.microsoft.com/azure/cosmos-db/quickstart-python)
- [Azure Functions security concepts](https://learn.microsoft.com/azure/azure-functions/security-concepts)

## License

MIT License — see [LICENSE](LICENSE).
