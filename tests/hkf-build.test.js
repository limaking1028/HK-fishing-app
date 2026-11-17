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
    const flags=JSON.parse(html.match(/window.HKF_BUILD=(\{[^;]+\});/)[1]);
    assert.equal(flags.pushUi,env==='test');
    assert.ok(html.indexOf('window.HKF_BUILD=') < html.indexOf('./lib/push.js'));
    for(const id of ['push-enabled','push-record_broken','push-overtaken','push-status','push-explain']) {
      assert.equal(html.includes('id="'+id+'"'),env==='test',id);
    }
    assert.equal(/<legend>通知<\/legend>/.test(html),env==='test');
    assert.ok(html.includes('src="./lib/push.js"'));
    assert.equal((html.match(/HKF.createClient\(/g)||[]).length,2);
    {
      const forbidden=env==='test'?'lucizjohiycxdynrkjus':'qyijyrcbzalvqiautvjf';
      function scan(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const f=path.join(dir,e.name);if(e.isDirectory())scan(f);else assert.ok(!fs.readFileSync(f).includes(Buffer.from(forbidden)),f);}}scan(path.join(root,'www'));
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

test('both builds reject contamination from the other environment, including binary files',()=>{
  const fixture=fs.mkdtempSync(path.join(root,'lib/.hkf-scan-'));
  try{
    for(const [env,ref] of [['prod','qyijyrcbzalvqiautvjf'],['test','lucizjohiycxdynrkjus']]){
      fs.writeFileSync(path.join(fixture,'contaminated.bin'),Buffer.concat([Buffer.from([0,255]),Buffer.from(ref)]));
      const result=build(env);assert.notEqual(result.status,0);assert.match(result.stderr,/Other environment ref found/);
      assert.equal(fs.existsSync(path.join(root,'www')),false);
    }
  }finally{fs.rmSync(fixture,{recursive:true,force:true});}
});
test('test and production workflows both increment the latest integer TestFlight build',()=>{
  const yaml=fs.readFileSync(path.join(root,'codemagic.yaml'),'utf8');
  const scripts=[...yaml.matchAll(/      - name: Build number\n        script: \|\n([\s\S]*?)(?=      - name:)/g)].map(m=>m[1]);
  assert.equal(scripts.length,2);assert.equal(scripts[0],scripts[1]);assert.ok(!yaml.includes('2.0.'));
  // Execute their exact shell snippet against fake local CLIs: test 42 -> prod 43.
  const dir=fs.mkdtempSync(path.join(require('node:os').tmpdir(),'hkf-number-'));
  try{
    fs.writeFileSync(path.join(dir,'app-store-connect'),'#!/bin/sh\ncat "$HKF_COUNTER"\n',{mode:0o755});
    fs.writeFileSync(path.join(dir,'agvtool'),'#!/bin/sh\nprintf "%s" "$3" > "$HKF_COUNTER"\n',{mode:0o755});
    const counter=path.join(dir,'counter');fs.writeFileSync(counter,'41');
    const run=script=>cp.spawnSync('bash',['-e','-c',script],{cwd:root,env:{...process.env,PATH:dir+':'+process.env.PATH,HKF_COUNTER:counter,APP_STORE_APPLE_ID:'offline-app'},encoding:'utf8'});
    assert.equal(run(scripts[1]).status,0);assert.equal(fs.readFileSync(counter,'utf8'),'42');
    assert.equal(run(scripts[0]).status,0);assert.equal(fs.readFileSync(counter,'utf8'),'43');
  }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('one production constant restores push UI without changing the test build',()=>{
  const module={exports:{}};
  const source=fs.readFileSync(path.join(root,'scripts/ios/transform.js'),'utf8');
  const enabledSource=source.replace('const PROD_PUSH_UI = false;', 'const PROD_PUSH_UI = true;');
  assert.notEqual(enabledSource,source);
  vm.runInNewContext(enabledSource,{module});
  for(const env of ['prod','test']){
    const html=module.exports.transform('index.html',fs.readFileSync(path.join(root,'index.html'),'utf8'),{env,ref:'offline-ref'});
    assert.equal(JSON.parse(html.match(/window.HKF_BUILD=(\{[^;]+\});/)[1]).pushUi,true);
    assert.ok(html.includes('id="push-enabled"') && html.includes('id="push-explain"'));
  }
});
