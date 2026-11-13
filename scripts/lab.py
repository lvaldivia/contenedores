"""Provisionador por etapas. No ejecuta nada al importarse; ver README.md."""
import argparse
import base64
import ipaddress
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = os.environ.get('LAB_AWS_ACCOUNT_ID', '')
REGION = os.environ.get('LAB_AWS_REGION', 'us-east-1')
PROFILE = os.environ.get('LAB_AWS_PROFILE', os.environ.get('AWS_PROFILE', 'default'))
OPERATOR = os.environ.get('LAB_OPERATOR_ARN', '')
CLUSTER = 'contenedores-eks'


def settings():
    global ACCOUNT, REGION, PROFILE, OPERATOR
    path = ROOT / 'lab.config.json'
    config = json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else {}
    ACCOUNT = config.get('account_id', os.environ.get('LAB_AWS_ACCOUNT_ID', ''))
    REGION = config.get('region', os.environ.get('LAB_AWS_REGION', 'us-east-1'))
    PROFILE = config.get('profile', os.environ.get('LAB_AWS_PROFILE', os.environ.get('AWS_PROFILE', 'default')))
    OPERATOR = config.get('operator_arn', os.environ.get('LAB_OPERATOR_ARN', ''))
    if not re.fullmatch(r'[0-9]{12}', ACCOUNT):
        raise RuntimeError('Copiar lab.config.example.json a lab.config.json y completar la cuenta AWS propia.')
    if not re.fullmatch(r'[a-z]{2}-[a-z]+-[0-9]+', REGION) or not PROFILE:
        raise RuntimeError('Region o perfil invalido en lab.config.json.')
    return config


def configure():
    """Consultas previas y variables locales. No crea recursos AWS."""
    config = settings()
    missing = [name for name in ('aws', 'terraform', 'docker', 'kubectl') if not shutil.which(name)]
    if missing:
        raise RuntimeError('Instalar dependencias: ' + ', '.join(missing))
    if not run('aws', '--version').startswith('aws-cli/2.'):
        raise RuntimeError('Instalar AWS CLI v2.')
    if run('docker', 'info', '--format', '{{.OSType}}') != 'linux':
        raise RuntimeError('Iniciar Docker con contenedores Linux.')
    identity = aws('sts', 'get-caller-identity')
    if identity['Account'] != ACCOUNT:
        raise RuntimeError('El perfil no corresponde a la cuenta configurada; no se escribieron variables.')
    principal = OPERATOR or identity['Arn']
    if not re.fullmatch(rf'arn:aws:iam::{ACCOUNT}:(user|role)/[^\s]+', principal):
        raise RuntimeError('Configurar operator_arn con el ARN IAM del usuario o rol; no usar el ARN STS de una sesion.')
    requested = config.get('mysql_engine_version', '')
    if requested and not re.fullmatch(r'8\.4\.[0-9]+', requested):
        raise RuntimeError('mysql_engine_version debe estar vacio o ser una version MySQL 8.4.x.')
    flags = dict(Engine='mysql', EngineVersion=requested or '8.4')
    if not requested:
        flags['DefaultOnly'] = True
    versions = aws('rds', 'describe-db-engine-versions', **flags)['DBEngineVersions']
    versions = [v['EngineVersion'] for v in versions if v.get('Status', 'available') == 'available']
    if not versions:
        raise RuntimeError('No se encontro MySQL 8.4 disponible; elegir una version valida en lab.config.json.')
    version = versions[0]
    options = aws('rds', 'describe-orderable-db-instance-options', Engine='mysql',
                  EngineVersion=version, DBInstanceClass='db.t4g.micro')['OrderableDBInstanceOptions']
    if not options:
        raise RuntimeError('db.t4g.micro no esta disponible para esa version/region.')
    config.update(account_id=ACCOUNT, profile=PROFILE, region=REGION,
                  operator_arn=principal, mysql_engine_version=version)
    variables = dict(account_id=ACCOUNT, profile=PROFILE, region=REGION, mysql_engine_version=version)
    (ROOT / 'lab.config.json').write_text(json.dumps(config, indent=2)+'\n', encoding='utf-8')
    (ROOT / 'infra/lab.auto.tfvars.json').write_text(json.dumps(variables, indent=2)+'\n', encoding='utf-8')
    print(f'Configuracion validada: cuenta={ACCOUNT}, perfil={PROFILE}, region={REGION}, MySQL={version}')
    print('Se escribieron archivos locales ignorados. No se creo ningun recurso AWS.')


