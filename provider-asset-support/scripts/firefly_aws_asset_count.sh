#!/usr/bin/env bash
#
# =============================================================================
#  Firefly - AWS Supported Asset Count
# =============================================================================
#  Counts the resources in this AWS account that match Firefly's supported
#  AWS Terraform resource types, using AWS Config advanced queries.
#
#  READ-ONLY: this script only calls Describe/List/Select APIs.
#
#  HOW IT WORKS
#    1. Runs an AWS Config advanced query per region:
#         SELECT resourceType, COUNT(*) GROUP BY resourceType
#    2. Maps each AWS Config resource type to its Terraform resource type
#       and keeps only the ones on Firefly's supported list.
#    3. Prints a per-type breakdown + grand total, and writes a CSV.
#
#  REQUIREMENTS
#    - aws CLI v2, jq
#    - AWS Config recorder ENABLED in the regions you care about
#      (this is how the counts are sourced). If Config is not enabled in a
#      region, that region is skipped and reported at the end.
#    - IAM permissions: config:SelectResourceConfig, ec2:DescribeRegions
#      (or use --aggregator for org-wide counts: config:SelectAggregateResourceConfig)
#
#  USAGE
#    ./firefly_aws_asset_count.sh                       # all enabled regions, current account
#    ./firefly_aws_asset_count.sh -r "us-east-1 eu-west-1"
#    ./firefly_aws_asset_count.sh -a MY_AGGREGATOR      # org-wide via Config aggregator
#    ./firefly_aws_asset_count.sh -p my-profile
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}", which PROFILE_ARG hits
# any time -p isn't passed. Every scalar var below has an explicit default.

PROFILE_ARG=()
REGIONS=""
AGGREGATOR=""
OUT_CSV="firefly_aws_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "p:r:a:h" opt; do
  case $opt in
    p) PROFILE_ARG=(--profile "$OPTARG") ;;
    r) REGIONS="$OPTARG" ;;
    a) AGGREGATOR="$OPTARG" ;;
    h) awk '/^#/{print; next} {exit}' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found";      exit 1; }

