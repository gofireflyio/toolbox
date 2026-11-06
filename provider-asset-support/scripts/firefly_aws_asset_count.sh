#!/usr/bin/env bash
#
# =============================================================================
#  Firefly - AWS Supported Asset Count
# =============================================================================
#  Counts the resources in this AWS account that match Firefly's supported
#  AWS Terraform resource types.
#
#  READ-ONLY: this script only calls Describe/List/Get/Select APIs.
#
#  HOW IT WORKS
#    1. Direct API counts (default). For every supported Terraform type the
#       script calls the service's own read-only Describe/List API in every
#       enabled region (global services such as IAM, S3, Route 53 and
#       CloudFront are counted once). Child resources Firefly tracks as their
#       own assets (security group rules, S3 bucket settings, IAM role policy
#       attachments, EventBridge targets, API Gateway methods, ...) are
#       counted per parent. AWS-created defaults that Firefly also inventories
#       (default VPCs, default NACLs, default event buses, managed CodeDeploy
#       configs, default parameter groups, ...) are included.
#    2. AWS Config as a fallback. In regions where the Config recorder is on,
#       the script also runs an advanced query
#         SELECT resourceType, COUNT(*) GROUP BY resourceType
#       and uses it only for types whose API call failed (for example
#       AccessDenied), so missing permissions do not silently zero a type.
#    3. Prints a per-type breakdown + grand total, and writes a CSV.
#
#  REQUIREMENTS
#    - aws CLI v2, jq
#    - IAM: the AWS managed policy ReadOnlyAccess (or SecurityAudit +
#      ViewOnlyAccess) on the account. Types whose API is denied fall back to
#      AWS Config when it records them, and are listed at the end.
#
#  USAGE
#    ./firefly_aws_asset_count.sh                       # all enabled regions, current account
#    ./firefly_aws_asset_count.sh -r "us-east-1 eu-west-1"
#    ./firefly_aws_asset_count.sh -p my-profile
#    ./firefly_aws_asset_count.sh -j 6                  # regions scanned in parallel (default 4)
#    ./firefly_aws_asset_count.sh -C                    # AWS Config only (fast, lower bound)
#    ./firefly_aws_asset_count.sh -a MY_AGGREGATOR      # org-wide via Config aggregator (lower bound)
#    ./firefly_aws_asset_count.sh -v                    # also list errors and uncounted types
# =============================================================================

set -o pipefail
# Not using `set -u`: Bash < 4.4 (macOS ships 3.2) throws "unbound variable"
# when an empty array is expanded with "${arr[@]}". Every scalar var below has
# an explicit default.

