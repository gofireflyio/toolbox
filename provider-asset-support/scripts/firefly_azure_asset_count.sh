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
#    1. Runs Azure Resource Graph queries grouped by type:
#         - Resources                 (top-level + child ARM resources)
#         - Resources, expanded       (child config embedded in a parent:
#                                      subnets, NSG rules, LB rules, peerings...)
#         - ResourceContainers        (resource groups)
#         - AuthorizationResources    (role assignments)
#         - PolicyResources           (policy definitions/assignments/exemptions)
#         - RecoveryServicesResources (Azure Backup file shares/containers)
#         - DnsResources              (private DNS A records)
#    2. Maps each ARM resource type (or variant, e.g. Windows vs Linux VM) to
#       its Terraform resource type and keeps only Firefly-supported ones.
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
#    ./firefly_azure_asset_count.sh -v                  # also list types not countable here
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}", which SCOPE_ARGS hits
# any time -s/-m isn't passed. Every scalar var below has an explicit default.

SUBS=()
MG=""
VERBOSE=0
OUT_CSV="firefly_azure_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "s:m:vh" opt; do
  case $opt in
    s) SUBS+=("$OPTARG") ;;
    m) MG="$OPTARG" ;;
    v) VERBOSE=1 ;;
    h) awk '/^#/{print; next} {exit}' "$0"; exit 0 ;;
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

ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/az_asset_err.XXXXXX") || exit 1
trap 'rm -f "$ERR_LOG"' EXIT

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
# Count key -> Firefly-supported Terraform resource type.
#
# A count key is the lowercase ARM type returned by Resource Graph, optionally
# with a '#variant' suffix computed in the queries below, for ARM types that
# back several Terraform types (Linux vs Windows VMs/VMSS, web vs function vs
# Logic App Standard sites, AI Foundry hubs/projects, policy assignment scope).
# Keys ending in '#embedded' are child resources counted from their parent's
# properties (e.g. subnets inside a virtual network).
#
# Every Terraform type the script handles appears here or in NOT_COUNTABLE
# below; the biweekly sync (monitor/check_provider_pages.py) flags any newly
# supported type that appears in neither.
# -----------------------------------------------------------------------------
MAP_KEYS=(
  # --- Resources table: top-level ARM resources
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
  "microsoft.compute/virtualmachines#linux"
  "microsoft.compute/virtualmachines#windows"
  "microsoft.compute/virtualmachinescalesets#linux"
  "microsoft.compute/virtualmachinescalesets#windows"
  "microsoft.compute/virtualmachinescalesets"
  "microsoft.web/sites#linux-web"
  "microsoft.web/sites#windows-web"
  "microsoft.web/sites#linux-function"
  "microsoft.web/sites#windows-function"
  "microsoft.web/sites#logicapp"
  "microsoft.web/hostingenvironments"
  "microsoft.operationalinsights/workspaces"
  "microsoft.operationsmanagement/solutions"
  "microsoft.logic/workflows"
  "microsoft.machinelearningservices/workspaces"
  "microsoft.machinelearningservices/workspaces#hub"
  "microsoft.machinelearningservices/workspaces#project"
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
  "microsoft.network/frontdoorwebapplicationfirewallpolicies"
  # --- Resources table: child resources Resource Graph returns as rows
  "microsoft.cdn/profiles/endpoints"
  "microsoft.cdn/profiles/afdendpoints"
  "microsoft.compute/virtualmachines/extensions"
  "microsoft.sql/servers/databases"
  "microsoft.sql/servers/elasticpools"
  "microsoft.automation/automationaccounts/runbooks"
  # --- Resources table: child config embedded in the parent's properties
  "microsoft.network/virtualnetworks/subnets#embedded"
  "microsoft.network/virtualnetworks/subnets/nsgassociation#embedded"
  "microsoft.network/virtualnetworks/subnets/routetableassociation#embedded"
  "microsoft.network/virtualnetworks/virtualnetworkpeerings#embedded"
  "microsoft.network/networksecuritygroups/securityrules#embedded"
  "microsoft.network/loadbalancers/loadbalancingrules#embedded"
  "microsoft.network/loadbalancers/probes#embedded"
  "microsoft.network/loadbalancers/backendaddresspools#embedded"
  "microsoft.containerservice/managedclusters/agentpools#embedded"
  "microsoft.keyvault/vaults/accesspolicies#embedded"
  "microsoft.network/privateendpoints/asgassociation#embedded"
  "microsoft.storage/storageaccounts/networkrules#embedded"
  "microsoft.web/sites/vnetintegration#embedded"
  # --- Other Resource Graph tables
  "microsoft.resources/subscriptions/resourcegroups"
  "microsoft.authorization/roleassignments"
  "microsoft.authorization/policydefinitions"
  "microsoft.authorization/policyassignments#mg"
  "microsoft.authorization/policyassignments#subscription"
  "microsoft.authorization/policyassignments#resourcegroup"
  "microsoft.authorization/policyexemptions#resource"
  "microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers"
  "microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems"
  "microsoft.network/privatednszones/a"
)