# -----------------------------------------------------------------------------
# AWS Config resourceType -> Firefly-supported Terraform resource type
# (Only types recordable by AWS Config appear here; unmapped types found in
#  the account are reported separately so nothing is hidden.)
# -----------------------------------------------------------------------------
MAP_KEYS=(
  "AWS::ACM::Certificate"
  "AWS::ApiGateway::RestApi"
  "AWS::ApiGateway::Stage"
  "AWS::ApiGatewayV2::Api"
  "AWS::ApiGatewayV2::Stage"
  "AWS::AppConfig::Application"
  "AWS::Athena::DataCatalog"
  "AWS::Athena::WorkGroup"
  "AWS::AutoScaling::AutoScalingGroup"
  "AWS::AutoScaling::LaunchConfiguration"
  "AWS::AutoScaling::ScalingPolicy"
  "AWS::Backup::BackupVault"
  "AWS::CloudFront::Distribution"
  "AWS::CloudFront::Function"
  "AWS::CloudTrail::Trail"
  "AWS::CloudWatch::Alarm"
  "AWS::CloudWatch::MetricStream"
  "AWS::Events::EventBus"
  "AWS::Events::Rule"
  "AWS::Logs::LogGroup"
  "AWS::CodeBuild::Project"
  "AWS::CodeBuild::ReportGroup"
  "AWS::CodeDeploy::Application"
  "AWS::CodeDeploy::DeploymentConfig"
  "AWS::CodeDeploy::DeploymentGroup"
  "AWS::CodePipeline::Pipeline"
  "AWS::Cognito::IdentityPool"
  "AWS::Cognito::UserPool"
  "AWS::Cognito::UserPoolClient"
  "AWS::Cognito::UserPoolGroup"
  "AWS::Config::ConfigurationRecorder"
  "AWS::Connect::Instance"
  "AWS::DMS::Endpoint"
  "AWS::DMS::ReplicationInstance"
  "AWS::DynamoDB::Table"
  "AWS::EC2::DHCPOptions"
  "AWS::EC2::EIP"
  "AWS::EC2::FlowLog"
  "AWS::EC2::Instance"
  "AWS::EC2::InternetGateway"
  "AWS::EC2::LaunchTemplate"
  "AWS::EC2::NatGateway"
  "AWS::EC2::NetworkAcl"
  "AWS::EC2::NetworkInterface"
  "AWS::EC2::RouteTable"
  "AWS::EC2::SecurityGroup"
  "AWS::EC2::Subnet"
  "AWS::EC2::TrafficMirrorFilter"
  "AWS::EC2::TrafficMirrorSession"
  "AWS::EC2::TrafficMirrorTarget"
  "AWS::EC2::TransitGateway"
  "AWS::EC2::TransitGatewayAttachment"
  "AWS::EC2::TransitGatewayRouteTable"
  "AWS::EC2::Volume"
  "AWS::EC2::VPC"
  "AWS::EC2::VPCEndpoint"
  "AWS::EC2::VPCEndpointService"
  "AWS::EC2::VPCPeeringConnection"
  "AWS::EC2::VPNConnection"
  "AWS::EC2::VPNGateway"
  "AWS::ECR::PublicRepository"
  "AWS::ECR::Repository"
  "AWS::ECS::CapacityProvider"
  "AWS::ECS::Cluster"
  "AWS::ECS::Service"
  "AWS::ECS::TaskDefinition"
  "AWS::EFS::AccessPoint"
  "AWS::EFS::FileSystem"
  "AWS::EKS::Addon"
  "AWS::EKS::Cluster"
  "AWS::EKS::FargateProfile"
  "AWS::ElasticBeanstalk::Application"
  "AWS::ElasticBeanstalk::Environment"
  "AWS::Elasticsearch::Domain"
  "AWS::OpenSearch::Domain"
  "AWS::ElasticLoadBalancing::LoadBalancer"
  "AWS::ElasticLoadBalancingV2::LoadBalancer"
  "AWS::ElasticLoadBalancingV2::Listener"
  "AWS::GlobalAccelerator::Accelerator"
  "AWS::GlobalAccelerator::Listener"
  "AWS::Glue::Job"
  "AWS::GuardDuty::Detector"
  "AWS::IAM::Group"
  "AWS::IAM::Policy"
  "AWS::IAM::Role"
  "AWS::IAM::User"
  "AWS::KMS::Alias"
  "AWS::KMS::Key"
  "AWS::Kinesis::Stream"
  "AWS::Kinesis::StreamConsumer"
  "AWS::KinesisFirehose::DeliveryStream"
  "AWS::Lambda::CodeSigningConfig"
  "AWS::Lambda::Function"
  "AWS::AmazonMQ::Broker"
  "AWS::MSK::Cluster"
  "AWS::NetworkFirewall::Firewall"
  "AWS::RDS::DBCluster"
  "AWS::RDS::DBClusterSnapshot"
  "AWS::RDS::DBInstance"
  "AWS::RDS::DBSecurityGroup"
  "AWS::RDS::DBSnapshot"
  "AWS::RDS::DBSubnetGroup"
  "AWS::RDS::EventSubscription"
  "AWS::Redshift::Cluster"
  "AWS::Redshift::ClusterParameterGroup"
  "AWS::Redshift::ClusterSubnetGroup"
  "AWS::Route53::HostedZone"
  "AWS::Route53Resolver::ResolverEndpoint"
  "AWS::S3::Bucket"
  "AWS::SageMaker::Domain"
  "AWS::SageMaker::EndpointConfig"
  "AWS::SageMaker::Model"
  "AWS::SageMaker::NotebookInstance"
  "AWS::SecretsManager::Secret"
  "AWS::ServiceDiscovery::Service"
  "AWS::StepFunctions::StateMachine"
  "AWS::SNS::Topic"
  "AWS::SQS::Queue"
  "AWS::WAFv2::WebACL"
)

