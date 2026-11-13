"""Checks de seguridad y orquestacion, sin crear recursos AWS."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import lab


class LabTests(unittest.TestCase):
    def setUp(self):
        for name, value in {'ACCOUNT':'123456789012', 'REGION':'us-west-2',
                            'PROFILE':'alumno', 'OPERATOR':'arn:aws:iam::123456789012:user/student'}.items():
            patcher = patch.object(lab, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_service_models_use_their_own_field_casing(self):
        self.assertEqual(lab.request_payload('ecs', flags={'TaskDefinition': 'task'}),
                         {'taskDefinition': 'task'})
        self.assertEqual(lab.request_payload('eks', flags={'AccessConfig': {'authenticationMode': 'API'}}),
                         {'accessConfig': {'authenticationMode': 'API'}})
        self.assertEqual(lab.request_payload('ec2', flags={'GroupName': 'test'}), {'GroupName': 'test'})

    def test_json_transport_keeps_password_out_of_arguments_and_deletes_file(self):
        paths = []

        def execute(*args, **kwargs):
            self.assertNotIn('very-private-password', ' '.join(args))
            source = args[args.index('--cli-input-json') + 1]
            path = Path(source.removeprefix('file://'))
            paths.append(path)
            self.assertEqual(json.loads(path.read_text())['SecretString'], 'very-private-password')
            return '{"ARN":"example"}'

        with patch.object(lab, 'run', side_effect=execute):
            self.assertEqual(lab.aws('secretsmanager', 'create-secret',
                                    SecretString='very-private-password')['ARN'], 'example')
        self.assertTrue(paths)
        self.assertFalse(paths[0].exists())

    def test_iam_policy_is_a_json_string_in_cli_request(self):
        def execute(*args, **kwargs):
            path = Path(args[-1].removeprefix('file://'))
            payload = json.loads(path.read_text())
            self.assertIsInstance(payload['AssumeRolePolicyDocument'], str)
            self.assertEqual(json.loads(payload['AssumeRolePolicyDocument'])['Version'], '2012-10-17')
            return '{}'

        with patch.object(lab, 'run', side_effect=execute):
            lab.aws('iam', 'create-role', RoleName='test',
                    AssumeRolePolicyDocument={'Version': '2012-10-17'})

    def test_secret_existing_is_not_rotated(self):
        with patch.object(lab, 'aws', return_value={
            'SecretList': [{'Name': 'contenedores/api/mysql'}]}) as api:
            with contextlib.redirect_stdout(io.StringIO()):
                lab.secret()
        self.assertEqual(api.call_count, 1)

    def test_bootstrap_run_failure_stops_before_wait(self):
        with patch.object(lab, 'load', return_value={}), \
                patch.object(lab, 'aws', return_value={'failures': [{'reason': 'NO_CAPACITY'}]}), \
                patch.object(lab, 'run') as execute:
            with self.assertRaisesRegex(RuntimeError, 'iniciar bootstrap'):
                lab.bootstrap()
        execute.assert_not_called()

    def test_bootstrap_nonzero_exit_is_failure(self):
        responses = [{'tasks': [{'taskArn': 'task-1'}]},
                     {'tasks': [{'containers': [{'exitCode': 1}]}]}]
        with patch.object(lab, 'load', return_value={}), \
                patch.object(lab, 'aws', side_effect=responses), patch.object(lab, 'run'):
            with self.assertRaisesRegex(RuntimeError, 'Bootstrap fallo'):
                lab.bootstrap()

    def test_invalid_cidr_has_no_side_effects(self):
        with patch.object(lab, 'aws') as api, patch.object(lab, 'infra') as outputs:
            with self.assertRaises(ValueError):
                lab.ecs('192.168.1.1/24')
        api.assert_not_called()
        outputs.assert_not_called()

    def test_wrong_account_stops_before_provisioning(self):
        with patch('sys.argv', ['lab.py', 'secret']), \
                patch.object(lab, 'settings', return_value={}), \
                patch.object(lab, 'aws', return_value={'Account': '000000000000'}), \
                patch.object(lab, 'secret') as create:
            with self.assertRaisesRegex(RuntimeError, 'Cuenta AWS'):
                lab.main()
        create.assert_not_called()

    def test_auto_mode_uses_current_sg_and_private_network(self):
        calls = []

        def api(service, operation, payload=None, **kwargs):
            calls.append((service, operation, payload, kwargs))
            if operation == 'describe-cluster':
                return {'cluster': {'resourcesVpcConfig': {'clusterSecurityGroupId': 'sg-current'}}}
            return {}

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'infra').mkdir()
            with patch.object(lab, 'ROOT', root), patch.object(lab, 'role'), \
                    patch.object(lab, 'load', return_value={}), patch.object(lab, 'run'), \
                    patch.object(lab.time, 'sleep'), patch.object(lab, 'aws', side_effect=api), \
                    patch.object(lab, 'infra', return_value={
                        'app_private_subnet_ids': ['subnet-private-a', 'subnet-private-b'],
                        'eks_security_group_id': 'sg-prepared'}):
                with contextlib.redirect_stdout(io.StringIO()):
                    lab.eks('203.0.113.10/32')
            created = next(call[3] for call in calls if call[1] == 'create-cluster')
            self.assertTrue(created['ComputeConfig']['enabled'])
            self.assertFalse(created['AccessConfig']['bootstrapClusterCreatorAdminPermissions'])
            self.assertEqual(created['ResourcesVpcConfig']['publicAccessCidrs'], ['203.0.113.10/32'])
            self.assertTrue(created['ResourcesVpcConfig']['endpointPrivateAccess'])
            self.assertEqual(created['ResourcesVpcConfig']['subnetIds'], ['subnet-private-a', 'subnet-private-b'])
            self.assertIn('sg-current', (root / 'infra/eks-auto.auto.tfvars').read_text())

    def test_student_settings_read_own_account_profile_and_region(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'lab.config.json').write_text(json.dumps({
                'account_id':'123456789012','profile':'mi-perfil','region':'eu-west-1',
                'operator_arn':'arn:aws:iam::123456789012:role/student'}))
            with patch.object(lab, 'ROOT', root):
                lab.settings()
                self.assertEqual((lab.ACCOUNT,lab.REGION,lab.PROFILE), ('123456789012','eu-west-1','mi-perfil'))

    def test_missing_account_never_contacts_aws(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {}, clear=True), \
                patch.object(lab, 'ROOT', Path(folder)), patch.object(lab, 'aws') as api:
            with self.assertRaisesRegex(RuntimeError, 'cuenta AWS propia'):
                lab.settings()
        api.assert_not_called()

    def test_infra_outputs_from_another_account_are_rejected(self):
        raw = json.dumps({'region':{'value':'us-west-2'}, 'mysql_admin_secret_arn':{'value':
            'arn:aws:secretsmanager:us-west-2:999999999999:secret:other'}})
        with patch.object(lab, 'run', return_value=raw):
            with self.assertRaisesRegex(RuntimeError, 'otra cuenta/region'):
                lab.infra()

    def test_setup_only_reads_aws_and_writes_student_local_files(self):
        def api(service, operation, **kwargs):
            if operation == 'get-caller-identity':
                return {'Account':'123456789012','Arn':'arn:aws:iam::123456789012:user/student'}
            if operation == 'describe-db-engine-versions':
                return {'DBEngineVersions':[{'EngineVersion':'8.4.99','Status':'available'}]}
            if operation == 'describe-orderable-db-instance-options':
                return {'OrderableDBInstanceOptions':[{}]}
            self.fail('Operacion no esperada: '+operation)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'infra').mkdir()
            (root/'lab.config.json').write_text(json.dumps({'account_id':'123456789012',
                'profile':'alumno','region':'us-west-2','operator_arn':''}))
            with patch.object(lab,'ROOT',root), patch.object(lab.shutil,'which',return_value='/bin/tool'), \
                    patch.object(lab,'run',side_effect=lambda *args, **kwargs: 'aws-cli/2.40.0' if args[:2]==('aws','--version') else 'linux'), \
                    patch.object(lab,'aws',side_effect=api), \
                    contextlib.redirect_stdout(io.StringIO()):
                lab.configure()
            variables=json.loads((root/'infra/lab.auto.tfvars.json').read_text())
            self.assertEqual(variables['account_id'],'123456789012')
            self.assertEqual(variables['mysql_engine_version'],'8.4.99')

    def test_windows_publish_fills_only_current_student_subnets(self):
        calls=[]
        def execute(*args, **kwargs):
            calls.append((args,kwargs))
            return lab.CLUSTER if args[1:]==('config','current-context') else 'applied'
        with patch.object(lab,'infra',return_value={'public_subnet_ids':['subnet-student-a','subnet-student-b']}), \
                patch.object(lab.shutil,'which',return_value='kubectl'), patch.object(lab,'run',side_effect=execute), \
                contextlib.redirect_stdout(io.StringIO()):
            lab.publish('203.0.113.10/32')
        manifest=calls[-1][1]['stdin']
        self.assertIn('subnet-student-a',manifest)
        self.assertIn('203.0.113.10/32',manifest)
        self.assertNotIn('__PUBLIC_SUBNET_',manifest)


if __name__ == '__main__':
    unittest.main()
