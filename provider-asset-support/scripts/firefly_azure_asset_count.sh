#!/usr/bin/env bash
#
# =============================================================================
#  Firefly - Azure Supported Asset Count
# =============================================================================
#  Counts the resources in an Azure tenant / subscription(s) / management group
#  that match Firefly's supported Azure Terraform resource types, using
#  Azure Resource Graph.
#
#  READ-ONLY: this script only runs 'az graph query' (a read API).
#
#  HOW IT WORKS
#    1. Runs an Azure Resource Graph query grouping resources by type:
#         Resources | summarize count() by type
#       (plus one small query for resource groups).
#    2. Maps each ARM resource type to its Terraform resource type and keeps
#       only the ones on Firefly's supported list.
#    3. Prints a per-type breakdown + grand total, and writes a CSV.
#
#  REQUIREMENTS
#    - az CLI (authenticated: 'az login'), plus jq
#    - The resource-graph extension (the script installs it automatically if
#      missing: 'az extension add --name resource-graph').
#    - Permissions: Reader on the subscriptions / management group you scope to.
#      Resource Graph returns only resources the signed-in identity can read.
#
#  USAGE
#    ./firefly_azure_asset_count.sh                     # all accessible subscriptions
#    ./firefly_azure_asset_count.sh -s SUB_ID           # one subscription (repeatable)
#    ./firefly_azure_asset_count.sh -s SUB1 -s SUB2     # several subscriptions
#    ./firefly_azure_asset_count.sh -m MG_NAME          # a management group (recursive)
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}", which SCOPE_ARGS hits
# any time -s/-m isn't passed. Every scalar var below has an explicit default.

SUBS=()
MG=""
OUT_CSV="firefly_azure_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "s:m:h" opt; do
  case $opt in
    s) SUBS+=("$OPTARG") ;;
    m) MG="$OPTARG" ;;
    h) grep '^#' "$0" | head -35; exit 0 ;;
    *) exit 1 ;;
  esac
done

command -v az >/dev/null || { echo "ERROR: az CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found";     exit 1; }

# Ensure the Resource Graph extension is available (quiet, idempotent).
if ! az extension show --name resource-graph >/dev/null 2>&1; then
  echo "Installing Azure CLI 'resource-graph' extension..."
  az extension add --name resource-graph >/dev/null 2>&1 \
    || { echo "ERROR: could not install the resource-graph extension."; exit 1; }
fi

# Scope arguments shared by every query.
SCOPE_ARGS=()
SCOPE_DESC="all accessible subscriptions"
if [[ -n "$MG" ]]; then
  SCOPE_ARGS=(--management-groups "$MG")
  SCOPE_DESC="management group '$MG'"
