"""Offline checks using actual rendered pinned CRDs/controller, never a cluster."""
import copy
import json
import pathlib
import re
import sys

import hcl2
import jsonschema
import yaml

root = pathlib.Path(__file__).resolve().parents[1]
rendered = pathlib.Path(sys.argv[1])
load = lambda p: [d for d in yaml.safe_load_all(p.read_text()) if d]
crds = load(rendered / 'crds.yaml')
resources = load(rendered / 'capacity.yaml')
controller = load(rendered / 'controller.yaml')
schemas = {d['spec']['names']['kind']: next(v['schema']['openAPIV3Schema'] for v in d['spec']['versions'] if v['name'] == 'v1') for d in crds if d['kind'] == 'CustomResourceDefinition' and any(v['name'] == 'v1' for v in d['spec']['versions'])}
# Kubernetes int-or-string extension is not part of standard JSON Schema.
def normalize(schema):
    if isinstance(schema, dict):
        if schema.get('x-kubernetes-int-or-string'):
            schema.pop('type', None)
            schema['anyOf'] = [{'type': 'integer'}, {'type': 'string'}]
        for value in schema.values():
            normalize(value)
    elif isinstance(schema, list):
        for value in schema:
            normalize(value)

for obj in resources:
    schema = copy.deepcopy(schemas[obj['kind']])
    normalize(schema)
    jsonschema.Draft7Validator(schema).validate(obj)
    # Catch unknown fields JSON Schema otherwise permits (Kubernetes prunes them).
    def known(value, s):
        if isinstance(value, dict) and 'properties' in s:
            for k, v in value.items():
                assert k in s['properties'] or 'additionalProperties' in s, (obj['kind'], k)
                if k in s['properties']:
                    known(v, s['properties'][k])
        elif isinstance(value, list) and 'items' in s:
            for v in value:
                known(v, s['items'])
    known(obj['spec'], schema['properties']['spec'])

pool = next(x for x in resources if x['kind'] == 'NodePool')['spec']
nodeclass = next(x for x in resources if x['kind'] == 'EC2NodeClass')['spec']
assert pool['limits'] == {'cpu': '16', 'memory': '64Gi'}
assert pool['disruption'] == {'consolidationPolicy': 'WhenEmptyOrUnderutilized', 'consolidateAfter': '5m', 'budgets': [{'nodes': '1'}]}
req = {r['key']: r['values'] for r in pool['template']['spec']['requirements']}
assert req['karpenter.sh/capacity-type'] == ['spot']
assert req['kubernetes.io/arch'] == ['amd64']
assert req['kubernetes.io/os'] == ['linux']
assert len(req['topology.kubernetes.io/zone']) == 2
assert len(req['karpenter.k8s.aws/instance-family']) >= 2
assert all(re.fullmatch(r'[mcr][5-6][ai]?', f) for f in req['karpenter.k8s.aws/instance-family'])
assert nodeclass['amiSelectorTerms'] == [{'alias': 'al2023@v20261003'}]
assert all(set(s) == {'id'} for s in nodeclass['subnetSelectorTerms'])
assert nodeclass['securityGroupSelectorTerms'] == [{'id': 'sg-cluster'}]
assert nodeclass['associatePublicIPAddress'] is False
assert nodeclass['metadataOptions']['httpTokens'] == 'required'
dep = next(x for x in controller if x['kind'] == 'Deployment')['spec']
assert dep['replicas'] == 1
assert dep['strategy']['rollingUpdate'] == {'maxSurge': 0, 'maxUnavailable': 1}
pod = dep['template']['spec']
assert pod['nodeSelector']['eks.amazonaws.com/nodegroup'] == 'general'
assert pod['serviceAccountName'] == 'karpenter'
container = pod['containers'][0]
assert '1.13.0@sha256:' in container['image']
assert container['resources']['requests'] == {'cpu': '100m', 'memory': '256Mi'}
env = {x['name']: x.get('value') for x in container['env']}
assert env['INTERRUPTION_QUEUE'] == 'dev-eks-karpenter'
assert env['AWS_REGION'] == 'eu-west-1'
substitutions = dict(partition='aws', region='eu-west-1', account_id='123456789012', cluster_name='dev-eks', node_role_arn='arn:aws:iam::123456789012:role/dev-eks-karpenter-nodes', queue_arn='arn:aws:sqs:eu-west-1:123456789012:dev-eks-karpenter')
statements = []
class CloudFormationLoader(yaml.SafeLoader):
    pass
