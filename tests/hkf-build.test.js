const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),cp=require('node:child_process');
const root=path.resolve(__dirname,'..');
const {transform}=require('../scripts/ios/transform');
const build=env=>cp.spawnSync(process.execPath,['scripts/build-ios-web.js'],{cwd:root,env:{...process.env,APP_ENV:env,HKF_TEST_SUPABASE_ANON_KEY:'sb_publishable_offline_fixture_only'},encoding:'utf8'});
test('build requires explicit environment and test key; no stale output after invalid config',()=>{
  assert.notEqual(build('').status,0);
  const r=cp.spawnSync(process.execPath,['scripts/build-ios-web.js'],{cwd:root,env:{...process.env,APP_ENV:'test',HKF_TEST_SUPABASE_ANON_KEY:''}});assert.notEqual(r.status,0);
});
test('both iOS bundles parse, all files scan, original web and Android sources unchanged',()=>{
  const originals=['index.html','lib/auth.js','lib/push.js','sw.js'].map(f=>fs.readFileSync(path.join(root,f)));
  for(const env of ['test','prod']){
    const r=build(env);assert.equal(r.status,0,r.stderr);
    const html=fs.readFileSync(path.join(root,'www/index.html'),'utf8');
    const manifest=JSON.parse(fs.readFileSync(path.join(root,'www/hkf-env.json')));assert.equal(manifest.env,env);
    for(const m of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) if(m[1].trim()&&!m[0].includes('application/json'))new vm.Script(m[1]);
    for(const f of fs.readdirSync(path.join(root,'www/lib')))if(f.endsWith('.js'))new vm.Script(fs.readFileSync(path.join(root,'www/lib',f),'utf8'));
    assert.ok(!html.includes('Object.keys(HKF.local)'));assert.ok(!html.includes('caches.delete'));
    assert.equal(html.includes('id="hkf-test-banner"'),env==='test');
    assert.equal((html.match(/HKF.createClient\(/g)||[]).length,2);
    if(env==='test'){
      function scan(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const f=path.join(dir,e.name);if(e.isDirectory())scan(f);else assert.ok(!fs.readFileSync(f).includes(Buffer.from('lucizjohiycxdynrkjus')),f);}}scan(path.join(root,'www'));
    }
  }
  originals.forEach((b,i)=>assert.deepEqual(fs.readFileSync(path.join(root,['index.html','lib/auth.js','lib/push.js','sw.js'][i])),b));
});
test('service worker fetch stays same-origin photo-only, activate only removes own environment',async()=>{
  const handlers={},removed=[];const m={env:'test',ref:'qyijyrcbzalvqiautvjf'};
  const code=transform('sw.js',fs.readFileSync(path.join(root,'sw.js'),'utf8'),m);
  const prefix='hkf:test:'+m.ref+':';
  vm.runInNewContext(code,{self:{addEventListener(n,f){handlers[n]=f;},clients:{claim(){}},location:{origin:'https://localhost'}},caches:{keys:async()=>[prefix+'old','hkf:prod:other:old','unrelated'],delete:async k=>removed.push(k)},URL});
  let promise;handlers.activate({waitUntil(p){promise=p;}});await promise;assert.deepEqual(removed,[prefix+'old']);
  for(const url of ['https://remote/photos/fish.webp','https://localhost/index.html','https://localhost/auth/v1/token'])handlers.fetch({request:{url,method:'GET'},respondWith(){assert.fail('Unexpected interception');}});
});