def run(*args, stdin=None):
    result = subprocess.run(list(args), input=stdin, text=True, encoding='utf-8',
                            capture_output=True, cwd=ROOT)
    if result.returncode:
        # Do not echo arguments: some requests contain secret values.
        raise RuntimeError(f'{args[0]} {args[1]} fallo: {result.stderr.strip()}')
    return result.stdout.strip()


def request_payload(service, payload=None, flags=None):
    flags = flags or {}
    payload = {**(payload or {}), **flags}
    # ECS/EKS/ECR/Logs model their top-level fields in lowerCamelCase;
    # IAM, EC2, ELBv2 and Secrets Manager use PascalCase.
    if service in ('ecs', 'eks', 'ecr', 'logs'):
        payload = {key[0].lower() + key[1:]: value for key, value in payload.items()}
    if service == 'iam':
        for key in ('AssumeRolePolicyDocument', 'PolicyDocument'):
            if isinstance(payload.get(key), dict):
                payload[key] = json.dumps(payload[key])
    return payload


def aws(service, operation, payload=None, **flags):
    payload = request_payload(service, payload, flags)
    args = ['aws', service, operation, '--profile', PROFILE, '--region', REGION,
            '--output', 'json', '--no-cli-pager']
    if not payload:
        raw = run(*args)
    else:
        # AWS CLI reads JSON from a restricted temporary file, never argv/history.
        with tempfile.TemporaryDirectory(prefix='contenedores-') as folder:
            path = Path(folder) / 'request.json'
            path.write_text(json.dumps(payload), encoding='utf-8')
            path.chmod(0o600)
            raw = run(*args, '--cli-input-json', 'file://' + path.as_posix())
    return json.loads(raw) if raw else {}


def infra():
    data = json.loads(run('terraform', '-chdir=infra', 'output', '-json'))
    outputs = {key: item['value'] for key, item in data.items()}
    arn = outputs.get('mysql_admin_secret_arn', '')
    if len(arn.split(':')) < 6 or arn.split(':')[4] != ACCOUNT or outputs.get('region') != REGION:
        raise RuntimeError('El estado Terraform pertenece a otra cuenta/region o faltan outputs; no reutilizarlo.')
    return outputs


def secret_arn():
    return aws('secretsmanager', 'describe-secret', SecretId='contenedores/api/mysql')['ARN']


def secret():
    existing = aws('secretsmanager', 'list-secrets')['SecretList']
    if any(item['Name'] == 'contenedores/api/mysql' for item in existing):
        print('Se reutiliza contenedores/api/mysql sin cambiar su password.')
        return
    password = aws('secretsmanager', 'get-random-password', PasswordLength=32,
                   ExcludePunctuation=True)['RandomPassword']
    result = aws('secretsmanager', 'create-secret', {
        'Name': 'contenedores/api/mysql',
        'SecretString': json.dumps({'username': 'appuser', 'password': password}),
        'Tags': [{'Key': 'Project', 'Value': 'contenedores-lab'}]})
    print('Secreto creado:', result['ARN'])


def image(version):
    repositories = aws('ecr', 'describe-repositories')['repositories']
    if not any(r['repositoryName'] == 'contenedores-api' for r in repositories):
        aws('ecr', 'create-repository', RepositoryName='contenedores-api',
            ImageScanningConfiguration={'scanOnPush': True})
    registry = f'{ACCOUNT}.dkr.ecr.{REGION}.amazonaws.com'
    password = run('aws', 'ecr', 'get-login-password', '--profile', PROFILE, '--region', REGION)
    run('docker', 'login', '--username', 'AWS', '--password-stdin', registry, stdin=password)
    uri = f'{registry}/contenedores-api:{version}'
    print('Construyendo y publicando', uri, flush=True)
    run('docker', 'build', '--platform', 'linux/amd64', '-t', uri, 'backend')
    run('docker', 'push', uri)


def role(name, trust, policies):
    roles = aws('iam', 'list-roles')['Roles']
    if not any(r['RoleName'] == name for r in roles):
        aws('iam', 'create-role', RoleName=name, AssumeRolePolicyDocument=trust)
    else:
        aws('iam', 'update-assume-role-policy', RoleName=name, PolicyDocument=trust)
    for policy in policies:
        aws('iam', 'attach-role-policy', RoleName=name,
            PolicyArn=f'arn:aws:iam::aws:policy/{policy}')


