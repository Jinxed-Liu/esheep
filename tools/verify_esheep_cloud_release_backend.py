#!/usr/bin/env python3
"""Read-only release/backend binding, deployment and authorization preflight.

This is one release gate, not a replacement for signed isolated end-to-end tests.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import urllib.error
import urllib.request


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--release-info-plist',type=Path,required=True)
    p.add_argument('--project',required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args(); assert re.fullmatch('[a-z]{20}',a.project)
    info=plistlib.loads(a.release_info_plist.read_bytes())
    base=f'https://{a.project}.supabase.co'
    assert info['CFBundleIdentifier']=='com.sheepfarm.ios' and info['SUPABASE_URL'].rstrip('/')==base
    def cli(args):
        return json.loads(subprocess.run(['supabase',*args,'-o','json'],capture_output=True,check=True).stdout)
    deployed=cli(['functions','list','--project-ref',a.project])
    expected={'esheep-cloud-v2-writes':'integrated-v1','esheep-cloud-checkpoints':'checkpoint-v1-integrated-v1'}
    functions=[]
    for name,version in expected.items():
        found=next((f for f in deployed if f['slug']==name),None)
        req=urllib.request.Request(base+'/functions/v1/'+name,data=b'{}',method='POST',headers={'content-type':'application/json'})
        try:
            response=urllib.request.urlopen(req,timeout=30)
        except urllib.error.HTTPError as error:
            response=error
        with response:
            status=response.status; actual_version=response.headers.get('x-esheep-service-version')
        functions.append(dict(name=name,deployedVersion=found.get('version') if found else None,
                              active=bool(found and found['status']=='ACTIVE'),anonymousStatus=status,
                              serviceVersion=actual_version,passed=bool(found and found['status']=='ACTIVE' and status==401 and actual_version==version)))
    names=['esheep_cloud_submit_verified_commands_v2','esheep_cloud_resolve_verified_attention_v2',
           'esheep_cloud_asset_verification_target_v2','esheep_cloud_confirm_verified_asset_v2']
    literals=','.join("'"+n+"'" for n in names)
    query=f"select p.proname, bool_and(has_function_privilege('service_role',p.oid,'execute')) server_execute, bool_and(not has_function_privilege('authenticated',p.oid,'execute') and not has_function_privilege('anon',p.oid,'execute')) client_denied from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ({literals}) group by p.proname"
    dependencies=cli(['db','query','--project-ref',a.project,'--linked',query])['rows']
    device=cli(['db','query','--project-ref',a.project,'--linked',"select bool_and(has_column_privilege('service_role','public.devices',name,'select')) allowed from unnest(array['device_id','user_id','public_key_jwk','status']) name"])['rows'][0]['allowed']
    checkpoint_query = """select signature,
      coalesce(to_regprocedure(signature) is not null
        and (server_allowed is null or has_function_privilege('service_role',to_regprocedure(signature),'execute')=server_allowed)
        and has_function_privilege('authenticated',to_regprocedure(signature),'execute')=member_allowed
        and not has_function_privilege('anon',to_regprocedure(signature),'execute'),false) passed
      from (values
        ('public.esheep_cloud_checkpoint_manifest_v1(uuid,integer,uuid)',null,true),
        ('public.esheep_cloud_command_audit_v1(uuid,uuid[])',null,true),
        ('public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text)',true,false),
        ('public.esheep_cloud_publish_checkpoint_content_v1(jsonb,text,text)',false,false),
        ('public.esheep_cloud_checkpoint_retention_v1(uuid,integer,boolean)',true,false),
        ('public.esheep_cloud_claim_checkpoint_purge_v1(uuid,integer,uuid)',true,false),
        ('public.esheep_cloud_finish_checkpoint_purge_v1(uuid,text)',true,false)
      ) expected(signature,server_allowed,member_allowed)"""
    checkpoint_dependencies=cli(['db','query','--project-ref',a.project,'--linked',checkpoint_query])['rows']
    controls_query = """select coalesce(to_regclass('esheep_cloud.checkpoint_rollout_controls') is not null
      and has_table_privilege('service_role',to_regclass('esheep_cloud.checkpoint_rollout_controls'),'update')
      and not has_table_privilege('authenticated',to_regclass('esheep_cloud.checkpoint_rollout_controls'),'update')
      and not has_table_privilege('anon',to_regclass('esheep_cloud.checkpoint_rollout_controls'),'select'),false) passed"""
    controls=cli(['db','query','--project-ref',a.project,'--linked',controls_query])['rows'][0]['passed']
    passed=all(f['passed'] for f in functions) and len(dependencies)==len(names) and all(d['server_execute'] and d['client_denied'] for d in dependencies) and device and controls and len(checkpoint_dependencies)==7 and all(d['passed'] for d in checkpoint_dependencies)
    report=dict(passed=passed,project=a.project,bundle=info['CFBundleIdentifier'],build=info['CFBundleVersion'],
                functions=functions,dependencies=dependencies,devicePublicKeyAccess=device,checkpointDependencies=checkpoint_dependencies,rolloutControls=controls,readOnly=True)
    a.output.write_text(json.dumps(report,indent=2));print(json.dumps(report))
    raise SystemExit(0 if passed else 1)

if __name__=='__main__': main()
