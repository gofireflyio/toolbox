#!/usr/bin/env bash
#
# =============================================================================
#  Firefly - GCP Supported Asset Count
# =============================================================================
#  Counts the resources in a GCP project / folder / organization that match
#  Firefly's supported GCP Terraform resource types, using Cloud Asset
#  Inventory (CAI).
#
#  READ-ONLY: this script only runs 'gcloud asset search-all-resources'.
#
#  HOW IT WORKS
#    1. Runs Cloud Asset Inventory search across the chosen scope and
#       groups results by assetType.
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
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}". No arrays here today, but
# keeping this consistent with the other two scripts in this repo.

SCOPE=""
OUT_CSV="firefly_gcp_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "p:o:f:h" opt; do
  case $opt in
    p) SCOPE="projects/$OPTARG" ;;
    o) SCOPE="organizations/$OPTARG" ;;
    f) SCOPE="folders/$OPTARG" ;;
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
  "apigee.googleapis.com/EnvironmentGroup"
  "apigee.googleapis.com/Instance"
  "bigquery.googleapis.com/Dataset"
  "bigquery.googleapis.com/Table"
  "bigquery.googleapis.com/Routine"
  "bigtableadmin.googleapis.com/AppProfile"
  "bigtableadmin.googleapis.com/Instance"
  "bigtableadmin.googleapis.com/Table"
  "run.googleapis.com/Service"
  "cloudscheduler.googleapis.com/Job"
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
)

MAP_VALS=(
  "google_apigee_organization"
  "google_apigee_environment"
  "google_apigee_envgroup"
  "google_apigee_instance"
  "google_bigquery_dataset"
  "google_bigquery_table"
  "google_bigquery_routine"
  "google_bigtable_app_profile"
  "google_bigtable_instance"
  "google_bigtable_table"
  "google_cloud_run_v2_service"
  "google_cloud_scheduler_job"
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
RAW=$(gcloud asset search-all-resources \
        --scope="$SCOPE" \
        --page-size=500 \
        --format="value(assetType)" 2>/tmp/gcp_asset_err.log)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Cloud Asset Inventory query failed:"
  cat /tmp/gcp_asset_err.log
  echo ""
  echo "Check that cloudasset.googleapis.com is enabled and that you have"
  echo "roles/cloudasset.viewer on $SCOPE."
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

while read -r c t; do
  [[ -z "${t:-}" ]] && continue
  count_set "$t" "$c"
done <<< "$(echo "$RAW" | sort | uniq -c | awk '{print $1, $2}')"

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

for cai_type in $(printf '%s\n' "${COUNT_KEYS[@]}" | sort); do
  tf_type=$(map_lookup "$cai_type") || tf_type=""
  count=$(count_get "$cai_type")
  if [[ -n "$tf_type" ]]; then
    printf "%-55s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$cai_type,$count" >> "$OUT_CSV"
    TOTAL=$(( TOTAL + count ))
  else
    unmapped_set "$cai_type" "$count"
  fi
done

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

echo ""
echo "NOTE: IAM bindings/members/policies (google_*_iam_*), Apigee sub-entities"
echo "      (proxies, products, developers, flowhooks, KVMs), SQL databases and"
echo "      HMAC keys are configuration/sub-resources without a discrete Cloud"
echo "      Asset Inventory entry, so they are not counted here. Treat this"
echo "      total as a LOWER BOUND of Firefly-supported assets."
echo ""
echo "CSV written to: $OUT_CSV"
