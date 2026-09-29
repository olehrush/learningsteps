# LearningSteps Terraform starter

This configuration is a teaching starting point. It creates resources in Azure only when **you** authenticate, review a plan, and apply it. The accompanying walkthrough explains those steps.

## What it creates

- One project resource group and a `10.42.0.0/16` VNet.
- AKS worker subnet `10.42.1.0/24` and delegated PostgreSQL subnet `10.42.2.0/24`.
- AKS with Microsoft Entra authentication, Azure RBAC, local accounts disabled, OIDC, workload identity, and the Key Vault CSI add-on.
- Two `Standard_D4s_v5` system nodes by default, Azure CNI Overlay, and a Standard load balancer. The cluster's **pricing tier** is Free; VM, disk, network, and other resource charges still apply. Free has no API-server uptime SLA.
- ACR Basic in explicit `LegacyRegistryPermissions` mode. Image upload/download uses `AcrPush`/`AcrPull`; the registry admin password and anonymous pull are disabled.
- PostgreSQL 16, private VNet access, private DNS, 32 GiB initial storage, and the `learning_journal` database. Table/user creation is a separate initialization step.
- A Key Vault with RBAC, purge protection, seven-day soft-delete retention, and a firewall allowing only your public `/32` address and the AKS subnet's service endpoint.
- Separate random application and administrator passwords, stored as connection-URI secrets in Key Vault. Both require certificate-verified TLS and the CA bundle `/etc/ssl/certs/ca-certificates.crt` in the API and initialization containers.
- An application identity federated to `system:serviceaccount:learningsteps:learningsteps-sa`, allowed to read **only** `DATABASE-URL`.

## Before applying

1. Install Terraform 1.6+ and the Azure CLI. Authenticate locally with `az login`; select the intended subscription.
2. Use an account permitted to create the resources and role assignments. Contributor alone cannot create Azure role assignments. The starter grants its executing principal the bootstrap data-plane roles on the new resources; use this as a local operator workflow first.
3. Check subscription policy, regional availability, and quota. The node default needs at least eight vCPUs, with additional headroom for one surge node during upgrades. These sizes are not a promise of availability or low monthly cost. Review an Azure cost estimate before applying.
4. Copy `terraform.tfvars.example` to `terraform.tfvars` and set your subscription, prefix, location, and real public IPv4 `/32`. The documentation IP in the example is deliberately not usable.
5. From this folder run `terraform init`, `terraform fmt -check`, `terraform validate`, then `terraform plan -out=tfplan`. Review the resource list and apply with `terraform apply tfplan`.
6. Keep `.terraform.lock.hcl` in Git. Keep `terraform.tfvars`, state, state backups, and saved plans out of Git. State and saved plans contain database credentials even though no secret is exposed as an output.

Terraform waits two minutes after granting its executing principal `Key Vault Secrets Officer` before creating the secrets. Azure role or firewall propagation can take longer. For an initial 403, check the error's principal and public IP, verify the role and network rule, allow propagation, and rerun `terraform apply`. Do not open the vault to all networks to fix an identity error.

## Output contract for the walkthrough

Use `terraform output -raw NAME` for a single non-secret value.

| Output | Consumer |
|---|---|
| `subscription_id`, `resource_group`, `resource_group_id` | Azure CLI, resource lookup, workflow setup |
| `aks_name`, `aks_id` | Get kubeconfig; assign deployment permissions |
| `acr_name`, `acr_id`, `acr_login_server` | Image build/push and workflow setup |
| `key_vault_name`, `key_vault_id` | Secret initialization and `SecretProviderClass` |
| `workload_client_id`, `tenant_id` | Kubernetes service account and secret provider |
| `postgres_fqdn`, `database_name`, `app_username` | Schema initialization and troubleshooting |
| `app_secret_name`, `admin_secret_name` | Non-secret names: `DATABASE-URL` and `DATABASE-ADMIN-URL` |

The application identity does not have access to `DATABASE-ADMIN-URL`. The local operator's `Key Vault Secrets Officer` role allows the initialization helper to retrieve both URI values without printing them. The helper creates `learningsteps_app`, initializes tables, grants the required table permissions, then removes its transient Kubernetes credentials. The current schema uses text IDs and does not require sequence grants.