MAP_VALS=(
  # --- Resources table: top-level ARM resources
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
  "azurerm_windows_virtual_machine"
  "azurerm_linux_virtual_machine_scale_set"
  "azurerm_windows_virtual_machine_scale_set"
  "azurerm_virtual_machine_scale_set"
  "azurerm_linux_web_app"
  "azurerm_windows_web_app"
  "azurerm_linux_function_app"
  "azurerm_windows_function_app"
  "azurerm_logic_app_standard"
  "azurerm_app_service_environment_v3"
  "azurerm_log_analytics_workspace"
  "azurerm_log_analytics_solution"
  "azurerm_logic_app_workflow"
  "azurerm_machine_learning_workspace"
  "azurerm_ai_foundry"
  "azurerm_ai_foundry_project"
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
  "azurerm_cdn_frontdoor_firewall_policy"
  # --- Resources table: child resources Resource Graph returns as rows
  "azurerm_cdn_endpoint"
  "azurerm_cdn_frontdoor_endpoint"
  "azurerm_virtual_machine_extension"
  "azurerm_mssql_database"
  "azurerm_mssql_elasticpool"
  "azurerm_automation_runbook"
  # --- Resources table: child config embedded in the parent's properties
  "azurerm_subnet"
  "azurerm_subnet_network_security_group_association"
  "azurerm_subnet_route_table_association"
  "azurerm_virtual_network_peering"
  "azurerm_network_security_rule"
  "azurerm_lb_rule"
  "azurerm_lb_probe"
  "azurerm_lb_backend_address_pool"
  "azurerm_kubernetes_cluster_node_pool"
  "azurerm_key_vault_access_policy"
  "azurerm_private_endpoint_application_security_group_association"
  "azurerm_storage_account_network_rules"
  "azurerm_app_service_virtual_network_swift_connection"
  # --- Other Resource Graph tables
  "azurerm_resource_group"
  "azurerm_role_assignment"
  "azurerm_policy_definition"
  "azurerm_management_group_policy_assignment"
  "azurerm_subscription_policy_assignment"
  "azurerm_resource_group_policy_assignment"
  "azurerm_resource_policy_exemption"
  "azurerm_backup_container_storage_account"
  "azurerm_backup_protected_file_share"
  "azurerm_private_dns_a_record"
)

# Firefly-supported types that Azure Resource Graph does not expose (data-plane
# objects, or child resources that are neither ARG rows nor embedded in their
# parent's properties). They cannot be counted here, so the total is a lower bound.
NOT_COUNTABLE=(
  "azurerm_app_configuration_key"
  "azurerm_cdn_frontdoor_custom_domain"
  "azurerm_cdn_frontdoor_origin"
  "azurerm_cdn_frontdoor_origin_group"
  "azurerm_cdn_frontdoor_route"
  "azurerm_cdn_frontdoor_rule"
  "azurerm_cdn_frontdoor_rule_set"
  "azurerm_cosmosdb_mongo_collection"
  "azurerm_cosmosdb_mongo_database"
  "azurerm_cosmosdb_sql_container"
  "azurerm_cosmosdb_sql_database"
  "azurerm_cosmosdb_sql_role_assignment"
  "azurerm_cosmosdb_table"
  "azurerm_eventhub"
  "azurerm_federated_identity_credential"
  "azurerm_key_vault_certificate"
  "azurerm_key_vault_secret"
  "azurerm_machine_learning_compute_instance"
  "azurerm_monitor_diagnostic_setting"
  "azurerm_monitor_private_link_scoped_service"
  "azurerm_mssql_database_extended_auditing_policy"
  "azurerm_mssql_server_extended_auditing_policy"
  "azurerm_pim_eligible_role_assignment"
  "azurerm_postgresql_flexible_server_configuration"
  "azurerm_postgresql_flexible_server_database"
  "azurerm_servicebus_queue"
  "azurerm_servicebus_queue_authorization_rule"
  "azurerm_servicebus_subscription"
  "azurerm_servicebus_subscription_rule"
  "azurerm_servicebus_topic"
  "azurerm_servicebus_topic_authorization_rule"
  "azurerm_storage_container"
  "azurerm_storage_queue"
  "azurerm_storage_share"
  "azurerm_storage_table"
)

