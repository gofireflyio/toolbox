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
#    ./firefly_aws_asset_count.sh -v                    # also list types not countable here
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}", which PROFILE_ARG hits
# any time -p isn't passed. Every scalar var below has an explicit default.

PROFILE_ARG=()
PROFILE_NAME=""
REGIONS=""
AGGREGATOR=""
VERBOSE=0
OUT_CSV="firefly_aws_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "p:r:a:vh" opt; do
  case $opt in
    p) PROFILE_ARG=(--profile "$OPTARG"); PROFILE_NAME="$OPTARG" ;;
    r) REGIONS="$OPTARG" ;;
    a) AGGREGATOR="$OPTARG" ;;
    v) VERBOSE=1 ;;
    h) awk '/^#/{print; next} {exit}' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found";      exit 1; }

# Fail fast with a clear message if credentials are missing/expired, instead
# of limping through to a misleading "TOTAL: 0" report (describe-regions and
# every per-region Config query would otherwise fail silently too).
ACCOUNT=$(aws sts get-caller-identity "${PROFILE_ARG[@]}" --query Account --output text 2>&1)
if [[ $? -ne 0 || -z "$ACCOUNT" ]]; then
  echo "ERROR: could not authenticate to AWS."
  echo "$ACCOUNT"
  if [[ -n "$PROFILE_NAME" ]]; then
    echo "If you're using AWS SSO, try: aws sso login --profile $PROFILE_NAME"
  else
    echo "If you're using AWS SSO, try: aws sso login   (or aws configure to set up static credentials)"
  fi
  exit 1
