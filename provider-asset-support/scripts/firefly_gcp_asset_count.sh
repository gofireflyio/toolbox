#!/usr/bin/env bash
#
# =============================================================================
#  Firefly - GCP Supported Asset Count
# =============================================================================
#  Counts the resources in a GCP project / folder / organization that match
#  Firefly's supported GCP Terraform resource types, using Cloud Asset
#  Inventory (CAI).
#
#  READ-ONLY: this script only runs read-only Cloud Asset Inventory calls
#  ('gcloud asset search-all-resources', 'list' and 'search-all-iam-policies').
#
#  HOW IT WORKS
#    1. Runs Cloud Asset Inventory search across the chosen scope and
#       groups results by assetType (regional vs global/zonal compute
#       variants are told apart by location). Asset types the search API
#       may not return are also listed with 'gcloud asset list', and IAM
#       policy search counts project / bucket IAM members.
#    2. Maps each CAI asset type to its Terraform resource type and keeps
#       only the ones on Firefly's supported list.
#    3. Prints a per-type breakdown + grand total, and writes a CSV.
#
#  REQUIREMENTS
#    - gcloud CLI (authenticated), plus standard coreutils (sort/uniq/awk)
#    - Cloud Asset API enabled on the scoping project:
#        gcloud services enable cloudasset.googleapis.com
#    - IAM: roles/cloudasset.viewer (cloudasset.assets.searchAllResources)
#      on the chosen scope.
#
#  USAGE
#    ./firefly_gcp_asset_count.sh -p PROJECT_ID          # single project
#    ./firefly_gcp_asset_count.sh -o ORG_ID              # whole organization
#    ./firefly_gcp_asset_count.sh -f FOLDER_ID           # a folder
#    ./firefly_gcp_asset_count.sh -p PROJECT_ID -v       # also list types not countable here
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}". No arrays here today, but
# keeping this consistent with the other two scripts in this repo.

SCOPE=""
VERBOSE=0
OUT_CSV="firefly_gcp_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "p:o:f:vh" opt; do
  case $opt in
    p) SCOPE="projects/$OPTARG" ;;
    o) SCOPE="organizations/$OPTARG" ;;
    f) SCOPE="folders/$OPTARG" ;;
    v) VERBOSE=1 ;;
    h) awk '/^#/{print; next} {exit}' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done

command -v gcloud >/dev/null || { echo "ERROR: gcloud CLI not found"; exit 1; }

if [[ -z "$SCOPE" ]]; then
  DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null)
  if [[ -z "$DEFAULT_PROJECT" || "$DEFAULT_PROJECT" == "(unset)" ]]; then
    echo "ERROR: no scope given. Use -p PROJECT_ID, -f FOLDER_ID or -o ORG_ID."
    exit 1
  fi
  SCOPE="projects/$DEFAULT_PROJECT"
fi

