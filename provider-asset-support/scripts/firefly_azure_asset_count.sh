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

set -uo pipefail

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
declare -A MAP=(
  ["microsoft.apimanagement/service"]="azurerm_api_management"
  ["microsoft.appconfiguration/configurationstores"]="azurerm_app_configuration"
  ["microsoft.network/applicationgateways"]="azurerm_application_gateway"
  ["microsoft.insights/components"]="azurerm_application_insights"
  ["microsoft.network/applicationsecuritygroups"]="azurerm_application_security_group"
  ["microsoft.automation/automationaccounts"]="azurerm_automation_account"
  ["microsoft.cdn/profiles"]="azurerm_cdn_frontdoor_profile"
  ["microsoft.cognitiveservices/accounts"]="azurerm_cognitive_account"
  ["microsoft.app/containerapps"]="azurerm_container_app"
  ["microsoft.app/managedenvironments"]="azurerm_container_app_environment"
  ["microsoft.containerinstance/containergroups"]="azurerm_container_group"
  ["microsoft.containerregistry/registries"]="azurerm_container_registry"
  ["microsoft.documentdb/databaseaccounts"]="azurerm_cosmosdb_account"
  ["microsoft.datafactory/factories"]="azurerm_data_factory"
  ["microsoft.databricks/workspaces"]="azurerm_databricks_workspace"
  ["microsoft.eventgrid/systemtopics"]="azurerm_eventgrid_system_topic"
  ["microsoft.eventhub/namespaces"]="azurerm_eventhub_namespace"
  ["microsoft.devices/iothubs"]="azurerm_iothub"
  ["microsoft.keyvault/vaults"]="azurerm_key_vault"
  ["microsoft.containerservice/managedclusters"]="azurerm_kubernetes_cluster"
  ["microsoft.kusto/clusters"]="azurerm_kusto_cluster"
  ["microsoft.network/loadbalancers"]="azurerm_lb"
  ["microsoft.compute/virtualmachines"]="azurerm_linux_virtual_machine"
  ["microsoft.compute/virtualmachinescalesets"]="azurerm_virtual_machine_scale_set"
  ["microsoft.web/sites"]="azurerm_linux_web_app"
  ["microsoft.operationalinsights/workspaces"]="azurerm_log_analytics_workspace"
  ["microsoft.operationsmanagement/solutions"]="azurerm_log_analytics_solution"
  ["microsoft.logic/workflows"]="azurerm_logic_app_workflow"
  ["microsoft.machinelearningservices/workspaces"]="azurerm_machine_learning_workspace"
  ["microsoft.compute/disks"]="azurerm_managed_disk"
  ["microsoft.maps/accounts"]="azurerm_maps_account"
  ["microsoft.insights/actiongroups"]="azurerm_monitor_action_group"
  ["microsoft.insights/activitylogalerts"]="azurerm_monitor_activity_log_alert"
  ["microsoft.insights/autoscalesettings"]="azurerm_monitor_autoscale_setting"
  ["microsoft.insights/metricalerts"]="azurerm_monitor_metric_alert"
  ["microsoft.insights/scheduledqueryrules"]="azurerm_monitor_scheduled_query_rules_alert_v2"
  ["microsoft.insights/privatelinkscopes"]="azurerm_monitor_private_link_scope"
  ["microsoft.sql/servers"]="azurerm_mssql_server"
  ["microsoft.sql/managedinstances"]="azurerm_mssql_managed_instance"
  ["microsoft.sqlvirtualmachine/sqlvirtualmachines"]="azurerm_mssql_virtual_machine"
  ["microsoft.network/natgateways"]="azurerm_nat_gateway"
  ["microsoft.network/networkinterfaces"]="azurerm_network_interface"
  ["microsoft.network/networksecuritygroups"]="azurerm_network_security_group"
  ["microsoft.authorization/policydefinitions"]="azurerm_policy_definition"
  ["microsoft.dbforpostgresql/flexibleservers"]="azurerm_postgresql_flexible_server"
  ["microsoft.dbforpostgresql/servers"]="azurerm_postgresql_server"
  ["microsoft.network/privatednszones"]="azurerm_private_dns_zone"
  ["microsoft.network/privateendpoints"]="azurerm_private_endpoint"
  ["microsoft.network/publicipaddresses"]="azurerm_public_ip"
  ["microsoft.cache/redis"]="azurerm_redis_cache"
  ["microsoft.network/routetables"]="azurerm_route_table"
  ["microsoft.search/searchservices"]="azurerm_search_service"
  ["microsoft.web/serverfarms"]="azurerm_service_plan"
  ["microsoft.servicebus/namespaces"]="azurerm_servicebus_namespace"
  ["microsoft.storage/storageaccounts"]="azurerm_storage_account"
  ["microsoft.streamanalytics/streamingjobs"]="azurerm_stream_analytics_job"
  ["microsoft.network/trafficmanagerprofiles"]="azurerm_traffic_manager_profile"
  ["microsoft.managedidentity/userassignedidentities"]="azurerm_user_assigned_identity"
  ["microsoft.network/virtualnetworks"]="azurerm_virtual_network"
  ["microsoft.network/virtualnetworkgateways"]="azurerm_virtual_network_gateway"
  ["microsoft.network/applicationgatewaywebapplicationfirewallpolicies"]="azurerm_web_application_firewall_policy"
)

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

declare -A COUNTS
while IFS='|' read -r atype acount; do
  [[ -z "$atype" ]] && continue
  COUNTS["$atype"]=$acount
done <<< "$(echo "$RAW" | jq -r '.data[] | "\(.type)|\(.count_)"')"

# Resource groups live in a separate Resource Graph table.
RG_COUNT=$(az graph query "${SCOPE_ARGS[@]}" \
             -q "ResourceContainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | summarize count()" \
             -o json 2>/dev/null | jq -r '.data[0].count_ // 0')
if [[ "${RG_COUNT:-0}" -gt 0 ]]; then
  COUNTS["microsoft.resources/subscriptions/resourcegroups"]=$RG_COUNT
  MAP["microsoft.resources/subscriptions/resourcegroups"]="azurerm_resource_group"
fi

# ------------------------- report -------------------------
TOTAL=0
declare -A UNMAPPED
echo ""
echo "------------------------------------------------------------"
printf "%-58s %10s\n" "Firefly-supported Terraform type" "Count"
echo "------------------------------------------------------------"
echo "terraform_type,arm_type,count" > "$OUT_CSV"

for arm_type in $(echo "${!COUNTS[@]}" | tr ' ' '\n' | sort); do
  tf_type="${MAP[$arm_type]:-}"
  count=${COUNTS[$arm_type]}
  if [[ -n "$tf_type" ]]; then
    printf "%-58s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$arm_type,$count" >> "$OUT_CSV"
    TOTAL=$(( TOTAL + count ))
  else
    UNMAPPED[$arm_type]=$count
  fi
done

echo "------------------------------------------------------------"
printf "%-58s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ ${#UNMAPPED[@]} -gt 0 ]]; then
  echo ""
  echo "Other ARM types found in Resource Graph (not on the supported list / not mapped):"
  for t in $(echo "${!UNMAPPED[@]}" | tr ' ' '\n' | sort); do
    printf "  %-56s %10d\n" "$t" "${UNMAPPED[$t]}"
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
