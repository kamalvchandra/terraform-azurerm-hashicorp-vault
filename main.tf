resource "random_string"  "kv" {
  length  = 3
  upper   = false
  special = false
}

resource "azurerm_key_vault" "kv" {
  name                 = "${var.names.product_group}${var.names.subscription_type}hcv${random_string.kv.result}" 
  location             = var.location
  resource_group_name  = var.resource_group_name
  tenant_id            = data.azurerm_client_config.current.tenant_id

  sku_name = "standard"

  purge_protection_enabled = false
  soft_delete_enabled      = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = merge(var.tags, {
           "purpose"     = "HashiCorp Vault initialization info"
         })
}

resource "azurerm_key_vault_access_policy" "manager" {
  for_each = local.key_vault_managers

  key_vault_id = azurerm_key_vault.kv.id

  tenant_id = each.value.tenant_id
  object_id = each.value.object_id

  key_permissions = [
    "create",
    "delete",
    "get",
    "list",
    "update",
  ]

  secret_permissions = [
    "delete",
    "get",
    "list",
    "set",
  ]

}

resource "azurerm_key_vault_key" "generated" {
  depends_on   = [azurerm_key_vault_access_policy.manager]
  name         = "hashicorp-vault-key"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  tags                 = var.tags
}

resource "azurerm_key_vault_secret" "vault_init" {
  depends_on   = [azurerm_key_vault_access_policy.manager]
  name         = "hashicorp-vault-init"
  value        = ""
  key_vault_id = azurerm_key_vault.kv.id

  tags           = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_user_assigned_identity" "vault" {
  name                 = "${var.names.product_group}-${var.names.subscription_type}-vault"
  location             = var.location
  resource_group_name  = var.resource_group_name
  tags                 = var.tags
}

resource "azurerm_user_assigned_identity" "vault_init" {
  name                 = "${var.names.product_group}-${var.names.subscription_type}-vault-init"
  location             = var.location
  resource_group_name  = var.resource_group_name
  tags                 = var.tags
}

resource "azurerm_key_vault_access_policy" "vault" {
  depends_on   = [azurerm_user_assigned_identity.vault]
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.vault.principal_id

  key_permissions = [
      "get",
      "unwrapKey",
      "wrapKey",
  ]
}

resource "azurerm_key_vault_access_policy" "vault_init" {
  depends_on   = [azurerm_user_assigned_identity.vault]
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.vault_init.principal_id

  secret_permissions = [
      "get",
      "set",
  ]
}

module "vault_identity" {
  source = "git@github.com:Azure-Terraform/terraform-azurerm-kubernetes.git//aad-pod-identity/identity?ref=v1.1.0"

  identity_name        = azurerm_user_assigned_identity.vault.name
  identity_client_id   = azurerm_user_assigned_identity.vault.client_id
  identity_resource_id = azurerm_user_assigned_identity.vault.id
}

module "vault_init_identity" {
  source = "git@github.com:Azure-Terraform/terraform-azurerm-kubernetes.git//aad-pod-identity/identity?ref=v1.1.0"

  identity_name        = azurerm_user_assigned_identity.vault_init.name
  identity_client_id   = azurerm_user_assigned_identity.vault_init.client_id
  identity_resource_id = azurerm_user_assigned_identity.vault_init.id
}

resource "helm_release" "vault" {
  depends_on = [module.vault_identity]

  name      = "vault"
  repository                       = "https://helm.releases.hashicorp.com"
  chart                            = "vault"
  version                          = "0.19.0"

  namespace        = var.kubernetes_namespace
  create_namespace = true

  values = [
    templatefile("${path.module}/config/vault_config.yaml.tmpl", {
      node_selector             = (length(var.kubernetes_node_selector) > 0 ? indent(4, chomp(yamlencode(var.kubernetes_node_selector))) : "")
      tenant_id                = data.azurerm_client_config.current.tenant_id
      vault_name               = azurerm_key_vault.kv.name
      key_name                 = azurerm_key_vault_key.generated.name
      pod_identity             = azurerm_user_assigned_identity.vault.name
      vault_version            = var.vault_version
      ingress_enabled          = var.vault_ingress_enabled
      ingress_hostname         = var.vault_ingress_hostname
      ingress_tls_secret_name  = var.vault_ingress_tls_secret_name
      injector_enabled         = var.vault_agent_injector_enabled
      injector_version         = var.vault_agent_injector_version
      injector_sidecar_version = (var.vault_agent_injector_sidecar_version == "" ? var.vault_version : var.vault_agent_injector_sidecar_version)
      enable_ha                = var.vault_enable_ha
      enable_raft_backend      = var.vault_enable_raft_backend
      enable_ui                = var.vault_enable_ui
      enable_data_storage      = var.vault_enable_data_storage
      data_storage_class       = var.vault_data_storage_class
      data_storage_size        = var.vault_data_storage_size
      enable_audit_storage     = var.vault_enable_audit_storage
      audit_storage_class      = var.vault_data_storage_class
      audit_storage_size       = var.vault_data_storage_size
      private_docker_repo      = var.private_docker_repo
      image_pull_secret        = var.image_pull_secret
    }),
    var.additional_yaml_config
  ]
}

resource "helm_release" "vault_rbac" {
  depends_on = [helm_release.vault]
  name       = "vault-rbac"
  chart      = "${path.module}/charts/rbac"
  namespace  = var.kubernetes_namespace
}

resource "helm_release" "vault_init" {
  depends_on = [module.vault_init_identity,helm_release.vault]
  name       = "vault-init"
  chart      = "${path.module}/charts/init"

  namespace  = var.kubernetes_namespace

  values= [yamlencode({
    "azureKeyVaultSecretTags" = base64encode(jsonencode(var.tags)),
    "azureKeyVaultSecretUrl"  = "${azurerm_key_vault.kv.vault_uri}secrets/${azurerm_key_vault_secret.vault_init.name}",
    "identityName"            = azurerm_user_assigned_identity.vault_init.name
    "nodeSelector"            = (length(var.kubernetes_node_selector) > 0 ? chomp(yamlencode(var.kubernetes_node_selector)) : "")
    "image_pull_secret"       = var.image_pull_secret
    "private_docker_repo"     = var.private_docker_repo
  })]
}
