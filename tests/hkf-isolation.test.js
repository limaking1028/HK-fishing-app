const test = require('node:test'), assert = require('node:assert/strict'), vm = require('node:vm'), fs = require('node:fs');
const runtime = fs.readFileSync(__dirname + '/../scripts/ios/runtime.js','utf8');
function store(seed = {}) {
  const data = new Map(Object.entries(seed)), reads = [], removed = [];
  return {data, reads, removed, get length(){return data.size;}, key(i){return [...data.keys()][i];},
    getItem(k){reads.push(k);return data.get(k) ?? null;}, setItem(k,v){data.set(k,String(v));},removeItem(k){removed.push(k);data.delete(k);}};
}
function load(env='test', seed={}, mutation={}) {
  const ref=env==='test'?'qyijyrcbzalvqiautvjf':'lucizjohiycxdynrkjus';
  const localStorage=store(seed), sessionStorage=store();
  const window={localStorage,sessionStorage,HKF_BUILD:{env,ref},HKF_MANIFEST:{env,ref,url:'https://'+ref+'.supabase.co',anonKey:'sb_publishable_fixture_123',...mutation},stop(){}};
  const document={documentElement:{innerHTML:''}};
  const context=vm.createContext({window,document,URL,console});
  return {window,document,context,localStorage,sessionStorage,run(){vm.runInContext(runtime,context);return window.HKF;}};
}
module.exports={load,store};
test('test legacy data: names counted, values never read/moved/deleted',()=>{
  const seed={hk_fishing_unsynced_v1:'secret',hk_fishing_tallies_v1:'secret',hk_fishing_active_trip:'secret','sb-lucizjohiycxdynrkjus-auth-token':'secret'};
  const x=load('test',seed), h=x.run();h.setOwner('alice');assert.equal(h.legacyCount(),4);
  for(const k of Object.keys(seed)){assert.equal(h.local.getItem(k),null);h.local.removeItem(k);}
  h.clearOwner();assert.ok(Object.keys(seed).every(k=>!x.localStorage.reads.includes(k)&&x.localStorage.data.get(k)==='secret'));
  assert.deepEqual(x.localStorage.removed,[]);
});
test('owner isolation, scoped deletion, session explicit key and tombstones',()=>{
  const x=load(),h=x.run(); h.setOwner('alice'); h.local.setItem('tally','alice');h.setOwner('bob');h.local.setItem('tally','bob');h.clearOwner();
  assert.equal(h.local.getItem('tally'),'');h.setOwner('alice');assert.equal(h.local.getItem('tally'),'alice');
  let options;h.createClient({createClient(u,k,o){options=o;return {};}});assert.match(options.auth.storageKey,/^hkf:v2:test:qyijyrcbzalvqiautvjf:auth:session$/);
  assert.equal(options.auth.detectSessionInUrl,false);
  assert.throws(()=>options.auth.storage.getItem('sb-other'),/refused/);
});
test('prod legacy migration checks owner, filters queue, preserves originals and never resurrects synced queue',()=>{
  const seed={hk_fishing_user_id:'alice',hk_fishing_unsynced_v1:JSON.stringify([{userId:'alice'},{userId:'bob'}]),hk_fishing_tallies_v1:'{"data":{}}',hk_fishing_active_trip:'{"id":"trip"}'};
  const x=load('prod',seed),h=x.run();h.setOwner('bob');assert.equal(h.local.getItem('hk_fishing_tallies_v1'),null);
  h.setOwner('alice');assert.equal(JSON.parse(h.local.getItem('hk_fishing_unsynced_v1')).length,1);
  assert.equal(h.local.getItem('hk_fishing_active_trip'),seed.hk_fishing_active_trip);
  h.local.removeItem('hk_fishing_unsynced_v1');assert.equal(h.local.getItem('hk_fishing_unsynced_v1'),'');
  for(const [k,v] of Object.entries(seed))assert.equal(x.localStorage.data.get(k),v);
  h.clearOwner();assert.equal(h.local.getItem('hk_fishing_tallies_v1'),'');
  assert.equal(x.localStorage.data.get('hk_fishing_active_trip'),seed.hk_fishing_active_trip);
  assert.deepEqual(JSON.parse(x.localStorage.data.get('hk_fishing_unsynced_v1')),[{userId:'bob'}]);
});
test('manifest missing or wrong env/ref/url halts boot before clients',()=>{
  for(const mutation of [{ref:'wrong'}, {env:'prod'}, {url:'https://other.supabase.co'}, {anonKey:''}]){
    const x=load('test',{},mutation);assert.throws(()=>x.run(),/environment refused/);assert.match(x.document.documentElement.innerHTML,/環境設定錯誤/);assert.equal(x.window.HKF,undefined);
  }
  const x=load();delete x.window.HKF_MANIFEST;assert.throws(()=>x.run(),/environment refused/);
});
test('generated push registers APNs only with sealed test client and namespaces prompt preference',async()=>{
  const x=load(),h=x.run(),listeners={},calls=[];
  h.setOwner('alice');
  const plugin={addListener:async(n,fn)=>{listeners[n]=fn;},checkPermissions:async()=>({receive:'granted'}),register:async()=>{},unregister:async()=>{}};
  x.window.Capacitor={getPlatform:()=> 'ios',Plugins:{PushNotifications:plugin}};
  x.context.HKF=h;x.context.navigator={};x.context.document={getElementById:()=>null};x.context.location={search:''};x.context.URLSearchParams=URLSearchParams;
  const sb=h.createClient({createClient(url){return {rpc:async(name)=>{calls.push({url,name});return {data:null};},from(){return {select(){return this;},eq(){return this;},maybeSingle:async()=>({data:{enabled:true}})};}};}});
  const {transform}=require('../scripts/ios/transform');
  vm.runInContext(transform('lib/push.js',fs.readFileSync(__dirname+'/../lib/push.js','utf8'),{env:'test'}),x.context);
  x.window.pushLib.init({sb,navigate(){}});x.window.pushLib.login('alice');
  await new Promise(setImmediate);
  await listeners.registration({value:'noncredential-fixture-token'});await new Promise(setImmediate);
  assert.deepEqual(calls,[{url:'https://qyijyrcbzalvqiautvjf.supabase.co',name:'push_register_device'}]);
  x.window.pushLib.dismiss();assert.equal(x.localStorage.data.get(h.key('hk-push-asked:alice')),'1');
  assert.equal(x.localStorage.data.has('hk-push-asked:alice'),false);
});

