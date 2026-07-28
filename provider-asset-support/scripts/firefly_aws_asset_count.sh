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

set -uo pipefail

PROFILE_ARG=()
REGIONS=""
AGGREGATOR=""
OUT_CSV="firefly_aws_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "p:r:a:h" opt; do
  case $opt in
    p) PROFILE_ARG=(--profile "$OPTARG") ;;
    r) REGIONS="$OPTARG" ;;
    a) AGGREGATOR="$OPTARG" ;;
    h) grep '^#' "$0" | head -40; exit 0 ;;
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
declare -A MAP=(
  ["AWS::ACM::Certificate"]="aws_acm_certificate"
  ["AWS::ApiGateway::RestApi"]="aws_api_gateway_rest_api"
  ["AWS::ApiGateway::Stage"]="aws_api_gateway_stage"
  ["AWS::ApiGatewayV2::Api"]="aws_apigatewayv2_api"
  ["AWS::ApiGatewayV2::Stage"]="aws_apigatewayv2_stage"
  ["AWS::AppConfig::Application"]="aws_appconfig_application"
  ["AWS::Athena::DataCatalog"]="aws_athena_data_catalog"
  ["AWS::Athena::WorkGroup"]="aws_athena_workgroup"
  ["AWS::AutoScaling::AutoScalingGroup"]="aws_autoscaling_group"
  ["AWS::AutoScaling::LaunchConfiguration"]="aws_launch_configuration"
  ["AWS::AutoScaling::ScalingPolicy"]="aws_autoscaling_policy"
  ["AWS::Backup::BackupVault"]="aws_backup_vault"
  ["AWS::CloudFront::Distribution"]="aws_cloudfront_distribution"
  ["AWS::CloudFront::Function"]="aws_cloudfront_function"
  ["AWS::CloudTrail::Trail"]="aws_cloudtrail"
  ["AWS::CloudWatch::Alarm"]="aws_cloudwatch_metric_alarm"
  ["AWS::CloudWatch::MetricStream"]="aws_cloudwatch_metric_stream"
  ["AWS::Events::EventBus"]="aws_cloudwatch_event_bus"
  ["AWS::Events::Rule"]="aws_cloudwatch_event_rule"
  ["AWS::Logs::LogGroup"]="aws_cloudwatch_log_group"
  ["AWS::CodeBuild::Project"]="aws_codebuild_project"
  ["AWS::CodeBuild::ReportGroup"]="aws_codebuild_report_group"
  ["AWS::CodeDeploy::Application"]="aws_codedeploy_app"
  ["AWS::CodeDeploy::DeploymentConfig"]="aws_codedeploy_deployment_config"
  ["AWS::CodeDeploy::DeploymentGroup"]="aws_codedeploy_deployment_group"
  ["AWS::CodePipeline::Pipeline"]="aws_codepipeline"
  ["AWS::Cognito::IdentityPool"]="aws_cognito_identity_pool"
  ["AWS::Cognito::UserPool"]="aws_cognito_user_pool"
  ["AWS::Cognito::UserPoolClient"]="aws_cognito_user_pool_client"
  ["AWS::Cognito::UserPoolGroup"]="aws_cognito_user_group"
  ["AWS::Config::ConfigurationRecorder"]="aws_config_configuration_recorder"
  ["AWS::Connect::Instance"]="aws_connect_instance"
  ["AWS::DMS::Endpoint"]="aws_dms_endpoint"
  ["AWS::DMS::ReplicationInstance"]="aws_dms_replication_instance"
  ["AWS::DynamoDB::Table"]="aws_dynamodb_table"
  ["AWS::EC2::DHCPOptions"]="aws_vpc_dhcp_options"
  ["AWS::EC2::EIP"]="aws_eip"
  ["AWS::EC2::FlowLog"]="aws_flow_log"
  ["AWS::EC2::Instance"]="aws_instance"
  ["AWS::EC2::InternetGateway"]="aws_internet_gateway"
  ["AWS::EC2::LaunchTemplate"]="aws_launch_template"
  ["AWS::EC2::NatGateway"]="aws_nat_gateway"
  ["AWS::EC2::NetworkAcl"]="aws_network_acl"
  ["AWS::EC2::NetworkInterface"]="aws_network_interface"
  ["AWS::EC2::RouteTable"]="aws_route_table"
  ["AWS::EC2::SecurityGroup"]="aws_security_group"
  ["AWS::EC2::Subnet"]="aws_subnet"
  ["AWS::EC2::TrafficMirrorFilter"]="aws_ec2_traffic_mirror_filter"
  ["AWS::EC2::TrafficMirrorSession"]="aws_ec2_traffic_mirror_session"
  ["AWS::EC2::TrafficMirrorTarget"]="aws_ec2_traffic_mirror_target"
  ["AWS::EC2::TransitGateway"]="aws_ec2_transit_gateway"
  ["AWS::EC2::TransitGatewayAttachment"]="aws_ec2_transit_gateway_vpc_attachment"
  ["AWS::EC2::TransitGatewayRouteTable"]="aws_ec2_transit_gateway_route_table"
  ["AWS::EC2::Volume"]="aws_ebs_volume"
  ["AWS::EC2::VPC"]="aws_vpc"
  ["AWS::EC2::VPCEndpoint"]="aws_vpc_endpoint"
  ["AWS::EC2::VPCEndpointService"]="aws_vpc_endpoint_service"
  ["AWS::EC2::VPCPeeringConnection"]="aws_vpc_peering_connection"
  ["AWS::EC2::VPNConnection"]="aws_vpn_connection"
  ["AWS::EC2::VPNGateway"]="aws_vpn_gateway"
  ["AWS::ECR::PublicRepository"]="aws_ecrpublic_repository"
  ["AWS::ECR::Repository"]="aws_ecr_repository"
  ["AWS::ECS::CapacityProvider"]="aws_ecs_capacity_provider"
  ["AWS::ECS::Cluster"]="aws_ecs_cluster"
  ["AWS::ECS::Service"]="aws_ecs_service"
  ["AWS::ECS::TaskDefinition"]="aws_ecs_task_definition"
  ["AWS::EFS::AccessPoint"]="aws_efs_access_point"
  ["AWS::EFS::FileSystem"]="aws_efs_file_system"
  ["AWS::EKS::Addon"]="aws_eks_addon"
  ["AWS::EKS::Cluster"]="aws_eks_cluster"
  ["AWS::EKS::FargateProfile"]="aws_eks_fargate_profile"
  ["AWS::ElasticBeanstalk::Application"]="aws_elastic_beanstalk_application"
  ["AWS::ElasticBeanstalk::Environment"]="aws_elastic_beanstalk_environment"
  ["AWS::Elasticsearch::Domain"]="aws_elasticsearch_domain"
  ["AWS::OpenSearch::Domain"]="aws_opensearch_domain"
  ["AWS::ElasticLoadBalancing::LoadBalancer"]="aws_elb"
  ["AWS::ElasticLoadBalancingV2::LoadBalancer"]="aws_lb"
  ["AWS::ElasticLoadBalancingV2::Listener"]="aws_lb_listener"
  ["AWS::GlobalAccelerator::Accelerator"]="aws_globalaccelerator_accelerator"
  ["AWS::GlobalAccelerator::Listener"]="aws_globalaccelerator_listener"
  ["AWS::Glue::Job"]="aws_glue_job"
  ["AWS::GuardDuty::Detector"]="aws_guardduty_detector"
  ["AWS::IAM::Group"]="aws_iam_group"
  ["AWS::IAM::Policy"]="aws_iam_policy"
  ["AWS::IAM::Role"]="aws_iam_role"
  ["AWS::IAM::User"]="aws_iam_user"
  ["AWS::KMS::Alias"]="aws_kms_alias"
  ["AWS::KMS::Key"]="aws_kms_key"
  ["AWS::Kinesis::Stream"]="aws_kinesis_stream"
  ["AWS::Kinesis::StreamConsumer"]="aws_kinesis_stream_consumer"
  ["AWS::KinesisFirehose::DeliveryStream"]="aws_kinesis_firehose_delivery_stream"
  ["AWS::Lambda::CodeSigningConfig"]="aws_lambda_code_signing_config"
  ["AWS::Lambda::Function"]="aws_lambda_function"
  ["AWS::AmazonMQ::Broker"]="aws_mq_broker"
  ["AWS::MSK::Cluster"]="aws_msk_cluster"
  ["AWS::NetworkFirewall::Firewall"]="aws_networkfirewall_firewall"
  ["AWS::RDS::DBCluster"]="aws_rds_cluster"
  ["AWS::RDS::DBClusterSnapshot"]="aws_db_cluster_snapshot"
  ["AWS::RDS::DBInstance"]="aws_db_instance"
  ["AWS::RDS::DBSecurityGroup"]="aws_db_security_group"
  ["AWS::RDS::DBSnapshot"]="aws_db_snapshot"
  ["AWS::RDS::DBSubnetGroup"]="aws_db_subnet_group"
  ["AWS::RDS::EventSubscription"]="aws_db_event_subscription"
  ["AWS::Redshift::Cluster"]="aws_redshift_cluster"
  ["AWS::Redshift::ClusterParameterGroup"]="aws_redshift_parameter_group"
  ["AWS::Redshift::ClusterSubnetGroup"]="aws_redshift_subnet_group"
  ["AWS::Route53::HostedZone"]="aws_route53_zone"
  ["AWS::Route53Resolver::ResolverEndpoint"]="aws_route53_resolver_endpoint"
  ["AWS::S3::Bucket"]="aws_s3_bucket"
  ["AWS::SageMaker::Domain"]="aws_sagemaker_domain"
  ["AWS::SageMaker::EndpointConfig"]="aws_sagemaker_endpoint_configuration"
  ["AWS::SageMaker::Model"]="aws_sagemaker_model"
  ["AWS::SageMaker::NotebookInstance"]="aws_sagemaker_notebook_instance"
  ["AWS::SecretsManager::Secret"]="aws_secretsmanager_secret"
  ["AWS::ServiceDiscovery::Service"]="aws_service_discovery_service"
  ["AWS::StepFunctions::StateMachine"]="aws_sfn_state_machine"
  ["AWS::SNS::Topic"]="aws_sns_topic"
  ["AWS::SQS::Queue"]="aws_sqs_queue"
  ["AWS::WAFv2::WebACL"]="aws_wafv2_web_acl"
)

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