SELF="$0"
case "$SELF" in /*) ;; *) SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" ;; esac

# ----------------------------------------------------------- API helpers ---
# Each observation is one line in $WORK/obs:  api|<region or global>|<tf type>|<count>
# Every successful call writes a line (even 0), so the report can tell
# "counted, none found" from "could not count" (which falls back to Config).

emit() { printf 'api|%s|%s|%s\n' "$1" "$2" "$3" >> "$WORK/obs"; }

# Errors that just mean "nothing here" (service not in region / not enabled /
# optional sub-resource absent) count as 0.
ZERO_ERR='NoSuch|NotFound|NotInUse|not subscribed|SubscriptionRequired|OptInRequired|Could not connect to the endpoint|UnknownEndpoint|EndpointConnectionError|not supported|InvalidAction|UnsupportedOperation|UnsupportedUserEdition|is not available|not available in|does not exist|DoesNotExist|PolicyNotFound|LifecyclePolicyNotFound|RepositoryPolicyNotFound|ServerSideEncryptionConfigurationNotFound|OwnershipControlsNotFound|ReplicationConfigurationNotFound|NoSuchLifecycleConfiguration|ObjectLockConfigurationNotFound|EntityNotFound|InvalidParameterValue.*not supported|Unknown [Oo]peration|UnknownOperation|InvalidRequestException|Unsupported service namespace|Member must satisfy enum value set'
PERM_ERR='AccessDenied|UnauthorizedOperation|not authorized|AuthorizationError|UnrecognizedClient|InvalidClientTokenId|ExpiredToken|Forbidden'

# _call <region> <query> <aws args...>   -> stdout result; returns 0 ok, 2 zero, 1 error
_call() {
  local r="$1" q="$2" out err rc; shift 2
  err="$WORK/e.$$.$RANDOM"
  # Counts use JSON output: with text output the CLI applies --query to each
  # page separately and prints one number per page.
  out=$(aws "$@" --region "$r" --query "$q" --output "${CALL_FMT:-text}" $AWS_TIMEOUTS 2>"$err"); rc=$?
  if [[ $rc -eq 0 ]]; then rm -f "$err"; printf '%s' "$out"; return 0; fi
  local msg; msg=$(tr '\n' ' ' < "$err" | cut -c1-240); rm -f "$err"
  if echo "$msg" | grep -Eq "$PERM_ERR"; then
    printf '%s|%s|perm|%s\n' "$r" "$*" "$msg" >> "$WORK/err"; return 1
  fi
  if echo "$msg" | grep -Eq "$ZERO_ERR"; then return 2; fi
  printf '%s|%s|other|%s\n' "$r" "$*" "$msg" >> "$WORK/err"; return 1
}

# cnt <label> <tf> <region> <list-expr> <aws args...>
cnt() {
  local label="$1" tf="$2" r="$3" expr="$4" out rc; shift 4
  out=$(CALL_FMT=json _call "$r" "length(($expr) || \`[]\`)" "$@"); rc=$?
  if [[ $rc -eq 0 && "$out" =~ ^[0-9]+$ ]]; then emit "$label" "$tf" "$out"
  elif [[ $rc -eq 2 ]]; then emit "$label" "$tf" 0
  elif [[ $rc -eq 0 ]]; then printf '%s|%s|other|unexpected output: %s\n' "$r" "$*" "$(echo "$out" | head -c 80)" >> "$WORK/err"; fi
}

# has <label> <tf> <region> <expr> <aws args...>  -> 1 if the call succeeds and expr is non-empty/true
has() {
  local label="$1" tf="$2" r="$3" expr="$4" out rc; shift 4
  out=$(_call "$r" "$expr" "$@"); rc=$?
  if [[ $rc -eq 0 ]]; then
    case "$out" in ""|None|False|false|null|"[]"|0) emit "$label" "$tf" 0 ;; *) emit "$label" "$tf" 1 ;; esac
  elif [[ $rc -eq 2 ]]; then emit "$label" "$tf" 0; fi
}

# lst <region> <expr> <aws args...>  -> items, one per line; returns non-zero on error
lst() {
  local r="$1" expr="$2" out rc; shift 2
  out=$(_call "$r" "$expr" "$@"); rc=$?
  [[ $rc -eq 1 ]] && return 1
  [[ $rc -eq 2 ]] && return 0
  printf '%s\n' "$out" | tr '\t' '\n' | grep -v -e '^None$' -e '^$'
  return 0
}

# ------------------------------------------------- flat (single-call) specs ---
# One line per type:  <terraform type>;<JMESPath list expression>;<aws args>
# @ACCT@ is replaced with the account id. Run in every region.
REGIONAL_SPECS='
aws_instance;Reservations[].Instances[];ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped
aws_ebs_volume;Volumes;ec2 describe-volumes
aws_ebs_snapshot;Snapshots;ec2 describe-snapshots --owner-ids self
aws_ami;Images;ec2 describe-images --owners self
aws_security_group;SecurityGroups;ec2 describe-security-groups
aws_security_group_rule;SecurityGroupRules;ec2 describe-security-group-rules
aws_vpc;Vpcs;ec2 describe-vpcs
aws_vpc_ipv4_cidr_block_association;Vpcs[].CidrBlockAssociationSet[?CidrBlockState.State==`associated`][];ec2 describe-vpcs
aws_vpc_ipv6_cidr_block_association;Vpcs[].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State==`associated`][];ec2 describe-vpcs
aws_subnet;Subnets;ec2 describe-subnets
aws_route_table;RouteTables;ec2 describe-route-tables
aws_route_table_association;RouteTables[].Associations[?!Main][];ec2 describe-route-tables
aws_internet_gateway;InternetGateways;ec2 describe-internet-gateways
aws_nat_gateway;NatGateways;ec2 describe-nat-gateways --filter Name=state,Values=pending,available
aws_eip;Addresses;ec2 describe-addresses
aws_network_interface;NetworkInterfaces;ec2 describe-network-interfaces
aws_network_acl;NetworkAcls;ec2 describe-network-acls --filters Name=default,Values=false
aws_default_network_acl;NetworkAcls;ec2 describe-network-acls --filters Name=default,Values=true
aws_vpc_dhcp_options;DhcpOptions;ec2 describe-dhcp-options
aws_key_pair;KeyPairs;ec2 describe-key-pairs
aws_launch_template;LaunchTemplates;ec2 describe-launch-templates
aws_vpc_endpoint;VpcEndpoints[?State!=`deleted`];ec2 describe-vpc-endpoints
aws_vpc_endpoint_service;ServiceConfigurations;ec2 describe-vpc-endpoint-service-configurations
aws_vpc_peering_connection;VpcPeeringConnections;ec2 describe-vpc-peering-connections --filters Name=requester-vpc-info.owner-id,Values=@ACCT@ Name=status-code,Values=active,pending-acceptance,provisioning
aws_vpc_peering_connection_options;VpcPeeringConnections;ec2 describe-vpc-peering-connections --filters Name=requester-vpc-info.owner-id,Values=@ACCT@ Name=status-code,Values=active
aws_vpc_peering_connection_accepter;VpcPeeringConnections[?RequesterVpcInfo.OwnerId!=`@ACCT@` || RequesterVpcInfo.Region!=AccepterVpcInfo.Region];ec2 describe-vpc-peering-connections --filters Name=accepter-vpc-info.owner-id,Values=@ACCT@ Name=status-code,Values=active
aws_flow_log;FlowLogs;ec2 describe-flow-logs
aws_ec2_transit_gateway;TransitGateways[?State!=`deleted`];ec2 describe-transit-gateways --filters Name=owner-id,Values=@ACCT@
aws_ec2_transit_gateway_vpc_attachment;TransitGatewayVpcAttachments[?VpcOwnerId==`@ACCT@` && State!=`deleted`];ec2 describe-transit-gateway-vpc-attachments
aws_ec2_transit_gateway_vpc_attachment_accepter;TransitGatewayVpcAttachments[?VpcOwnerId!=`@ACCT@` && State!=`deleted`];ec2 describe-transit-gateway-vpc-attachments
aws_ec2_transit_gateway_peering_attachment;TransitGatewayPeeringAttachments[?RequesterTgwInfo.OwnerId==`@ACCT@` && State!=`deleted`];ec2 describe-transit-gateway-peering-attachments
aws_ec2_transit_gateway_peering_attachment_accepter;TransitGatewayPeeringAttachments[?AccepterTgwInfo.OwnerId==`@ACCT@` && RequesterTgwInfo.OwnerId!=`@ACCT@` && State!=`deleted`];ec2 describe-transit-gateway-peering-attachments
aws_ec2_transit_gateway_route_table;TransitGatewayRouteTables[?State!=`deleted`];ec2 describe-transit-gateway-route-tables
aws_vpn_connection;VpnConnections[?State!=`deleted`];ec2 describe-vpn-connections
aws_vpn_gateway;VpnGateways[?State!=`deleted`];ec2 describe-vpn-gateways
aws_ec2_traffic_mirror_filter;TrafficMirrorFilters;ec2 describe-traffic-mirror-filters
aws_ec2_traffic_mirror_session;TrafficMirrorSessions;ec2 describe-traffic-mirror-sessions
aws_ec2_traffic_mirror_target;TrafficMirrorTargets;ec2 describe-traffic-mirror-targets
aws_launch_configuration;LaunchConfigurations;autoscaling describe-launch-configurations
aws_autoscaling_group;AutoScalingGroups;autoscaling describe-auto-scaling-groups
aws_autoscaling_policy;ScalingPolicies;autoscaling describe-policies
aws_elb;LoadBalancerDescriptions;elb describe-load-balancers
aws_lb;LoadBalancers;elbv2 describe-load-balancers
aws_lb_target_group;TargetGroups;elbv2 describe-target-groups
aws_lambda_function;Functions;lambda list-functions
aws_lambda_event_source_mapping;EventSourceMappings;lambda list-event-source-mappings
aws_lambda_code_signing_config;CodeSigningConfigs;lambda list-code-signing-configs
aws_cloudwatch_log_group;logGroups;logs describe-log-groups
aws_cloudwatch_metric_alarm;MetricAlarms;cloudwatch describe-alarms --alarm-types MetricAlarm
aws_cloudwatch_composite_alarm;CompositeAlarms;cloudwatch describe-alarms --alarm-types CompositeAlarm
aws_cloudwatch_dashboard;DashboardEntries;cloudwatch list-dashboards
aws_cloudwatch_metric_stream;Entries;cloudwatch list-metric-streams
aws_cloudwatch_event_bus;EventBuses;events list-event-buses
aws_kms_key;Keys;kms list-keys
aws_kms_alias;Aliases[?TargetKeyId];kms list-aliases
aws_dynamodb_table;TableNames;dynamodb list-tables
aws_sqs_queue;QueueUrls;sqs list-queues
aws_sns_topic;Topics;sns list-topics
aws_sns_topic_subscription;Subscriptions[?SubscriptionArn!=`PendingConfirmation`];sns list-subscriptions
aws_ssm_parameter;Parameters;ssm describe-parameters
aws_ssm_association;Associations;ssm list-associations
aws_secretsmanager_secret;SecretList;secretsmanager list-secrets
aws_acm_certificate;CertificateSummaryList;acm list-certificates --includes keyTypes=RSA_1024,RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1,EC_secp521r1
aws_db_instance;DBInstances[?!DBClusterIdentifier];rds describe-db-instances
aws_rds_cluster_instance;DBInstances[?DBClusterIdentifier && Engine!=`docdb` && Engine!=`neptune`];rds describe-db-instances
aws_docdb_cluster_instance;DBInstances[?Engine==`docdb`];rds describe-db-instances
aws_neptune_cluster_instance;DBInstances[?Engine==`neptune`];rds describe-db-instances
aws_rds_cluster;DBClusters[?Engine!=`docdb` && Engine!=`neptune`];rds describe-db-clusters
aws_docdb_cluster;DBClusters[?Engine==`docdb`];rds describe-db-clusters
aws_neptune_cluster;DBClusters[?Engine==`neptune`];rds describe-db-clusters
aws_db_parameter_group;DBParameterGroups[?!starts_with(DBParameterGroupFamily,`neptune`)];rds describe-db-parameter-groups
aws_neptune_parameter_group;DBParameterGroups[?starts_with(DBParameterGroupFamily,`neptune`)];rds describe-db-parameter-groups
aws_rds_cluster_parameter_group;DBClusterParameterGroups[?!starts_with(DBParameterGroupFamily,`docdb`) && !starts_with(DBParameterGroupFamily,`neptune`)];rds describe-db-cluster-parameter-groups
aws_docdb_cluster_parameter_group;DBClusterParameterGroups[?starts_with(DBParameterGroupFamily,`docdb`)];rds describe-db-cluster-parameter-groups
aws_neptune_cluster_parameter_group;DBClusterParameterGroups[?starts_with(DBParameterGroupFamily,`neptune`)];rds describe-db-cluster-parameter-groups
aws_db_option_group;OptionGroupsList;rds describe-option-groups
aws_db_subnet_group;DBSubnetGroups;rds describe-db-subnet-groups
aws_db_snapshot;DBSnapshots;rds describe-db-snapshots
aws_db_cluster_snapshot;DBClusterSnapshots;rds describe-db-cluster-snapshots
aws_db_event_subscription;EventSubscriptionsList;rds describe-event-subscriptions
aws_db_proxy;DBProxies;rds describe-db-proxies
aws_db_proxy_default_target_group;DBProxies;rds describe-db-proxies
aws_db_proxy_endpoint;DBProxyEndpoints[?!IsDefault];rds describe-db-proxy-endpoints
aws_rds_cluster_endpoint;DBClusterEndpoints[?EndpointType==`CUSTOM`];rds describe-db-cluster-endpoints
aws_elasticache_cluster;CacheClusters;elasticache describe-cache-clusters
aws_elasticache_replication_group;ReplicationGroups;elasticache describe-replication-groups
aws_elasticache_parameter_group;CacheParameterGroups;elasticache describe-cache-parameter-groups
aws_elasticache_subnet_group;CacheSubnetGroups;elasticache describe-cache-subnet-groups
aws_elasticache_user;Users;elasticache describe-users
aws_elasticache_user_group;UserGroups;elasticache describe-user-groups
aws_memorydb_cluster;Clusters;memorydb describe-clusters
aws_ecr_repository;repositories;ecr describe-repositories
aws_ecr_replication_configuration;replicationConfiguration.rules[:1];ecr describe-registry
aws_ecs_cluster;clusterArns;ecs list-clusters
aws_ecs_task_definition;taskDefinitionArns;ecs list-task-definitions --status ACTIVE
aws_ecs_capacity_provider;capacityProviders;ecs describe-capacity-providers
aws_eks_cluster;clusters;eks list-clusters
aws_efs_file_system;FileSystems;efs describe-file-systems
aws_efs_access_point;AccessPoints;efs describe-access-points
aws_fsx_ontap_file_system;FileSystems[?FileSystemType==`ONTAP`];fsx describe-file-systems
aws_fsx_windows_file_system;FileSystems[?FileSystemType==`WINDOWS`];fsx describe-file-systems
aws_fsx_ontap_storage_virtual_machine;StorageVirtualMachines;fsx describe-storage-virtual-machines
aws_fsx_ontap_volume;Volumes[?VolumeType==`ONTAP`];fsx describe-volumes
aws_athena_workgroup;WorkGroups;athena list-work-groups
aws_athena_data_catalog;DataCatalogsSummary[?CatalogName!=`AwsDataCatalog`];athena list-data-catalogs
aws_athena_named_query;NamedQueryIds;athena list-named-queries
aws_athena_database;DatabaseList;athena list-databases --catalog-name AwsDataCatalog
aws_glue_catalog_database;DatabaseList;glue get-databases
aws_glue_crawler;Crawlers;glue get-crawlers
aws_glue_job;JobNames;glue list-jobs
aws_backup_vault;BackupVaultList;backup list-backup-vaults
aws_backup_vault_lock_configuration;BackupVaultList[?Locked];backup list-backup-vaults
aws_bedrock_guardrail;guardrails;bedrock list-guardrails
aws_bedrock_custom_model;modelSummaries;bedrock list-custom-models
aws_cloudtrail;trailList;cloudtrail describe-trails --no-include-shadow-trails
aws_config_configuration_recorder;ConfigurationRecorders;configservice describe-configuration-recorders
aws_config_delivery_channel;DeliveryChannels;configservice describe-delivery-channels
aws_config_aggregate_authorization;AggregationAuthorizations;configservice describe-aggregation-authorizations
aws_codedeploy_app;applications;deploy list-applications
aws_codedeploy_deployment_config;deploymentConfigsList;deploy list-deployment-configs
aws_codebuild_project;projects;codebuild list-projects
aws_codebuild_report_group;reportGroups;codebuild list-report-groups
aws_codepipeline;pipelines;codepipeline list-pipelines
aws_codepipeline_webhook;webhooks;codepipeline list-webhooks
aws_cognito_user_pool;UserPools;cognito-idp list-user-pools --max-results 60
aws_cognito_identity_pool;IdentityPools;cognito-identity list-identity-pools --max-results 60
aws_sfn_state_machine;stateMachines;stepfunctions list-state-machines
aws_wafv2_web_acl;WebACLs;wafv2 list-web-acls --scope REGIONAL
aws_wafv2_web_acl_logging_configuration;LoggingConfigurations;wafv2 list-logging-configurations --scope REGIONAL
aws_api_gateway_rest_api;items;apigateway get-rest-apis
aws_api_gateway_api_key;items;apigateway get-api-keys
aws_api_gateway_usage_plan;items;apigateway get-usage-plans
aws_api_gateway_domain_name;items;apigateway get-domain-names
aws_api_gateway_vpc_link;items;apigateway get-vpc-links
aws_apigatewayv2_api;Items;apigatewayv2 get-apis
aws_apigatewayv2_domain_name;Items;apigatewayv2 get-domain-names
aws_apigatewayv2_vpc_link;Items;apigatewayv2 get-vpc-links
aws_appconfig_application;Items;appconfig list-applications
aws_appmesh_mesh;meshes;appmesh list-meshes
aws_cloudhsm_v2_cluster;Clusters[?State!=`DELETED`];cloudhsmv2 describe-clusters
aws_cloudhsm_v2_hsm;Clusters[].Hsms[];cloudhsmv2 describe-clusters
aws_connect_instance;InstanceSummaryList;connect list-instances
aws_dms_endpoint;Endpoints;dms describe-endpoints
aws_dms_replication_instance;ReplicationInstances;dms describe-replication-instances
aws_dms_replication_task;ReplicationTasks;dms describe-replication-tasks
aws_directory_service_directory;DirectoryDescriptions;ds describe-directories
aws_dx_connection;connections[?connectionState!=`deleted`];directconnect describe-connections
aws_dx_lag;lags[?lagState!=`deleted`];directconnect describe-lags
aws_elastic_beanstalk_application;Applications;elasticbeanstalk describe-applications
aws_elastic_beanstalk_environment;Environments;elasticbeanstalk describe-environments --no-include-deleted
aws_elasticsearch_domain;DomainNames;es list-domain-names --engine-type Elasticsearch
aws_opensearch_domain;DomainNames;opensearch list-domain-names --engine-type OpenSearch
aws_emr_cluster;Clusters;emr list-clusters --active
aws_guardduty_detector;DetectorIds;guardduty list-detectors
aws_kinesis_stream;StreamNames;kinesis list-streams
aws_kinesis_firehose_delivery_stream;DeliveryStreamNames;firehose list-delivery-streams
aws_mq_broker;BrokerSummaries;mq list-brokers
aws_mq_configuration;Configurations;mq list-configurations
aws_msk_cluster;ClusterInfoList;kafka list-clusters-v2
aws_msk_configuration;Configurations;kafka list-configurations
aws_mwaa_environment;Environments;mwaa list-environments
aws_networkfirewall_firewall;Firewalls;network-firewall list-firewalls
aws_osis_pipeline;Pipelines;osis list-pipelines
aws_prometheus_workspace;workspaces;amp list-workspaces
aws_quicksight_data_source;DataSources;quicksight list-data-sources --aws-account-id @ACCT@
aws_quicksight_group;GroupList;quicksight list-groups --aws-account-id @ACCT@ --namespace default
aws_ram_resource_share;resourceShares[?status==`ACTIVE`];ram get-resource-shares --resource-owner SELF
aws_redshift_cluster;Clusters;redshift describe-clusters
aws_redshift_parameter_group;ParameterGroups;redshift describe-cluster-parameter-groups
aws_redshift_subnet_group;ClusterSubnetGroups;redshift describe-cluster-subnet-groups
aws_route53_resolver_endpoint;ResolverEndpoints;route53resolver list-resolver-endpoints
aws_sagemaker_app;Apps[?Status!=`Deleted`];sagemaker list-apps
aws_sagemaker_app_image_config;AppImageConfigs;sagemaker list-app-image-configs
aws_sagemaker_code_repository;CodeRepositorySummaryList;sagemaker list-code-repositories
aws_sagemaker_domain;Domains;sagemaker list-domains
aws_sagemaker_endpoint;Endpoints;sagemaker list-endpoints
aws_sagemaker_endpoint_configuration;EndpointConfigs;sagemaker list-endpoint-configs
aws_sagemaker_image;Images;sagemaker list-images
aws_sagemaker_feature_group;FeatureGroupSummaries;sagemaker list-feature-groups
aws_sagemaker_flow_definition;FlowDefinitionSummaries;sagemaker list-flow-definitions
aws_sagemaker_human_task_ui;HumanTaskUiSummaries;sagemaker list-human-task-uis
aws_sagemaker_model;Models;sagemaker list-models
aws_sagemaker_model_package_group;ModelPackageGroupSummaryList;sagemaker list-model-package-groups
aws_sagemaker_notebook_instance;NotebookInstances;sagemaker list-notebook-instances
aws_sagemaker_notebook_instance_lifecycle_configuration;NotebookInstanceLifecycleConfigs;sagemaker list-notebook-instance-lifecycle-configs
aws_sagemaker_project;ProjectSummaryList;sagemaker list-projects
aws_sagemaker_studio_lifecycle_config;StudioLifecycleConfigs;sagemaker list-studio-lifecycle-configs
aws_sagemaker_user_profile;UserProfiles;sagemaker list-user-profiles
aws_sagemaker_workforce;Workforces;sagemaker list-workforces
aws_sagemaker_workteam;Workteams;sagemaker list-workteams
aws_service_discovery_service;Services;servicediscovery list-services
aws_ses_domain_identity;EmailIdentities[?IdentityType==`DOMAIN`];sesv2 list-email-identities
aws_ses_email_identity;EmailIdentities[?IdentityType==`EMAIL_ADDRESS`];sesv2 list-email-identities
aws_transfer_server;Servers;transfer list-servers
aws_transfer_workflow;Workflows;transfer list-workflows
aws_lightsail_instance;instances;lightsail get-instances
aws_workspaces_workspace;Workspaces;workspaces describe-workspaces
aws_workspaces_directory;Directories;workspaces describe-workspace-directories
aws_workspaces_ip_group;Result;workspaces describe-ip-groups
'

# Global services: counted once (from us-east-1 unless noted with region=).
GLOBAL_SPECS='
aws_iam_role;Roles;iam list-roles
aws_iam_policy;Policies;iam list-policies --scope Local
aws_iam_user;Users;iam list-users
aws_iam_group;Groups;iam list-groups
aws_iam_instance_profile;InstanceProfiles;iam list-instance-profiles
aws_iam_openid_connect_provider;OpenIDConnectProviderList;iam list-open-id-connect-providers
aws_iam_virtual_mfa_device;VirtualMFADevices;iam list-virtual-mfa-devices
aws_s3_bucket;Buckets;s3api list-buckets
aws_s3_bucket_acl;Buckets;s3api list-buckets
aws_route53_zone;HostedZones;route53 list-hosted-zones
aws_cloudfront_distribution;DistributionList.Items;cloudfront list-distributions
aws_cloudfront_cache_policy;CachePolicyList.Items;cloudfront list-cache-policies
aws_cloudfront_origin_request_policy;OriginRequestPolicyList.Items;cloudfront list-origin-request-policies
aws_cloudfront_origin_access_identity;CloudFrontOriginAccessIdentityList.Items;cloudfront list-cloud-front-origin-access-identities
aws_cloudfront_function;FunctionList.Items;cloudfront list-functions
aws_cloudfront_key_group;KeyGroupList.Items;cloudfront list-key-groups
aws_cloudfront_realtime_log_config;RealtimeLogConfigs.Items;cloudfront list-realtime-log-configs
aws_ecrpublic_repository;repositories;ecr-public describe-repositories
aws_dx_gateway;directConnectGateways[?directConnectGatewayState!=`deleted`];directconnect describe-direct-connect-gateways
aws_rds_global_cluster;GlobalClusters[?Engine!=`docdb`];rds describe-global-clusters
aws_docdb_global_cluster;GlobalClusters[?Engine==`docdb`];rds describe-global-clusters
aws_elasticache_global_replication_group;GlobalReplicationGroups;elasticache describe-global-replication-groups
aws_organizations_resource_policy;ResourcePolicy.ResourcePolicySummary.Id;organizations describe-resource-policy
aws_globalaccelerator_accelerator;Accelerators;globalaccelerator list-accelerators;us-west-2
'

# Run one flat spec. $1 = label (region or "global"), $2 = region, $3 = spec line
run_spec() {
  local label="$1" r="$2" spec="$3" tf expr cmd sr args
  IFS=';' read -r tf expr cmd sr <<< "$spec"
  [[ -z "$tf" ]] && return
  [[ -n "$sr" ]] && r="$sr"
  expr="${expr//@ACCT@/$ACCOUNT}"; cmd="${cmd//@ACCT@/$ACCOUNT}"
  read -r -a args <<< "$cmd"
  # A ";;"-free special case: ECR replication / org resource policy are presence checks.
  case "$tf" in
    aws_ecr_replication_configuration|aws_organizations_resource_policy)
      has "$label" "$tf" "$r" "$expr" "${args[@]}" ;;
    *) cnt "$label" "$tf" "$r" "$expr" "${args[@]}" ;;
  esac
}

# --------------------------------------------- per-parent child counters ---
# Each job is "<function>|<region>|<arg>[|<arg2>]". Regional jobs emit under
# their region; global ones (S3, IAM, Route 53, Global Accelerator,
# Organizations) emit under "global".

j_evt_rules() {   # region bus -> rules + one target job per rule
  local r="$1" bus="$2" rules
  rules=$(lst "$r" 'Rules[].Name' events list-rules --event-bus-name "$bus") || return
  emit "$r" aws_cloudwatch_event_rule "$(printf '%s' "$rules" | grep -c .)"
  printf '%s\n' "$rules" | grep . | while read -r rule; do
    printf 'j_evt_targets|%s|%s|%s\n' "$r" "$bus" "$rule"
  done >> "$WORK/jobs2.$r"
}
j_evt_targets()  { cnt "$1" aws_cloudwatch_event_target "$1" Targets events list-targets-by-rule --rule "$3" --event-bus-name "$2"; }
j_asg()          { cnt "$1" aws_autoscaling_lifecycle_hook "$1" LifecycleHooks autoscaling describe-lifecycle-hooks --auto-scaling-group-name "$2"; }
j_lb() {
  local r="$1" lb="$2" ls l
  ls=$(lst "$r" 'Listeners[].ListenerArn' elbv2 describe-listeners --load-balancer-arn "$lb") || return
  emit "$r" aws_lb_listener "$(printf '%s' "$ls" | grep -c .)"
  emit "$r" aws_lb_listener_rule 0; emit "$r" aws_lb_listener_certificate 0
  for l in $ls; do
    cnt "$r" aws_lb_listener_rule "$r" 'Rules[?!IsDefault]' elbv2 describe-rules --listener-arn "$l"
    cnt "$r" aws_lb_listener_certificate "$r" 'Certificates[?!IsDefault]' elbv2 describe-listener-certificates --listener-arn "$l"
  done
}
j_lambda_fn() {
  cnt "$1" aws_lambda_alias "$1" Aliases lambda list-aliases --function-name "$2"
  cnt "$1" aws_lambda_function_event_invoke_config "$1" FunctionEventInvokeConfigs lambda list-function-event-invoke-configs --function-name "$2"
}
j_lambda_layer() {
  local r="$1" layer="$2" vs v
  vs=$(lst "$r" 'LayerVersions[].Version' lambda list-layer-versions --layer-name "$layer") || return
  emit "$r" aws_lambda_layer_version "$(printf '%s' "$vs" | grep -c .)"
  for v in $vs; do
    has "$r" aws_lambda_layer_version_permission "$r" Policy lambda get-layer-version-policy --layer-name "$layer" --version-number "$v"
  done
}
j_loggroup()     { cnt "$1" aws_cloudwatch_log_subscription_filter "$1" subscriptionFilters logs describe-subscription-filters --log-group-name "$2"; }
j_ecr_repo() {
  has "$1" aws_ecr_repository_policy "$1" policyText ecr get-repository-policy --repository-name "$2"
  has "$1" aws_ecr_lifecycle_policy "$1" lifecyclePolicyText ecr get-lifecycle-policy --repository-name "$2"
}
j_ecs_cluster()  { cnt "$1" aws_ecs_service "$1" serviceArns ecs list-services --cluster "$2"; }
j_eks() {
  cnt "$1" aws_eks_node_group "$1" nodegroups eks list-nodegroups --cluster-name "$2"
  cnt "$1" aws_eks_addon "$1" addons eks list-addons --cluster-name "$2"
  cnt "$1" aws_eks_fargate_profile "$1" fargateProfileNames eks list-fargate-profiles --cluster-name "$2"
  cnt "$1" aws_eks_identity_provider_config "$1" identityProviderConfigs eks list-identity-provider-configs --cluster-name "$2"
}
j_efs() {
  cnt "$1" aws_efs_mount_target "$1" MountTargets efs describe-mount-targets --file-system-id "$2"
  has "$1" aws_efs_backup_policy "$1" "BackupPolicy.Status==\`ENABLED\`" efs describe-backup-policy --file-system-id "$2"
}
j_glue_db()      { cnt "$1" aws_glue_catalog_table "$1" TableList glue get-tables --database-name "$2"; }
j_gd()           { cnt "$1" aws_guardduty_publishing_destination "$1" Destinations guardduty list-publishing-destinations --detector-id "$2"; }
j_kinesis()      { cnt "$1" aws_kinesis_stream_consumer "$1" Consumers kinesis list-stream-consumers --stream-arn "$2"; }
j_amp()          { cnt "$1" aws_prometheus_rule_group_namespace "$1" ruleGroupsNamespaces amp list-rule-groups-namespaces --workspace-id "$2"; }
j_sm_image()     { cnt "$1" aws_sagemaker_image_version "$1" ImageVersions sagemaker list-image-versions --image-name "$2"; }
j_sm_mpg()       { has "$1" aws_sagemaker_model_package_group_policy "$1" ResourcePolicy sagemaker get-model-package-group-policy --model-package-group-name "$2"; }
j_transfer() {
  local r="$1" srv="$2" us u
  cnt "$r" aws_transfer_access "$r" Accesses transfer list-accesses --server-id "$srv"
  us=$(lst "$r" 'Users[].UserName' transfer list-users --server-id "$srv") || return
  emit "$r" aws_transfer_user "$(printf '%s' "$us" | grep -c .)"
  emit "$r" aws_transfer_ssh_key 0
  for u in $us; do
    cnt "$r" aws_transfer_ssh_key "$r" User.SshPublicKeys transfer describe-user --server-id "$srv" --user-name "$u"
  done
}
j_tgw_rt() {
  cnt "$1" aws_ec2_transit_gateway_route "$1" Routes ec2 search-transit-gateway-routes --transit-gateway-route-table-id "$2" --filters Name=type,Values=static
  cnt "$1" aws_ec2_transit_gateway_route_table_association "$1" Associations ec2 get-transit-gateway-route-table-associations --transit-gateway-route-table-id "$2"
  cnt "$1" aws_ec2_transit_gateway_route_table_propagation "$1" TransitGatewayRouteTablePropagations ec2 get-transit-gateway-route-table-propagations --transit-gateway-route-table-id "$2"
}
j_cd_app()       { cnt "$1" aws_codedeploy_deployment_group "$1" deploymentGroups deploy list-deployment-groups --application-name "$2"; }
j_cognito() {
  cnt "$1" aws_cognito_user_pool_client "$1" UserPoolClients cognito-idp list-user-pool-clients --user-pool-id "$2"
  cnt "$1" aws_cognito_user_group "$1" Groups cognito-idp list-groups --user-pool-id "$2"
  cnt "$1" aws_cognito_identity_provider "$1" Providers cognito-idp list-identity-providers --user-pool-id "$2"
  cnt "$1" aws_cognito_resource_server "$1" ResourceServers cognito-idp list-resource-servers --user-pool-id "$2" --max-results 50
}
j_apigw() {
  local r="$1" api="$2" json
  json=$(aws apigateway get-resources --rest-api-id "$api" --embed methods --region "$r" --output json $AWS_TIMEOUTS 2>/dev/null)
  if [[ -n "$json" ]]; then
    emit "$r" aws_api_gateway_resource "$(echo "$json" | jq '[.items[] | select(.path != "/")] | length')"
    emit "$r" aws_api_gateway_method "$(echo "$json" | jq '[.items[].resourceMethods // {} | .[]] | length')"
    emit "$r" aws_api_gateway_method_response "$(echo "$json" | jq '[.items[].resourceMethods // {} | .[] | .methodResponses // {} | .[]] | length')"
    emit "$r" aws_api_gateway_integration "$(echo "$json" | jq '[.items[].resourceMethods // {} | .[] | select(.methodIntegration)] | length')"
    emit "$r" aws_api_gateway_integration_response "$(echo "$json" | jq '[.items[].resourceMethods // {} | .[] | .methodIntegration.integrationResponses // {} | .[]] | length')"
  fi
  cnt "$r" aws_api_gateway_stage "$r" item apigateway get-stages --rest-api-id "$api"
  cnt "$r" aws_api_gateway_model "$r" items apigateway get-models --rest-api-id "$api"
  cnt "$r" aws_api_gateway_authorizer "$r" items apigateway get-authorizers --rest-api-id "$api"
  cnt "$r" aws_api_gateway_request_validator "$r" items apigateway get-request-validators --rest-api-id "$api"
  cnt "$r" aws_api_gateway_documentation_part "$r" items apigateway get-documentation-parts --rest-api-id "$api"
  cnt "$r" aws_api_gateway_documentation_version "$r" items apigateway get-documentation-versions --rest-api-id "$api"
}
j_apigw_plan()   { cnt "$1" aws_api_gateway_usage_plan_key "$1" items apigateway get-usage-plan-keys --usage-plan-id "$2"; }
j_apigw_dom()    { cnt "$1" aws_api_gateway_base_path_mapping "$1" items apigateway get-base-path-mappings --domain-name "$2"; }
j_apigw2() {
  cnt "$1" aws_apigatewayv2_route "$1" Items apigatewayv2 get-routes --api-id "$2"
  cnt "$1" aws_apigatewayv2_integration "$1" Items apigatewayv2 get-integrations --api-id "$2"
  cnt "$1" aws_apigatewayv2_stage "$1" Items apigatewayv2 get-stages --api-id "$2"
  cnt "$1" aws_apigatewayv2_authorizer "$1" Items apigatewayv2 get-authorizers --api-id "$2"
  cnt "$1" aws_apigatewayv2_model "$1" Items apigatewayv2 get-models --api-id "$2"
  cnt "$1" aws_apigatewayv2_deployment "$1" Items apigatewayv2 get-deployments --api-id "$2"
}
j_apigw2_dom()   { cnt "$1" aws_apigatewayv2_api_mapping "$1" Items apigatewayv2 get-api-mappings --domain-name "$2"; }
j_appmesh() {
  cnt "$1" aws_appmesh_virtual_node "$1" virtualNodes appmesh list-virtual-nodes --mesh-name "$2"
  cnt "$1" aws_appmesh_virtual_router "$1" virtualRouters appmesh list-virtual-routers --mesh-name "$2"
  cnt "$1" aws_appmesh_virtual_service "$1" virtualServices appmesh list-virtual-services --mesh-name "$2"
  cnt "$1" aws_appmesh_virtual_gateway "$1" virtualGateways appmesh list-virtual-gateways --mesh-name "$2"
}
j_ses_dom() {
  has "$1" aws_ses_domain_dkim "$1" 'DkimAttributes.SigningEnabled' sesv2 get-email-identity --email-identity "$2"
  has "$1" aws_ses_domain_mail_from "$1" 'MailFromAttributes.MailFromDomain' sesv2 get-email-identity --email-identity "$2"
}
j_appas() {
  cnt "$1" aws_appautoscaling_target "$1" ScalableTargets application-autoscaling describe-scalable-targets --service-namespace "$2"
  cnt "$1" aws_appautoscaling_policy "$1" ScalingPolicies application-autoscaling describe-scaling-policies --service-namespace "$2"
}
j_glue_policy()  { has "$1" aws_glue_resource_policy "$1" PolicyInJson glue get-resource-policy; }
j_bedrock_log()  { has "$1" aws_bedrock_model_invocation_logging_configuration "$1" loggingConfig bedrock get-model-invocation-logging-configuration; }

# Global children. $1 is the API region to call; they emit under "global".
j_s3() {   # region bucket
  local r="$1" b="$2" g=global
  has $g aws_s3_bucket_policy "$r" Policy s3api get-bucket-policy --bucket "$b"
  has $g aws_s3_bucket_versioning "$r" Status s3api get-bucket-versioning --bucket "$b"
  has $g aws_s3_bucket_server_side_encryption_configuration "$r" ServerSideEncryptionConfiguration.Rules s3api get-bucket-encryption --bucket "$b"
  has $g aws_s3_bucket_public_access_block "$r" PublicAccessBlockConfiguration s3api get-public-access-block --bucket "$b"
  has $g aws_s3_bucket_ownership_controls "$r" OwnershipControls.Rules s3api get-bucket-ownership-controls --bucket "$b"
  has $g aws_s3_bucket_lifecycle_configuration "$r" Rules s3api get-bucket-lifecycle-configuration --bucket "$b"
  has $g aws_s3_bucket_replication_configuration "$r" ReplicationConfiguration.Rules s3api get-bucket-replication --bucket "$b"
  has $g aws_s3_bucket_cors_configuration "$r" CORSRules s3api get-bucket-cors --bucket "$b"
  has $g aws_s3_bucket_website_configuration "$r" '[IndexDocument,RedirectAllRequestsTo][]' s3api get-bucket-website --bucket "$b"
  has $g aws_s3_bucket_logging "$r" LoggingEnabled s3api get-bucket-logging --bucket "$b"
  has $g aws_s3_bucket_accelerate_configuration "$r" Status s3api get-bucket-accelerate-configuration --bucket "$b"
  has $g aws_s3_bucket_object_lock_configuration "$r" ObjectLockConfiguration.ObjectLockEnabled s3api get-object-lock-configuration --bucket "$b"
  has $g aws_s3_bucket_request_payment_configuration "$r" "Payer==\`Requester\`" s3api get-bucket-request-payment --bucket "$b"
}
j_iam_role() {
  cnt global aws_iam_role_policy "$1" PolicyNames iam list-role-policies --role-name "$2"
  cnt global aws_iam_role_policy_attachment "$1" AttachedPolicies iam list-attached-role-policies --role-name "$2"
}
j_iam_user()     { cnt global aws_iam_access_key "$1" AccessKeyMetadata iam list-access-keys --user-name "$2"; }
j_r53_zone()     { cnt global aws_route53_record "$1" ResourceRecordSets route53 list-resource-record-sets --hosted-zone-id "$2"; }
j_ga()           { cnt global aws_globalaccelerator_listener "$1" Listeners globalaccelerator list-listeners --accelerator-arn "$2"; }
j_org_policy()   { cnt global aws_organizations_policy_attachment "$1" Targets organizations list-targets-for-policy --policy-id "$2"; }

# Run a job line in a worker process.
run_job() {
  local line="$1" f r a b
  IFS='|' read -r f r a b <<< "$line"
  case "$f" in j_*) "$f" "$r" "$a" "$b" ;; esac
}

# Fan a list of lines out to $J worker processes (re-invoking this script).
fan() {  # fan <mode: spec|job> <label> <region> <J>  (lines on stdin)
  grep . | tr '\n' '\0' | xargs -0 -n1 -P "$4" "$SELF" __worker "$1" "$2" "$3"
}

# Enumerate parents in one region and queue child jobs; then run them.
api_region() {
  local r="$1" items x
  local jobs="$WORK/jobs.$r"; : > "$jobs"; : > "$WORK/jobs2.$r"
  printf '%s\n' "$REGIONAL_SPECS" | fan spec "$r" "$r" "$INNER_J"

  # parents -> child jobs (a zero line first so "none found" is recorded)
  q() { local tf_list="$1" fn="$2" expr="$3"; shift 3
        local t; items=$(lst "$r" "$expr" "$@") || return
        for t in $tf_list; do emit "$r" "$t" 0; done
        printf '%s\n' "$items" | grep . | sed "s#^#$fn|$r|#" >> "$jobs"; }
  local buses
  if buses=$(lst "$r" 'EventBuses[].Name' events list-event-buses); then
    emit "$r" aws_cloudwatch_event_rule 0; emit "$r" aws_cloudwatch_event_target 0
    printf '%s\n' "$buses" | grep . | sed "s#^#j_evt_rules|$r|#" >> "$jobs"
  fi
  q "aws_autoscaling_lifecycle_hook" j_asg 'AutoScalingGroups[].AutoScalingGroupName' autoscaling describe-auto-scaling-groups
  q "aws_lb_listener aws_lb_listener_rule aws_lb_listener_certificate" j_lb 'LoadBalancers[].LoadBalancerArn' elbv2 describe-load-balancers
  q "aws_lambda_alias aws_lambda_function_event_invoke_config" j_lambda_fn 'Functions[].FunctionName' lambda list-functions
  q "aws_lambda_layer_version aws_lambda_layer_version_permission" j_lambda_layer 'Layers[].LayerName' lambda list-layers
  q "aws_cloudwatch_log_subscription_filter" j_loggroup 'logGroups[].logGroupName' logs describe-log-groups
  q "aws_ecr_repository_policy aws_ecr_lifecycle_policy" j_ecr_repo 'repositories[].repositoryName' ecr describe-repositories
  q "aws_ecs_service" j_ecs_cluster 'clusterArns' ecs list-clusters
  q "aws_eks_node_group aws_eks_addon aws_eks_fargate_profile aws_eks_identity_provider_config" j_eks 'clusters' eks list-clusters
  q "aws_efs_mount_target aws_efs_backup_policy" j_efs 'FileSystems[].FileSystemId' efs describe-file-systems
  q "aws_glue_catalog_table" j_glue_db 'DatabaseList[].Name' glue get-databases
  q "aws_guardduty_publishing_destination" j_gd 'DetectorIds' guardduty list-detectors
  q "aws_kinesis_stream_consumer" j_kinesis 'StreamSummaries[].StreamARN' kinesis list-streams
  q "aws_prometheus_rule_group_namespace" j_amp 'workspaces[].workspaceId' amp list-workspaces
  q "aws_sagemaker_image_version" j_sm_image 'Images[].ImageName' sagemaker list-images
  q "aws_sagemaker_model_package_group_policy" j_sm_mpg 'ModelPackageGroupSummaryList[].ModelPackageGroupName' sagemaker list-model-package-groups
  q "aws_transfer_access aws_transfer_user aws_transfer_ssh_key" j_transfer 'Servers[].ServerId' transfer list-servers
  q "aws_ec2_transit_gateway_route aws_ec2_transit_gateway_route_table_association aws_ec2_transit_gateway_route_table_propagation" j_tgw_rt 'TransitGatewayRouteTables[?State!=`deleted`].TransitGatewayRouteTableId' ec2 describe-transit-gateway-route-tables
  q "aws_codedeploy_deployment_group" j_cd_app 'applications' deploy list-applications
  q "aws_cognito_user_pool_client aws_cognito_user_group aws_cognito_identity_provider aws_cognito_resource_server" j_cognito 'UserPools[].Id' cognito-idp list-user-pools --max-results 60
  q "aws_api_gateway_resource aws_api_gateway_method aws_api_gateway_method_response aws_api_gateway_integration aws_api_gateway_integration_response aws_api_gateway_stage aws_api_gateway_model aws_api_gateway_authorizer aws_api_gateway_request_validator aws_api_gateway_documentation_part aws_api_gateway_documentation_version" j_apigw 'items[].id' apigateway get-rest-apis
  q "aws_api_gateway_usage_plan_key" j_apigw_plan 'items[].id' apigateway get-usage-plans
  q "aws_api_gateway_base_path_mapping" j_apigw_dom 'items[].domainName' apigateway get-domain-names
  q "aws_apigatewayv2_route aws_apigatewayv2_integration aws_apigatewayv2_stage aws_apigatewayv2_authorizer aws_apigatewayv2_model aws_apigatewayv2_deployment" j_apigw2 'Items[].ApiId' apigatewayv2 get-apis
  q "aws_apigatewayv2_api_mapping" j_apigw2_dom 'Items[].DomainName' apigatewayv2 get-domain-names
  q "aws_appmesh_virtual_node aws_appmesh_virtual_router aws_appmesh_virtual_service aws_appmesh_virtual_gateway" j_appmesh 'meshes[].meshName' appmesh list-meshes
  q "aws_ses_domain_dkim aws_ses_domain_mail_from" j_ses_dom 'EmailIdentities[?IdentityType==`DOMAIN`].IdentityName' sesv2 list-email-identities
  for x in ecs dynamodb rds lambda elasticmapreduce appstream sagemaker custom-resource comprehend kafka cassandra elasticache neptune workspaces; do
    echo "j_appas|$r|$x" >> "$jobs"
  done
  echo "j_glue_policy|$r" >> "$jobs"
  echo "j_bedrock_log|$r" >> "$jobs"

  fan job "$r" "$r" "$INNER_J" < "$jobs"
  # event targets are queued by j_evt_rules
  [[ -s "$WORK/jobs2.$r" ]] && fan job "$r" "$r" "$INNER_J" < "$WORK/jobs2.$r"
  return 0
}

api_global() {
  local r=us-east-1 jobs="$WORK/jobs.global" items
  : > "$jobs"
  printf '%s\n' "$GLOBAL_SPECS" | fan spec global "$r" "$INNER_J"
  g() { local tf_list="$1" fn="$2" ar="$3" expr="$4"; shift 4
        local t; items=$(lst "$ar" "$expr" "$@") || return
        for t in $tf_list; do emit global "$t" 0; done
        printf '%s\n' "$items" | grep . | sed "s#^#$fn|$ar|#" >> "$jobs"; }
  g "aws_iam_role_policy aws_iam_role_policy_attachment" j_iam_role $r 'Roles[].RoleName' iam list-roles
  g "aws_iam_access_key" j_iam_user $r 'Users[].UserName' iam list-users
  g "aws_route53_record" j_r53_zone $r 'HostedZones[].Id' route53 list-hosted-zones
  g "aws_globalaccelerator_listener" j_ga us-west-2 'Accelerators[].AcceleratorArn' globalaccelerator list-accelerators
  g "aws_organizations_policy_attachment" j_org_policy $r 'Policies[].Id' organizations list-policies --filter SERVICE_CONTROL_POLICY
  # Organizations policy types beyond SCPs
  local pt; for pt in TAG_POLICY BACKUP_POLICY AISERVICES_OPT_OUT_POLICY; do
    items=$(lst $r 'Policies[].Id' organizations list-policies --filter $pt) && \
      printf '%s\n' "$items" | grep . | sed "s#^#j_org_policy|$r|#" >> "$jobs"
  done
  cnt global aws_organizations_policy $r 'Policies[?!AwsManaged]' organizations list-policies --filter SERVICE_CONTROL_POLICY
  # CloudFront-scope WAF lives in us-east-1 but is a global resource
  cnt global aws_wafv2_web_acl $r WebACLs wafv2 list-web-acls --scope CLOUDFRONT
  cnt global aws_wafv2_web_acl_logging_configuration $r LoggingConfigurations wafv2 list-logging-configurations --scope CLOUDFRONT
  # S3: each bucket's settings are read in the bucket's own region
  local s3
  if s3=$(aws s3api list-buckets --region $r --output json 2>>"$WORK/err.s3"); then
    local s3sub="aws_s3_bucket_policy aws_s3_bucket_versioning aws_s3_bucket_server_side_encryption_configuration aws_s3_bucket_public_access_block aws_s3_bucket_ownership_controls aws_s3_bucket_lifecycle_configuration aws_s3_bucket_replication_configuration aws_s3_bucket_cors_configuration aws_s3_bucket_website_configuration aws_s3_bucket_logging aws_s3_bucket_accelerate_configuration aws_s3_bucket_object_lock_configuration aws_s3_bucket_request_payment_configuration"
    local t; for t in $s3sub; do emit global "$t" 0; done
    echo "$s3" | jq -r '.Buckets[]? | "\(.BucketRegion // "")|\(.Name)"' | while IFS='|' read -r br bn; do
      if [[ -z "$br" ]]; then
        br=$(aws s3api get-bucket-location --bucket "$bn" --region $r --query LocationConstraint --output text 2>/dev/null)
        [[ -z "$br" || "$br" == None ]] && br=us-east-1; [[ "$br" == EU ]] && br=eu-west-1
      fi
      echo "j_s3|$br|$bn"
    done >> "$jobs"
  fi
  fan job global "$r" "$INNER_J" < "$jobs"
  return 0
}

# --------------------------------------------------- worker entry point ---
if [[ "$1" == "__worker" ]]; then
  # __worker <spec|job> <label> <region> <line>
  if [[ "$2" == spec ]]; then run_spec "$3" "$4" "$5"; else run_job "$5"; fi
  exit 0
fi

# -----------------------------------------------------------------------------
# AWS Config resourceType -> Firefly-supported Terraform resource type.
# Used as a fallback where the direct API call for a type failed.
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

# Supported types counted by the direct API pass above (run_spec / j_*).
API_COUNTED=(
  "aws_acm_certificate"
  "aws_ami"
  "aws_api_gateway_api_key"
  "aws_api_gateway_authorizer"
  "aws_api_gateway_base_path_mapping"
  "aws_api_gateway_documentation_part"
  "aws_api_gateway_documentation_version"
  "aws_api_gateway_domain_name"
  "aws_api_gateway_integration"
  "aws_api_gateway_integration_response"
  "aws_api_gateway_method"
  "aws_api_gateway_method_response"
  "aws_api_gateway_model"
  "aws_api_gateway_request_validator"
  "aws_api_gateway_resource"
  "aws_api_gateway_rest_api"
  "aws_api_gateway_stage"
  "aws_api_gateway_usage_plan"
  "aws_api_gateway_usage_plan_key"
  "aws_api_gateway_vpc_link"
  "aws_apigatewayv2_api"
  "aws_apigatewayv2_api_mapping"
  "aws_apigatewayv2_authorizer"
  "aws_apigatewayv2_deployment"
  "aws_apigatewayv2_domain_name"
  "aws_apigatewayv2_integration"
  "aws_apigatewayv2_model"
  "aws_apigatewayv2_route"
  "aws_apigatewayv2_stage"
  "aws_apigatewayv2_vpc_link"
  "aws_appautoscaling_policy"
  "aws_appautoscaling_target"
  "aws_appconfig_application"
  "aws_appmesh_mesh"
  "aws_appmesh_virtual_gateway"
  "aws_appmesh_virtual_node"
  "aws_appmesh_virtual_router"
  "aws_appmesh_virtual_service"
  "aws_athena_data_catalog"
  "aws_athena_database"
  "aws_athena_named_query"
  "aws_athena_workgroup"
  "aws_autoscaling_group"
  "aws_autoscaling_lifecycle_hook"
  "aws_autoscaling_policy"
  "aws_backup_vault"
  "aws_backup_vault_lock_configuration"
  "aws_bedrock_custom_model"
  "aws_bedrock_guardrail"
  "aws_bedrock_model_invocation_logging_configuration"
  "aws_cloudfront_cache_policy"
  "aws_cloudfront_distribution"
  "aws_cloudfront_function"
  "aws_cloudfront_key_group"
  "aws_cloudfront_origin_access_identity"
  "aws_cloudfront_origin_request_policy"
  "aws_cloudfront_realtime_log_config"
  "aws_cloudhsm_v2_cluster"
  "aws_cloudhsm_v2_hsm"
  "aws_cloudtrail"
  "aws_cloudwatch_composite_alarm"
  "aws_cloudwatch_dashboard"
  "aws_cloudwatch_event_bus"
  "aws_cloudwatch_event_rule"
  "aws_cloudwatch_event_target"
  "aws_cloudwatch_log_group"
  "aws_cloudwatch_log_subscription_filter"
  "aws_cloudwatch_metric_alarm"
  "aws_cloudwatch_metric_stream"
  "aws_codebuild_project"
  "aws_codebuild_report_group"
  "aws_codedeploy_app"
  "aws_codedeploy_deployment_config"
  "aws_codedeploy_deployment_group"
  "aws_codepipeline"
  "aws_codepipeline_webhook"
  "aws_cognito_identity_pool"
  "aws_cognito_identity_provider"
  "aws_cognito_resource_server"
  "aws_cognito_user_group"
  "aws_cognito_user_pool"
  "aws_cognito_user_pool_client"
  "aws_config_aggregate_authorization"
  "aws_config_configuration_recorder"
  "aws_config_delivery_channel"
  "aws_connect_instance"
  "aws_db_cluster_snapshot"
  "aws_db_event_subscription"
  "aws_db_instance"
  "aws_db_option_group"
  "aws_db_parameter_group"
  "aws_db_proxy"
  "aws_db_proxy_default_target_group"
  "aws_db_proxy_endpoint"
  "aws_db_snapshot"
  "aws_db_subnet_group"
  "aws_default_network_acl"
  "aws_directory_service_directory"
  "aws_dms_endpoint"
  "aws_dms_replication_instance"
  "aws_dms_replication_task"
  "aws_docdb_cluster"
  "aws_docdb_cluster_instance"
  "aws_docdb_cluster_parameter_group"
  "aws_docdb_global_cluster"
  "aws_dx_connection"
  "aws_dx_gateway"
  "aws_dx_lag"
  "aws_dynamodb_table"
  "aws_ebs_snapshot"
  "aws_ebs_volume"
  "aws_ec2_traffic_mirror_filter"
  "aws_ec2_traffic_mirror_session"
  "aws_ec2_traffic_mirror_target"
  "aws_ec2_transit_gateway"
  "aws_ec2_transit_gateway_peering_attachment"
  "aws_ec2_transit_gateway_peering_attachment_accepter"
  "aws_ec2_transit_gateway_route"
  "aws_ec2_transit_gateway_route_table"
  "aws_ec2_transit_gateway_route_table_association"
  "aws_ec2_transit_gateway_route_table_propagation"
  "aws_ec2_transit_gateway_vpc_attachment"
  "aws_ec2_transit_gateway_vpc_attachment_accepter"
  "aws_ecr_lifecycle_policy"
  "aws_ecr_replication_configuration"
  "aws_ecr_repository"
  "aws_ecr_repository_policy"
  "aws_ecrpublic_repository"
  "aws_ecs_capacity_provider"
  "aws_ecs_cluster"
  "aws_ecs_service"
  "aws_ecs_task_definition"
  "aws_efs_access_point"
  "aws_efs_backup_policy"
  "aws_efs_file_system"
  "aws_efs_mount_target"
  "aws_eip"
  "aws_eks_addon"
  "aws_eks_cluster"
  "aws_eks_fargate_profile"
  "aws_eks_identity_provider_config"
  "aws_eks_node_group"
  "aws_elastic_beanstalk_application"
  "aws_elastic_beanstalk_environment"
  "aws_elasticache_cluster"
  "aws_elasticache_global_replication_group"
  "aws_elasticache_parameter_group"
  "aws_elasticache_replication_group"
  "aws_elasticache_subnet_group"
  "aws_elasticache_user"
  "aws_elasticache_user_group"
  "aws_elasticsearch_domain"
  "aws_elb"
  "aws_emr_cluster"
  "aws_flow_log"
  "aws_fsx_ontap_file_system"
  "aws_fsx_ontap_storage_virtual_machine"
  "aws_fsx_ontap_volume"
  "aws_fsx_windows_file_system"
  "aws_globalaccelerator_accelerator"
  "aws_globalaccelerator_listener"
  "aws_glue_catalog_database"
  "aws_glue_catalog_table"
  "aws_glue_crawler"
  "aws_glue_job"
  "aws_glue_resource_policy"
  "aws_guardduty_detector"
  "aws_guardduty_publishing_destination"
  "aws_iam_access_key"
  "aws_iam_group"
  "aws_iam_instance_profile"
  "aws_iam_openid_connect_provider"
  "aws_iam_policy"
  "aws_iam_role"
  "aws_iam_role_policy"
  "aws_iam_role_policy_attachment"
  "aws_iam_user"
  "aws_iam_virtual_mfa_device"
  "aws_instance"
  "aws_internet_gateway"
  "aws_key_pair"
  "aws_kinesis_firehose_delivery_stream"
  "aws_kinesis_stream"
  "aws_kinesis_stream_consumer"
  "aws_kms_alias"
  "aws_kms_key"
  "aws_lambda_alias"
  "aws_lambda_code_signing_config"
  "aws_lambda_event_source_mapping"
  "aws_lambda_function"
  "aws_lambda_function_event_invoke_config"
  "aws_lambda_layer_version"
  "aws_lambda_layer_version_permission"
  "aws_launch_configuration"
  "aws_launch_template"
  "aws_lb"
  "aws_lb_listener"
  "aws_lb_listener_certificate"
  "aws_lb_listener_rule"
  "aws_lb_target_group"
  "aws_lightsail_instance"
  "aws_memorydb_cluster"
  "aws_mq_broker"
  "aws_mq_configuration"
  "aws_msk_cluster"
  "aws_msk_configuration"
  "aws_mwaa_environment"
  "aws_nat_gateway"
  "aws_neptune_cluster"
  "aws_neptune_cluster_instance"
  "aws_neptune_cluster_parameter_group"
  "aws_neptune_parameter_group"
  "aws_network_acl"
  "aws_network_interface"
  "aws_networkfirewall_firewall"
  "aws_opensearch_domain"
  "aws_organizations_policy"
  "aws_organizations_policy_attachment"
  "aws_organizations_resource_policy"
  "aws_osis_pipeline"
  "aws_prometheus_rule_group_namespace"
  "aws_prometheus_workspace"
  "aws_quicksight_data_source"
  "aws_quicksight_group"
  "aws_ram_resource_share"
  "aws_rds_cluster"
  "aws_rds_cluster_endpoint"
  "aws_rds_cluster_instance"
  "aws_rds_cluster_parameter_group"
  "aws_rds_global_cluster"
  "aws_redshift_cluster"
  "aws_redshift_parameter_group"
  "aws_redshift_subnet_group"
  "aws_route53_record"
  "aws_route53_resolver_endpoint"
  "aws_route53_zone"
  "aws_route_table"
  "aws_route_table_association"
  "aws_s3_bucket"
  "aws_s3_bucket_accelerate_configuration"
  "aws_s3_bucket_acl"
  "aws_s3_bucket_cors_configuration"
  "aws_s3_bucket_lifecycle_configuration"
  "aws_s3_bucket_logging"
  "aws_s3_bucket_object_lock_configuration"
  "aws_s3_bucket_ownership_controls"
  "aws_s3_bucket_policy"
  "aws_s3_bucket_public_access_block"
  "aws_s3_bucket_replication_configuration"
  "aws_s3_bucket_request_payment_configuration"
  "aws_s3_bucket_server_side_encryption_configuration"
  "aws_s3_bucket_versioning"
  "aws_s3_bucket_website_configuration"
  "aws_sagemaker_app"
  "aws_sagemaker_app_image_config"
  "aws_sagemaker_code_repository"
  "aws_sagemaker_domain"
  "aws_sagemaker_endpoint"
  "aws_sagemaker_endpoint_configuration"
  "aws_sagemaker_feature_group"
  "aws_sagemaker_flow_definition"
  "aws_sagemaker_human_task_ui"
  "aws_sagemaker_image"
  "aws_sagemaker_image_version"
  "aws_sagemaker_model"
  "aws_sagemaker_model_package_group"
  "aws_sagemaker_model_package_group_policy"
  "aws_sagemaker_notebook_instance"
  "aws_sagemaker_notebook_instance_lifecycle_configuration"
  "aws_sagemaker_project"
  "aws_sagemaker_studio_lifecycle_config"
  "aws_sagemaker_user_profile"
  "aws_sagemaker_workforce"
  "aws_sagemaker_workteam"
  "aws_secretsmanager_secret"
  "aws_security_group"
  "aws_security_group_rule"
  "aws_service_discovery_service"
  "aws_ses_domain_dkim"
  "aws_ses_domain_identity"
  "aws_ses_domain_mail_from"
  "aws_ses_email_identity"
  "aws_sfn_state_machine"
  "aws_sns_topic"
  "aws_sns_topic_subscription"
  "aws_sqs_queue"
  "aws_ssm_association"
  "aws_ssm_parameter"
  "aws_subnet"
  "aws_transfer_access"
  "aws_transfer_server"
  "aws_transfer_ssh_key"
  "aws_transfer_user"
  "aws_transfer_workflow"
  "aws_vpc"
  "aws_vpc_dhcp_options"
  "aws_vpc_endpoint"
  "aws_vpc_endpoint_service"
  "aws_vpc_ipv4_cidr_block_association"
  "aws_vpc_ipv6_cidr_block_association"
  "aws_vpc_peering_connection"
  "aws_vpc_peering_connection_accepter"
  "aws_vpc_peering_connection_options"
  "aws_vpn_connection"
  "aws_vpn_gateway"
  "aws_wafv2_web_acl"
  "aws_wafv2_web_acl_logging_configuration"
  "aws_workspaces_directory"
  "aws_workspaces_ip_group"
  "aws_workspaces_workspace"
)

# Supported types counted under another type's row. (Empty for AWS since the
# API pass splits DocumentDB / Neptune / Aurora instances out of RDS.)
COUNTED_AS_OTHER=(
)

# Supported types neither the API pass nor AWS Config can count.
NOT_COUNTABLE=(
)

# Bash 3.2 (macOS default) has no associative arrays: lookups are linear scans
# or done in awk.
in_list() { local x="$1" i; shift; for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done; return 1; }

# Config resource types recorded once per account (in the recorder's home
# region): take the MAX across regions instead of the SUM.
GLOBAL_PREFIXES="AWS::IAM:: AWS::CloudFront:: AWS::Route53:: AWS::GlobalAccelerator:: AWS::ECR::PublicRepository AWS::Organizations::"
# Terraform types the API pass counts once per account (label "global").
GLOBAL_TF_RE='^aws_(iam_|s3_bucket|route53_zone$|route53_record$|cloudfront_|ecrpublic_|dx_gateway$|rds_global_cluster$|docdb_global_cluster$|elasticache_global_replication_group$|organizations_|globalaccelerator_)'

QUERY="SELECT resourceType, COUNT(*) GROUP BY resourceType"

# ------------------------------------------------------------- options ---
PROFILE_NAME=""
REGIONS=""
AGGREGATOR=""
VERBOSE=0
CONFIG_ONLY=0
REGION_J=4
INNER_J=6
OUT_CSV="firefly_aws_asset_count_$(date +%Y%m%d_%H%M%S).csv"

while getopts "p:r:a:j:Cvh" opt; do
  case $opt in
    p) PROFILE_NAME="$OPTARG"; export AWS_PROFILE="$OPTARG" ;;
    r) REGIONS="$OPTARG" ;;
    a) AGGREGATOR="$OPTARG" ;;
    j) REGION_J="$OPTARG" ;;
    C) CONFIG_ONLY=1 ;;
    v) VERBOSE=1 ;;
    h) awk '/^#/{print; next} {exit}' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done
[[ "$REGION_J" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: -j needs a positive number"; exit 1; }

command -v aws >/dev/null || { echo "ERROR: aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found";      exit 1; }

# Fail fast with a clear message if credentials are missing/expired, instead
# of limping through to a misleading "TOTAL: 0" report.
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1)
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ff_aws_count.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/obs"; : > "$WORK/err"
export WORK ACCOUNT AWS_PAGER=""
# Throttling is common with many parallel list calls: let the CLI back off.
# Timeouts keep one unresponsive endpoint from stalling a region for minutes.
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-adaptive}" AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-5}"
export AWS_TIMEOUTS="--cli-connect-timeout 10 --cli-read-timeout 60"

# Config map as "<config type> <tf type>" lines for awk.
for i in "${!MAP_KEYS[@]}"; do echo "${MAP_KEYS[$i]} ${MAP_VALS[$i]}"; done > "$WORK/map"

config_query() {   # config_query <region>  -> obs lines "config|<region|global>|<cfg type>|<n>"
  local r="$1" next="" out
  while :; do
    if [[ -n "$next" ]]; then
      out=$(aws configservice select-resource-config --region "$r" --expression "$QUERY" --next-token "$next" 2>/dev/null) || return 1
    else
      out=$(aws configservice select-resource-config --region "$r" --expression "$QUERY" 2>/dev/null) || return 1
    fi
    echo "$out" | jq -r --arg r "$r" '.Results[] | fromjson | "config|\($r)|\(.resourceType)|\(."COUNT(*)")"' >> "$WORK/obs"
    next=$(echo "$out" | jq -r '.NextToken // empty')
    [[ -z "$next" ]] && break
  done
}

echo "============================================================"
echo " Firefly - AWS Supported Asset Count"
echo " Account: $ACCOUNT"
echo " Date:    $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "============================================================"

NO_RECORDER=(); PARTIAL_RECORDER=()

if [[ -n "$AGGREGATOR" ]]; then
  echo "Mode: AWS Config aggregator '$AGGREGATOR' (org / multi-account, Config data only)"
  next=""
  while :; do
    if [[ -n "$next" ]]; then
      out=$(aws configservice select-aggregate-resource-config --configuration-aggregator-name "$AGGREGATOR" \
              --expression "$QUERY" --next-token "$next") || exit 1
    else
      out=$(aws configservice select-aggregate-resource-config --configuration-aggregator-name "$AGGREGATOR" \
              --expression "$QUERY") || exit 1
    fi
    echo "$out" | jq -r '.Results[] | fromjson | "config|agg|\(.resourceType)|\(."COUNT(*)")"' >> "$WORK/obs"
    next=$(echo "$out" | jq -r '.NextToken // empty')
    [[ -z "$next" ]] && break
  done
else
  if [[ -z "$REGIONS" ]]; then
    REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "ERROR: could not list AWS regions:"
      echo "$REGIONS"
      echo "Check IAM permissions (ec2:DescribeRegions), or pass explicit regions with -r."
      exit 1
    fi
  fi
  N_REG=$(echo $REGIONS | wc -w | tr -d ' ')
  if [[ $CONFIG_ONLY -eq 1 ]]; then
    echo "Mode: AWS Config only, $N_REG regions"
  else
    echo "Mode: direct API counts in $N_REG regions (+ AWS Config fallback), $REGION_J regions at a time"
  fi

  scan_region() {  # runs in the background, one per region
    local r="$1" status
    # AWS Config: only query where a recorder is actually recording. A region
    # without one answers the query with 0 rows, not an error.
    status=$(aws configservice describe-configuration-recorder-status --region "$r" \
               --query 'ConfigurationRecordersStatus[?recording] | length(@)' --output text 2>/dev/null)
    if [[ "$status" =~ ^[1-9] ]]; then
      config_query "$r" && echo "$r" >> "$WORK/config_ok"
      aws configservice describe-configuration-recorders --region "$r" \
        --query 'ConfigurationRecorders[0].recordingGroup.allSupported' --output text 2>/dev/null \
        | grep -qi true || echo "$r" >> "$WORK/config_partial"
    else
      echo "$r" >> "$WORK/config_none"
    fi
    [[ $CONFIG_ONLY -eq 1 ]] && return 0
    api_region "$r"
  }

  if [[ $CONFIG_ONLY -eq 0 ]]; then
    printf "  scanning global services (IAM, S3, Route 53, CloudFront, ...)\n"
    api_global &
  fi
  for region in $REGIONS; do
    while [[ $(jobs -rp | wc -l | tr -d ' ') -ge $REGION_J ]]; do sleep 1; done
    printf "  scanning %s\n" "$region"
    scan_region "$region" &
  done
  wait
fi

# ------------------------------------------------------------ aggregate ---
# Per type: sum over regions of (API count if the API call worked, else the
# Config count). Global types: API total if it worked, else Config total.
awk -F'|' -v gre="$GLOBAL_TF_RE" -v gpre="$GLOBAL_PREFIXES" '
  BEGIN { n = split(gpre, GP, " ") }
  FILENAME ~ /\/map$/ { split($0, kv, " "); M[kv[1]] = kv[2]; next }
  $1 == "api" { api[$2 SUBSEP $3] += $4; hasapi[$2 SUBSEP $3] = 1; seen[$3] = 1; next }
  $1 == "config" {
    if (!($3 in M)) { unm[$3] += $4; next }
    t = M[$3]; g = 0
    for (i = 1; i <= n; i++) if (index($3, GP[i]) == 1) g = 1
    if (g) { if ($4 > cmax[t]) cmax[t] = $4 }
    else   { cfg[$2 SUBSEP t] += $4; regs[$2] = 1 }
    seen[t] = 1; next
  }
  END {
    for (k in api) { split(k, p, SUBSEP); if (p[1] != "global") regs[p[1]] = 1 }
    for (t in seen) {
      tot = 0; src = ""
      if (t ~ gre) {
        if (("global" SUBSEP t) in hasapi) { tot = api["global" SUBSEP t]; src = "api" }
        else { tot = cmax[t]; for (r in regs) tot += cfg[r SUBSEP t]; src = "config" }
      } else {
        ua = 0; uc = 0
        for (r in regs) {
          if ((r SUBSEP t) in hasapi) { tot += api[r SUBSEP t]; ua = 1 }
          else if ((r SUBSEP t) in cfg) { tot += cfg[r SUBSEP t]; uc = 1 }
        }
        if (cmax[t] > 0 && !ua) { tot += cmax[t]; uc = 1 }
        src = (ua && uc) ? "api+config" : (ua ? "api" : "config")
      }
      print "T|" t "|" src "|" tot
    }
    for (u in unm) print "U|" u "|" unm[u]
  }' "$WORK/map" "$WORK/obs" > "$WORK/result"

# ------------------------- report -------------------------
TOTAL=0
echo ""
echo "------------------------------------------------------------"
printf "%-55s %10s  %s\n" "Firefly-supported Terraform type" "Count" "Source"
echo "------------------------------------------------------------"
echo "terraform_type,source,count" > "$OUT_CSV"
COUNTED=("${MAP_VALS[@]}" "${API_COUNTED[@]}")
while IFS='|' read -r _ tf src count; do
  in_list "$tf" "${COUNTED[@]}" || continue
  [[ "$count" -eq 0 ]] && continue
  printf "%-55s %10d  %s\n" "$tf" "$count" "$src"
  echo "$tf,$src,$count" >> "$OUT_CSV"
  TOTAL=$(( TOTAL + count ))
done <<< "$(grep '^T|' "$WORK/result" | sort -t'|' -k2,2)"
echo "------------------------------------------------------------"
printf "%-55s %10d\n" "TOTAL Firefly-supported assets" "$TOTAL"
echo "------------------------------------------------------------"
echo "TOTAL,,${TOTAL}" >> "$OUT_CSV"

if [[ $VERBOSE -eq 1 ]] && grep -q '^U|' "$WORK/result"; then
  echo ""
  echo "Other resource types found in AWS Config (not on the supported list / not mapped):"
  grep '^U|' "$WORK/result" | sort | while IFS='|' read -r _ t c; do printf "  %-53s %10d\n" "$t" "$c"; done
fi

if [[ -z "$AGGREGATOR" ]]; then
  echo ""
  n_ok=$( [[ -f "$WORK/config_ok" ]] && wc -l < "$WORK/config_ok" | tr -d ' ' || echo 0)
  echo "AWS Config: recording in $n_ok of $N_REG regions (used only where an API call failed)."
  if [[ $CONFIG_ONLY -eq 1 ]]; then
    echo "WARNING: -C counts only what AWS Config records. Regions without a recorder"
    echo "         contribute 0, and many supported types are never recorded. Treat the"
    echo "         total as a LOWER BOUND; run without -C for a full count."
    [[ -f "$WORK/config_none" ]] && echo "  No recorder: $(sort "$WORK/config_none" | tr '\n' ' ')"
    [[ -f "$WORK/config_partial" ]] && echo "  Recorder not set to all resource types: $(sort "$WORK/config_partial" | tr '\n' ' ')"
  fi
else
  echo ""
  echo "WARNING: aggregator mode counts only what AWS Config records in the aggregated"
  echo "         accounts/regions. Treat the total as a LOWER BOUND; for a full count run"
  echo "         the script without -a in each account."
fi

# Permission gaps: types whose API was denied (Config may have filled some in).
if [[ -s "$WORK/err" ]]; then
  PERM_N=$(grep -c '|perm|' "$WORK/err")
  OTHER_N=$(grep -vc '|perm|' "$WORK/err")
  if [[ $PERM_N -gt 0 ]]; then
    echo ""
    echo "WARNING: $PERM_N API calls were denied, so these services may be undercounted"
    echo "         (attach the ReadOnlyAccess managed policy for a complete count):"
    grep '|perm|' "$WORK/err" | cut -d'|' -f2 | awk '{print $1 " " $2}' \
      | sort | uniq -c | sort -rn | head -25 | sed 's/^/  /'
  fi
  if [[ $OTHER_N -gt 0 ]]; then
    echo ""
    echo "NOTE: $OTHER_N API calls failed for other reasons (throttling, service errors)."
    if [[ $VERBOSE -eq 1 ]]; then
      grep -v '|perm|' "$WORK/err" | cut -c1-220 | sed 's/^/  /' | head -40
    else
      echo "      Run with -v to see them."
    fi
  fi
fi

N_COUNTABLE=$(printf '%s\n' "${MAP_VALS[@]}" "${API_COUNTED[@]}" | sort -u | wc -l | tr -d ' ')
N_NOT=${#NOT_COUNTABLE[@]}
echo ""
echo "COVERAGE: this script counts $N_COUNTABLE of $(( N_COUNTABLE + N_NOT )) Firefly-supported AWS types."
if [[ $N_NOT -gt 0 ]]; then
  if [[ $VERBOSE -eq 1 ]]; then
    echo "Supported types not countable here:"
    printf '  %s\n' "${NOT_COUNTABLE[@]}"
  else
    echo "      Run with -v to list the $N_NOT it cannot count."
  fi
fi
echo ""
echo "CSV written to: $OUT_CSV"
