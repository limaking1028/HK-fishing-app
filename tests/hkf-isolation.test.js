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
  h.clearOwner();assert.equal(h.local.getItem('hk_fishing_tallies_v1'),'');
  for(const [k,v] of Object.entries(seed))assert.equal(x.localStorage.data.get(k),v);
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
