// iOS-only output: never modify the web/Android sources.
const fs = require('fs'), path = require('path');
const {transform} = require('./ios/transform');
const root = path.resolve(__dirname, '..');
const out = path.join(root, 'www');
// Remove generated output first: an invalid build must not leave a stale prod bundle.
fs.rmSync(out, {recursive:true, force:true});
const env = process.env.APP_ENV;
if (!['test', 'prod'].includes(env)) throw new Error('APP_ENV=test|prod must be explicitly selected');
const ref = env === 'test' ? 'qyijyrcbzalvqiautvjf' : 'lucizjohiycxdynrkjus';
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const anonKey = env === 'test' ? process.env.HKF_TEST_SUPABASE_ANON_KEY : html.match(/const SB_KEY\s*= '([^']+)'/)[1];
if (!anonKey || anonKey.length < 21) throw new Error('Missing anon key for selected environment');
// Reject service-role JWTs and project-mismatched JWTs without logging their contents.
if (anonKey.startsWith('eyJ')) {
  let claims;
  try { claims = JSON.parse(Buffer.from(anonKey.split('.')[1], 'base64url').toString()); } catch (_) { throw new Error('Invalid anon JWT'); }
  if (claims.role !== 'anon' || claims.ref !== ref) throw new Error('Anon JWT role/ref mismatch');
} else if (!anonKey.startsWith('sb_publishable_')) throw new Error('Expected anon JWT or publishable key');
const manifest = {env, ref, url: 'https://' + ref + '.supabase.co', anonKey};
fs.rmSync(out, {recursive:true, force:true});
fs.mkdirSync(out);
const FILES = ['index.html', 'privacy.html', 'delete-account.html', 'manifest.json', 'sw.js',
  'apple-touch-icon.png', 'icon-192.png', 'icon-512.png', 'icon-maskable-512.png'];
for (const f of FILES) if (fs.existsSync(path.join(root, f))) fs.copyFileSync(path.join(root, f), path.join(out, f));
for (const d of ['lib', 'photos', 'assets']) if (fs.existsSync(path.join(root,d))) fs.cpSync(path.join(root,d),path.join(out,d),{recursive:true});
function visit(dir, fn) {
  for (const entry of fs.readdirSync(dir,{withFileTypes:true})) {
    const f = path.join(dir,entry.name);
    if (entry.isDirectory()) visit(f,fn); else fn(f);
  }
}
visit(out, f => {
  const relative = path.relative(out,f).split(path.sep).join('/');
  if (relative === 'index.html' || relative.endsWith('.js')) fs.writeFileSync(f,transform(relative,fs.readFileSync(f,'utf8'),manifest));
});
fs.copyFileSync(path.join(__dirname,'ios/runtime.js'),path.join(out,'lib/hkf-runtime.js'));
fs.writeFileSync(path.join(out,'hkf-env.js'),'window.HKF_MANIFEST=' + JSON.stringify(manifest) + ';\n');
fs.writeFileSync(path.join(out,'hkf-env.json'),JSON.stringify(manifest,null,2));
const forbiddenRef = env === 'test' ? 'lucizjohiycxdynrkjus' : 'qyijyrcbzalvqiautvjf';
visit(out,f => {
  if (fs.readFileSync(f).includes(Buffer.from(forbiddenRef))) {
    fs.rmSync(out,{recursive:true,force:true});
    throw new Error('Other environment ref found in ' + env + ' bundle');
  }
});
console.log('www/ ready: ' + env + ' (' + ref + ')');
