// node --test tests/ — proves web/TWA auth redirects are unchanged and the iOS path is native-only.
const test = require('node:test'), assert = require('node:assert'), fs = require('fs'), vm = require('vm');
const SRC = fs.readFileSync(__dirname + '/../lib/auth.js', 'utf8');
const same = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b)); // cross-realm (vm) safe
const WEB = 'https://limaking1028.github.io/HK-fishing-app';

function load(capacitor) {
  const calls = [], listeners = [];
  const sb = { auth: {
    signInWithOtp: async (a) => (calls.push(['otp', a]), { error: null }),
    signUp: async (a) => (calls.push(['signUp', a]), { data: { session: null, user: { identities: [1] } }, error: null }),
    resetPasswordForEmail: async (e, o) => (calls.push(['reset', o]), { error: null }),
    signInWithOAuth: async (a) => (calls.push(['oauth', a]), { data: { url: 'https://x.supabase.co/auth/v1/authorize?p=google' }, error: null }),
    exchangeCodeForSession: async (c) => (calls.push(['exchange', c]), { error: null }),
    setSession: async (s) => (calls.push(['setSession', s]), { error: null }),
  } };
  if (capacitor) capacitor.Plugins = {
    App: { addListener: (n, cb) => listeners.push([n, cb]) },
    Browser: { open: async (o) => calls.push(['browser.open', o]), close: async () => calls.push(['browser.close']) },
  };
  const window = { location: { origin: 'https://limaking1028.github.io', pathname: '/HK-fishing-app/' },
    sb, localStorage: {}, Capacitor: capacitor, console };
  const ctx = vm.createContext({ window, console, URL, setTimeout, clearTimeout, localStorage: {} });
  vm.runInContext(SRC, ctx);
  return { lib: window.authLib, calls, listeners };
}
const cap = (native, platform) => ({ isNativePlatform: () => native, getPlatform: () => platform });

for (const [label, c] of [['web (no Capacitor)', undefined], ['Android TWA / Capacitor android', cap(true, 'android')], ['Capacitor web', cap(false, 'web')]]) {
  test(`${label}: redirects unchanged, implicit flow, no listener`, async () => {
    const { lib, calls, listeners } = load(c);
    assert.strictEqual(lib.isNativeIOS(), false);
    assert.strictEqual(lib.authRedirectUrl(), WEB);
    assert.strictEqual(lib.authFlowType(), 'implicit');
    await lib.sendMagicLink('a@b.com'); await lib.signUpWithPassword('a@b.com', 'abc12345'); await lib.sendPasswordReset('a@b.com'); await lib.signInWithGoogle();
    assert.strictEqual(calls[0][1].options.emailRedirectTo, WEB);
    assert.strictEqual(calls[1][1].options.emailRedirectTo, WEB);
    assert.strictEqual(calls[2][1].redirectTo, WEB);
    same(calls[3][1], { provider: 'google', options: { redirectTo: WEB } });
    assert.ok(!calls.some(x => x[0].startsWith('browser')));
    assert.strictEqual(listeners.length, 0);
  });
}

test('iOS native: custom scheme, pkce, Browser.open, appUrlOpen -> exchange + close', async () => {
  const { lib, calls, listeners } = load(cap(true, 'ios'));
  const R = 'app.hkfishing.ios://auth-callback';
  assert.strictEqual(lib.authRedirectUrl(), R);
  assert.strictEqual(lib.authFlowType(), 'pkce');
  await lib.sendMagicLink('a@b.com'); await lib.sendPasswordReset('a@b.com'); await lib.signInWithGoogle();
  assert.strictEqual(calls[0][1].options.emailRedirectTo, R);
  assert.strictEqual(calls[1][1].redirectTo, R);
  same(calls[2][1], { provider: 'google', options: { redirectTo: R, skipBrowserRedirect: true } });
  same(calls[3], ['browser.open', { url: 'https://x.supabase.co/auth/v1/authorize?p=google' }]);
  assert.strictEqual(listeners.length, 1); assert.strictEqual(listeners[0][0], 'appUrlOpen');
  calls.length = 0;
  await lib.handleNativeAuthUrl(R + '?code=abc123');
  same(calls, [['browser.close'], ['exchange', 'abc123']]);
  calls.length = 0;
  assert.strictEqual(await lib.handleNativeAuthUrl('https://evil.example/?code=x'), false);
  assert.strictEqual(calls.length, 0);
});