fi

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
  "AWS::CloudTrail::Trail"
  "AWS::CloudWatch::Alarm"
  "AWS::CloudWatch::MetricStream"
  "AWS::Events::EventBus"
  "AWS::Events::Rule"
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
  "AWS::Connect::Instance"
  "AWS::DMS::Endpoint"
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
  "AWS::SageMaker::Model"
  "AWS::SecretsManager::Secret"
  "AWS::ServiceDiscovery::Service"
  "AWS::StepFunctions::StateMachine"
  "AWS::SNS::Topic"
  "AWS::SQS::Queue"
  "AWS::WAFv2::WebACL"
  "AWS::ApiGateway::Method"
  "AWS::ApiGateway::UsagePlan"
  "AWS::ApiGatewayV2::Integration"
  "AWS::AppMesh::Mesh"
  "AWS::AppMesh::VirtualGateway"
  "AWS::AppMesh::VirtualNode"
  "AWS::AppMesh::VirtualRouter"
  "AWS::AppMesh::VirtualService"
  "AWS::Bedrock::Guardrail"
  "AWS::CloudFront::RealtimeLogConfig"
  "AWS::Config::AggregationAuthorization"
  "AWS::RDS::OptionGroup"
  "AWS::ECR::ReplicationConfiguration"
  "AWS::EKS::IdentityProviderConfig"
  "AWS::Glue::Database"
  "AWS::IAM::InstanceProfile"
  "AWS::IAM::OIDCProvider"
  "AWS::ElasticLoadBalancingV2::TargetGroup"
  "AWS::MSK::Configuration"
  "AWS::APS::RuleGroupsNamespace"
  "AWS::QuickSight::DataSource"
  "AWS::RDS::GlobalCluster"
  "AWS::EC2::SubnetRouteTableAssociation"
  "AWS::SageMaker::AppImageConfig"
  "AWS::SageMaker::CodeRepository"
  "AWS::SageMaker::FeatureGroup"
  "AWS::SageMaker::Image"
  "AWS::SageMaker::NotebookInstanceLifecycleConfig"
  "AWS::SageMaker::StudioLifecycleConfig"
  "AWS::SageMaker::UserProfile"
  "AWS::SageMaker::Workteam"
  "AWS::Transfer::Server"
  "AWS::Transfer::Workflow"
  "AWS::WorkSpaces::Workspace"
  "AWS::Config::ConfigurationRecorder"
  "AWS::DMS::ReplicationInstance"
  "AWS::SageMaker::EndpointConfig"
  "AWS::SageMaker::NotebookInstance"
  "AWS::ApiGateway::DomainName"
  "AWS::ApiGatewayV2::VpcLink"
  "AWS::CodePipeline::Webhook"
  "AWS::Cognito::UserPoolIdentityProvider"
  "AWS::Cognito::UserPoolResourceServer"
  "AWS::DMS::ReplicationTask"
  "AWS::EKS::Nodegroup"
  "AWS::ElasticLoadBalancingV2::ListenerRule"
  "AWS::Glue::Crawler"
  "AWS::IAM::RolePolicy"
  "AWS::Lightsail::Instance"
  "AWS::OSIS::Pipeline"
  "AWS::Organizations::Policy"
  "AWS::Organizations::ResourcePolicy"
  "AWS::RAM::ResourceShare"
  "AWS::RDS::DBProxy"
  "AWS::S3::BucketPolicy"
  "AWS::SageMaker::App"
  "AWS::SageMaker::Endpoint"
  "AWS::SageMaker::ImageVersion"
  "AWS::SageMaker::ModelPackageGroup"
  "AWS::SageMaker::Project"
  "AWS::Transfer::User"
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
  "aws_cloudtrail"
  "aws_cloudwatch_metric_alarm"
  "aws_cloudwatch_metric_stream"
  "aws_cloudwatch_event_bus"
  "aws_cloudwatch_event_rule"
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
  "aws_connect_instance"
  "aws_dms_endpoint"
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
  "aws_sagemaker_model"
  "aws_secretsmanager_secret"
  "aws_service_discovery_service"
  "aws_sfn_state_machine"
  "aws_sns_topic"
  "aws_sqs_queue"
  "aws_wafv2_web_acl"
  "aws_api_gateway_method"
  "aws_api_gateway_usage_plan"
  "aws_apigatewayv2_integration"
  "aws_appmesh_mesh"
  "aws_appmesh_virtual_gateway"
  "aws_appmesh_virtual_node"
  "aws_appmesh_virtual_router"
  "aws_appmesh_virtual_service"
  "aws_bedrock_guardrail"
  "aws_cloudfront_realtime_log_config"
  "aws_config_aggregate_authorization"
  "aws_db_option_group"
  "aws_ecr_replication_configuration"
  "aws_eks_identity_provider_config"
  "aws_glue_catalog_database"
  "aws_iam_instance_profile"
  "aws_iam_openid_connect_provider"
  "aws_lb_target_group"
  "aws_msk_configuration"
  "aws_prometheus_rule_group_namespace"
  "aws_quicksight_data_source"
  "aws_rds_global_cluster"
  "aws_route_table_association"
  "aws_sagemaker_app_image_config"
  "aws_sagemaker_code_repository"
  "aws_sagemaker_feature_group"
  "aws_sagemaker_image"
  "aws_sagemaker_notebook_instance_lifecycle_configuration"
  "aws_sagemaker_studio_lifecycle_config"
  "aws_sagemaker_user_profile"
  "aws_sagemaker_workteam"
  "aws_transfer_server"
  "aws_transfer_workflow"
  "aws_workspaces_workspace"
  "aws_config_configuration_recorder"
  "aws_dms_replication_instance"
  "aws_sagemaker_endpoint_configuration"
  "aws_sagemaker_notebook_instance"
  "aws_api_gateway_domain_name"
  "aws_apigatewayv2_vpc_link"
  "aws_codepipeline_webhook"
  "aws_cognito_identity_provider"
  "aws_cognito_resource_server"
  "aws_dms_replication_task"
  "aws_eks_node_group"
  "aws_lb_listener_rule"
  "aws_glue_crawler"
  "aws_iam_role_policy"
  "aws_lightsail_instance"
  "aws_osis_pipeline"
  "aws_organizations_policy"
  "aws_organizations_resource_policy"
  "aws_ram_resource_share"
  "aws_db_proxy"
  "aws_s3_bucket_policy"
  "aws_sagemaker_app"
  "aws_sagemaker_endpoint"
  "aws_sagemaker_image_version"
  "aws_sagemaker_model_package_group"
  "aws_sagemaker_project"
  "aws_transfer_user"
)

# Supported types AWS Config records under a type shared with another
# Terraform type, so they are counted, but under that other type:
#   DocumentDB / Neptune clusters -> AWS::RDS::DBCluster  (aws_rds_cluster)
#   their instances + Aurora cluster instances -> AWS::RDS::DBInstance (aws_db_instance)
#   TGW peering attachments -> AWS::EC2::TransitGatewayAttachment
COUNTED_AS_OTHER=(
  "aws_docdb_cluster"
  "aws_neptune_cluster"
  "aws_docdb_cluster_instance"
  "aws_neptune_cluster_instance"
  "aws_rds_cluster_instance"
  "aws_ec2_transit_gateway_peering_attachment"
)