# -----------------------------------------------------------------------------
# Cloud Asset Inventory assetType -> Firefly-supported Terraform resource type
# (IAM bindings/members/policies and a few API-config-only types are not
#  discrete CAI assets, so they cannot be counted this way - see note below.)
# -----------------------------------------------------------------------------
MAP_KEYS=(
  "apigee.googleapis.com/Organization"
  "apigee.googleapis.com/Environment"
  "apigee.googleapis.com/Instance"
  "bigquery.googleapis.com/Dataset"
  "bigquery.googleapis.com/Table"
  "bigquery.googleapis.com/Routine"
  "bigtableadmin.googleapis.com/AppProfile"
  "bigtableadmin.googleapis.com/Instance"
  "bigtableadmin.googleapis.com/Table"
  "run.googleapis.com/Service"
  "cloudfunctions.googleapis.com/CloudFunction"
  "cloudfunctions.googleapis.com/Function"
  "composer.googleapis.com/Environment"
  "compute.googleapis.com/Address"
  "compute.googleapis.com/GlobalAddress"
  "compute.googleapis.com/Autoscaler"
  "compute.googleapis.com/BackendService"
  "compute.googleapis.com/RegionBackendService"
  "compute.googleapis.com/Disk"
  "compute.googleapis.com/RegionDisk"
  "compute.googleapis.com/Firewall"
  "compute.googleapis.com/ForwardingRule"
  "compute.googleapis.com/GlobalForwardingRule"
  "compute.googleapis.com/HealthCheck"
  "compute.googleapis.com/Image"
  "compute.googleapis.com/Instance"
  "compute.googleapis.com/InstanceGroup"
  "compute.googleapis.com/InstanceGroupManager"
  "compute.googleapis.com/InstanceTemplate"
  "compute.googleapis.com/Network"
  "compute.googleapis.com/NetworkEndpointGroup"
  "compute.googleapis.com/ResourcePolicy"
  "compute.googleapis.com/Router"
  "compute.googleapis.com/SecurityPolicy"
  "compute.googleapis.com/Snapshot"
  "compute.googleapis.com/SslCertificate"
  "compute.googleapis.com/SslPolicy"
  "compute.googleapis.com/Subnetwork"
  "compute.googleapis.com/TargetHttpProxy"
  "compute.googleapis.com/TargetHttpsProxy"
  "compute.googleapis.com/TargetPool"
  "compute.googleapis.com/UrlMap"
  "container.googleapis.com/Cluster"
  "container.googleapis.com/NodePool"
  "dns.googleapis.com/ManagedZone"
  "dns.googleapis.com/ResourceRecordSet"
  "file.googleapis.com/Backup"
  "file.googleapis.com/Instance"
  "iam.googleapis.com/ServiceAccount"
  "iam.googleapis.com/Role"
  "iam.googleapis.com/WorkloadIdentityPool"
  "logging.googleapis.com/LogSink"
  "pubsub.googleapis.com/Schema"
  "pubsub.googleapis.com/Subscription"
  "pubsub.googleapis.com/Topic"
  "redis.googleapis.com/Instance"
  "secretmanager.googleapis.com/Secret"
  "spanner.googleapis.com/Database"
  "spanner.googleapis.com/Instance"
  "sqladmin.googleapis.com/Instance"
  "storage.googleapis.com/Bucket"
  "cloudresourcemanager.googleapis.com/Project"
  "compute.googleapis.com/HealthCheck#regional"
  "compute.googleapis.com/SslCertificate#regional"
  "compute.googleapis.com/TargetHttpProxy#regional"
  "compute.googleapis.com/TargetHttpsProxy#regional"
  "compute.googleapis.com/UrlMap#regional"
  "compute.googleapis.com/Autoscaler#regional"
  "compute.googleapis.com/InstanceGroupManager#regional"
  "compute.googleapis.com/NetworkEndpointGroup#regional"
  "compute.googleapis.com/NetworkEndpointGroup#global"
  "servicenetworking.googleapis.com/Connection"
  "file.googleapis.com/Snapshot"
  "apigee.googleapis.com/ApiProxy"
  "orgpolicy.googleapis.com/Policy#organization"
  "orgpolicy.googleapis.com/Policy#folder"
  "orgpolicy.googleapis.com/Policy#project"
  "iam-policy/cloudresourcemanager.googleapis.com/Project#member"
  "iam-policy/storage.googleapis.com/Bucket#member"
  "iam-policy/cloudfunctions.googleapis.com/CloudFunction"
)

