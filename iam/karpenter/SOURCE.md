The five policy templates are the corresponding PolicyDocument blocks from
[the official v1.13.0 CloudFormation prerequisites](https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.13.0/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml).
Only substitution names changed (AWS partition/region/account, cluster, dedicated
node role ARN and queue ARN). No ZonalShift policy is attached because that feature
is disabled. Regional describe, pricing and profile-list permissions necessarily
use `*`; lifecycle writes require cluster/NodePool tags, profile writes require
cluster/region/EC2NodeClass tags, and PassRole names only the dedicated worker role.
The queue producer policy is narrower than the example: only our EventBridge rules
in this account can send. Worker policies omit optional SSM access and retain
worker, CNI and ECR PullOnly. This does not change existing node or LBC roles.
