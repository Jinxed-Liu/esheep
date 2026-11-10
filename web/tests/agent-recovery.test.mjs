import test from 'node:test';
import assert from 'node:assert/strict';
import { createAgentRouter } from '../container/agent-router.mjs';
import { responsesTurn } from '../server/agent-runtime.mjs';
import { validateAgentBody } from '../server/agent-api.mjs';
import { streamOpenAITurn } from '../src/lib/openaiAssistant.js';

const farm='00000000-0000-4000-8000-000000000001';
const request=(method='POST')=>new Request(`https://app.test/api/assistant/agent/${method==='POST'?'turn':'status'}?farm_id=${farm}`,{method,headers:{authorization:'Bearer test','x-agent-consent':'2026-11-05-agent-v1','x-assistant-api-key':'sk-synthetic-only'},...(method==='POST'?{body:'{}'}:{})});

test('two running container slots reject a third scope as busy without retries or hiding normal status',async()=>{
 let starts=0;const slots=new Set();let userID='one';
 let membership={provider:'esheep_cloud',initial_sync_ready:true};
 const route=createAgentRouter({verifyAccess:async()=>({userID,membership}),verifyCheckpoint:async()=>true});
 const env={SUPABASE_URL:'https://test.supabase.co',SUPABASE_PUBLISHABLE_KEY:'public',AGENT_RUNTIME_VERIFIED:'true',HARNESS_CONTAINER:{getByName:name=>({fetch:async()=>{starts++;if(!slots.has(name)&&slots.size===2)throw new Error('max_instances limit exceeded');slots.add(name);return new Response('ok');}})}};
 assert.equal((await route(request(),env)).status,200);userID='two';assert.equal((await route(request(),env)).status,200);
 userID='three';const busy=await route(request(),env);assert.equal(busy.status,503);assert.equal((await busy.json()).code,'AGENT_BUSY');assert.equal(starts,3);
 const status=await route(request('GET'),env);assert.equal(status.status,200);assert.equal((await status.json()).credentialStatus,'checked_on_request');assert.equal(starts,3);
 const notVerified=await route(request('GET'),{...env,AGENT_RUNTIME_VERIFIED:'false'});const body=await notVerified.json();assert.equal(body.configured,false);assert.equal(body.code,'AGENT_NOT_VERIFIED');
 const absent=await route(request('GET'),{...env,HARNESS_CONTAINER:undefined});assert.equal((await absent.json()).code,'AGENT_NOT_CONFIGURED');
 for (const candidate of [{provider:'supabase'},{provider:'esheep_cloud',initial_sync_ready:false}]) {
  membership=candidate;const notReady=await route(request('GET'),env);const value=await notReady.json();assert.equal(value.configured,false);assert.equal(value.code,'AGENT_FARM_NOT_READY');assert.equal(starts,3);
 }
});

test('provider credential, quota and temporary rate errors remain distinct and never expose provider bodies',async()=>{
 for(const [status,providerCode,expected] of [[401,'invalid_api_key','AGENT_KEY_INVALID'],[403,'permission_denied','AGENT_MODEL_FORBIDDEN'],[429,'insufficient_quota','AGENT_QUOTA_EXHAUSTED'],[429,'rate_limit_exceeded','AGENT_RATE_LIMITED'],[503,'overloaded','AGENT_MODEL_UNAVAILABLE']]) {
  let calls=0;await assert.rejects(()=>responsesTurn({provider:'openai',apiKey:'sk-synthetic-only',input:[],tools:[],instructions:'',fetchImpl:async()=>{calls++;return Response.json({error:{code:providerCode,message:'SECRET_SENTINEL'}},{status});}}),e=>e.code===expected&&!e.message.includes('SECRET_SENTINEL'));assert.equal(calls,1);
 }
});

test('browser busy and interrupted streams stop after one request; they never retry automatically',async()=>{
 for(const response of [Response.json({error:'服务繁忙',code:'AGENT_BUSY',recovery:'retry'},{status:503}),new Response('{"type":"status","message":"正在读取"}\n')]) {
  let calls=0;await assert.rejects(()=>streamOpenAITurn({accessToken:'test',apiKey:'sk-synthetic-only',farmID:farm,prompt:'查羊',fetchImpl:async()=>{calls++;return response;}}),/繁忙|连接中断/);assert.equal(calls,1);
 }
});

test('malformed body and tools fail as correctable client requests before model use',()=>{
 for(const body of [{provider:'openai',input:{}},{provider:'mimo',input:[null]},{provider:'openai',input:[{role:'user',content:'x'}],clientTools:{}}])assert.throws(()=>validateAgentBody(body),e=>e.status===400);
});