# -----------------------------------------------------------------------------
# Resource Graph queries. Each returns rows of (type, count_) where 'type' is a
# count key from MAP_KEYS (anything unmapped is reported as "other").
# -----------------------------------------------------------------------------

# Top-level and child ARM resources, with variant suffixes where one ARM type
# backs several Terraform types. Built-in 'master' SQL databases are skipped.
Q_RESOURCES="Resources
| extend t = tolower(type), k = tolower(kind)
| where not(t == 'microsoft.sql/servers/databases' and name =~ 'master')
| extend key = case(
    t == 'microsoft.compute/virtualmachines',
      strcat(t, iff(tostring(properties.storageProfile.osDisk.osType) =~ 'windows', '#windows', '#linux')),
    t == 'microsoft.compute/virtualmachinescalesets',
      strcat(t, case(isnotnull(properties.virtualMachineProfile.osProfile.windowsConfiguration), '#windows',
                     isnotnull(properties.virtualMachineProfile.osProfile.linuxConfiguration), '#linux', '')),
    t == 'microsoft.web/sites',
      strcat(t, case(k contains 'workflowapp', '#logicapp',
                     k contains 'functionapp', iff(k contains 'linux', '#linux-function', '#windows-function'),
                     k contains 'linux', '#linux-web', '#windows-web')),
    t == 'microsoft.machinelearningservices/workspaces',
      strcat(t, case(k == 'hub', '#hub', k == 'project', '#project', '')),
    t)
| summarize count_ = count() by type = key"

# Child config embedded in a parent's properties, one sum per child type,
# unpivoted into (type, count_) rows.
Q_EMBEDDED="Resources
| where type in~ ('microsoft.network/virtualnetworks', 'microsoft.network/networksecuritygroups',
                  'microsoft.network/loadbalancers', 'microsoft.containerservice/managedclusters',
                  'microsoft.keyvault/vaults', 'microsoft.network/privateendpoints',
                  'microsoft.storage/storageaccounts', 'microsoft.web/sites')
| extend t = tolower(type)
| summarize
    peerings  = sumif(array_length(properties.virtualNetworkPeerings), t == 'microsoft.network/virtualnetworks'),
    nsgrules  = sumif(array_length(properties.securityRules), t == 'microsoft.network/networksecuritygroups'),
    lbrules   = sumif(array_length(properties.loadBalancingRules), t == 'microsoft.network/loadbalancers'),
    lbprobes  = sumif(array_length(properties.probes), t == 'microsoft.network/loadbalancers'),
    lbpools   = sumif(array_length(properties.backendAddressPools), t == 'microsoft.network/loadbalancers'),
    nodepools = sumif(array_length(properties.agentPoolProfiles) - 1, t == 'microsoft.containerservice/managedclusters'),
    kvpols    = sumif(array_length(properties.accessPolicies), t == 'microsoft.keyvault/vaults' and not(tobool(properties.enableRbacAuthorization))),
    peasgs    = sumif(array_length(properties.applicationSecurityGroups), t == 'microsoft.network/privateendpoints'),
    sanet     = countif(t == 'microsoft.storage/storageaccounts' and tostring(properties.networkAcls.defaultAction) =~ 'deny'),
    vnetint   = countif(t == 'microsoft.web/sites' and isnotempty(tostring(properties.virtualNetworkSubnetId)))
