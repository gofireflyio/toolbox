const { EC2Client, DescribeRegionsCommand } = require("@aws-sdk/client-ec2");
          const { CloudWatchEventsClient, ListRulesCommand, ListTargetsByRuleCommand, RemoveTargetsCommand, DeleteRuleCommand } = require("@aws-sdk/client-cloudwatch-events");
          const { IAMClient, ListAttachedRolePoliciesCommand, DetachRolePolicyCommand, ListRolePoliciesCommand, DeleteRolePolicyCommand, DeleteRoleCommand, ListPoliciesCommand, ListEntitiesForPolicyCommand, DetachUserPolicyCommand, DetachGroupPolicyCommand, ListPolicyVersionsCommand, DeletePolicyVersionCommand, DeletePolicyCommand } = require("@aws-sdk/client-iam");
          const https = require('https');
          const url = require('url');

          // First define all helper functions
          async function getEnabledRegions() {
              try {
                  const client = new EC2Client({ region: 'us-east-1' });
                  const command = new DescribeRegionsCommand({ AllRegions: false });
                  const response = await client.send(command);
                  return response.Regions.map(region => region.RegionName);
              } catch (error) {
                  console.error('Error getting regions:', error);
                  throw error;
              }
          }

          async function sendCloudFormationResponse(event, context, responseStatus, responseData, physicalResourceId) {
              if (!event.ResponseURL) {
                  console.log('No ResponseURL found in event');
                  return;
              }

              const responseBody = JSON.stringify({
                  Status: responseStatus,
                  Reason: responseStatus === 'FAILED' ? JSON.stringify(responseData) : 'See CloudWatch logs for details',
                  PhysicalResourceId: physicalResourceId || context.logStreamName,
                  StackId: event.StackId,
                  RequestId: event.RequestId,
                  LogicalResourceId: event.LogicalResourceId,
                  NoEcho: false,
                  Data: responseData
              });

              console.log('Sending response to CloudFormation:', responseBody);

              return new Promise((resolve, reject) => {
                  try {
                      const parsedUrl = url.parse(event.ResponseURL);
                      const options = {
                          hostname: parsedUrl.hostname,
                          port: 443,
                          path: parsedUrl.path,
                          method: 'PUT',
                          headers: {
                              'content-type': '',
                              'content-length': responseBody.length
                          }
                      };

                      const request = https.request(options, (response) => {
                          console.log(`Status code: ${response.statusCode}`);
                          resolve();
                      });

                      request.on('error', (error) => {
                          console.error('Error sending response:', error);
                          reject(error);
                      });

                      request.write(responseBody);
                      request.end();
                  } catch (error) {
                      console.error('Error in sendCloudFormationResponse:', error);
                      reject(error);
                  }
              });
          }

          async function deleteEventRules(region) {
              const client = new CloudWatchEventsClient({ region });
              let nextToken;
              const deletedRules = [];

              try {
                  do {
                      const listCommand = new ListRulesCommand({
                          NamePrefix: 'firefly-events-',
                          NextToken: nextToken
                      });
                      const response = await client.send(listCommand);

                      for (const rule of response.Rules || []) {
                          try {
                              console.log(`Getting targets for rule ${rule.Name} in ${region}`);
                              const targetsCommand = new ListTargetsByRuleCommand({
                                  Rule: rule.Name
                              });
                              const targetsResponse = await client.send(targetsCommand);

                              if (targetsResponse.Targets && targetsResponse.Targets.length > 0) {
                                  console.log(`Removing ${targetsResponse.Targets.length} targets from rule ${rule.Name}`);
                                  const removeTargetsCommand = new RemoveTargetsCommand({
                                      Rule: rule.Name,
                                      Ids: targetsResponse.Targets.map(target => target.Id)
                                  });
                                  await client.send(removeTargetsCommand);
                              }

                              console.log(`Deleting rule ${rule.Name}`);
                              const deleteCommand = new DeleteRuleCommand({
                                  Name: rule.Name
                              });
                              await client.send(deleteCommand);

                              deletedRules.push({ region, ruleName: rule.Name });
                          } catch (error) {
                              console.error(`Error processing rule ${rule.Name}:`, error);
                          }
                      }

                      nextToken = response.NextToken;
                  } while (nextToken);

              } catch (error) {
                  console.error(`Error processing region ${region}:`, error);
              }

              return deletedRules;
          }

          async function deleteIAMRole() {
              const client = new IAMClient({});
              const roleName = 'invoke-firefly-remote-event-bus';

              try {
                  // List and detach managed policies
                  const attachedPolicies = await client.send(new ListAttachedRolePoliciesCommand({ RoleName: roleName }));
                  for (const policy of attachedPolicies.AttachedPolicies || []) {
                      await client.send(new DetachRolePolicyCommand({
                          RoleName: roleName,
                          PolicyArn: policy.PolicyArn
                      }));
                  }

                  // List and delete inline policies
                  const inlinePolicies = await client.send(new ListRolePoliciesCommand({ RoleName: roleName }));
                  for (const policyName of inlinePolicies.PolicyNames || []) {
                      await client.send(new DeleteRolePolicyCommand({
                          RoleName: roleName,
                          PolicyName: policyName
                      }));
                  }

                  // Delete the role
                  await client.send(new DeleteRoleCommand({ RoleName: roleName }));
                  return true;
              } catch (error) {
                  if (error.name === 'NoSuchEntityException') {
                      console.log(`Role ${roleName} does not exist or was already deleted`);
                      return true;
                  }
                  throw error;
              }
          }

          async function deleteIAMPolicy() {
              const client = new IAMClient({});
              let marker;

              try {
                  do {
                      const policiesResponse = await client.send(new ListPoliciesCommand({
                          Scope: 'Local',
                          PathPrefix: '/',
                          Marker: marker
                      }));

                      for (const policy of policiesResponse.Policies || []) {
                          if (policy.PolicyName.startsWith('firefly-readonly-InvokeFireflyEventBusPolicy')) {
                              // Get policy entities
                              const entities = await client.send(new ListEntitiesForPolicyCommand({
                                  PolicyArn: policy.Arn
                              }));

                              // Detach from roles
                              for (const role of entities.PolicyRoles || []) {
                                  await client.send(new DetachRolePolicyCommand({
                                      PolicyArn: policy.Arn,
                                      RoleName: role.RoleName
                                  }));
                              }

                              // Delete non-default versions
                              const versions = await client.send(new ListPolicyVersionsCommand({
                                  PolicyArn: policy.Arn
                              }));

                              for (const version of versions.Versions || []) {
                                  if (!version.IsDefaultVersion) {
                                      await client.send(new DeletePolicyVersionCommand({
                                          PolicyArn: policy.Arn,
                                          VersionId: version.VersionId
                                      }));
                                  }
                              }

                              // Delete the policy
                              await client.send(new DeletePolicyCommand({
                                  PolicyArn: policy.Arn
                              }));
                          }
                      }

                      marker = policiesResponse.Marker;
                  } while (marker);

                  return true;
              } catch (error) {
                  console.error('Error deleting IAM policy:', error);
                  throw error;
              }
          }

          exports.handler = async (event, context) => {
              console.log('Event:', JSON.stringify(event, null, 2));
              
              if (event.RequestType) {
                  const physicalResourceId = event.PhysicalResourceId || `cleanup-${Date.now()}`;
                  
                  try {
                      if (event.RequestType === 'Delete') {
                          await sendCloudFormationResponse(event, context, 'SUCCESS', {}, physicalResourceId);
                          return;
                      }

                      if (event.RequestType === 'Create' || event.RequestType === 'Update') {
                          const regions = await getEnabledRegions();
                          const deletionResults = await Promise.all(
                              regions.map(region => deleteEventRules(region))
                          );

                          await deleteIAMRole();
                          await deleteIAMPolicy();

                          const allDeletedRules = deletionResults.flat();
                          const summary = {
                              totalRulesDeleted: allDeletedRules.length,
                              rulesByRegion: allDeletedRules.reduce((acc, rule) => {
                                  acc[rule.region] = (acc[rule.region] || 0) + 1;
                                  return acc;
                              }, {})
                          };

                          await sendCloudFormationResponse(event, context, 'SUCCESS', summary, physicalResourceId);
                          return;
                      }
                  } catch (error) {
                      console.error('Error:', error);
                      await sendCloudFormationResponse(event, context, 'FAILED', {
                          Error: error.message
                      }, physicalResourceId);
                      throw error;
                  }
              }

              // Direct invocation
              const regions = await getEnabledRegions();
              const deletionResults = await Promise.all(
                  regions.map(region => deleteEventRules(region))
              );

              await deleteIAMRole();
              await deleteIAMPolicy();

              return {
                  statusCode: 200,
                  body: {
                      totalRulesDeleted: deletionResults.flat().length,
                      deletedRules: deletionResults.flat()
                  }
              };
          };