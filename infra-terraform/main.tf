data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name            = "${var.prefix}-${random_string.suffix.result}"
  compact_name    = "${var.prefix}${random_string.suffix.result}"
  database_name   = "learning_journal"
  admin_username  = "lsadmin"
  app_username    = "learningsteps_app"
  namespace       = "learningsteps"
  service_account = "learningsteps-sa"
  # Both the API and schema-initialization containers use Debian CA certificates.
  tls_query = "sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt"
}

resource "azurerm_resource_group" "project" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "project" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.project.location
  resource_group_name = azurerm_resource_group.project.name
  address_space       = ["10.42.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.project.name
  virtual_network_name = azurerm_virtual_network.project.name
  address_prefixes     = ["10.42.1.0/24"]
  service_endpoints    = ["Microsoft.KeyVault"]
}

resource "azurerm_subnet" "database" {
  name                 = "snet-postgresql"
  resource_group_name  = azurerm_resource_group.project.name
  virtual_network_name = azurerm_virtual_network.project.name
  address_prefixes     = ["10.42.2.0/24"]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "postgresql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.name}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.project.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-vnet-link"
  resource_group_name   = azurerm_resource_group.project.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.project.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "id-aks-${local.name}"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "aks_network" {
  scope                            = azurerm_subnet.aks.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks_control_plane.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_kubernetes_cluster" "project" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.project.location
  resource_group_name = azurerm_resource_group.project.name
  dns_prefix          = "aks-${local.name}"
  api_server_authorized_ip_ranges = ["0.0.0.0/0"]

  # Standard means the regular AKS service here. The Free pricing tier has no uptime SLA.
  sku_tier                          = "Free"
  private_cluster_enabled           = false
  role_based_access_control_enabled = true
  local_account_disabled            = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  # Auto-upgrade disabled: 10 vCPU quota leaves no room for a surge node (risk accepted, see README)
  node_os_upgrade_channel = "Unmanaged"

  default_node_pool {
    name                        = "system"
    vm_size                     = var.aks_vm_size
    node_count                  = var.aks_node_count
    vnet_subnet_id              = azurerm_subnet.aks.id
    max_pods                    = 30
    os_disk_size_gb             = 64
    temporary_name_for_rotation = "systemtemp"

    upgrade_settings {
      max_surge = "1"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_control_plane.id]
  }

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # CI temporarily adds its current runner /32 and restores this baseline afterward.
 api_server_access_profile {
    authorized_ip_ranges = concat([var.operator_ipv4_cidr], var.aks_api_additional_cidrs)
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.43.0.0/16"
    dns_service_ip      = "10.43.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  tags       = var.tags
  depends_on = [azurerm_role_assignment.aks_network]
}

# The interactive operator bootstraps Kubernetes; CI receives separate, narrower roles.
resource "azurerm_role_assignment" "operator_cluster_user" {
  scope                = azurerm_kubernetes_cluster.project.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "operator_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.project.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_container_registry" "project" {
  name                          = "acr${local.compact_name}"
  resource_group_name           = azurerm_resource_group.project.name
  location                      = azurerm_resource_group.project.location
  sku                           = "Basic"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
  role_assignment_mode          = "LegacyRegistryPermissions"
  tags                          = var.tags
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.project.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.project.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "operator_acr_push" {
  scope                = azurerm_container_registry.project.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "admin" {
  length      = 40
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "app" {
  length      = 40
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "azurerm_postgresql_flexible_server" "project" {
  name                          = "pg-${local.name}"
  resource_group_name           = azurerm_resource_group.project.name
  location                      = azurerm_resource_group.project.location
  version                       = "16"
  delegated_subnet_id           = azurerm_subnet.database.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false
  administrator_login           = local.admin_username
  administrator_password        = random_password.admin.result
  storage_mb                    = 32768
  sku_name                      = var.postgres_sku
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  auto_grow_enabled             = true
  tags                          = var.tags

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = local.database_name
  server_id = azurerm_postgresql_flexible_server.project.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_configuration" "tls" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.project.id
  value     = "on"
}

resource "azurerm_key_vault" "project" {
  name                          = "kv-${local.name}"
  location                      = azurerm_resource_group.project.location
  resource_group_name           = azurerm_resource_group.project.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = true
  public_network_access_enabled = true

  network_acls {
    bypass                     = "None"
    default_action             = "Deny"
    ip_rules                   = [var.operator_ipv4_cidr]
    virtual_network_subnet_ids = [azurerm_subnet.aks.id]
  }

  tags = var.tags
}

# Contributor/Owner on the subscription is not a Key Vault data-plane secret role.
resource "azurerm_role_assignment" "operator_secret_writer" {
  scope                = azurerm_key_vault.project.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC propagates asynchronously. This delay reduces initial 403 failures;
# if propagation takes longer, verify the correct principal/IP and retry apply.
resource "time_sleep" "secret_role_propagation" {
  create_duration = "120s"
  triggers = {
    assignment = azurerm_role_assignment.operator_secret_writer.id
  }
  depends_on = [azurerm_role_assignment.operator_secret_writer]
}

resource "time_static" "secret_created" {}

resource "azurerm_key_vault_secret" "app_url" {
  name            = "DATABASE-URL"
  value           = "postgresql://${local.app_username}:${random_password.app.result}@${azurerm_postgresql_flexible_server.project.fqdn}:5432/${local.database_name}?${local.tls_query}"
  key_vault_id    = azurerm_key_vault.project.id
  content_type    = "PostgreSQL application connection URI; verify-full TLS"
  expiration_date = timeadd(time_static.secret_created.rfc3339, "2160h")
  tags            = var.tags
  depends_on      = [time_sleep.secret_role_propagation]
}

resource "azurerm_key_vault_secret" "admin_url" {
  name            = "DATABASE-ADMIN-URL"
  value           = "postgresql://${local.admin_username}:${random_password.admin.result}@${azurerm_postgresql_flexible_server.project.fqdn}:5432/${local.database_name}?${local.tls_query}"
  key_vault_id    = azurerm_key_vault.project.id
  content_type    = "PostgreSQL initialization connection URI; verify-full TLS"
  expiration_date = timeadd(time_static.secret_created.rfc3339, "2160h")
  tags            = var.tags
  depends_on      = [time_sleep.secret_role_propagation]
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-app-${local.name}"
  location            = azurerm_resource_group.project.location
  resource_group_name = azurerm_resource_group.project.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "app" {
  name                = "learningsteps-service-account"
  resource_group_name = azurerm_resource_group.project.name
  parent_id           = azurerm_user_assigned_identity.app.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.project.oidc_issuer_url
  subject             = "system:serviceaccount:${local.namespace}:${local.service_account}"
}

# The app can read ONLY its secret, not DATABASE-ADMIN-URL in the same vault.
resource "azurerm_role_assignment" "app_secret_reader" {
  scope                            = "${azurerm_key_vault.project.id}/secrets/${azurerm_key_vault_secret.app_url.name}"
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_user_assigned_identity.app.principal_id
  skip_service_principal_aad_check = true
}
