"""Integration tests for native Bash scripts with fake AWS; no network/resources."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP_ARN = 'arn:aws:secretsmanager:us-west-2:123456789012:secret:contenedores/api/mysql-MOCK01'
ADMIN_ARN = 'arn:aws:secretsmanager:us-west-2:123456789012:secret:rds-master-MOCK02'

FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
tool=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if tool=='aws' and args==['--version']:
    print('aws-cli/2.40.0'); sys.exit()
stdin=sys.stdin.read() if tool=='kubectl' and '-f' in args and args[args.index('-f')+1]=='-' else ''
event={'tool':tool,'args':args}
if stdin: event['stdin']=stdin
if '--cli-input-json' in args:
    event['payload']=json.loads(pathlib.Path(args[args.index('--cli-input-json')+1].removeprefix('file://')).read_text())
with open(os.environ['MOCK_LOG'],'a') as stream: stream.write(json.dumps(event)+'\n')
if tool=='terraform':
    outputs={'vpc_id':'vpc-mock','mysql_host':'mysql.mock.internal','mysql_database':'contenedores',
      'mysql_admin_secret_arn':os.environ['MOCK_ADMIN_ARN'],'region':'us-west-2',
      'app_private_subnet_ids':['subnet-private-a','subnet-private-b'],
      'public_subnet_ids':['subnet-public-a','subnet-public-b'],
      'ecs_security_group_id':'sg-ecs','eks_security_group_id':'sg-eks'}
    print(json.dumps({key:{'value':value} for key,value in outputs.items()})); sys.exit()
if tool=='kubectl':
    if args==['config','current-context']: print(os.environ.get('MOCK_CONTEXT','contenedores-eks'))
    elif 'set' in args and 'image' in args:
        image=next(value.split('=',1)[1] for value in args if value.startswith('api='))
        print(json.dumps({'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':'productos-api','namespace':'contenedores'},
          'spec':{'template':{'spec':{'containers':[{'name':'api','image':image}]}}}}))
    else: print('ok')
    sys.exit()
if tool=='docker':
    if args and args[0]=='info': print('linux')
    sys.exit()
if tool=='sleep': sys.exit()
services={'sts','secretsmanager','ecr','logs','iam','ecs','elbv2','ec2','eks','rds'}
position=next(i for i,value in enumerate(args) if value in services)
service,operation=args[position:position+2]
responses={
 ('sts','get-caller-identity'):{'Account':os.environ.get('MOCK_ACCOUNT','123456789012'),
   'Arn':'arn:aws:iam::123456789012:user/student'},
 ('rds','describe-db-engine-versions'):{'DBEngineVersions':[{'EngineVersion':'8.4.99','Status':'available'}]},
 ('rds','describe-orderable-db-instance-options'):{'OrderableDBInstanceOptions':[{}]},
 ('secretsmanager','list-secrets'):{'SecretList':[]},
 ('secretsmanager','get-random-password'):{'RandomPassword':'MOCK_PASSWORD_ONLY'},
 ('secretsmanager','create-secret'):{'ARN':os.environ['MOCK_APP_ARN'],'Name':'contenedores/api/mysql'},
 ('secretsmanager','describe-secret'):{'ARN':os.environ['MOCK_APP_ARN']},
 ('secretsmanager','get-secret-value'):{'SecretString':json.dumps({'username':'appuser','password':'MOCK_PASSWORD_ONLY'})},
 ('ecr','describe-repositories'):{'repositories':[]},
 ('logs','describe-log-groups'):{'logGroups':[]},
 ('iam','list-roles'):{'Roles':[]},
 ('ecs','register-task-definition'):{'taskDefinition':{'taskDefinitionArn':'arn:mock:task:1'}},
 ('ecs','create-cluster'):{'cluster':{'clusterArn':'arn:mock:cluster'}},
 ('ecs','run-task'):{'tasks':[{'taskArn':'arn:mock:bootstrap'}],'failures':[]},
 ('ecs','describe-tasks'):{'tasks':[{'containers':[{'exitCode':int(os.environ.get('MOCK_EXIT','0'))}]}]},
 ('ecs','describe-services'):{'services':[],'failures':[]},
 ('ec2','create-security-group'):{'GroupId':'sg-alb'},
 ('elbv2','create-load-balancer'):{'LoadBalancers':[{'LoadBalancerArn':'arn:mock:alb','DNSName':'alb.mock.internal'}]},
 ('elbv2','create-target-group'):{'TargetGroups':[{'TargetGroupArn':'arn:mock:tg'}]},
 ('eks','create-cluster'):{'cluster':{'name':'contenedores-eks','status':'CREATING','version':'mock'}},
 ('eks','describe-cluster'):{'cluster':{'name':'contenedores-eks','status':'ACTIVE',
     'resourcesVpcConfig':{'clusterSecurityGroupId':'sg-real-auto'}}}}
if operation=='get-login-password': print('MOCK_TOKEN')
else: print(json.dumps(responses.get((service,operation),{})))
'''


@unittest.skipUnless(sys.platform.startswith('linux') and shutil.which('bash') and shutil.which('jq'),
                     'Requires Linux, Bash and jq; see docs/LINUX.md for Docker command')
class NativeBashTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lab-bash-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for relative in ('scripts', 'backend/scripts', 'backend/ecs/generated', 'backend/k8s',
                         'policy', 'policy/02-ecs', 'policy/03-eks', 'eks', 'infra'):
            dest = self.root / relative
            dest.mkdir(parents=True, exist_ok=True)
            for source in (ROOT / relative).iterdir():
                if source.is_file() and source.suffix in ('.sh', '.json', '.yaml'):
                    shutil.copyfile(source, dest / source.name)
        (self.root / 'scripts/lib').mkdir()
        shutil.copyfile(ROOT / 'scripts/lib/common.sh', self.root / 'scripts/lib/common.sh')
        bindir = self.root / 'fake-bin'
        bindir.mkdir()
        for tool in ('aws', 'terraform', 'kubectl', 'docker', 'sleep'):
            path = bindir / tool
            path.write_text(FAKE)
            path.chmod(0o755)
        self.log = self.root / 'calls.jsonl'
        (self.root/'lab.config.json').write_text(json.dumps({'account_id':'123456789012','profile':'alumno',
            'region':'us-west-2','operator_arn':'arn:aws:iam::123456789012:user/student','mysql_engine_version':''}))
        self.env = {**os.environ, 'PATH': str(bindir) + ':' + os.environ['PATH'],
                    'MOCK_LOG': str(self.log), 'MOCK_APP_ARN': APP_ARN, 'MOCK_ADMIN_ARN': ADMIN_ARN}

    def execute(self, script, *args, success=True):
        result = subprocess.run(['bash', str(self.root / script), *args], cwd=self.root,
                                env=self.env, text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def generate(self):
        self.execute('backend/scripts/Prepare-Ecs.sh', '--image-uri', 'registry/api:v3',
                     '--app-secret-arn', APP_ARN, '--version', 'v3')

    def test_generator_creates_real_tasks_and_limits_runtime_secret(self):
        self.generate()
        folder = self.root / 'backend/ecs/generated'
        runtime = json.loads((folder / 'runtime-task.json').read_text())
        bootstrap = json.loads((folder / 'bootstrap-task.json').read_text())
        self.assertEqual(runtime['containerDefinitions'][0]['image'], 'registry/api:v3')
        self.assertEqual(len(runtime['containerDefinitions'][0]['secrets']), 2)
        self.assertEqual(len(bootstrap['containerDefinitions'][0]['secrets']), 4)
        self.assertIn(ADMIN_ARN, json.dumps(bootstrap))
        self.assertNotIn(ADMIN_ARN, json.dumps(runtime))
        self.assertIn('arn:aws:iam::123456789012:', runtime['executionRoleArn'])
        self.assertNotIn('299147769461', json.dumps(runtime))
        complete=json.loads((self.root/'policy/02-ecs/runtime-execution-policy.json').read_text())
        self.assertNotIn('299147769461',json.dumps(complete))
        self.assertEqual(json.loads((folder / 'network.json').read_text())['awsvpcConfiguration']['assignPublicIp'], 'DISABLED')
        for name in ('bootstrap-task', 'runtime-task', 'bootstrap-secrets-policy', 'runtime-secrets-policy', 'network', 'trust'):
            self.assertNotRegex((folder / (name + '.json')).read_text(), r'__[A-Z0-9_]+__')
        self.assertFalse(any(call['tool'] == 'aws' for call in self.calls()))

    def test_ecs_all_creation_and_update_stages_without_real_aws(self):
        for step in ('secret', 'image', 'prepare', 'bootstrap', 'service', 'update', 'status'):
            args = ['--cidr', '203.0.113.10/32'] if step == 'service' else []
            result = self.execute('scripts/ecs.sh', step, *args)
            self.assertNotIn('MOCK_PASSWORD_ONLY', result.stdout + result.stderr)
        operations = [call['args'] for call in self.calls() if call['tool'] == 'aws']
        self.assertTrue(any('create-service' in args for args in operations))
        self.assertTrue(any('register-task-definition' in args for args in operations))
        self.assertTrue(any('tasks-stopped' in args for args in operations))
        self.assertTrue(all('MOCK_PASSWORD_ONLY' not in ' '.join(call['args']) for call in self.calls()))
        secret_request = next(call for call in self.calls() if 'create-secret' in call['args'])
        request_path = secret_request['args'][secret_request['args'].index('--cli-input-json') + 1].removeprefix('file://')
        self.assertFalse(Path(request_path).exists(), 'El temporal de secretos debe eliminarse al salir')
        self.assertFalse(any(call['tool'] in ('python', 'pwsh', 'powershell') for call in self.calls()))

    def test_eks_create_deploy_and_current_subnets_for_alb(self):
        for step in ('create', 'connect', 'deploy', 'publish-alb', 'status'):
            args = ['--cidr', '203.0.113.10/32'] if step in ('create', 'publish-alb') else ['--version', 'v3']
            result = self.execute('scripts/eks.sh', step, *args)
            self.assertNotIn('MOCK_PASSWORD_ONLY', result.stdout + result.stderr)
        calls = self.calls()
        cluster = next(call['payload'] for call in calls if 'create-cluster' in call['args'] and 'eks' in call['args'])
        self.assertFalse(cluster['accessConfig']['bootstrapClusterCreatorAdminPermissions'])
        self.assertEqual(cluster['resourcesVpcConfig']['subnetIds'], ['subnet-private-a', 'subnet-private-b'])
        self.assertIn('sg-real-auto', (self.root / 'infra/eks-auto.auto.tfvars').read_text())
        inputs = [json.loads(call['stdin']) for call in calls if call.get('stdin')]
        secret = next(item for item in inputs if item['kind'] == 'Secret')
        self.assertIn('DB_PASSWORD', secret['data'])
        ingress = next(item for item in inputs if item['kind'] == 'List')['items'][0]
        self.assertEqual(ingress['spec']['subnets']['ids'], ['subnet-public-a', 'subnet-public-b'])
        self.assertEqual(ingress['spec']['inboundCIDRs'], ['203.0.113.10/32'])
        create_access = next(call for call in calls if 'create-access-entry' in call['args'])
        self.assertIn('arn:aws:iam::123456789012:user/student',create_access['args'])
        self.assertTrue(all('luisvaldivia' not in ' '.join(call['args']) for call in calls))

    def test_wrong_account_stops_before_create(self):
        self.env['MOCK_ACCOUNT'] = '000000000000'
        self.execute('scripts/ecs.sh', 'secret', success=False)
        self.assertEqual(len(self.calls()), 1)

    def test_wrong_context_never_reads_secret(self):
        self.env['MOCK_CONTEXT'] = 'another-cluster'
        self.execute('backend/scripts/Sync-EksSecret.sh', '--app-secret-arn', APP_ARN, success=False)
        self.assertFalse(any(call['tool'] == 'aws' for call in self.calls()))

    def test_bad_cidr_stops_before_aws(self):
        self.execute('scripts/eks.sh', 'create', '--cidr', '999.1.1.1/32', success=False)
        self.assertFalse(self.calls())

    def test_bootstrap_nonzero_exit_is_not_success(self):
        self.generate()
        self.env['MOCK_EXIT'] = '1'
        result = self.execute('scripts/ecs.sh', 'bootstrap', success=False)
        self.assertIn('Bootstrap fallo', result.stderr)

    def test_setup_discovers_version_and_writes_only_local_variables(self):
        self.execute('scripts/setup.sh')
        variables=json.loads((self.root/'infra/lab.auto.tfvars.json').read_text())
        self.assertEqual(variables,{'account_id':'123456789012','profile':'alumno',
            'region':'us-west-2','mysql_engine_version':'8.4.99'})
        aws_calls=[call['args'] for call in self.calls() if call['tool']=='aws']
        self.assertFalse(any(any(arg.startswith(('create-','delete-')) for arg in args) for args in aws_calls))


if __name__ == '__main__':
    unittest.main()