MAP_VALS=(
  "google_apigee_organization"
  "google_apigee_environment"
  "google_apigee_instance"
  "google_bigquery_dataset"
  "google_bigquery_table"
  "google_bigquery_routine"
  "google_bigtable_app_profile"
  "google_bigtable_instance"
  "google_bigtable_table"
  "google_cloud_run_v2_service"
  "google_cloudfunctions_function"
  "google_cloudfunctions2_function"
  "google_composer_environment"
  "google_compute_address"
  "google_compute_global_address"
  "google_compute_autoscaler"
  "google_compute_backend_service"
  "google_compute_region_backend_service"
  "google_compute_disk"
  "google_compute_region_disk"
  "google_compute_firewall"
  "google_compute_forwarding_rule"
  "google_compute_global_forwarding_rule"
  "google_compute_health_check"
  "google_compute_image"
  "google_compute_instance"
  "google_compute_instance_group"
  "google_compute_instance_group_manager"
  "google_compute_instance_template"
  "google_compute_network"
  "google_compute_network_endpoint_group"
  "google_compute_resource_policy"
  "google_compute_router"
  "google_compute_security_policy"
  "google_compute_snapshot"
  "google_compute_ssl_certificate"
  "google_compute_ssl_policy"
  "google_compute_subnetwork"
  "google_compute_target_http_proxy"
  "google_compute_target_https_proxy"
  "google_compute_target_pool"
  "google_compute_url_map"
  "google_container_cluster"
  "google_container_node_pool"
  "google_dns_managed_zone"
  "google_dns_record_set"
  "google_filestore_backup"
  "google_filestore_instance"
  "google_service_account"
  "google_project_iam_custom_role"
  "google_iam_workload_identity_pool"
  "google_logging_project_sink"
  "google_pubsub_schema"
  "google_pubsub_subscription"
  "google_pubsub_topic"
  "google_redis_instance"
  "google_secret_manager_secret"
  "google_spanner_database"
  "google_spanner_instance"
  "google_sql_database_instance"
  "google_storage_bucket"
  "google_project"
  "google_compute_region_health_check"
  "google_compute_region_ssl_certificate"
  "google_compute_region_target_http_proxy"
  "google_compute_region_target_https_proxy"
  "google_compute_region_url_map"
  "google_compute_region_autoscaler"
  "google_compute_region_instance_group_manager"
  "google_compute_region_network_endpoint_group"
  "google_compute_global_network_endpoint_group"
  "google_service_networking_connection"
  "google_filestore_snapshot"
  "google_apigee_api"
  "google_organization_policy"
  "google_folder_organization_policy"
  "google_project_organization_policy"
  "google_project_iam_member"
  "google_storage_bucket_iam_member"
  "google_cloudfunctions_function_iam_policy"
)

# Supported types counted under another type's row, because CAI does not
# distinguish them: Google-managed SSL certificates are SslCertificate assets,
# and bucket IAM bindings/policies are the same grants as the bucket IAM
# members counted from IAM policy search.
COUNTED_AS_OTHER=(
  "google_compute_managed_ssl_certificate"
  "google_storage_bucket_iam_binding"
  "google_storage_bucket_iam_policy"
)

