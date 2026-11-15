// Checked transformations over current sources. A changed anchor fails the build.
function replace(source, from, to) {
  if (!source.includes(from)) throw new Error('iOS source anchor changed: ' + from.slice(0, 70));
  return source.replace(from, to);
}
function storage(s) { return s.replace(/\b(?:window\.)?localStorage\b/g, 'HKF.local').replace(/\b(?:window\.)?sessionStorage\b/g, 'HKF.session'); }
function transform(file, source, manifest) {
  let s = source;
  const test = manifest.env === 'test';
  if (file === 'index.html') {
    const start = s.indexOf('  // 強制清除舊 Service Worker');
    const end = s.indexOf('  </script>', start);
    if (start < 0 || end < 0) throw new Error('Missing SW cleanup anchor');
    s = s.slice(0, start) + '  // iOS: preserve all existing registrations and caches.\n' + s.slice(end);
    s = s.replace(/const SB_URL\s*= '[^']*';/, 'const SB_URL = HKF.manifest.url;')
      .replace(/const SB_KEY\s*= '[^']*';/, 'const SB_KEY = HKF.manifest.anonKey;');
    const clients = /window.supabase.createClient\(SB_URL, SB_KEY, \{\s*auth: \{[^\n]+\}\s*\}\)/g;
    const matches = s.match(clients) || [];
    if (matches.length !== 2) throw new Error('Expected both index client paths');
    s = s.replace(clients, 'HKF.createClient(window.supabase, authLib.authFlowType())');
    s = replace(s, "Object.keys(localStorage).filter(k => /^(hk[_-]fishing|sb-)/.test(k)).forEach(k => localStorage.removeItem(k));", 'HKF.clearOwner();');
    s = s.replace(/state.user = (data|user|profile|userProfile|null);/g, '$& HKF.setOwner(state.user && state.user.id);');
    s = replace(s, '  state.user = userProfile; HKF.setOwner(state.user && state.user.id);', '  state.user = userProfile; HKF.setOwner(state.user && state.user.id);\n  tallyLoadLocal();');
    // Legacy storage is not even read by test; retain normal prod migration.
    if (test) {
      s = replace(s, 'const migrated = await withTimeout(migrateLocalCatches(),', 'const migrated = await withTimeout(Promise.resolve(0),');
      for (const [id, text] of [['auth-google-btn','Google：測試環境未啟用'], ['auth-apple-btn','Apple：測試環境未啟用']]) {
        const re = new RegExp('(<button[^>]+id="' + id + '"[^>]*>)[\\s\\S]*?(</button>)');
        s = s.replace(re, '$1' + text + '$2');
        s = replace(s, 'id="' + id + '"', 'disabled id="' + id + '"');
      }
      for (const id of ['auth-tab-register', 'auth-forgot-btn']) s = replace(s, 'id="' + id + '"', 'disabled title="測試環境未啟用" id="' + id + '"');
      s = s.replace('用電郵登入／註冊 ›', '用電郵及密碼登入 ›');
      s = replace(s, '<body', '<body data-hkf-env="test"');
      s = replace(s, '</head>', `<style>
:root{--hkf-safe-top:env(safe-area-inset-top,0px);--hkf-banner-height:calc(var(--hkf-safe-top) + 28px)}
#hkf-test-banner{position:fixed;top:0;left:0;right:0;height:var(--hkf-banner-height);z-index:2147483647;background:#ffd600;color:#111;text-align:center;font-size:16px;line-height:20px;font-weight:bold;padding:calc(var(--hkf-safe-top) + 4px) 8px 4px;pointer-events:none}
body{padding-top:var(--hkf-banner-height)}
#app{min-height:calc(100vh - var(--hkf-banner-height));min-height:calc(100dvh - var(--hkf-banner-height))}
#header{top:var(--hkf-banner-height);padding:12px 16px}
.login-screen{top:var(--hkf-banner-height)}
</style></head>`);
      s = s.replace(/(<body[^>]*>)/, '$1<div id="hkf-test-banner" role="status">測試環境</div>');
    }
    s = s.replace(/^.*切換到新項目.*$/m, '// Environment supplied by iOS build manifest.');
    s = storage(s);
    // First synchronous script validates the manifest before app code can run.
    s = replace(s, '<head>', '<head>\n<script>window.HKF_BUILD=' + JSON.stringify({env:manifest.env,ref:manifest.ref}) + ';</script>\n<script src="./hkf-env.js"></script>\n<script src="./lib/hkf-runtime.js"></script>');
  } else if (file === 'lib/auth.js') {
    s = replace(s, "const IOS_AUTH_REDIRECT = 'app.hkfishing.ios://auth-callback';", 'const IOS_AUTH_REDIRECT = ' + JSON.stringify('app.hkfishing.ios://' + (test ? 'auth-test-callback' : 'auth-callback')) + ';');
    s = replace(s, "if (!url || url.indexOf(IOS_AUTH_REDIRECT) !== 0) return false;", `if (!url) return false;
    try { const u = new URL(url), expected = new URL(IOS_AUTH_REDIRECT);
      if (u.protocol !== expected.protocol || u.host !== expected.host || u.pathname !== expected.pathname || u.username || u.password) return false;
      ${test ? "if (u.hash || u.searchParams.has('access_token') || u.searchParams.has('refresh_token')) return false;" : ''}
    } catch (_) { return false; }`);
    s = replace(s, `window.sb = window.supabase.createClient(url, key, {
        auth: { persistSession: true, autoRefreshToken: true, storage: window.localStorage, flowType: authFlowType() }
      });`, 'window.sb = HKF.createClient(window.supabase, authFlowType());');
    if (test) for (const fn of ['sendMagicLink(email)', 'verifyCode(email, code)', 'signUpWithPassword(email, password)', 'sendPasswordReset(email)', 'signInWithGoogle()', 'signInWithApple()']) {
      s = replace(s, 'async function ' + fn + ' {', 'async function ' + fn + ' {\n    throw new Error("測試環境未啟用");');
    }
    s = storage(s);
  } else if (file === 'sw.js') {
    s = replace(s, "const CACHE = 'hk-fishing-v201';", `const CACHE_PREFIX = 'hkf:${manifest.env}:${manifest.ref}:';\nconst CACHE = CACHE_PREFIX + 'photos-v199';`);
    s = replace(s, 'keys.filter(k => k !== CACHE)', 'keys.filter(k => k.startsWith(CACHE_PREFIX) && k !== CACHE)');
    s = replace(s, 'caches.match(e.request, { ignoreSearch: true })', 'caches.open(CACHE).then(c => c.match(e.request, { ignoreSearch: true }))');
  } else if (file.endsWith('.js')) s = storage(s);
  return s;
}
module.exports = {transform};
