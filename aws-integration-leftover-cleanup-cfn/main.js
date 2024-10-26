const { EC2Client, DescribeRegionsCommand } = require("@aws-sdk/client-ec2");
          const { CloudWatchEventsClient, ListRulesCommand, ListTargetsByRuleCommand, RemoveTargetsCommand, DeleteRuleCommand } = require("@aws-sdk/client-cloudwatch-events");
          const { IAMClient, ListAttachedRolePoliciesCommand, DetachRolePolicyCommand, ListRolePoliciesCommand, DeleteRolePolicyCommand, DeleteRoleCommand, ListPoliciesCommand, ListEntitiesForPolicyCommand, DetachUserPolicyCommand, DetachGroupPolicyCommand, ListPolicyVersionsCommand, DeletePolicyVersionCommand, DeletePolicyCommand } = require("@aws-sdk/client-iam");

          async function getEnabledRegions() {
              const client = new EC2Client({ region: 'us-east-1' });
              const command = new DescribeRegionsCommand({ AllRegions: false });
              const response = await client.send(command);
              return response.Regions.map(region => region.RegionName);
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
                              console.log(`Successfully deleted rule ${rule.Name} in ${region}`);
                          } catch (error) {
                              console.error(`Error deleting rule ${rule.Name} in ${region}:`, error);
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
                  const listPoliciesCommand = new ListAttachedRolePoliciesCommand({ RoleName: roleName });
                  const attachedPolicies = await client.send(listPoliciesCommand);
                  
                  for (const policy of attachedPolicies.AttachedPolicies) {
                      console.log(`Detaching policy ${policy.PolicyArn} from role ${roleName}`);
                      const detachCommand = new DetachRolePolicyCommand({
                          RoleName: roleName,
                          PolicyArn: policy.PolicyArn
                      });
                      await client.send(detachCommand);
                  }

                  const listInlinePoliciesCommand = new ListRolePoliciesCommand({ RoleName: roleName });
                  const inlinePolicies = await client.send(listInlinePoliciesCommand);
                  
                  for (const policyName of inlinePolicies.PolicyNames) {
                      console.log(`Deleting inline policy ${policyName} from role ${roleName}`);
                      const deleteInlinePolicyCommand = new DeleteRolePolicyCommand({
                          RoleName: roleName,
                          PolicyName: policyName
                      });
                      await client.send(deleteInlinePolicyCommand);
                  }

                  const deleteRoleCommand = new DeleteRoleCommand({ RoleName: roleName });
                  await client.send(deleteRoleCommand);
                  console.log(`Successfully deleted IAM role: ${roleName}`);
                  return true;
              } catch (error) {
                  if (error.name === 'NoSuchEntityException') {
                      console.log(`IAM role ${roleName} does not exist or was already deleted`);
                      return true;
                  }
                  console.error('Error deleting IAM role:', error);
                  return false;
              }
          }

          async function deleteIAMPolicy() {
              const client = new IAMClient({});
              let marker;
              
              try {
                  do {
                      const listPoliciesCommand = new ListPoliciesCommand({
                          Scope: 'Local',
                          PathPrefix: '/',
                          Marker: marker
                      });
                      const policies = await client.send(listPoliciesCommand);

                      for (const policy of policies.Policies) {
                          if (policy.PolicyName.startsWith('firefly-readonly-InvokeFireflyEventBusPolicy')) {
                              console.log(`Deleting policy: ${policy.PolicyName}`);
                              
                              const listEntitiesCommand = new ListEntitiesForPolicyCommand({
                                  PolicyArn: policy.Arn
                              });
                              const entities = await client.send(listEntitiesCommand);

                              for (const role of entities.PolicyRoles) {
                                  const detachCommand = new DetachRolePolicyCommand({
                                      RoleName: role.RoleName,
                                      PolicyArn: policy.Arn
                                  });
                                  await client.send(detachCommand);
                              }

                              for (const user of entities.PolicyUsers) {
                                  const detachCommand = new DetachUserPolicyCommand({
                                      UserName: user.UserName,
                                      PolicyArn: policy.Arn
                                  });
                                  await client.send(detachCommand);
                              }

                              for (const group of entities.PolicyGroups) {
                                  const detachCommand = new DetachGroupPolicyCommand({
                                      GroupName: group.GroupName,
                                      PolicyArn: policy.Arn
                                  });
                                  await client.send(detachCommand);
                              }

                              const versionsCommand = new ListPolicyVersionsCommand({
                                  PolicyArn: policy.Arn
                              });
                              const versions = await client.send(versionsCommand);

                              for (const version of versions.Versions) {
                                  if (!version.IsDefaultVersion) {
                                      const deleteVersionCommand = new DeletePolicyVersionCommand({
                                          PolicyArn: policy.Arn,
                                          VersionId: version.VersionId
                                      });
                                      await client.send(deleteVersionCommand);
                                  }
                              }

                              const deletePolicyCommand = new DeletePolicyCommand({
                                  PolicyArn: policy.Arn
                              });
                              await client.send(deletePolicyCommand);
                          }
                      }

                      marker = policies.Marker;
                  } while (marker);

                  console.log('Successfully completed IAM policy cleanup');
                  return true;
              } catch (error) {
                  console.error('Error deleting IAM policy:', error);
                  return false;
              }
          }

          exports.handler = async (event, context) => {
              try {
                  const regions = await getEnabledRegions();
                  console.log('Processing regions:', regions);

                  const deletionResults = await Promise.all(
                      regions.map(region => deleteEventRules(region))
                  );

                  console.log('\nCleaning up IAM resources...');
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

                  console.log('Execution Summary:', JSON.stringify(summary, null, 2));
                  return {
                      statusCode: 200,
                      body: summary
                  };

              } catch (error) {
                  console.error('Error in Lambda execution:', error);
                  throw error;
              }
          };