test('prod upgrade retains logged-in session using the actual Supabase SDK, without network or legacy deletion',async()=>{
  const {createClient}=require('@supabase/supabase-js');
  const expires=Math.floor(Date.now()/1000)+3600;
  const encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
  const session={access_token:encode({alg:'HS256',typ:'JWT'})+'.'+encode({sub:'upgrade-user',exp:expires})+'.offline-signature',refresh_token:'offline-refresh-fixture',expires_at:expires,expires_in:3600,token_type:'bearer',user:{id:'upgrade-user',aud:'authenticated',role:'authenticated'}};
  const legacy='sb-lucizjohiycxdynrkjus-auth-token', serialized=JSON.stringify(session);
  const x=load('prod',{[legacy]:serialized}),h=x.run();
  let network=0;
  const options={global:{fetch:async()=>{network++;throw new Error('Network forbidden in upgrade test');}}};
  const old=createClient(x.window.HKF_MANIFEST.url,x.window.HKF_MANIFEST.anonKey,{...options,auth:{storage:x.localStorage,persistSession:true,autoRefreshToken:false,detectSessionInUrl:false}});
  assert.equal(old.auth.storageKey,legacy); // Confirms actual SDK default, not a guessed key.
  assert.equal((await old.auth.getSession()).data.session.user.id,'upgrade-user');
  const upgraded=h.createClient({createClient:(url,key,opts)=>createClient(url,key,{...opts,...options})});
  const {data,error}=await upgraded.auth.getSession();
  assert.equal(error,null);assert.equal(data.session.user.id,'upgrade-user');
  assert.equal(data.session.access_token,session.access_token);
  assert.equal(x.localStorage.data.get(h.key('session','auth')),serialized);
  assert.equal(x.localStorage.data.get(legacy),serialized);assert.deepEqual(x.localStorage.removed,[]);
  await upgraded.auth.stopAutoRefresh();await old.auth.stopAutoRefresh();
  assert.equal(network,0);
});
test('existing new session or logout tombstone takes precedence over old prod session',()=>{
  const legacy='sb-lucizjohiycxdynrkjus-auth-token';
  for(const value of ['new-session','']){
    const x=load('prod',{[legacy]:'old-session','hkf:v2:prod:lucizjohiycxdynrkjus:auth:session':value}),h=x.run();
    let options;h.createClient({createClient(u,k,o){options=o;}});
    assert.equal(options.auth.storage.getItem(options.auth.storageKey),value);
    assert.ok(!x.localStorage.reads.includes(legacy));
  }
});
test('prod account deletion removes only explicit owner legacy records and own session, preserving other/unknown data',()=>{
  const legacy='sb-lucizjohiycxdynrkjus-auth-token';
  const bob={userId:'bob',unsynced:true},unknown={unsynced:true},conflict={userId:'alice',user_id:'bob'};
  const seed={hk_fishing_unsynced_v1:JSON.stringify([{userId:'alice'},bob,unknown,conflict]),hk_fishing_catches_v5:JSON.stringify([{user_id:'alice'},{user_id:'bob'}]),hk_fishing_active_trip:JSON.stringify({userId:'alice',id:'own-trip'}),hk_fishing_tallies_v1:JSON.stringify({data:{unattributed:{}}}),hk_fishing_user_id:'alice',[legacy]:JSON.stringify({user:{id:'alice'}}),'hk-push-asked:alice':'1','hk-push-asked:bob':'1',hk_fishing_imported_v1:'invalid-json'};
  const x=load('prod',seed),h=x.run();h.setOwner('bob');h.local.setItem('queue','bob');h.setOwner('alice');h.clearOwner();
  assert.deepEqual(JSON.parse(x.localStorage.data.get('hk_fishing_unsynced_v1')),[bob,unknown,conflict]);
  assert.deepEqual(JSON.parse(x.localStorage.data.get('hk_fishing_catches_v5')),[{user_id:'bob'}]);
  assert.equal(x.localStorage.data.has('hk_fishing_active_trip'),false);assert.equal(x.localStorage.data.has(legacy),false);
  for(const k of ['hk_fishing_tallies_v1','hk_fishing_imported_v1','hk-push-asked:bob'])assert.equal(x.localStorage.data.get(k),seed[k]);
  h.setOwner('bob');assert.equal(h.local.getItem('queue'),'bob');
  const other=load('prod',{[legacy]:JSON.stringify({user:{id:'bob'}}),hk_fishing_user_id:'bob'}),ho=other.run();ho.setOwner('alice');ho.clearOwner();assert.equal(other.localStorage.data.get(legacy),JSON.stringify({user:{id:'bob'}}));assert.equal(other.localStorage.data.get('hk_fishing_user_id'),'bob');
});
