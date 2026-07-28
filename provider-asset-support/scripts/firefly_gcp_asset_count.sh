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

set -uo pipefail

SCOPE=""
OUT_CSV="firefly_gcp_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "p:o:f:h" opt; do
  case $opt in
    p) SCOPE="projects/$OPTARG" ;;
    o) SCOPE="organizations/$OPTARG" ;;
    f) SCOPE="folders/$OPTARG" ;;
    h) grep '^#' "$0" | head -35; exit 0 ;;
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
declare -A MAP=(
  ["apigee.googleapis.com/Organization"]="google_apigee_organization"
  ["apigee.googleapis.com/Environment"]="google_apigee_environment"
  ["apigee.googleapis.com/EnvironmentGroup"]="google_apigee_envgroup"
  ["apigee.googleapis.com/Instance"]="google_apigee_instance"
  ["bigquery.googleapis.com/Dataset"]="google_bigquery_dataset"
  ["bigquery.googleapis.com/Table"]="google_bigquery_table"
  ["bigquery.googleapis.com/Routine"]="google_bigquery_routine"
  ["bigtableadmin.googleapis.com/AppProfile"]="google_bigtable_app_profile"
  ["bigtableadmin.googleapis.com/Instance"]="google_bigtable_instance"
  ["bigtableadmin.googleapis.com/Table"]="google_bigtable_table"
  ["run.googleapis.com/Service"]="google_cloud_run_v2_service"
  ["cloudscheduler.googleapis.com/Job"]="google_cloud_scheduler_job"
  ["cloudfunctions.googleapis.com/CloudFunction"]="google_cloudfunctions_function"
  ["cloudfunctions.googleapis.com/Function"]="google_cloudfunctions2_function"
  ["composer.googleapis.com/Environment"]="google_composer_environment"
  ["compute.googleapis.com/Address"]="google_compute_address"
  ["compute.googleapis.com/GlobalAddress"]="google_compute_global_address"
  ["compute.googleapis.com/Autoscaler"]="google_compute_autoscaler"
  ["compute.googleapis.com/BackendService"]="google_compute_backend_service"
  ["compute.googleapis.com/RegionBackendService"]="google_compute_region_backend_service"
  ["compute.googleapis.com/Disk"]="google_compute_disk"
  ["compute.googleapis.com/RegionDisk"]="google_compute_region_disk"
  ["compute.googleapis.com/Firewall"]="google_compute_firewall"
  ["compute.googleapis.com/ForwardingRule"]="google_compute_forwarding_rule"
  ["compute.googleapis.com/GlobalForwardingRule"]="google_compute_global_forwarding_rule"
  ["compute.googleapis.com/HealthCheck"]="google_compute_health_check"
  ["compute.googleapis.com/Image"]="google_compute_image"
  ["compute.googleapis.com/Instance"]="google_compute_instance"
  ["compute.googleapis.com/InstanceGroup"]="google_compute_instance_group"
  ["compute.googleapis.com/InstanceGroupManager"]="google_compute_instance_group_manager"
  ["compute.googleapis.com/InstanceTemplate"]="google_compute_instance_template"
  ["compute.googleapis.com/Network"]="google_compute_network"
  ["compute.googleapis.com/NetworkEndpointGroup"]="google_compute_network_endpoint_group"
  ["compute.googleapis.com/ResourcePolicy"]="google_compute_resource_policy"
  ["compute.googleapis.com/Router"]="google_compute_router"
  ["compute.googleapis.com/SecurityPolicy"]="google_compute_security_policy"
  ["compute.googleapis.com/Snapshot"]="google_compute_snapshot"
  ["compute.googleapis.com/SslCertificate"]="google_compute_ssl_certificate"
  ["compute.googleapis.com/SslPolicy"]="google_compute_ssl_policy"
  ["compute.googleapis.com/Subnetwork"]="google_compute_subnetwork"
  ["compute.googleapis.com/TargetHttpProxy"]="google_compute_target_http_proxy"
  ["compute.googleapis.com/TargetHttpsProxy"]="google_compute_target_https_proxy"
  ["compute.googleapis.com/TargetPool"]="google_compute_target_pool"
  ["compute.googleapis.com/UrlMap"]="google_compute_url_map"
  ["container.googleapis.com/Cluster"]="google_container_cluster"
  ["container.googleapis.com/NodePool"]="google_container_node_pool"
  ["dns.googleapis.com/ManagedZone"]="google_dns_managed_zone"
  ["dns.googleapis.com/ResourceRecordSet"]="google_dns_record_set"
  ["file.googleapis.com/Backup"]="google_filestore_backup"
  ["file.googleapis.com/Instance"]="google_filestore_instance"
  ["iam.googleapis.com/ServiceAccount"]="google_service_account"
  ["iam.googleapis.com/Role"]="google_project_iam_custom_role"
  ["iam.googleapis.com/WorkloadIdentityPool"]="google_iam_workload_identity_pool"
  ["logging.googleapis.com/LogSink"]="google_logging_project_sink"
  ["pubsub.googleapis.com/Schema"]="google_pubsub_schema"
  ["pubsub.googleapis.com/Subscription"]="google_pubsub_subscription"
  ["pubsub.googleapis.com/Topic"]="google_pubsub_topic"
  ["redis.googleapis.com/Instance"]="google_redis_instance"
  ["secretmanager.googleapis.com/Secret"]="google_secret_manager_secret"
  ["spanner.googleapis.com/Database"]="google_spanner_database"
  ["spanner.googleapis.com/Instance"]="google_spanner_instance"
  ["sqladmin.googleapis.com/Instance"]="google_sql_database_instance"
  ["storage.googleapis.com/Bucket"]="google_storage_bucket"
  ["cloudresourcemanager.googleapis.com/Project"]="google_project"
)

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

declare -A COUNTS
while read -r c t; do
  [[ -z "${t:-}" ]] && continue
  COUNTS[$t]=$c
done <<< "$(echo "$RAW" | sort | uniq -c | awk '{print $1, $2}')"

# ------------------------- report -------------------------
TOTAL=0
declare -A UNMAPPED
echo ""
echo "------------------------------------------------------------"
printf "%-55s %10s\n" "Firefly-supported Terraform type" "Count"
echo "------------------------------------------------------------"
echo "terraform_type,cai_asset_type,count" > "$OUT_CSV"

for cai_type in $(echo "${!COUNTS[@]}" | tr ' ' '\n' | sort); do
  tf_type="${MAP[$cai_type]:-}"
  count=${COUNTS[$cai_type]}
  if [[ -n "$tf_type" ]]; then
    printf "%-55s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$cai_type,$count" >> "$OUT_CSV"
    TOTAL=$(( TOTAL + count ))
  else
    UNMAPPED[$cai_type]=$count
  fi
done

echo "------------------------------------------------------------"
printf "%-55s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ ${#UNMAPPED[@]} -gt 0 ]]; then
  echo ""
  echo "Other asset types found in Cloud Asset Inventory (not on the supported list / not mapped):"
  for t in $(echo "${!UNMAPPED[@]}" | tr ' ' '\n' | sort); do
    printf "  %-53s %10d\n" "$t" "${UNMAPPED[$t]}"
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