Terraform creates the Azure database resource; it does **not** create the PostgreSQL application's login or table schema. Do the database initialization before testing API operations.

Secrets have a stable 90-day expiration from initial creation. This is sufficient for the four-week project. Before reusing the environment after that period, implement coordinated credential rotation, including the PostgreSQL password and application refresh. Extending an expiration alone does not rotate a password. CSI updates mounted files; environment-variable consumers require a rollout to load a changed value.

## Network and deployment assumptions

- PostgreSQL is private; a normal laptop/GitHub-hosted runner cannot connect to its database port directly. The initialization helper runs SQL inside AKS.
- Key Vault uses a restricted public endpoint plus service endpoints. It is not a Private Link deployment. If your public IP changes, restore operator access through the state-storage and Key Vault network settings, then update `operator_ipv4_cidr` and apply the reviewed plan. The main walkthrough explains this access-recovery sequence; a normal refresh can otherwise fail before Terraform updates the firewall.
- ACR Basic has an authenticated public endpoint. A Private Link registry requires Premium and a runner with suitable network access; increasing the tier alone does not create that connectivity.
- The application workflow does not need to read the database secret. Its workload receives it through the AKS workload identity and CSI integration.
- The AKS API allowlist initially contains your public `/32`, plus any entries in `aks_api_additional_cidrs`. Standard GitHub-hosted runners have changing egress addresses. The companion workflow temporarily adds its current runner `/32`, deploys, and restores the previous allowlist in its cleanup step; this needs a narrowly scoped AKS write permission as well as deployment permissions. Serialize these updates and avoid concurrent Terraform changes. Check and remove a stale runner address after cancellation or cleanup failure. Identity permission alone does not establish connectivity.
- Default node-pool size and HPA Pod replica count are separate. This starter does not enable cluster autoscaling.
- This small teaching stack has no database HA, geographic backup copy, private AKS API, WAF, or centralized diagnostic logging. Document and evaluate these choices when extending it.

## Remote state and recovery

Without activating a backend file, Terraform defaults to local state. The main walkthrough instead creates an Azure storage backend first in a separate, retained resource group. Grant the Terraform operator `Storage Blob Data Contributor`, configure its networking and recovery controls, and use the two `.example` backend files as templates. No account key belongs in `backend.hcl`.

After the storage exists, copy `backend.tf.example` to `backend.tf`, copy and fill `backend.hcl.example`, and run `terraform init -backend-config=backend.hcl` for a new environment. If you already have local state, migrate it instead:

```bash
terraform init -migrate-state -backend-config=backend.hcl
```

Keep this backend outside the project-destruction exercise. It is not created by this configuration. Confirm the remote state is present before removing old local copies.

`terraform destroy` removes the database and its records, the registry and its images, and the application infrastructure. Back up records separately if needed. After recreation, republish the image, initialize or restore the database, reconfigure any identities referring to previous resource IDs, and reapply the Kubernetes resources. Key Vault purge protection retains deleted vault contents for the retention period; the provider is configured not to purge it automatically. Review restore/name-reuse behavior before reusing a deleted vault name.

## Checking this configuration

This configuration targets Terraform 1.6 or newer below 2.0, with the AzureRM provider constrained to the 4.81 series and the provider selections pinned in `.terraform.lock.hcl`.

Run the strict scanner below and resolve findings before publishing a change. Do not remove a security setting to make a finding disappear. A successful `terraform validate` only checks configuration consistency; it does not prove security, quota availability, or runtime behavior.

```bash
trivy config --severity HIGH,CRITICAL --exit-code 1 .
```

References checked for this starter:

- [AzureRM 4.81 AKS resource schema](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/kubernetes_cluster.html.markdown)
- [AzureRM 4.81 ACR resource schema](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/container_registry.html.markdown)
- [AzureRM 4.81 PostgreSQL resource schema](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/postgresql_flexible_server.html.markdown)
- [AzureRM 4.81 Key Vault resource schema](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/key_vault.html.markdown)
- [Current AKS system-node requirements](https://learn.microsoft.com/en-us/azure/aks/use-system-pools)
- [AKS workload identity and Key Vault CSI](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-identity-access)
- [Key Vault network controls](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security)
- [AKS API authorized IP ranges](https://learn.microsoft.com/en-us/azure/aks/api-server-authorized-ip-ranges)
- [AzureRM state backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)
