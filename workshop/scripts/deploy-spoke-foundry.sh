#!/usr/bin/env bash
set -euo pipefail

AI_PROJECT_MANAGER_ROLE_ID="eadc314b-1a2d-4efa-be10-5d325db5065e"
KEY_VAULT_SECRETS_USER_ROLE_ID="4633458b-17de-408a-b874-0445c86b69e6"

log() {
  printf '\n==> %s\n' "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

azd_get_required() {
  local key="$1"
  local value
  value="$(azd env get-value "$key" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    printf 'Required azd environment value is missing: %s\nRun azd up/provision first, then rerun this script.\n' "$key" >&2
    exit 1
  fi
  printf '%s' "$value"
}

azd_get_optional() {
  azd env get-value "$1" 2>/dev/null || true
}

safe_name_part() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-*//; s/-*$//')"
  if [[ -z "$value" ]]; then
    value="citadel"
  fi
  printf '%s' "$value"
}

compact_name_part() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
  if [[ -z "$value" ]]; then
    value="citadel"
  fi
  printf '%s' "$value"
}

trim_trailing_hyphen() {
  sed 's/-*$//'
}

assign_role_if_missing() {
  local principal_id="$1"
  local principal_type="$2"
  local role_id="$3"
  local role_name="$4"
  local scope="$5"

  local assignment_id
  assignment_id="$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --role "$role_id" \
    --scope "$scope" \
    --all \
    --fill-principal-name false \
    --fill-role-definition-name false \
    --query '[0].id' \
    -o tsv 2>/dev/null || true)"

  if [[ -n "$assignment_id" ]]; then
    printf 'Role assignment already exists: %s\n' "$role_name"
    return
  fi

  az role assignment create \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type "$principal_type" \
    --role "$role_id" \
    --scope "$scope" \
    --only-show-errors \
    -o none
  printf 'Assigned role: %s\n' "$role_name"
}

require_command az
require_command azd

if ! az account show >/dev/null 2>&1; then
  printf 'Azure CLI is not logged in. Run az login, then rerun this script.\n' >&2
  exit 1
fi

if ! az cognitiveservices account project -h >/dev/null 2>&1; then
  printf 'This Azure CLI does not include az cognitiveservices account project. Update Azure CLI and rerun this script.\n' >&2
  exit 1
fi

governance_rg="$(azd_get_required AZURE_RESOURCE_GROUP)"
location="$(azd_get_required AZURE_LOCATION)"
azd_env_name="$(azd_get_optional AZURE_ENV_NAME)"
subscription_id="$(azd_get_optional AZURE_SUBSCRIPTION_ID)"

if [[ -n "$subscription_id" ]]; then
  az account set --subscription "$subscription_id"
else
  subscription_id="$(az account show --query id -o tsv)"
fi

spoke_resource_group_name="${SPOKE_RESOURCE_GROUP_NAME:-${governance_rg}-spoke}"
name_seed="$(safe_name_part "${azd_env_name:-$governance_rg}")"
compact_seed="$(compact_name_part "${azd_env_name:-$governance_rg}")"
subscription_suffix="$(printf '%s' "$subscription_id" | tr -d '-' | cut -c1-8)"

default_foundry_name="$(printf 'aif-%s-%s' "$name_seed" "$subscription_suffix" | cut -c1-64 | trim_trailing_hyphen)"
default_key_vault_name="$(printf 'kv%s%s' "$compact_seed" "$subscription_suffix" | cut -c1-24)"

foundry_account_name="${FOUNDRY_ACCOUNT_NAME:-$default_foundry_name}"
foundry_project_name="${FOUNDRY_PROJECT_NAME:-citadel-agents-project}"
key_vault_name="${KEY_VAULT_NAME:-$default_key_vault_name}"
key_vault_enable_purge_protection="${KEY_VAULT_ENABLE_PURGE_PROTECTION:-false}"
current_user_object_id="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"

if [[ -z "$current_user_object_id" ]]; then
  printf 'Could not resolve the signed-in user object ID. This script expects an interactive user login.\n' >&2
  exit 1
fi

log "Creating spoke resource group"
az group create \
  --name "$spoke_resource_group_name" \
  --location "$location" \
  --tags "azd-env-name=${azd_env_name:-unknown}" "workload=citadel-spoke" \
  -o none

