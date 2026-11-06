#!/usr/bin/env bash
#
# =============================================================================
#  Firefly - Azure Supported Asset Count
# =============================================================================
#  Counts the resources in an Azure tenant / subscription(s) / management group
#  that match Firefly's supported Azure Terraform resource types, using
#  Azure Resource Graph.
#
#  READ-ONLY: this script only runs 'az graph query' and ARM GET requests
#  (sent through the ARM batch API with 'az rest').
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
#    2. Reads child resources Resource Graph does not return with ARM GETs on
#       their parents (storage containers/shares/queues/tables, Cosmos DB
#       databases/containers, Service Bus/Event Hubs entities, Key Vault
#       secrets, SQL auditing policies, Front Door origins/routes/rules,
#       diagnostic settings, PIM eligible assignments, ...).
#    3. Maps each ARM resource type (or variant, e.g. Windows vs Linux VM) to
#       its Terraform resource type and keeps only Firefly-supported ones.
#    4. Prints a per-type breakdown + grand total, and writes a CSV.
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
#    ./firefly_azure_asset_count.sh -q                  # Resource Graph only (faster, lower bound)
#    ./firefly_azure_asset_count.sh -v                  # also list types not countable here
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}", which SCOPE_ARGS hits
# any time -s/-m isn't passed. Every scalar var below has an explicit default.

SUBS=()
MG=""
VERBOSE=0
QUICK=0
OUT_CSV="firefly_azure_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "s:m:qvh" opt; do
  case $opt in
    s) SUBS+=("$OPTARG") ;;
    m) MG="$OPTARG" ;;
    q) QUICK=1 ;;
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

# Firefly-supported types that only exist on a data plane (App Configuration
# keys, Key Vault certificates): neither Resource Graph nor ARM lists them, and
# reading them needs data-plane access, so they are not counted.
NOT_COUNTABLE=(
  "azurerm_app_configuration_key"
  "azurerm_key_vault_certificate"
)