def load(relative):
    return json.loads((ROOT / relative).read_text(encoding='utf-8-sig'))


def prepare(version):
    outputs, arn = infra(), secret_arn()
    uri = f'{ACCOUNT}.dkr.ecr.{REGION}.amazonaws.com/contenedores-api:{version}'
    out = ROOT / 'backend/ecs/generated'
    out.mkdir(parents=True, exist_ok=True)
    for kind in ('bootstrap', 'runtime'):
        name = f'contenedores-api-{kind}-execution'
        role(name, load('policy/ecs-task-trust.json'),
             ['service-role/AmazonECSTaskExecutionRolePolicy'])
        policy = {'Version': '2012-10-17', 'Statement': [{
            'Effect': 'Allow', 'Action': 'secretsmanager:GetSecretValue',
            'Resource': [arn] + ([outputs['mysql_admin_secret_arn']] if kind == 'bootstrap' else [])}]}
        aws('iam', 'put-role-policy', RoleName=name, PolicyName='database-secret', PolicyDocument=policy)
        # Keep the commit-ready policy copies aligned with the new deployment.
        (ROOT / f'policy/ecs-{kind}-secrets-policy.json').write_text(json.dumps(policy, indent=2)+'\n')
        complete = load(f'policy/02-ecs/{kind}-execution-policy.json')
        for statement in complete['Statement']:
            resources = statement.get('Resource', [])
            resources = [resources] if isinstance(resources, str) else resources
            replaced = []
            for resource in resources:
                parts = resource.split(':')
                if resource.startswith('arn:aws:') and len(parts) > 5:
                    if parts[3]:
                        parts[3] = REGION
                    if re.fullmatch(r'[0-9]{12}|__ACCOUNT_ID__', parts[4]):
                        parts[4] = ACCOUNT
                    resource = ':'.join(parts)
                replaced.append(resource)
            statement['Resource'] = replaced[0] if isinstance(statement.get('Resource'), str) else replaced
            if statement.get('Sid') == 'ReadDatabaseCredentials':
                statement['Resource'] = policy['Statement'][0]['Resource']
        (ROOT / f'policy/02-ecs/{kind}-execution-policy.json').write_text(json.dumps(complete, indent=2)+'\n')
        env = dict(DB_HOST=outputs['mysql_host'], DB_PORT='3306', DB_NAME=outputs['mysql_database'],
                   DB_SSL='true', DB_SSL_CA='/app/certs/rds-global-bundle.pem', APP_ENV='ecs', APP_VERSION=version)
        secrets = [{'name': f'DB_{key}', 'valueFrom': f'{arn}:{field}::'}
                   for key, field in [('USER', 'username'), ('PASSWORD', 'password')]]
        container = dict(name='api', image=uri, essential=True,
                         portMappings=[{'containerPort': 3000, 'protocol': 'tcp'}],
                         environment=[{'name': k, 'value': v} for k, v in env.items()], secrets=secrets,
                         logConfiguration={'logDriver': 'awslogs', 'options': {
                             'awslogs-group': '/ecs/contenedores-api', 'awslogs-region': REGION,
                             'awslogs-stream-prefix': kind}})
        if kind == 'bootstrap':
            container['command'] = ['node', 'src/init-db.mjs']
            container['secrets'] += [{'name': f'DB_ADMIN_{key}', 'valueFrom': f"{outputs['mysql_admin_secret_arn']}:{field}::"}
                                     for key, field in [('USER', 'username'), ('PASSWORD', 'password')]]
        else:
            container['healthCheck'] = {'command': ['CMD-SHELL',
                "node -e \"fetch('http://127.0.0.1:3000/health/live').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""],
                'interval': 30, 'timeout': 6, 'retries': 3, 'startPeriod': 20}
        task = dict(family=f'contenedores-api-{kind}', networkMode='awsvpc',
                    requiresCompatibilities=['FARGATE'], cpu='256', memory='512',
                    executionRoleArn=f'arn:aws:iam::{ACCOUNT}:role/{name}',
                    runtimePlatform={'cpuArchitecture': 'X86_64', 'operatingSystemFamily': 'LINUX'},
                    containerDefinitions=[container])
        (out / f'{kind}-task.json').write_text(json.dumps(task, indent=2)+'\n')
        aws('ecs', 'register-task-definition', task)
    groups = aws('logs', 'describe-log-groups', LogGroupNamePrefix='/ecs/contenedores-api')['logGroups']
    if not any(g['logGroupName'] == '/ecs/contenedores-api' for g in groups):
        aws('logs', 'create-log-group', LogGroupName='/ecs/contenedores-api')
    aws('logs', 'put-retention-policy', LogGroupName='/ecs/contenedores-api', RetentionInDays=7)
    aws('ecs', 'create-cluster', ClusterName='contenedores-lab')
    network = {'awsvpcConfiguration': {'subnets': outputs['app_private_subnet_ids'],
               'securityGroups': [outputs['ecs_security_group_id']], 'assignPublicIp': 'DISABLED'}}
    (out / 'network.json').write_text(json.dumps(network, indent=2)+'\n')
    print('Tareas registradas y roles configurados. Esperar propagacion IAM antes de bootstrap.')


def bootstrap():
    network = load('backend/ecs/generated/network.json')
    response = aws('ecs', 'run-task', Cluster='contenedores-lab', LaunchType='FARGATE',
                   PlatformVersion='LATEST', TaskDefinition='contenedores-api-bootstrap', NetworkConfiguration=network)
    if response.get('failures') or not response.get('tasks'):
        raise RuntimeError('No se pudo iniciar bootstrap: ' + json.dumps(response.get('failures')))
    task = response['tasks'][0]['taskArn']
    run('aws', 'ecs', 'wait', 'tasks-stopped', '--cluster', 'contenedores-lab', '--tasks', task,
        '--profile', PROFILE, '--region', REGION)
    task = aws('ecs', 'describe-tasks', Cluster='contenedores-lab', Tasks=[task])['tasks'][0]
    if not task.get('containers') or any(c.get('exitCode') != 0 for c in task['containers']):
        raise RuntimeError('Bootstrap fallo. Revisar /ecs/contenedores-api y stoppedReason en ECS.')
    print('Bootstrap terminado con exitCode=0: tabla y usuario de aplicacion inicializados.')


def ecs(cidr):
    cidr = str(ipaddress.IPv4Network(cidr, strict=True))
    o = infra()
    # This is a first-install step; AWS reports duplicate names on a repeat run.
    sg = aws('ec2', 'create-security-group', GroupName='contenedores-api-alb',
             Description='HTTP del operador para laboratorio', VpcId=o['vpc_id'])['GroupId']
    aws('ec2', 'authorize-security-group-ingress', GroupId=sg, IpPermissions=[{
        'IpProtocol': 'tcp', 'FromPort': 80, 'ToPort': 80, 'IpRanges': [{'CidrIp': cidr}]}])
    aws('ec2', 'authorize-security-group-ingress', GroupId=o['ecs_security_group_id'], IpPermissions=[{
        'IpProtocol': 'tcp', 'FromPort': 3000, 'ToPort': 3000, 'UserIdGroupPairs': [{'GroupId': sg}]}])
    lb = aws('elbv2', 'create-load-balancer', Name='contenedores-api-alb',
             Subnets=o['public_subnet_ids'], SecurityGroups=[sg], Scheme='internet-facing', Type='application')['LoadBalancers'][0]
    tg = aws('elbv2', 'create-target-group', Name='contenedores-api-tg', Protocol='HTTP', Port=3000,
             VpcId=o['vpc_id'], TargetType='ip', HealthCheckPath='/health/ready')['TargetGroups'][0]['TargetGroupArn']
    aws('elbv2', 'create-listener', LoadBalancerArn=lb['LoadBalancerArn'], Protocol='HTTP', Port=80,
        DefaultActions=[{'Type': 'forward', 'TargetGroupArn': tg}])
    aws('ecs', 'create-service', Cluster='contenedores-lab', ServiceName='contenedores-lab',
        TaskDefinition='contenedores-api-runtime', DesiredCount=2, LaunchType='FARGATE', PlatformVersion='LATEST',
        NetworkConfiguration=load('backend/ecs/generated/network.json'), HealthCheckGracePeriodSeconds=60,
        LoadBalancers=[{'targetGroupArn': tg, 'containerName': 'api', 'containerPort': 3000}])
    run('aws', 'ecs', 'wait', 'services-stable', '--cluster', 'contenedores-lab', '--services', 'contenedores-lab',
        '--profile', PROFILE, '--region', REGION)
    print('ECS:', 'http://' + lb['DNSName'] + '/docs/')


def eks(cidr):
    cidr = str(ipaddress.IPv4Network(cidr, strict=True))
    if not re.fullmatch(rf'arn:aws:iam::{ACCOUNT}:(user|role)/[^\s]+', OPERATOR):
        raise RuntimeError('Ejecutar configure y completar operator_arn propio antes de crear EKS.')
    o = infra()
    role('contenedores-eks-cluster-role', load('policy/03-eks/auto-cluster-trust.json'), [
        'AmazonEKSClusterPolicy', 'AmazonEKSComputePolicy', 'AmazonEKSBlockStoragePolicyV2',
        'AmazonEKSLoadBalancingPolicy', 'AmazonEKSNetworkingPolicy'])
    role('contenedores-eks-node-role', load('policy/03-eks/node-trust.json'),
         ['AmazonEKSWorkerNodeMinimalPolicy', 'AmazonEC2ContainerRegistryPullOnly'])
    time.sleep(15)  # IAM propagation; a first run can require retrying after more time.
    aws('eks', 'create-cluster', Name=CLUSTER,
        RoleArn=f'arn:aws:iam::{ACCOUNT}:role/contenedores-eks-cluster-role',
        ResourcesVpcConfig={'subnetIds': o['app_private_subnet_ids'], 'securityGroupIds': [o['eks_security_group_id']],
                            'endpointPrivateAccess': True, 'endpointPublicAccess': True, 'publicAccessCidrs': [cidr]},
        ComputeConfig={'enabled': True, 'nodePools': ['general-purpose', 'system'],
                       'nodeRoleArn': f'arn:aws:iam::{ACCOUNT}:role/contenedores-eks-node-role'},
        KubernetesNetworkConfig={'elasticLoadBalancing': {'enabled': True}},
        StorageConfig={'blockStorage': {'enabled': True}},
        AccessConfig={'authenticationMode': 'API', 'bootstrapClusterCreatorAdminPermissions': False},
        Logging={'clusterLogging': [{'types': ['api', 'audit', 'authenticator'], 'enabled': True}]})
    run('aws', 'eks', 'wait', 'cluster-active', '--name', CLUSTER, '--profile', PROFILE, '--region', REGION)
    principal = OPERATOR
    aws('eks', 'create-access-entry', ClusterName=CLUSTER, PrincipalArn=principal, Type='STANDARD')
    aws('eks', 'associate-access-policy', ClusterName=CLUSTER, PrincipalArn=principal,
        PolicyArn='arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy', AccessScope={'type': 'cluster'})
    sg = aws('eks', 'describe-cluster', Name=CLUSTER)['cluster']['resourcesVpcConfig']['clusterSecurityGroupId']
    (ROOT / 'infra/eks-auto.auto.tfvars').write_text(f'eks_auto_node_security_group_id = "{sg}"\n')
    print('Cluster activo. Aplicar Terraform para autorizar MySQL desde', sg)


def deploy(version):
    run('aws', 'eks', 'update-kubeconfig', '--name', CLUSTER, '--alias', CLUSTER,
        '--profile', PROFILE, '--region', REGION)
    kubectl = shutil.which('kubectl') or str(ROOT / 'tools/kubectl.exe')
    def kube(*args, stdin=None):
        return run(kubectl, '--context', CLUSTER, *args, stdin=stdin)
    # Preserve strict TLS validation on Windows networks that inspect HTTPS.
    # Combine the EKS CA with the trusted Windows bundle prepared by lab.ps1.
    bundle = os.environ.get('AWS_CA_BUNDLE')
    if os.name == 'nt' and bundle:
        cluster = aws('eks', 'describe-cluster', Name=CLUSTER)['cluster']
        ca = base64.b64decode(cluster['certificateAuthority']['data']).decode('ascii')
        trust = ROOT / 'eks/cluster-trust-bundle.pem'
        trust.write_text(ca + '\n' + Path(bundle).read_text(encoding='ascii'), encoding='ascii')
        run(kubectl, 'config', 'set-cluster', cluster['arn'],
            '--certificate-authority=' + str(trust), '--embed-certs=true')
        current_debug = [v for v in os.environ.get('GODEBUG', '').split(',')
                         if v and not v.startswith('http2client=')]
        os.environ['GODEBUG'] = ','.join(current_debug + ['http2client=0'])
    kube('apply', '-f', 'backend/k8s/namespace.yaml')
    config = infra()
    # JSON is valid YAML; generate the ConfigMap using current Terraform outputs.
    data = {'DB_HOST': config['mysql_host'], 'DB_PORT': '3306', 'DB_NAME': config['mysql_database'],
            'DB_SSL': 'true', 'DB_SSL_CA': '/app/certs/rds-global-bundle.pem', 'APP_ENV': 'eks', 'APP_VERSION': version}
    kube('apply', '-f', '-', stdin=json.dumps({'apiVersion': 'v1', 'kind': 'ConfigMap',
         'metadata': {'name': 'api-config', 'namespace': 'contenedores'}, 'data': data}))
    raw = aws('secretsmanager', 'get-secret-value', SecretId=secret_arn())['SecretString']
    credentials = json.loads(raw)
    if credentials.get('username') != 'appuser' or not credentials.get('password'):
        raise RuntimeError('Se esperaba el secreto del usuario appuser.')
    data = {key: base64.b64encode(credentials[field].encode()).decode()
            for key, field in [('DB_USER', 'username'), ('DB_PASSWORD', 'password')]}
    kube('apply', '--server-side', '--field-manager=lab-secret-sync', '-f', '-', stdin=json.dumps({
        'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
        'metadata': {'name': 'mysql-app', 'namespace': 'contenedores'}, 'data': data}))
    image_uri = f'{ACCOUNT}.dkr.ecr.{REGION}.amazonaws.com/contenedores-api:{version}'
    deployment = (ROOT / 'backend/k8s/deployment.yaml').read_text().replace('__IMAGE_URI__', image_uri)
    kube('apply', '-f', '-', stdin=deployment)
    kube('apply', '-f', 'backend/k8s/service.yaml')
    print(kube('-n', 'contenedores', 'rollout', 'status', 'deployment/productos-api', '--timeout=600s'))
    print('Acceso: kubectl --context contenedores-eks -n contenedores port-forward svc/productos-api 8080:80')


def publish(cidr):
    cidr = str(ipaddress.IPv4Network(cidr, strict=True))
    outputs = infra()
    replacements = {'__OPERATOR_CIDR__': cidr,
                    '__PUBLIC_SUBNET_1__': outputs['public_subnet_ids'][0],
                    '__PUBLIC_SUBNET_2__': outputs['public_subnet_ids'][1]}
    manifest = (ROOT / 'backend/k8s/alb/ingress.yaml').read_text(encoding='utf-8')
    for marker, value in replacements.items():
        manifest = manifest.replace(marker, value)
    if re.search(r'__[A-Z0-9_]+__', manifest):
        raise RuntimeError('Quedaron marcadores en el Ingress; revisar plantilla.')
    kubectl = shutil.which('kubectl') or str(ROOT / 'tools/kubectl.exe')
    current = run(kubectl, 'config', 'current-context')
    if current != CLUSTER:
        raise RuntimeError('Conectar primero al contexto contenedores-eks.')
    print(run(kubectl, '--context', CLUSTER, 'apply', '-f', '-', stdin=manifest))
    print('Esperar ADDRESS y targets healthy del Ingress productos-api-public.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('step', choices=['configure', 'secret', 'image', 'prepare', 'bootstrap', 'ecs', 'eks', 'deploy', 'publish'])
    parser.add_argument('--version', default='v1')
    parser.add_argument('--cidr', help='IPv4 publica del operador en formato x.x.x.x/32')
    args = parser.parse_args()
    if args.step == 'configure':
        configure()
        return
    if args.step in ('ecs', 'eks', 'publish') and not args.cidr:
        parser.error('--cidr es obligatorio para ecs, eks y publish')
    settings()
    if aws('sts', 'get-caller-identity')['Account'] != ACCOUNT:
        raise RuntimeError('Cuenta AWS distinta de la autorizada para este laboratorio.')
    os.environ['AWS_PAGER'] = ''
    if args.step in ('image', 'prepare', 'deploy'):
        globals()[args.step](args.version)
    elif args.step in ('ecs', 'eks', 'publish'):
        globals()[args.step](args.cidr)
    else:
        globals()[args.step]()


if __name__ == '__main__':
    main()