log "Creating Azure AI Foundry account"
if ! az cognitiveservices account show --name "$foundry_account_name" --resource-group "$spoke_resource_group_name" >/dev/null 2>&1; then
  az cognitiveservices account create \
    --name "$foundry_account_name" \
    --resource-group "$spoke_resource_group_name" \
    --location "$location" \
    --kind AIServices \
    --sku S0 \
    --assign-identity \
    --custom-domain "$foundry_account_name" \
    --allow-project-management true \
    --yes \
    --tags "azd-env-name=${azd_env_name:-unknown}" "workload=citadel-spoke" \
    -o none
else
  printf 'Foundry account already exists: %s\n' "$foundry_account_name"
fi

foundry_account_id="$(az cognitiveservices account show \
  --name "$foundry_account_name" \
  --resource-group "$spoke_resource_group_name" \
  --query id \
  -o tsv)"

az rest \
  --method patch \
  --uri "https://management.azure.com${foundry_account_id}?api-version=2025-06-01" \
  --headers 'Content-Type=application/json' \
  --body '{"properties":{"allowProjectManagement":true,"disableLocalAuth":true,"publicNetworkAccess":"Enabled","networkAcls":{"defaultAction":"Allow","ipRules":[],"virtualNetworkRules":[]}}}' \
  -o none

log "Creating Azure AI Foundry project"
if ! az cognitiveservices account project show \
  --name "$foundry_account_name" \
  --resource-group "$spoke_resource_group_name" \
  --project-name "$foundry_project_name" >/dev/null 2>&1; then
  az cognitiveservices account project create \
    --name "$foundry_account_name" \
    --resource-group "$spoke_resource_group_name" \
    --project-name "$foundry_project_name" \
    --location "$location" \
    --assign-identity \
    --display-name "$foundry_project_name" \
    --description 'Citadel workshop project for Foundry Agents.' \
    -o none
else
  printf 'Foundry project already exists: %s\n' "$foundry_project_name"
fi

log "Creating Key Vault"
if ! az keyvault show --name "$key_vault_name" --resource-group "$spoke_resource_group_name" >/dev/null 2>&1; then
  key_vault_create_args=(
    --name "$key_vault_name" \
    --resource-group "$spoke_resource_group_name" \
    --location "$location" \
    --sku standard \
    --enable-rbac-authorization true \
    --public-network-access Enabled \
    --default-action Allow \
    --bypass AzureServices \
    --tags "azd-env-name=${azd_env_name:-unknown}" "workload=citadel-spoke" \
    -o none
  )
  case "$key_vault_enable_purge_protection" in
    true|TRUE|True)
      key_vault_create_args+=(--enable-purge-protection true)
      ;;
  esac
  az keyvault create "${key_vault_create_args[@]}"
else
  printf 'Key Vault already exists: %s\n' "$key_vault_name"
fi

existing_key_vault_purge_protection="$(az keyvault show \
  --name "$key_vault_name" \
  --resource-group "$spoke_resource_group_name" \
  --query 'properties.enablePurgeProtection' \
  -o tsv)"

if [[ "$existing_key_vault_purge_protection" == "true" ]]; then
  printf 'Warning: Key Vault purge protection is enabled and cannot be disabled. Immediate purge will not be available for this vault.\n' >&2
fi

key_vault_id="$(az keyvault show \
  --name "$key_vault_name" \
  --resource-group "$spoke_resource_group_name" \
  --query id \
  -o tsv)"

log "Assigning RBAC roles to the signed-in user"
assign_role_if_missing "$current_user_object_id" User "$AI_PROJECT_MANAGER_ROLE_ID" "Azure AI Project Manager" "$foundry_account_id"
assign_role_if_missing "$current_user_object_id" User "$KEY_VAULT_SECRETS_USER_ROLE_ID" "Key Vault Secrets User" "$key_vault_id"

log "Saving spoke resource values to azd environment"
azd env set SPOKE_RESOURCE_GROUP "$spoke_resource_group_name" >/dev/null
azd env set SPOKE_AI_FOUNDRY_ACCOUNT_NAME "$foundry_account_name" >/dev/null
azd env set SPOKE_AI_FOUNDRY_PROJECT_NAME "$foundry_project_name" >/dev/null
azd env set SPOKE_KEY_VAULT_NAME "$key_vault_name" >/dev/null

cat <<EOF

Spoke resources are ready.
Resource group: $spoke_resource_group_name
Foundry account: $foundry_account_name
Foundry project: $foundry_project_name
Key Vault: $key_vault_name

After deleting these resources, purge soft-deleted names with:
az cognitiveservices account purge --name "$foundry_account_name" --resource-group "$spoke_resource_group_name" --location "$location"
az keyvault purge --name "$key_vault_name" --location "$location"
EOF
