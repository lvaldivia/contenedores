from pathlib import Path
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor
import subprocess,json,os,time,sys

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'scripts'))
import lab
lab.settings()
if lab.aws('sts','get-caller-identity')['Account'] != lab.ACCOUNT: raise RuntimeError('Cuenta incorrecta')
os.environ['AWS_CA_BUNDLE']=str(root/'infra/windows-ca.pem')
os.environ['GODEBUG']='http2client=0'
def run(args):
    for attempt in range(3):
        r=subprocess.run(args,capture_output=True,text=True)
        if not r.returncode:return r.stdout
        if 'forcibly closed' not in r.stderr or attempt==2:raise RuntimeError(r.stderr[-1200:])
        time.sleep(1)
def aws(*args):
    return json.loads(run(['aws',*args,'--profile',lab.PROFILE,'--region',lab.REGION,'--output','json']))
def kube(*args):
    return json.loads(run([str(root/'tools/kubectl.exe'),'--context','contenedores-eks','--request-timeout=20s',*args,'-o','json']))

cluster=aws('eks','describe-cluster','--name','contenedores-eks')['cluster']
nodes=kube('get','nodes')['items']
policies=aws('iam','list-attached-role-policies','--role-name','contenedores-eks-cluster-role')['AttachedPolicies']
required={'AmazonEKSClusterPolicy','AmazonEKSComputePolicy','AmazonEKSBlockStoragePolicyV2','AmazonEKSLoadBalancingPolicy','AmazonEKSNetworkingPolicy'}
assert required <= {p['PolicyName'] for p in policies}
access=aws('eks','list-associated-access-policies','--cluster-name','contenedores-eks','--principal-arn',lab.OPERATOR)['associatedAccessPolicies']
assert any(p['policyArn'].endswith('/AmazonEKSClusterAdminPolicy') for p in access)
assert cluster['status']=='ACTIVE'
assert cluster['resourcesVpcConfig']['endpointPrivateAccess']
assert all(c.endswith('/32') for c in cluster['resourcesVpcConfig']['publicAccessCidrs'])
logs={t for c in cluster['logging']['clusterLogging'] if c['enabled'] for t in c['types']}
assert {'api','audit','authenticator'} <= logs
node_status=[{'name':n['metadata']['name'],'arch':n['status']['nodeInfo']['architecture'],'ready':any(c['type']=='Ready' and c['status']=='True' for c in n['status']['conditions'])} for n in nodes]
assert node_status and all(n['ready'] for n in node_status)
def addon(name):
    a=aws('eks','describe-addon','--cluster-name','contenedores-eks','--addon-name',name)['addon']
    return {'name':name,'status':a['status'],'health':a['health']}
with ThreadPoolExecutor(max_workers=4) as pool: addons=list(pool.map(addon,['coredns','metrics-server','vpc-cni','kube-proxy']))
assert all(a['status']=='ACTIVE' and not a['health'].get('issues') for a in addons)
job=json.loads((root/'eks/mysql-network-check-result.json').read_text(encoding='utf-8-sig'))
assert job['status'].get('succeeded')==1
report={'checkedAt':datetime.now(timezone.utc).isoformat(),'cluster':cluster['name'],'status':cluster['status'],'version':cluster['version'],'autoMode':cluster['computeConfig']['enabled'],'publicAccessCidrs':cluster['resourcesVpcConfig']['publicAccessCidrs'],'controlPlaneLogTypes':sorted(logs),'clusterPolicies':sorted(required),'operatorAccess':lab.OPERATOR+' / AmazonEKSClusterAdminPolicy','kubectlVersion':kube('version','--client')['clientVersion']['gitVersion'],'nodes':node_status,'addons':addons,'mysqlTcpCheck':{'succeeded':True,'port':3306,'sqlAuthenticationTested':False},'tlsVerificationEnabled':True}
(root/'eks/verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