# Supported types counted by the ARM child-resource pass (see arm_tally).
API_COUNTED=(
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
# backs several Terraform types.
Q_RESOURCES="Resources
| extend t = tolower(type), k = tolower(kind)
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
  if [[ "$key" == api:* ]]; then          # counted by the ARM pass
    for i in "${API_COUNTED[@]}"; do
      [[ "$i" == "${key#api:}" ]] && { printf '%s' "$i"; return 0; }
    done
    return 1
  fi
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

# -----------------------------------------------------------------------------
# ARM pass: child resources Resource Graph does not return (storage containers
# / shares / queues / tables, Cosmos DB databases and containers, Service Bus
# and Event Hubs entities, Key Vault secrets, SQL auditing policies, Front Door
# origins / routes / rules, diagnostic settings, ...). Read with ARM GETs on
# each parent, sent through the ARM batch API (100 GETs per call), so Reader
# is enough. Skip with -q for a faster, Resource-Graph-only (lower) count.
# -----------------------------------------------------------------------------
ARM="https://management.azure.com"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/az_asset_arm.XXXXXX") || exit 1
trap 'rm -f "$ERR_LOG"; rm -rf "$WORK"' EXIT
ARM_FAILED=0

# graph_rows <fields> <kql> -> the named fields of every row (tab-joined), paged.
# (Resource Graph does not keep the projected column order.)
graph_rows() {
  local fields="$1" kql="$2" skip="" raw
  while :; do
    if [[ -n "$skip" ]]; then
      raw=$(az graph query "${SCOPE_ARGS[@]}" -q "$kql" --first 1000 --skip-token "$skip" -o json 2>>"$ERR_LOG") || return 1
    else
      raw=$(az graph query "${SCOPE_ARGS[@]}" -q "$kql" --first 1000 -o json 2>>"$ERR_LOG") || return 1
    fi
    echo "$raw" | jq -r --arg f "$fields" '.data[] | [.[($f | split(","))[]]] | map(tostring) | join("\t")'
    skip=$(echo "$raw" | jq -r '.skip_token // empty')
    [[ -z "$skip" ]] && break
  done
}

# arm_post_batch <body file> <out file>: POST to the ARM batch API. Large
# batches are answered 202 + Location; poll it until the results are ready.
arm_post_batch() {
  local body="$1" out="$2" hdr="$1.hdr" code loc wait_s tries=0
  code=$(curl -s -o "$out" -D "$hdr" -w '%{http_code}' -X POST \
           -H "Authorization: Bearer $ARM_TOKEN" -H 'Content-Type: application/json' \
           --data @"$body" "$ARM/batch?api-version=2020-06-01")
  while [[ "$code" == 202 && $tries -lt 120 ]]; do
    loc=$(awk 'tolower($1) == "location:" { print $2 }' "$hdr" | tr -d '\r')
    wait_s=$(awk 'tolower($1) == "retry-after:" { print $2 }' "$hdr" | tr -d '\r')
    [[ -z "$loc" ]] && break
    sleep "${wait_s:-2}"; tries=$((tries + 1))
    code=$(curl -s -o "$out" -D "$hdr" -w '%{http_code}' -H "Authorization: Bearer $ARM_TOKEN" "$loc")
  done
  [[ "$code" == 200 ]] || { echo "ARM batch HTTP $code: $(head -c 300 "$out")" >> "$ERR_LOG"; return 1; }
  # a finished batch can be paged (sync results come back as .responses,
  # async ones as .value)
  local next page=0
  next=$(jq -r '.nextLink // empty' "$out")
  while [[ -n "$next" && $page -lt 50 ]]; do
    curl -s -H "Authorization: Bearer $ARM_TOKEN" "$next" > "$out.next" || break
    jq -s '{responses: ((.[0].responses // .[0].value) + (.[1].responses // .[1].value)), nextLink: .[1].nextLink}' "$out" "$out.next" > "$out.m" && mv "$out.m" "$out"
    next=$(jq -r '.nextLink // empty' "$out"); page=$((page + 1))
  done
  return 0
}

# arm_batch: stdin "kind<TAB>path?api-version=..." -> stdout "kind<TAB>item-json"
# (one line per item of each response's 'value' list).
arm_batch() {
  local in="$WORK/req.$RANDOM" n=0 pids=()
  cat > "$in"
  [[ -s "$in" ]] || return 0
  split -l 100 "$in" "$in.part."
  for part in "$in".part.*; do
    (
      jq -R -s --arg arm "$ARM" 'split("\n") | map(select(length > 0) | split("\t"))
          | {requests: to_entries | map({name: (.key | tostring), httpMethod: "GET", url: ($arm + .value[1])})}' "$part" > "$part.body"
      if arm_post_batch "$part.body" "$part.out"; then
        jq -r -R -s 'split("\n") | map(select(length > 0) | split("\t")[0])' "$part" > "$part.kinds"
        jq -r --slurpfile k "$part.kinds" '
          (.responses // .value)[] | select(.httpStatusCode == 200)
          | $k[0][.name | tonumber] as $kind | (.content.value // [])[] | "\($kind)\t\(tojson)"' "$part.out" > "$part.res"
      else
        echo "batch" > "$part.failed"
      fi
    ) &
    pids+=($!); n=$((n+1))
    if [[ $n -ge 6 ]]; then wait "${pids[0]}"; pids=("${pids[@]:1}"); n=$((n-1)); fi
  done
  wait
  cat "$in".part.*.res 2>/dev/null
  ls "$in".part.*.failed >/dev/null 2>&1 && touch "$WORK/arm_failed"
  rm -f "$in" "$in".part.*
}

# kind -> Terraform type (+ optional jq filter on the item)
arm_tally() {  # stdin: kind<TAB>item  -> adds counts
  local kind tf filt n
  while IFS='|' read -r kind tf filt; do
    n=$(awk -F'\t' -v k="$kind" '$1 == k { print $2 }' "$1" \
        | jq -s "map(select(${filt:-true})) | length" 2>/dev/null)
    [[ -n "$n" && "$n" -gt 0 ]] && count_add "api:$tf" "$n"
  done <<'TALLY'
container|azurerm_storage_container|
share|azurerm_storage_share|
queue|azurerm_storage_queue|
table|azurerm_storage_table|
cosmos_sqldb|azurerm_cosmosdb_sql_database|
cosmos_sqlcontainer|azurerm_cosmosdb_sql_container|
cosmos_mongodb|azurerm_cosmosdb_mongo_database|
cosmos_mongocoll|azurerm_cosmosdb_mongo_collection|
cosmos_table|azurerm_cosmosdb_table|
cosmos_sqlrole|azurerm_cosmosdb_sql_role_assignment|
sb_queue|azurerm_servicebus_queue|
sb_queue_auth|azurerm_servicebus_queue_authorization_rule|
sb_topic|azurerm_servicebus_topic|
sb_topic_auth|azurerm_servicebus_topic_authorization_rule|
sb_sub|azurerm_servicebus_subscription|
sb_rule|azurerm_servicebus_subscription_rule|
eventhub|azurerm_eventhub|
kv_secret|azurerm_key_vault_secret|
fic|azurerm_federated_identity_credential|
ml_compute|azurerm_machine_learning_compute_instance|.properties.computeType == "ComputeInstance"
pg_db|azurerm_postgresql_flexible_server_database|
pg_config|azurerm_postgresql_flexible_server_configuration|.properties.source == "user-override"
pls_scoped|azurerm_monitor_private_link_scoped_service|
fd_origingroup|azurerm_cdn_frontdoor_origin_group|
fd_origin|azurerm_cdn_frontdoor_origin|
fd_customdomain|azurerm_cdn_frontdoor_custom_domain|
fd_ruleset|azurerm_cdn_frontdoor_rule_set|
fd_rule|azurerm_cdn_frontdoor_rule|
fd_route|azurerm_cdn_frontdoor_route|
diag|azurerm_monitor_diagnostic_setting|
sql_srv_audit|azurerm_mssql_server_extended_auditing_policy|
sql_db_audit|azurerm_mssql_database_extended_auditing_policy|
pim|azurerm_pim_eligible_role_assignment|
TALLY
}

if [[ $QUICK -eq 0 ]] && ! command -v curl >/dev/null; then
  SKIPPED+=("ARM child-resource pass (curl not found)"); QUICK=1
fi
if [[ $QUICK -eq 0 ]]; then
  ARM_TOKEN=$(az account get-access-token --resource "$ARM/" --query accessToken -o tsv 2>>"$ERR_LOG")
fi
if [[ $QUICK -eq 0 && -n "$ARM_TOKEN" ]]; then
  echo "Reading child resources from ARM (batched; can take a few minutes on large tenants)..."
  PARENTS="$WORK/parents"
  if graph_rows id,t,k "Resources | where type in~ ('microsoft.storage/storageaccounts','microsoft.documentdb/databaseaccounts','microsoft.servicebus/namespaces','microsoft.eventhub/namespaces','microsoft.keyvault/vaults','microsoft.managedidentity/userassignedidentities','microsoft.machinelearningservices/workspaces','microsoft.dbforpostgresql/flexibleservers','microsoft.insights/privatelinkscopes','microsoft.cdn/profiles','microsoft.cdn/profiles/afdendpoints','microsoft.sql/servers','microsoft.sql/servers/databases') | project id, t = tolower(type), k = tolower(kind)" > "$PARENTS" \
     && graph_rows subscriptionId "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId" > "$WORK/subs" \
     && graph_rows id "Resources | project id" > "$WORK/allids"; then
    # wave 1: children of Resource Graph parents
    awk -F'\t' '
      function r(kind, path) { printf "%s\t%s%s\n", kind, $1, path }
      $2 == "microsoft.storage/storageaccounts" {
        r("container", "/blobServices/default/containers?api-version=2023-01-01")
        r("share",     "/fileServices/default/shares?api-version=2023-01-01")
        r("queue",     "/queueServices/default/queues?api-version=2023-01-01")
        r("table",     "/tableServices/default/tables?api-version=2023-01-01") }
      $2 == "microsoft.documentdb/databaseaccounts" {
        r("cosmos_sqldb",   "/sqlDatabases?api-version=2023-04-15")
        r("cosmos_mongodb", "/mongodbDatabases?api-version=2023-04-15")
        r("cosmos_table",   "/tables?api-version=2023-04-15")
        r("cosmos_sqlrole", "/sqlRoleAssignments?api-version=2023-04-15") }
      $2 == "microsoft.servicebus/namespaces" {
        r("sb_queue", "/queues?api-version=2021-11-01")
        r("sb_topic", "/topics?api-version=2021-11-01") }
      $2 == "microsoft.eventhub/namespaces"  { r("eventhub", "/eventhubs?api-version=2024-01-01") }
      $2 == "microsoft.keyvault/vaults"      { r("kv_secret", "/secrets?api-version=2023-07-01") }
      $2 == "microsoft.managedidentity/userassignedidentities" { r("fic", "/federatedIdentityCredentials?api-version=2023-01-31") }
      $2 == "microsoft.machinelearningservices/workspaces" { r("ml_compute", "/computes?api-version=2024-04-01") }
      $2 == "microsoft.dbforpostgresql/flexibleservers" {
        r("pg_db",     "/databases?api-version=2022-12-01")
        r("pg_config", "/configurations?api-version=2022-12-01") }
      $2 == "microsoft.insights/privatelinkscopes" { r("pls_scoped", "/scopedResources?api-version=2021-07-01-preview") }
      $2 == "microsoft.cdn/profiles" && $3 == "frontdoor" {
        r("fd_origingroup",  "/originGroups?api-version=2023-05-01")
        r("fd_customdomain", "/customDomains?api-version=2023-05-01")
        r("fd_ruleset",      "/ruleSets?api-version=2023-05-01") }
      $2 == "microsoft.cdn/profiles/afdendpoints" { r("fd_route", "/routes?api-version=2023-05-01") }
      $2 == "microsoft.sql/servers"           { r("sql_srv_audit", "/extendedAuditingSettings?api-version=2021-11-01") }
      $2 == "microsoft.sql/servers/databases" { r("sql_db_audit",  "/extendedAuditingSettings?api-version=2021-11-01") }
    ' "$PARENTS" > "$WORK/w1.req"
    # subscription-scope: diagnostic settings + PIM eligible assignments
    awk 'NF { printf "diag\t/subscriptions/%s/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview\n", $1
              printf "pim\t/subscriptions/%s/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&$filter=atScope()\n", $1 }' "$WORK/subs" >> "$WORK/w1.req"
    # diagnostic settings on every resource (types without diagnostics just return an error)
    awk 'NF { printf "diag\t%s/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview\n", $1 }' "$WORK/allids" >> "$WORK/w1.req"
    arm_batch < "$WORK/w1.req" > "$WORK/w1.out"
    # wave 2: children of wave-1 items
    jq -r -R 'split("\t") | .[0] as $k | (.[1] | fromjson | .id) as $id |
      if   $k == "cosmos_sqldb"   then "cosmos_sqlcontainer\t\($id)/containers?api-version=2023-04-15"
      elif $k == "cosmos_mongodb" then "cosmos_mongocoll\t\($id)/collections?api-version=2023-04-15"
      elif $k == "sb_queue"       then "sb_queue_auth\t\($id)/authorizationRules?api-version=2021-11-01"
      elif $k == "sb_topic"       then "sb_topic_auth\t\($id)/authorizationRules?api-version=2021-11-01", "sb_sub\t\($id)/subscriptions?api-version=2021-11-01"
      elif $k == "fd_origingroup" then "fd_origin\t\($id)/origins?api-version=2023-05-01"
      elif $k == "fd_ruleset"     then "fd_rule\t\($id)/rules?api-version=2023-05-01"
      else empty end' "$WORK/w1.out" > "$WORK/w2.req"
    arm_batch < "$WORK/w2.req" > "$WORK/w2.out"
    # wave 3: Service Bus subscription rules
    jq -r -R 'split("\t") | select(.[0] == "sb_sub") | "sb_rule\t\(.[1] | fromjson | .id)/rules?api-version=2021-11-01"' \
      "$WORK/w2.out" > "$WORK/w3.req"
    arm_batch < "$WORK/w3.req" > "$WORK/w3.out"
    cat "$WORK/w1.out" "$WORK/w2.out" "$WORK/w3.out" > "$WORK/all.out"
    arm_tally "$WORK/all.out"
    [[ -f "$WORK/arm_failed" ]] && SKIPPED+=("some ARM batch calls (child resources may be undercounted)")
  else
    SKIPPED+=("ARM child-resource pass (Resource Graph parent query failed)")
  fi
fi

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

N_COUNTABLE=$(printf '%s\n' "${MAP_VALS[@]}" "${API_COUNTED[@]}" | sort -u | wc -l | tr -d ' ')
N_NOT=${#NOT_COUNTABLE[@]}

echo ""
echo "COVERAGE: this script counts $N_COUNTABLE of $(( N_COUNTABLE + N_NOT )) Firefly-supported Azure"
echo "      types. The other $N_NOT (App Configuration keys, Key Vault certificates) are"
echo "      data-plane objects and are not counted."
if [[ $QUICK -eq 1 ]]; then
  echo "      -q: child resources read from ARM (storage containers, Cosmos DB"
  echo "      databases, Service Bus entities, diagnostic settings, ...) were skipped,"
  echo "      so treat the total as a LOWER BOUND."
fi
if [[ $VERBOSE -eq 1 ]]; then
  echo ""
  echo "Supported types not counted:"
  printf '  %s\n' "${NOT_COUNTABLE[@]}"
else
  echo "      Run with -v to list them."
fi
echo ""
echo "CSV written to: $OUT_CSV"