# Supported types AWS Config does not record (sub-resources/config such as
# S3 bucket settings, IAM policy attachments, SG rules, Route 53 records, and
# services Config does not cover such as ElastiCache, EMR clusters, Lambda
# aliases/layers, SSM parameters). They cannot be counted here, so the total
# is a lower bound. Checked against the AWS Config supported resource types
# documentation (which lists more types than the API's ResourceType enum).
NOT_COUNTABLE=(
  "aws_ami"
  "aws_api_gateway_api_key"
  "aws_api_gateway_authorizer"
  "aws_api_gateway_base_path_mapping"
  "aws_api_gateway_documentation_part"
  "aws_api_gateway_documentation_version"
  "aws_api_gateway_integration"
  "aws_api_gateway_integration_response"
  "aws_api_gateway_method_response"
  "aws_api_gateway_model"
  "aws_api_gateway_request_validator"
  "aws_api_gateway_resource"
  "aws_api_gateway_usage_plan_key"
  "aws_api_gateway_vpc_link"
  "aws_apigatewayv2_api_mapping"
  "aws_apigatewayv2_authorizer"
  "aws_apigatewayv2_deployment"
  "aws_apigatewayv2_domain_name"
  "aws_apigatewayv2_model"
  "aws_apigatewayv2_route"
  "aws_appautoscaling_policy"
  "aws_appautoscaling_target"
  "aws_athena_database"
  "aws_athena_named_query"
  "aws_autoscaling_lifecycle_hook"
  "aws_backup_vault_lock_configuration"
  "aws_bedrock_custom_model"
  "aws_bedrock_model_invocation_logging_configuration"
  "aws_cloudfront_cache_policy"
  "aws_cloudfront_function"
  "aws_cloudfront_key_group"
  "aws_cloudfront_origin_access_identity"
  "aws_cloudfront_origin_request_policy"
  "aws_cloudhsm_v2_cluster"
  "aws_cloudhsm_v2_hsm"
  "aws_cloudwatch_composite_alarm"
  "aws_cloudwatch_dashboard"
  "aws_cloudwatch_event_target"
  "aws_cloudwatch_log_group"
  "aws_cloudwatch_log_subscription_filter"
  "aws_config_delivery_channel"
  "aws_db_parameter_group"
  "aws_db_proxy_default_target_group"
  "aws_db_proxy_endpoint"
  "aws_default_network_acl"
  "aws_directory_service_directory"
  "aws_docdb_cluster_parameter_group"
  "aws_docdb_global_cluster"
  "aws_dx_connection"
  "aws_dx_gateway"
  "aws_dx_lag"
  "aws_ebs_snapshot"
  "aws_ec2_transit_gateway_peering_attachment_accepter"
  "aws_ec2_transit_gateway_route"
  "aws_ec2_transit_gateway_route_table_association"
  "aws_ec2_transit_gateway_route_table_propagation"
  "aws_ec2_transit_gateway_vpc_attachment_accepter"
  "aws_ecr_lifecycle_policy"
  "aws_ecr_repository_policy"
  "aws_efs_backup_policy"
  "aws_efs_mount_target"
  "aws_elasticache_cluster"
  "aws_elasticache_global_replication_group"
  "aws_elasticache_parameter_group"
  "aws_elasticache_replication_group"
  "aws_elasticache_subnet_group"
  "aws_elasticache_user"
  "aws_elasticache_user_group"
  "aws_emr_cluster"
  "aws_fsx_ontap_file_system"
  "aws_fsx_ontap_storage_virtual_machine"
  "aws_fsx_ontap_volume"
  "aws_fsx_windows_file_system"
  "aws_glue_catalog_table"
  "aws_glue_resource_policy"
  "aws_guardduty_publishing_destination"
  "aws_iam_access_key"
  "aws_iam_role_policy_attachment"
  "aws_iam_virtual_mfa_device"
  "aws_key_pair"
  "aws_lambda_alias"
  "aws_lambda_event_source_mapping"
  "aws_lambda_function_event_invoke_config"
  "aws_lambda_layer_version"
  "aws_lambda_layer_version_permission"
  "aws_lb_listener_certificate"
  "aws_memorydb_cluster"
  "aws_mq_configuration"
  "aws_mwaa_environment"
  "aws_neptune_cluster_parameter_group"
  "aws_neptune_parameter_group"
  "aws_organizations_policy_attachment"
  "aws_prometheus_workspace"
  "aws_quicksight_group"
  "aws_rds_cluster_endpoint"
  "aws_rds_cluster_parameter_group"
  "aws_route53_record"
  "aws_s3_bucket_accelerate_configuration"
  "aws_s3_bucket_acl"
  "aws_s3_bucket_cors_configuration"
  "aws_s3_bucket_lifecycle_configuration"
  "aws_s3_bucket_logging"
  "aws_s3_bucket_object_lock_configuration"
  "aws_s3_bucket_ownership_controls"
  "aws_s3_bucket_public_access_block"
  "aws_s3_bucket_replication_configuration"
  "aws_s3_bucket_request_payment_configuration"
  "aws_s3_bucket_server_side_encryption_configuration"
  "aws_s3_bucket_versioning"
  "aws_s3_bucket_website_configuration"
  "aws_sagemaker_flow_definition"
  "aws_sagemaker_human_task_ui"
  "aws_sagemaker_model_package_group_policy"
  "aws_sagemaker_workforce"
  "aws_security_group_rule"
  "aws_ses_domain_dkim"
  "aws_ses_domain_identity"
  "aws_ses_domain_mail_from"
  "aws_ses_email_identity"
  "aws_sns_topic_subscription"
  "aws_ssm_association"
  "aws_ssm_parameter"
  "aws_transfer_access"
  "aws_transfer_ssh_key"
  "aws_vpc_ipv4_cidr_block_association"
  "aws_vpc_ipv6_cidr_block_association"
  "aws_vpc_peering_connection_accepter"
  "aws_vpc_peering_connection_options"
  "aws_wafv2_web_acl_logging_configuration"
  "aws_workspaces_directory"
  "aws_workspaces_ip_group"
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
GLOBAL_PREFIXES="AWS::IAM:: AWS::CloudFront:: AWS::Route53:: AWS::GlobalAccelerator:: AWS::ECR::PublicRepository AWS::Organizations::"

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
echo " Account: $ACCOUNT"
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
                --query "Regions[].RegionName" --output text 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "ERROR: could not list AWS regions:"
      echo "$REGIONS"
      echo "Check IAM permissions (ec2:DescribeRegions), or pass explicit regions with -r."
      exit 1
    fi
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

ROWS=()   # "tf_type|config_type|count", for sorting by Terraform type
for cfg_type in "${SUM_KEYS[@]}"; do
  count=$(sum_get "$cfg_type")
  if tf_type=$(map_lookup "$cfg_type"); then
    ROWS+=("$tf_type|$cfg_type|$count")
    TOTAL=$(( TOTAL + count ))
  else
    unmapped_set "$cfg_type" "$count"
  fi
done
if [[ ${#ROWS[@]} -gt 0 ]]; then
  while IFS='|' read -r tf_type cfg_type count; do
    printf "%-55s %10d\n" "$tf_type" "$count"
    echo "$tf_type,$cfg_type,$count" >> "$OUT_CSV"
  done <<< "$(printf '%s\n' "${ROWS[@]}" | sort -t'|' -k1,1 -k2,2)"
fi

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

N_COUNTABLE=$(printf '%s\n' "${MAP_VALS[@]}" | sort -u | wc -l | tr -d ' ')
N_SHARED=${#COUNTED_AS_OTHER[@]}
N_NOT=${#NOT_COUNTABLE[@]}

echo ""
echo "COVERAGE: this script counts $N_COUNTABLE of $(( N_COUNTABLE + N_SHARED + N_NOT )) Firefly-supported AWS types"
echo "      directly; $N_SHARED more (DocumentDB/Neptune, Aurora cluster instances, TGW"
echo "      peering) are included under the RDS / TGW attachment rows. The other"
echo "      $N_NOT are not recorded by AWS Config (e.g. S3 bucket settings, IAM policy"
echo "      attachments, security group rules, Route 53 records, ElastiCache, EMR,"
echo "      Lambda aliases/layers, SSM parameters, CloudWatch log groups). Treat the"
echo "      total as a LOWER BOUND of Firefly-supported assets."
if [[ $VERBOSE -eq 1 ]]; then
  echo ""
  echo "Supported types not countable via AWS Config:"
  printf '  %s\n' "${NOT_COUNTABLE[@]}"
else
  echo "      Run with -v to list them."
fi
echo ""
echo "CSV written to: $OUT_CSV"
