"""Project-scoped service credential; never requires a cloud account-wide PAT."""
import json
import os
import re
import subprocess
import urllib.request


def service_key(project):
    assert re.fullmatch('[a-z]{20}', project)
    if value := os.environ.get('ESHEEP_CHECKPOINT_SERVICE_KEY'):
        return value
    if os.environ.get('CI_XCODE_CLOUD'):
        raise RuntimeError('The protected workflow service secret is missing')
    result = subprocess.run(['supabase','projects','api-keys','--project-ref',project,'-o','json'],
        capture_output=True,check=True,timeout=180)
    return next(k['api_key'] for k in json.loads(result.stdout) if k['name']=='service_role')


def source_call(project, action, **parameters):
    key = service_key(project)
    payload = dict(p_action=action, **{'p_'+name: value for name,value in parameters.items()})
    request = urllib.request.Request(
        f'https://{project}.supabase.co/rest/v1/rpc/esheep_cloud_checkpoint_worker_source_v1',
        data=json.dumps(payload).encode(),
        headers={'authorization':'Bearer '+key,'apikey':key,'content-type':'application/json'})
    with urllib.request.urlopen(request,timeout=180) as response:
        raw=response.read(64*1024*1024+1)
    if len(raw)>64*1024*1024: raise RuntimeError('Checkpoint source exceeds worker memory bound')
    return json.loads(raw)