declare -A SUM_COUNT     # regional types: summed
declare -A MAX_COUNT     # global types: max across regions
declare -A UNMAPPED
SKIPPED_REGIONS=()

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
        (( rcount > ${MAX_COUNT[$rtype]:-0} )) && MAX_COUNT[$rtype]=$rcount
      else
        SUM_COUNT[$rtype]=$(( ${SUM_COUNT[$rtype]:-0} + rcount ))
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
      SUM_COUNT[$rtype]=$(( ${SUM_COUNT[$rtype]:-0} + rcount ))
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
for t in "${!MAX_COUNT[@]}"; do
  SUM_COUNT[$t]=$(( ${SUM_COUNT[$t]:-0} + MAX_COUNT[$t] ))
done

# ------------------------- report -------------------------
TOTAL=0
echo ""
echo "------------------------------------------------------------"
printf "%-55s %10s\n" "Firefly-supported Terraform type" "Count"
echo "------------------------------------------------------------"
echo "terraform_type,aws_config_type,count" > "$OUT_CSV"

for cfg_type in $(echo "${!SUM_COUNT[@]}" | tr ' ' '\n' | sort); do
  tf_type="${MAP[$cfg_type]:-}"
  count=${SUM_COUNT[$cfg_type]}
  if [[ -n "$tf_type" ]]; then
    printf "%-55s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$cfg_type,$count" >> "$OUT_CSV"
    TOTAL=$(( TOTAL + count ))
  else
    UNMAPPED[$cfg_type]=$count
  fi
done

echo "------------------------------------------------------------"
printf "%-55s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ ${#UNMAPPED[@]} -gt 0 ]]; then
  echo ""
  echo "Other resource types found in AWS Config (not on the supported list / not mapped):"
  for t in $(echo "${!UNMAPPED[@]}" | tr ' ' '\n' | sort); do
    printf "  %-53s %10d\n" "$t" "${UNMAPPED[$t]}"
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