elif [[ ${#SUBS[@]} -gt 0 ]]; then
  SCOPE_ARGS=(--subscriptions "${SUBS[@]}")
  SCOPE_DESC="subscriptions: ${SUBS[*]}"
fi

# -----------------------------------------------------------------------------
# ARM resource type (lowercase, as returned by Resource Graph) -> Firefly-
# supported Terraform resource type.
#
# Only TOP-LEVEL ARM types that Resource Graph returns as discrete rows are
# listed. Child/config resources (NSG rules, subnets, LB rules, VM extensions,
# Cosmos/SQL databases, Service Bus queues/topics, Key Vault secrets, etc.) and
# control-plane records in other Resource Graph tables (role assignments) are
# not discrete rows here, so they are not counted - see the note at the end.
#
# Where several Terraform types share one ARM type (Linux/Windows VMs and VMSS;
# web vs function apps under microsoft.web/sites), the ARM type is mapped to one
# representative Terraform type; the OS/kind split is not distinguished.
# -----------------------------------------------------------------------------
MAP_KEYS=(
  "microsoft.apimanagement/service"
  "microsoft.appconfiguration/configurationstores"
  "microsoft.network/applicationgateways"
  "microsoft.insights/components"
  "microsoft.network/applicationsecuritygroups"
  "microsoft.automation/automationaccounts"
  "microsoft.cdn/profiles"
  "microsoft.cognitiveservices/accounts"
  "microsoft.app/containerapps"
  "microsoft.app/managedenvironments"
  "microsoft.containerinstance/containergroups"
  "microsoft.containerregistry/registries"
  "microsoft.documentdb/databaseaccounts"
  "microsoft.datafactory/factories"
  "microsoft.databricks/workspaces"
  "microsoft.eventgrid/systemtopics"
  "microsoft.eventhub/namespaces"
  "microsoft.devices/iothubs"
  "microsoft.keyvault/vaults"
  "microsoft.containerservice/managedclusters"
  "microsoft.kusto/clusters"
  "microsoft.network/loadbalancers"
  "microsoft.compute/virtualmachines"
  "microsoft.compute/virtualmachinescalesets"
  "microsoft.web/sites"
  "microsoft.operationalinsights/workspaces"
  "microsoft.operationsmanagement/solutions"
  "microsoft.logic/workflows"
  "microsoft.machinelearningservices/workspaces"
  "microsoft.compute/disks"
  "microsoft.maps/accounts"
  "microsoft.insights/actiongroups"
  "microsoft.insights/activitylogalerts"
  "microsoft.insights/autoscalesettings"
  "microsoft.insights/metricalerts"
  "microsoft.insights/scheduledqueryrules"
  "microsoft.insights/privatelinkscopes"
  "microsoft.sql/servers"
  "microsoft.sql/managedinstances"
  "microsoft.sqlvirtualmachine/sqlvirtualmachines"
  "microsoft.network/natgateways"
  "microsoft.network/networkinterfaces"
  "microsoft.network/networksecuritygroups"
  "microsoft.authorization/policydefinitions"
  "microsoft.dbforpostgresql/flexibleservers"
  "microsoft.dbforpostgresql/servers"
  "microsoft.network/privatednszones"
  "microsoft.network/privateendpoints"
  "microsoft.network/publicipaddresses"
  "microsoft.cache/redis"
  "microsoft.network/routetables"
  "microsoft.search/searchservices"
  "microsoft.web/serverfarms"
  "microsoft.servicebus/namespaces"
  "microsoft.storage/storageaccounts"
  "microsoft.streamanalytics/streamingjobs"
  "microsoft.network/trafficmanagerprofiles"
  "microsoft.managedidentity/userassignedidentities"
  "microsoft.network/virtualnetworks"
  "microsoft.network/virtualnetworkgateways"
  "microsoft.network/applicationgatewaywebapplicationfirewallpolicies"
)

MAP_VALS=(
  "azurerm_api_management"
  "azurerm_app_configuration"
  "azurerm_application_gateway"
  "azurerm_application_insights"
  "azurerm_application_security_group"
  "azurerm_automation_account"
  "azurerm_cdn_frontdoor_profile"
  "azurerm_cognitive_account"
  "azurerm_container_app"
  "azurerm_container_app_environment"
  "azurerm_container_group"
  "azurerm_container_registry"
  "azurerm_cosmosdb_account"
  "azurerm_data_factory"
  "azurerm_databricks_workspace"
  "azurerm_eventgrid_system_topic"
  "azurerm_eventhub_namespace"
  "azurerm_iothub"
  "azurerm_key_vault"
  "azurerm_kubernetes_cluster"
  "azurerm_kusto_cluster"
  "azurerm_lb"
  "azurerm_linux_virtual_machine"
  "azurerm_virtual_machine_scale_set"
  "azurerm_linux_web_app"
  "azurerm_log_analytics_workspace"
  "azurerm_log_analytics_solution"
  "azurerm_logic_app_workflow"
  "azurerm_machine_learning_workspace"
  "azurerm_managed_disk"
  "azurerm_maps_account"
  "azurerm_monitor_action_group"
  "azurerm_monitor_activity_log_alert"
  "azurerm_monitor_autoscale_setting"
  "azurerm_monitor_metric_alert"
  "azurerm_monitor_scheduled_query_rules_alert_v2"
  "azurerm_monitor_private_link_scope"
  "azurerm_mssql_server"
  "azurerm_mssql_managed_instance"
  "azurerm_mssql_virtual_machine"
  "azurerm_nat_gateway"
  "azurerm_network_interface"
  "azurerm_network_security_group"
  "azurerm_policy_definition"
  "azurerm_postgresql_flexible_server"
  "azurerm_postgresql_server"
  "azurerm_private_dns_zone"
  "azurerm_private_endpoint"
  "azurerm_public_ip"
  "azurerm_redis_cache"
  "azurerm_route_table"
  "azurerm_search_service"
  "azurerm_service_plan"
  "azurerm_servicebus_namespace"
  "azurerm_storage_account"
  "azurerm_stream_analytics_job"
  "azurerm_traffic_manager_profile"
  "azurerm_user_assigned_identity"
  "azurerm_virtual_network"
  "azurerm_virtual_network_gateway"
  "azurerm_web_application_firewall_policy"
)

# Bash 3.2 (macOS default) has no associative arrays, so MAP is stored as two
# parallel indexed arrays and looked up by linear scan.
map_lookup() {
  local key="$1" i
  for i in "${!MAP_KEYS[@]}"; do
    if [[ "${MAP_KEYS[$i]}" == "$key" ]]; then
      printf '%s' "${MAP_VALS[$i]}"
      return 0
    fi
  done
  return 1
}

map_set() { # map_set <key> <val> - used for the resource-group entry added at runtime
  local key="$1" val="$2" i
  for i in "${!MAP_KEYS[@]}"; do
    if [[ "${MAP_KEYS[$i]}" == "$key" ]]; then
      MAP_VALS[$i]=$val
      return
    fi
  done
  MAP_KEYS+=("$key")
  MAP_VALS+=("$val")
}

echo "============================================================"
echo " Firefly - Azure Supported Asset Count"
echo " Scope: $SCOPE_DESC"
echo " Date:  $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "============================================================"
echo "Querying Azure Resource Graph (this can take a minute)..."

# Resource Graph 'summarize count() by type' returns one row per distinct type,
# so the result set is small (< 1000 rows) and fits in a single page.
RAW=$(az graph query "${SCOPE_ARGS[@]}" \
        -q "Resources | summarize count() by type" \
        --first 1000 -o json 2>/tmp/az_asset_err.log)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Azure Resource Graph query failed:"
  cat /tmp/az_asset_err.log
  echo ""
  echo "Check that you are logged in ('az login') and have Reader on the scope."
  exit 1
fi

# Bash 3.2 (macOS default) has no associative arrays, so COUNTS/UNMAPPED are
# each stored as two parallel indexed arrays, same approach as MAP above.
COUNT_KEYS=(); COUNT_VALS=()

count_set() { # count_set <key> <val>
  local key="$1" val="$2" i
  for i in "${!COUNT_KEYS[@]}"; do
    if [[ "${COUNT_KEYS[$i]}" == "$key" ]]; then
      COUNT_VALS[$i]=$val
      return
    fi
  done
  COUNT_KEYS+=("$key")
  COUNT_VALS+=("$val")
}

count_get() { # count_get <key> - prints its count, or 0
  local key="$1" i
  for i in "${!COUNT_KEYS[@]}"; do
    [[ "${COUNT_KEYS[$i]}" == "$key" ]] && { printf '%s' "${COUNT_VALS[$i]}"; return; }
  done
  printf '0'
}

while IFS='|' read -r atype acount; do
  [[ -z "$atype" ]] && continue
  count_set "$atype" "$acount"
done <<< "$(echo "$RAW" | jq -r '.data[] | "\(.type)|\(.count_)"')"

# Resource groups live in a separate Resource Graph table.
RG_COUNT=$(az graph query "${SCOPE_ARGS[@]}" \
             -q "ResourceContainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | summarize count()" \
             -o json 2>/dev/null | jq -r '.data[0].count_ // 0')
if [[ "${RG_COUNT:-0}" -gt 0 ]]; then
  count_set "microsoft.resources/subscriptions/resourcegroups" "$RG_COUNT"
  map_set "microsoft.resources/subscriptions/resourcegroups" "azurerm_resource_group"
fi

# ------------------------- report -------------------------
TOTAL=0
UNMAPPED_KEYS=(); UNMAPPED_VALS=()

unmapped_set() { # unmapped_set <key> <count>
  local key="$1" val="$2" i
  for i in "${!UNMAPPED_KEYS[@]}"; do
    if [[ "${UNMAPPED_KEYS[$i]}" == "$key" ]]; then
      UNMAPPED_VALS[$i]=$val
      return
    fi
  done
  UNMAPPED_KEYS+=("$key")
  UNMAPPED_VALS+=("$val")
}

unmapped_get() { # unmapped_get <key> - prints its count, or 0
  local key="$1" i
  for i in "${!UNMAPPED_KEYS[@]}"; do
    [[ "${UNMAPPED_KEYS[$i]}" == "$key" ]] && { printf '%s' "${UNMAPPED_VALS[$i]}"; return; }
  done
  printf '0'
}

echo ""
echo "------------------------------------------------------------"
printf "%-58s %10s\n" "Firefly-supported Terraform type" "Count"
echo "------------------------------------------------------------"
echo "terraform_type,arm_type,count" > "$OUT_CSV"

for arm_type in $(printf '%s\n' "${COUNT_KEYS[@]}" | sort); do
  tf_type=$(map_lookup "$arm_type") || tf_type=""
  count=$(count_get "$arm_type")
  if [[ -n "$tf_type" ]]; then
    printf "%-58s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$arm_type,$count" >> "$OUT_CSV"
    TOTAL=$(( TOTAL + count ))
  else
    unmapped_set "$arm_type" "$count"
  fi
done

echo "------------------------------------------------------------"
printf "%-58s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ ${#UNMAPPED_KEYS[@]} -gt 0 ]]; then
  echo ""
  echo "Other ARM types found in Resource Graph (not on the supported list / not mapped):"
  for t in $(printf '%s\n' "${UNMAPPED_KEYS[@]}" | sort); do
    printf "  %-56s %10d\n" "$t" "$(unmapped_get "$t")"
  done
fi

echo ""
echo "NOTE: Counts come from Azure Resource Graph, which returns top-level ARM"
echo "      resources only. Child/config resources Firefly also codifies"
echo "      (subnets, NSG rules, LB rules, VM extensions, Cosmos/SQL databases,"
echo "      Service Bus queues/topics, Key Vault secrets, role assignments) are"
echo "      not discrete rows and are not counted here. Linux/Windows VM and"
echo "      web/function-app variants share one ARM type and are counted"
echo "      together. Treat this total as a LOWER BOUND of Firefly-supported"
echo "      assets."
echo ""
echo "CSV written to: $OUT_CSV"