| project r = pack_array(
    pack('type', 'microsoft.network/virtualnetworks/virtualnetworkpeerings#embedded', 'count_', peerings),
    pack('type', 'microsoft.network/networksecuritygroups/securityrules#embedded', 'count_', nsgrules),
    pack('type', 'microsoft.network/loadbalancers/loadbalancingrules#embedded', 'count_', lbrules),
    pack('type', 'microsoft.network/loadbalancers/probes#embedded', 'count_', lbprobes),
    pack('type', 'microsoft.network/loadbalancers/backendaddresspools#embedded', 'count_', lbpools),
    pack('type', 'microsoft.containerservice/managedclusters/agentpools#embedded', 'count_', nodepools),
    pack('type', 'microsoft.keyvault/vaults/accesspolicies#embedded', 'count_', kvpols),
    pack('type', 'microsoft.network/privateendpoints/asgassociation#embedded', 'count_', peasgs),
    pack('type', 'microsoft.storage/storageaccounts/networkrules#embedded', 'count_', sanet),
    pack('type', 'microsoft.web/sites/vnetintegration#embedded', 'count_', vnetint))
| mv-expand r
| project type = tostring(r.type), count_ = tolong(r.count_)"

# Subnets and their NSG / route table associations (needs one row per subnet).
Q_SUBNETS="Resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand s = properties.subnets
| where isnotnull(s)
| summarize
    subnets = count(),
    nsg     = countif(isnotempty(tostring(s.properties.networkSecurityGroup.id))),
    rt      = countif(isnotempty(tostring(s.properties.routeTable.id)))
| project r = pack_array(
    pack('type', 'microsoft.network/virtualnetworks/subnets#embedded', 'count_', subnets),
    pack('type', 'microsoft.network/virtualnetworks/subnets/nsgassociation#embedded', 'count_', nsg),
    pack('type', 'microsoft.network/virtualnetworks/subnets/routetableassociation#embedded', 'count_', rt))
| mv-expand r
| project type = tostring(r.type), count_ = tolong(r.count_)"

Q_RESOURCE_GROUPS="ResourceContainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| summarize count_ = count() by type = tolower(type)"

Q_ROLE_ASSIGNMENTS="AuthorizationResources
| where type =~ 'microsoft.authorization/roleassignments'
| summarize count_ = count() by type = tolower(type)"

# Policy assignments/exemptions are keyed by the scope they are attached to
# (management group, subscription, resource group or individual resource),
# since each scope is a different Terraform type. Only custom policy
# definitions appear in this table (built-ins are not listed).
Q_POLICY="PolicyResources
| where type in~ ('microsoft.authorization/policydefinitions',
                  'microsoft.authorization/policyassignments',
                  'microsoft.authorization/policyexemptions')
| extend t = tolower(type), lid = tolower(id)
| extend scope = substring(lid, 0, indexof(lid, '/providers/microsoft.authorization/'))
| extend sfx = case(
    scope startswith '/providers/microsoft.management/managementgroups/', '#mg',
    scope matches regex '^/subscriptions/[^/]+\$', '#subscription',
    scope matches regex '^/subscriptions/[^/]+/resourcegroups/[^/]+\$', '#resourcegroup',
    '#resource')
| summarize count_ = count() by type = iff(t == 'microsoft.authorization/policydefinitions', t, strcat(t, sfx))"

Q_BACKUP="RecoveryServicesResources
| where (type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers'
         and properties.containerType =~ 'StorageContainer')
     or (type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems'
         and properties.workloadType =~ 'AzureFileShare')
| summarize count_ = count() by type = tolower(type)"

Q_DNS="DnsResources
| where type =~ 'microsoft.network/privatednszones/a'
| summarize count_ = count() by type = tolower(type)"

# Bash 3.2 (macOS default) has no associative arrays, so maps are stored as
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

COUNT_KEYS=(); COUNT_VALS=()

count_add() { # count_add <key> <n> - adds n to key's running count
  local key="$1" val="$2" i
  for i in "${!COUNT_KEYS[@]}"; do
    if [[ "${COUNT_KEYS[$i]}" == "$key" ]]; then
      COUNT_VALS[$i]=$(( COUNT_VALS[$i] + val ))
      return
    fi
  done
  COUNT_KEYS+=("$key")
  COUNT_VALS+=("$val")
}

SKIPPED=()