# Supported types Cloud Asset Inventory does not expose (Apigee sub-entities,
# Cloud Scheduler jobs, SQL databases, bucket ACLs, HMAC keys). They cannot be
# counted here, so the total is a lower bound. Checked against the CAI
# supported asset types list.
NOT_COUNTABLE=(
  "google_apigee_api_deployment"
  "google_apigee_api_product"
  "google_apigee_developer"
  "google_apigee_developer_app"
  "google_apigee_endpoint_attachment"
  "google_apigee_envgroup"
  "google_apigee_environment_iam_binding"
  "google_apigee_environment_iam_member"
  "google_apigee_environment_iam_policy"
  "google_apigee_environment_keyvaluemaps"
  "google_apigee_environment_keyvaluemaps_entries"
  "google_apigee_flowhook"
  "google_apigee_sharedflow"
  "google_apigee_sharedflow_deployment"
  "google_apigee_target_server"
  "google_cloud_scheduler_job"
  "google_sql_database"
  "google_storage_bucket_access_control"
  "google_storage_hmac_key"
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

echo "============================================================"
echo " Firefly - GCP Supported Asset Count"
echo " Scope: $SCOPE"
echo " Date:  $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "============================================================"
echo "Querying Cloud Asset Inventory (this can take a minute)..."

# One CAI search, grouped locally by assetType
ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/gcp_asset_err.XXXXXX") || exit 1
trap 'rm -f "$ERR_LOG"' EXIT

# 'gcloud asset list' takes the scope as a flag rather than --scope.
case "$SCOPE" in
  projects/*)      LIST_SCOPE=(--project="${SCOPE#projects/}") ;;
  folders/*)       LIST_SCOPE=(--folder="${SCOPE#folders/}") ;;
  organizations/*) LIST_SCOPE=(--organization="${SCOPE#organizations/}") ;;
esac

# Asset types that the search API may not return ("not available in the
# analysis APIs"), so they are also listed directly. Where a type comes back
# from both calls the larger count is kept, so nothing is counted twice.
LIST_TYPES="cloudresourcemanager.googleapis.com/Project,container.googleapis.com/NodePool,dns.googleapis.com/ResourceRecordSet,apigee.googleapis.com/Environment,apigee.googleapis.com/ApiProxy,iam.googleapis.com/WorkloadIdentityPool,file.googleapis.com/Snapshot,orgpolicy.googleapis.com/Policy"

echo "Querying Cloud Asset Inventory for $SCOPE (this can take a minute)..."

# 1) Resource search: one line per resource -> "assetType<TAB>location".
#    Regional compute resources share an asset type with their global/zonal
#    counterparts, so a '#regional' / '#global' suffix is added by location
#    (zones end in '-a', '-b', ...; regions end in a digit).
SEARCH=$(gcloud asset search-all-resources \
        --scope="$SCOPE" \
        --page-size=500 \
        --format="value(assetType,location)" 2>"$ERR_LOG")

if [[ $? -ne 0 ]]; then
  echo "ERROR: Cloud Asset Inventory query failed:"
  cat "$ERR_LOG"
  echo ""
  echo "Check that cloudasset.googleapis.com is enabled and that you have"
  echo "roles/cloudasset.viewer on $SCOPE."
  exit 1
fi

SEARCH_KEYS=$(echo "$SEARCH" | awk -F'\t' '
  $1 == "" { next }
  {
    t = $1; l = $2; k = t
    if (t ~ /^compute\.googleapis\.com\/(HealthCheck|SslCertificate|TargetHttpProxy|TargetHttpsProxy|UrlMap)$/) {
      if (l != "global" && l != "") k = t "#regional"
    } else if (t ~ /^compute\.googleapis\.com\/(Autoscaler|InstanceGroupManager)$/) {
      if (l !~ /-[a-z]$/) k = t "#regional"
    } else if (t == "compute.googleapis.com/NetworkEndpointGroup") {
      if (l == "global") k = t "#global"; else if (l !~ /-[a-z]$/) k = t "#regional"
    }
    print k
  }')

# 2) Direct listing of the types above: "assetType<TAB>name". Org policies are
#    split by the level they are set at (organization / folder / project).
SKIPPED=()
LISTED=$(gcloud asset list "${LIST_SCOPE[@]}" --asset-types="$LIST_TYPES" \
           --format="value(assetType,name)" 2>"$ERR_LOG")
if [[ $? -ne 0 ]]; then
  SKIPPED+=("asset list (projects, node pools, DNS records, Apigee, org policies, ...)")
  LISTED=""
fi
LIST_KEYS=$(echo "$LISTED" | awk -F'\t' '
  $1 == "" { next }
  $1 == "orgpolicy.googleapis.com/Policy" {
    if ($2 ~ /\/organizations\//) print $1 "#organization"
    else if ($2 ~ /\/folders\//) print $1 "#folder"
    else print $1 "#project"
    next
  }
  { print $1 }')

# 3) IAM policy search: one line per member for projects and buckets
#    (= google_project_iam_member / google_storage_bucket_iam_member), and
#    one line per Cloud Function that has an IAM policy set.
IAM_MEMBERS=$(gcloud asset search-all-iam-policies --scope="$SCOPE" \
                --asset-types="cloudresourcemanager.googleapis.com/Project,storage.googleapis.com/Bucket" \
                --flatten="policy.bindings[].members[]" \
                --format="value(assetType)" 2>"$ERR_LOG")
if [[ $? -ne 0 ]]; then
  SKIPPED+=("IAM policy search (project / bucket IAM members)")
  IAM_MEMBERS=""
fi
IAM_FUNCS=$(gcloud asset search-all-iam-policies --scope="$SCOPE" \
              --asset-types="cloudfunctions.googleapis.com/CloudFunction" \
              --format="value(assetType)" 2>"$ERR_LOG")
if [[ $? -ne 0 ]]; then
  SKIPPED+=("IAM policy search (Cloud Function IAM policies)")
  IAM_FUNCS=""
fi
IAM_KEYS=$( { echo "$IAM_MEMBERS" | awk 'NF { print "iam-policy/" $1 "#member" }'
              echo "$IAM_FUNCS"   | awk 'NF { print "iam-policy/" $1 }'; } )

# Bash 3.2 (macOS default) has no associative arrays, so COUNTS/UNMAPPED are
# each stored as two parallel indexed arrays, same approach as MAP above.
COUNT_KEYS=(); COUNT_VALS=()

count_max() { # count_max <key> <val> - keeps the larger of the stored and new count
  local key="$1" val="$2" i
  for i in "${!COUNT_KEYS[@]}"; do
    if [[ "${COUNT_KEYS[$i]}" == "$key" ]]; then
      (( val > COUNT_VALS[$i] )) && COUNT_VALS[$i]=$val
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

# Each source is tallied on its own, then merged with max() per key.
for src in "$SEARCH_KEYS" "$LIST_KEYS" "$IAM_KEYS"; do
  while read -r c t; do
    [[ -z "${t:-}" ]] && continue
    count_max "$t" "$c"
  done <<< "$(echo "$src" | awk 'NF' | sort | uniq -c | awk '{print $1, $2}')"
done

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
printf "%-55s %10s\n" "Firefly-supported Terraform type" "Count"
echo "------------------------------------------------------------"
echo "terraform_type,cai_asset_type,count" > "$OUT_CSV"

ROWS=()   # "tf_type|cai_key|count", for sorting by Terraform type
for cai_type in "${COUNT_KEYS[@]}"; do
  count=$(count_get "$cai_type")
  if tf_type=$(map_lookup "$cai_type"); then
    ROWS+=("$tf_type|$cai_type|$count")
    TOTAL=$(( TOTAL + count ))
  else
    unmapped_set "$cai_type" "$count"
  fi
done
if [[ ${#ROWS[@]} -gt 0 ]]; then
  while IFS='|' read -r tf_type cai_type count; do
    printf "%-55s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$cai_type,$count" >> "$OUT_CSV"
  done <<< "$(printf '%s\n' "${ROWS[@]}" | sort -t'|' -k1,1 -k2,2)"
fi

echo "------------------------------------------------------------"
printf "%-55s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ ${#UNMAPPED_KEYS[@]} -gt 0 ]]; then
  echo ""
  echo "Other asset types found in Cloud Asset Inventory (not on the supported list / not mapped):"
  for t in $(printf '%s\n' "${UNMAPPED_KEYS[@]}" | sort); do
    printf "  %-53s %10d\n" "$t" "$(unmapped_get "$t")"
  done
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo ""
  echo "WARNING: these queries failed and were skipped (their types are not counted):"
  printf '  - %s\n' "${SKIPPED[@]}"
fi

N_COUNTABLE=$(printf '%s\n' "${MAP_VALS[@]}" | sort -u | wc -l | tr -d ' ')
N_SHARED=${#COUNTED_AS_OTHER[@]}
N_NOT=${#NOT_COUNTABLE[@]}

echo ""
echo "COVERAGE: this script counts $N_COUNTABLE of $(( N_COUNTABLE + N_SHARED + N_NOT )) Firefly-supported GCP types"
echo "      directly; $N_SHARED more (managed SSL certificates, bucket IAM bindings/"
echo "      policies) are included under the SSL certificate / bucket IAM member"
echo "      rows. The other $N_NOT (Apigee sub-entities, Cloud Scheduler jobs, SQL"
echo "      databases, bucket ACLs, HMAC keys) are not exposed by Cloud Asset"
echo "      Inventory. Treat the total as a LOWER BOUND of Firefly-supported assets."
if [[ $VERBOSE -eq 1 ]]; then
  echo ""
  echo "Supported types not countable via Cloud Asset Inventory:"
  printf '  %s\n' "${NOT_COUNTABLE[@]}"
else
  echo "      Run with -v to list them."
fi
echo ""
echo "CSV written to: $OUT_CSV"