MAP_VALS=(
  "aws_acm_certificate"
  "aws_api_gateway_rest_api"
  "aws_api_gateway_stage"
  "aws_apigatewayv2_api"
  "aws_apigatewayv2_stage"
  "aws_appconfig_application"
  "aws_athena_data_catalog"
  "aws_athena_workgroup"
  "aws_autoscaling_group"
  "aws_launch_configuration"
  "aws_autoscaling_policy"
  "aws_backup_vault"
  "aws_cloudfront_distribution"
  "aws_cloudfront_function"
  "aws_cloudtrail"
  "aws_cloudwatch_metric_alarm"
  "aws_cloudwatch_metric_stream"
  "aws_cloudwatch_event_bus"
  "aws_cloudwatch_event_rule"
  "aws_cloudwatch_log_group"
  "aws_codebuild_project"
  "aws_codebuild_report_group"
  "aws_codedeploy_app"
  "aws_codedeploy_deployment_config"
  "aws_codedeploy_deployment_group"
  "aws_codepipeline"
  "aws_cognito_identity_pool"
  "aws_cognito_user_pool"
  "aws_cognito_user_pool_client"
  "aws_cognito_user_group"
  "aws_config_configuration_recorder"
  "aws_connect_instance"
  "aws_dms_endpoint"
  "aws_dms_replication_instance"
  "aws_dynamodb_table"
  "aws_vpc_dhcp_options"
  "aws_eip"
  "aws_flow_log"
  "aws_instance"
  "aws_internet_gateway"
  "aws_launch_template"
  "aws_nat_gateway"
  "aws_network_acl"
  "aws_network_interface"
  "aws_route_table"
  "aws_security_group"
  "aws_subnet"
  "aws_ec2_traffic_mirror_filter"
  "aws_ec2_traffic_mirror_session"
  "aws_ec2_traffic_mirror_target"
  "aws_ec2_transit_gateway"
  "aws_ec2_transit_gateway_vpc_attachment"
  "aws_ec2_transit_gateway_route_table"
  "aws_ebs_volume"
  "aws_vpc"
  "aws_vpc_endpoint"
  "aws_vpc_endpoint_service"
  "aws_vpc_peering_connection"
  "aws_vpn_connection"
  "aws_vpn_gateway"
  "aws_ecrpublic_repository"
  "aws_ecr_repository"
  "aws_ecs_capacity_provider"
  "aws_ecs_cluster"
  "aws_ecs_service"
  "aws_ecs_task_definition"
  "aws_efs_access_point"
  "aws_efs_file_system"
  "aws_eks_addon"
  "aws_eks_cluster"
  "aws_eks_fargate_profile"
  "aws_elastic_beanstalk_application"
  "aws_elastic_beanstalk_environment"
  "aws_elasticsearch_domain"
  "aws_opensearch_domain"
  "aws_elb"
  "aws_lb"
  "aws_lb_listener"
  "aws_globalaccelerator_accelerator"
  "aws_globalaccelerator_listener"
  "aws_glue_job"
  "aws_guardduty_detector"
  "aws_iam_group"
  "aws_iam_policy"
  "aws_iam_role"
  "aws_iam_user"
  "aws_kms_alias"
  "aws_kms_key"
  "aws_kinesis_stream"
  "aws_kinesis_stream_consumer"
  "aws_kinesis_firehose_delivery_stream"
  "aws_lambda_code_signing_config"
  "aws_lambda_function"
  "aws_mq_broker"
  "aws_msk_cluster"
  "aws_networkfirewall_firewall"
  "aws_rds_cluster"
  "aws_db_cluster_snapshot"
  "aws_db_instance"
  "aws_db_security_group"
  "aws_db_snapshot"
  "aws_db_subnet_group"
  "aws_db_event_subscription"
  "aws_redshift_cluster"
  "aws_redshift_parameter_group"
  "aws_redshift_subnet_group"
  "aws_route53_zone"
  "aws_route53_resolver_endpoint"
  "aws_s3_bucket"
  "aws_sagemaker_domain"
  "aws_sagemaker_endpoint_configuration"
  "aws_sagemaker_model"
  "aws_sagemaker_notebook_instance"
  "aws_secretsmanager_secret"
  "aws_service_discovery_service"
  "aws_sfn_state_machine"
  "aws_sns_topic"
  "aws_sqs_queue"
  "aws_wafv2_web_acl"
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

# Global services recorded by Config in a single "home" region.
# For these we take the MAX across regions instead of the SUM,
# to avoid double counting if global recording is on in several regions.
GLOBAL_PREFIXES="AWS::IAM:: AWS::CloudFront:: AWS::Route53:: AWS::GlobalAccelerator:: AWS::ECR::PublicRepository"

is_global() {
  local t="$1"
  for p in $GLOBAL_PREFIXES; do
    [[ "$t" == "$p"* || "$t" == "$p" ]] && return 0
  done
  return 1
}

QUERY="SELECT resourceType, COUNT(*) GROUP BY resourceType"

# Same parallel-array approach as MAP for the runtime-populated tallies below,
# since Bash 3.2 can't use associative arrays keyed by resourceType.
SUM_KEYS=(); SUM_VALS=()          # regional types: summed
MAX_KEYS=(); MAX_VALS=()          # global types: max across regions
UNMAPPED_KEYS=(); UNMAPPED_VALS=()
SKIPPED_REGIONS=()

sum_add() { # sum_add <key> <amount> - adds amount to key's running total
  local key="$1" amount="$2" i
  for i in "${!SUM_KEYS[@]}"; do
    if [[ "${SUM_KEYS[$i]}" == "$key" ]]; then
      SUM_VALS[$i]=$(( SUM_VALS[$i] + amount ))
      return
    fi
  done
  SUM_KEYS+=("$key")
  SUM_VALS+=("$amount")
}

sum_get() { # sum_get <key> - prints current total, or 0
  local key="$1" i
  for i in "${!SUM_KEYS[@]}"; do
    [[ "${SUM_KEYS[$i]}" == "$key" ]] && { printf '%s' "${SUM_VALS[$i]}"; return; }
  done
  printf '0'
}

max_update() { # max_update <key> <candidate> - keeps the larger of the two
  local key="$1" candidate="$2" i
  for i in "${!MAX_KEYS[@]}"; do
    if [[ "${MAX_KEYS[$i]}" == "$key" ]]; then
      (( candidate > MAX_VALS[$i] )) && MAX_VALS[$i]=$candidate
      return
    fi
  done
  MAX_KEYS+=("$key")
  MAX_VALS+=("$candidate")
}

max_get() { # max_get <key> - prints current max, or 0
  local key="$1" i
  for i in "${!MAX_KEYS[@]}"; do
    [[ "${MAX_KEYS[$i]}" == "$key" ]] && { printf '%s' "${MAX_VALS[$i]}"; return; }
  done
  printf '0'
}

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

run_query_region() {
  local region="$1" next="" out rows
  while :; do
    if [[ -n "$next" ]]; then
      out=$(aws configservice select-resource-config "${PROFILE_ARG[@]}" \
              --region "$region" --expression "$QUERY" --next-token "$next" 2>/dev/null) || return 1
    else
      out=$(aws configservice select-resource-config "${PROFILE_ARG[@]}" \
              --region "$region" --expression "$QUERY" 2>/dev/null) || return 1
    fi
    rows=$(echo "$out" | jq -r '.Results[] | fromjson | "\(.resourceType)|\(."COUNT(*)")"')
    while IFS='|' read -r rtype rcount; do
      [[ -z "$rtype" ]] && continue
      if is_global "$rtype"; then
        max_update "$rtype" "$rcount"
      else
        sum_add "$rtype" "$rcount"
      fi
    done <<< "$rows"
    next=$(echo "$out" | jq -r '.NextToken // empty')
    [[ -z "$next" ]] && break
  done
  return 0
}

echo "============================================================"
echo " Firefly - AWS Supported Asset Count"
echo " Account: $(aws sts get-caller-identity "${PROFILE_ARG[@]}" --query Account --output text 2>/dev/null || echo 'unknown')"
echo " Date:    $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "============================================================"

if [[ -n "$AGGREGATOR" ]]; then
  echo "Mode: AWS Config aggregator '$AGGREGATOR' (org / multi-account)"
  next=""
  while :; do
    if [[ -n "$next" ]]; then
      out=$(aws configservice select-aggregate-resource-config "${PROFILE_ARG[@]}" \
              --configuration-aggregator-name "$AGGREGATOR" \
              --expression "$QUERY" --next-token "$next") || exit 1
    else
      out=$(aws configservice select-aggregate-resource-config "${PROFILE_ARG[@]}" \
              --configuration-aggregator-name "$AGGREGATOR" \
              --expression "$QUERY") || exit 1
    fi
    while IFS='|' read -r rtype rcount; do
      [[ -z "$rtype" ]] && continue
      sum_add "$rtype" "$rcount"
    done <<< "$(echo "$out" | jq -r '.Results[] | fromjson | "\(.resourceType)|\(."COUNT(*)")"')"
    next=$(echo "$out" | jq -r '.NextToken // empty')
    [[ -z "$next" ]] && break
  done
else
  if [[ -z "$REGIONS" ]]; then
    REGIONS=$(aws ec2 describe-regions "${PROFILE_ARG[@]}" \
                --query "Regions[].RegionName" --output text)
  fi
  echo "Mode: per-region Config query"
  for region in $REGIONS; do
    printf "  querying %-16s ... " "$region"
    if run_query_region "$region"; then
      echo "ok"
    else
      echo "skipped (Config not enabled or no access)"
      SKIPPED_REGIONS+=("$region")
    fi
  done
fi

# Merge global maxima into the totals
for t in "${MAX_KEYS[@]}"; do
  sum_add "$t" "$(max_get "$t")"
done

# ------------------------- report -------------------------
TOTAL=0
echo ""
echo "------------------------------------------------------------"
printf "%-55s %10s\n" "Firefly-supported Terraform type" "Count"
echo "------------------------------------------------------------"
echo "terraform_type,aws_config_type,count" > "$OUT_CSV"

for cfg_type in $(printf '%s\n' "${SUM_KEYS[@]}" | sort); do
  tf_type=$(map_lookup "$cfg_type") || tf_type=""
  count=$(sum_get "$cfg_type")
  if [[ -n "$tf_type" ]]; then
    printf "%-55s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$cfg_type,$count" >> "$OUT_CSV"
    TOTAL=$(( TOTAL + count ))
  else
    unmapped_set "$cfg_type" "$count"
  fi
done

echo "------------------------------------------------------------"
printf "%-55s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ ${#UNMAPPED_KEYS[@]} -gt 0 ]]; then
  echo ""
  echo "Other resource types found in AWS Config (not on the supported list / not mapped):"
  for t in $(printf '%s\n' "${UNMAPPED_KEYS[@]}" | sort); do
    printf "  %-53s %10d\n" "$t" "$(unmapped_get "$t")"
  done
fi

if [[ ${#SKIPPED_REGIONS[@]} -gt 0 ]]; then
  echo ""
  echo "NOTE: These regions were skipped (AWS Config recorder not enabled or no access):"
  echo "  ${SKIPPED_REGIONS[*]}"
fi

echo ""
echo "NOTE: Counts are sourced from AWS Config, so only resource types that"
echo "      AWS Config records are included. Sub-resources Firefly also codifies"
echo "      (e.g. s3 bucket policies/ACLs, IAM role policies, API GW methods,"
echo "      listener rules) are not separately counted here - treat this total"
echo "      as a LOWER BOUND of Firefly-supported assets."
echo ""
echo "CSV written to: $OUT_CSV"
