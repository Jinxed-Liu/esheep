import test from 'node:test';
import assert from 'node:assert/strict';
import {createClient} from '@supabase/supabase-js';
import {createVerifiedUserHandoff} from '../src/lib/verifiedUserHandoff.js';

test('only the exact freshly verified user can skip one duplicate Auth request', async () => {
  let calls = 0;
  const handoff = createVerifiedUserHandoff(async()=>{calls++;return {id:'a'};});
  const user = await handoff.verify();
  assert.equal(await handoff.consume(user),user);
  assert.equal(calls,1);
  await handoff.consume(user);
  assert.equal(calls,2,'a consumed receipt cannot be reused for a later read');
  await handoff.consume({id:'a'});
  assert.equal(calls,3,'session-storage or caller-created objects require server verification');
});

test('auth changes and identity mutation invalidate a previous verification', async () => {
  let identity = 'a', calls = 0;
  const handoff = createVerifiedUserHandoff(async()=>{calls++;return {id:identity};});
  const user = await handoff.verify();
  user.id = 'forged';
  assert.equal((await handoff.consume(user)).id,'a');
  const next = await handoff.verify();
  identity = 'b';handoff.invalidate();
  assert.equal((await handoff.consume(next)).id,'b');
  assert.equal(calls,4);
});

test('a verification completing after sign-out cannot create a usable receipt', async () => {
  let finish, calls = 0;
  const handoff = createVerifiedUserHandoff(()=>++calls===1 ? new Promise(resolve=>{finish=resolve;}) : Promise.resolve(null));
  const pending = handoff.verify();
  handoff.invalidate();finish({id:'a'});
  assert.equal(await handoff.consume(await pending),null);
  assert.equal(calls,2);
});

test('verification errors remain failures and unverified reads still contact Auth', async () => {
  const failure = new Error('session revoked');
  const handoff = createVerifiedUserHandoff(async()=>{throw failure;});
  await assert.rejects(handoff.verify(),failure);
  await assert.rejects(handoff.consume({id:'a'}),failure);
  await assert.rejects(handoff.consume(),failure);
});

test('initial and refreshed same-account notifications do not discard an in-flight Auth result', async()=>{
  let finish, calls=0;
  const handoff=createVerifiedUserHandoff(()=>{calls++;return new Promise(resolve=>{finish=resolve;});});
  const pending=handoff.verify();
  handoff.observeIdentity('a');
  handoff.observeIdentity('a');
  finish({id:'a'});
  const user=await pending;
  handoff.observeIdentity('a');
  assert.equal(await handoff.consume(user),user);
  assert.equal(calls,1);
});

test('an actual account replacement during Auth verification rejects the old handoff',async()=>{
  let finish,calls=0;
  const handoff=createVerifiedUserHandoff(()=>++calls===1?new Promise(resolve=>{finish=resolve;}):Promise.resolve({id:'b'}));
  handoff.observeIdentity('a');
  const pending=handoff.verify();
  handoff.observeIdentity('b');finish({id:'a'});
  assert.equal((await handoff.consume(await pending)).id,'b');
  assert.equal(calls,2);
});

test('Supabase initial-session notifications allow one server verification for startup', async()=>{
  const user={id:'00000000-0000-4000-8000-000000000001',aud:'authenticated'};
  const storageKey='startup-handoff-test';
  const saved=new Map([[storageKey,JSON.stringify({access_token:'test-access',refresh_token:'test-refresh',
    token_type:'bearer',expires_at:Math.floor(Date.now()/1000)+3600,user})]]);
  let requests=0;
  const client=createClient('https://auth.example','test-publishable-key',{
    auth:{autoRefreshToken:false,detectSessionInUrl:false,persistSession:true,storageKey,storage:{
      getItem:key=>saved.get(key)??null,setItem:(key,value)=>saved.set(key,value),removeItem:key=>saved.delete(key),
    }},
    global:{fetch:async request=>{assert(String(request).endsWith('/auth/v1/user'));requests++;
      return new Response(JSON.stringify(user),{headers:{'content-type':'application/json'}});}},
  });
  const handoff=createVerifiedUserHandoff(async()=>{
    const {data,error}=await client.auth.getUser();if(error)throw error;return data.user;
  });
  const pending=handoff.verify();
  const {data:{subscription}}=client.auth.onAuthStateChange((event,session)=>handoff.observeIdentity(event==='SIGNED_OUT'?null:session?.user?.id));
  try {
    const verified=await pending;
    assert.equal((await handoff.consume(verified)).id,user.id);
    assert.equal(requests,1);
  } finally {subscription.unsubscribe();client.auth.stopAutoRefresh();}
});
