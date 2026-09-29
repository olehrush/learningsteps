output "subscription_id" {
  value = var.subscription_id
}

output "resource_group" {
  value = azurerm_resource_group.project.name
}

output "resource_group_id" {
  value = azurerm_resource_group.project.id
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.project.name
}

output "aks_id" {
  value = azurerm_kubernetes_cluster.project.id
}

output "acr_name" {
  value = azurerm_container_registry.project.name
}

output "acr_id" {
  value = azurerm_container_registry.project.id
}

output "acr_login_server" {
  value = azurerm_container_registry.project.login_server
}

output "key_vault_name" {
  value = azurerm_key_vault.project.name
}

output "key_vault_id" {
  value = azurerm_key_vault.project.id
}

output "workload_client_id" {
  value = azurerm_user_assigned_identity.app.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.project.fqdn
}

output "database_name" {
  value = local.database_name
}

output "app_username" {
  value = local.app_username
}

output "app_secret_name" {
  value = azurerm_key_vault_secret.app_url.name
}

output "admin_secret_name" {
  value = azurerm_key_vault_secret.admin_url.name
}