CloudFormationLoader.add_constructor('!Sub', lambda loader, node: loader.construct_scalar(node))
CloudFormationLoader.add_constructor('!Ref', lambda loader, node: loader.construct_scalar(node))
CloudFormationLoader.add_constructor('!GetAtt', lambda loader, node: loader.construct_scalar(node))
official = yaml.load((rendered / 'official-policy.yaml').read_text(), Loader=CloudFormationLoader)['Resources']
official_substitutions = {
    'AWS::Partition': substitutions['partition'], 'AWS::Region': substitutions['region'],
    'AWS::AccountId': substitutions['account_id'], 'ClusterName': substitutions['cluster_name'],
    'KarpenterNodeRole.Arn': substitutions['node_role_arn'],
    'KarpenterInterruptionQueue.Arn': substitutions['queue_arn'],
}
for p in (root / 'iam/karpenter').glob('*.json.tftpl'):
    s = p.read_text()
    for k, v in substitutions.items():
        s = s.replace('${' + k + '}', v)
    assert '${' not in s
    policy = json.loads(s)
    source = official[p.name.removesuffix('.json.tftpl')]['Properties']['PolicyDocument']
    for k, v in official_substitutions.items():
        source = source.replace('${' + k + '}', v)
    assert policy == json.loads(source), f'{p.name}: differs from official v1.13.0 policy'
    assert policy['Version'] == '2012-10-17'
    statements.extend(policy['Statement'])
by_sid = {s['Sid']: s for s in statements}
assert by_sid['AllowPassingInstanceRole']['Resource'] == substitutions['node_role_arn']
assert 'iam:PassedToService' in by_sid['AllowPassingInstanceRole']['Condition']['StringEquals']
assert by_sid['AllowInterruptionQueueActions']['Resource'] == substitutions['queue_arn']
for sid in ['AllowScopedDeletion', 'AllowScopedEC2InstanceActionsWithTags', 'AllowScopedInstanceProfileCreationActions', 'AllowScopedInstanceProfileActions']:
    assert 'dev-eks' in json.dumps(by_sid[sid]['Condition'])
assert all('*' not in ([s['Action']] if isinstance(s['Action'], str) else s['Action']) for s in statements)
# Existing infrastructure must remain semantically identical to the baseline.
import subprocess
for filename in ['eks.tf', 'eks_access_entries.tf', 'iam.tf', 'locals.tf', 'main.tf', 'network-private.tf', 'network-public.tf', 'aws-lbc.tf', 'external-dns.tf', 'domain.tf', 'providers.tf']:
    baseline = subprocess.check_output(['git', 'show', '5d2cf29:' + filename], cwd=root, text=True)
    assert hcl2.loads(baseline) == hcl2.loads((root / filename).read_text()), filename
baseline = subprocess.check_output(['git', 'show', '5d2cf29:manifests/it-tools/it-tools.yaml'], cwd=root)
assert baseline == (root / 'manifests/it-tools/it-tools.yaml').read_bytes()
smoke = load(root / 'manifests/karpenter/smoke.yaml')[1]['spec']
assert smoke['replicas'] == 0
assert smoke['template']['spec']['nodeSelector'] == {'karpenter.sh/nodepool': 'lab'}
assert smoke['template']['spec']['containers'][0]['resources']['requests']['cpu'] == '1'
print('PASS: pinned CRD schemas, controller placement/resources, bounded Spot capacity, IAM scope, smoke requests, existing infrastructure preservation')

config = hcl2.loads((root / 'karpenter.tf').read_text())
blocks = {kind.strip('"') + '.' + name.strip('"'): value for block in config['resource'] for kind, entries in block.items() for name, value in entries.items()}
assert blocks['aws_eks_access_entry.karpenter_nodes']['type'].strip('"') == 'EC2_LINUX'
assert blocks['helm_release.karpenter']['skip_crds'] is True
assert blocks['helm_release.karpenter_crd']['version'] == '${local.karpenter_version}'
capacity = blocks['helm_release.karpenter_capacity']
assert capacity['count'] == '${var.karpenter_capacity_enabled ? 1 : 0}'
assert 'cluster_security_group_id' in capacity['values'][0]
assert 'aws_subnet.private' in capacity['values'][0]
assert 'manifestRevision' in capacity['values'][0]
assert 'aws_eks_pod_identity_association.karpenter' in str(blocks['helm_release.karpenter']['depends_on'])
assert 'aws_eks_access_entry.karpenter_nodes' in str(blocks['helm_release.karpenter']['depends_on'])
assert 'aws:SourceArn' in blocks['aws_sqs_queue_policy.karpenter']['policy']
print('PASS: Terraform identity/access, discovery wiring, release dependencies and local chart upgrade tracking')