# run_query <label> <kql> [required] - runs one Resource Graph query and adds
# its (type, count_) rows. Optional queries that fail (e.g. a table the
# identity cannot read) are reported and skipped instead of aborting the run.
run_query() {
  local label="$1" kql="$2" required="${3:-}" raw atype acount
  raw=$(az graph query "${SCOPE_ARGS[@]}" -q "$kql" --first 1000 -o json 2>"$ERR_LOG")
  if [[ $? -ne 0 ]]; then
    if [[ -n "$required" ]]; then
      echo "ERROR: Azure Resource Graph query failed ($label):"
      cat "$ERR_LOG"
      echo ""
      echo "Check that you are logged in ('az login') and have Reader on the scope."
      exit 1
    fi
    SKIPPED+=("$label")
    return
  fi
  while IFS='|' read -r atype acount; do
    [[ -z "$atype" || -z "$acount" || "$acount" == "null" || "$acount" -le 0 ]] && continue
    count_add "$atype" "$acount"
  done <<< "$(echo "$raw" | jq -r '.data[] | "\(.type)|\(.count_)"')"
}

echo "============================================================"
echo " Firefly - Azure Supported Asset Count"
echo " Scope: $SCOPE_DESC"
echo " Date:  $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "============================================================"
echo "Querying Azure Resource Graph (this can take a minute)..."

run_query "resources"            "$Q_RESOURCES" required
run_query "embedded child config" "$Q_EMBEDDED"
run_query "subnets"              "$Q_SUBNETS"
run_query "resource groups"      "$Q_RESOURCE_GROUPS"
run_query "role assignments"     "$Q_ROLE_ASSIGNMENTS"
run_query "policy"               "$Q_POLICY"
run_query "backup"               "$Q_BACKUP"
run_query "private DNS records"  "$Q_DNS"

# ------------------------- report -------------------------
TOTAL=0
ROWS=()        # "tf_type|count_key|count", for sorting by Terraform type
UNMAPPED=()    # "count_key|count"

for i in "${!COUNT_KEYS[@]}"; do
  key="${COUNT_KEYS[$i]}"; count="${COUNT_VALS[$i]}"
  if tf_type=$(map_lookup "$key"); then
    ROWS+=("$tf_type|$key|$count")
    TOTAL=$(( TOTAL + count ))
  else
    UNMAPPED+=("$key|$count")
  fi
done

echo ""
echo "------------------------------------------------------------"
printf "%-58s %10s\n" "Firefly-supported Terraform type" "Count"
echo "------------------------------------------------------------"
echo "terraform_type,arm_type,count" > "$OUT_CSV"

if [[ ${#ROWS[@]} -gt 0 ]]; then
  while IFS='|' read -r tf_type key count; do
    printf "%-58s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$key,$count" >> "$OUT_CSV"
  done <<< "$(printf '%s\n' "${ROWS[@]}" | sort -t'|' -k1,1 -k2,2)"
fi

echo "------------------------------------------------------------"
printf "%-58s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ ${#UNMAPPED[@]} -gt 0 ]]; then
  echo ""
  echo "Other ARM types found in Resource Graph (not on the supported list / not mapped):"
  while IFS='|' read -r key count; do
    printf "  %-56s %10d\n" "$key" "$count"
  done <<< "$(printf '%s\n' "${UNMAPPED[@]}" | sort)"
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo ""
  echo "WARNING: these queries failed and were skipped (their types are not counted):"
  printf '  - %s\n' "${SKIPPED[@]}"
fi

N_COUNTABLE=$(printf '%s\n' "${MAP_VALS[@]}" | sort -u | wc -l | tr -d ' ')
N_NOT=${#NOT_COUNTABLE[@]}

echo ""
echo "COVERAGE: this script counts $N_COUNTABLE of $(( N_COUNTABLE + N_NOT )) Firefly-supported Azure"
echo "      types. The other $N_NOT (storage containers/queues/shares/tables, Service"
echo "      Bus queues/topics, Event Hubs, Cosmos DB databases/containers, Key Vault"
echo "      secrets/certificates, diagnostic settings, Front Door origins/routes/"
echo "      rules, ...) are not exposed by Azure Resource Graph. Treat the total"
echo "      as a LOWER BOUND of Firefly-supported assets."
if [[ $VERBOSE -eq 1 ]]; then
  echo ""
  echo "Supported types not countable via Resource Graph:"
  printf '  %s\n' "${NOT_COUNTABLE[@]}"
else
  echo "      Run with -v to list them."
fi
echo ""
echo "CSV written to: $OUT_CSV"
