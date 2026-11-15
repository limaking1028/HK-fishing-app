// node --test tests/ — proves web/TWA auth redirects are unchanged and the iOS path is native-only.
const test = require('node:test'), assert = require('node:assert'), fs = require('fs'), vm = require('vm');
const SRC = fs.readFileSync(__dirname + '/../lib/auth.js', 'utf8');
const same = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b)); // cross-realm (vm) safe
const WEB = 'https://limaking1028.github.io/HK-fishing-app';

function load(capacitor, source = SRC) {
  const calls = [], listeners = [];
  const sb = { auth: {
    signInWithPassword: async (a) => (calls.push(['password', a]), {data:{}, error:null}),
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
  const ctx = vm.createContext({ window, console, URL, setTimeout, clearTimeout, localStorage: {}, HKF: {local:{},session:{}} });
  vm.runInContext(source, ctx);
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

test('Apple: iOS opens system browser via custom scheme; web keeps plain redirect; disabled provider -> friendly error', async () => {
  const R = 'app.hkfishing.ios://auth-callback';
  let { lib, calls } = load(cap(true, 'ios'));
  await lib.signInWithApple();
  same(calls[0][1], { provider: 'apple', options: { redirectTo: R, skipBrowserRedirect: true } });
  assert.strictEqual(calls[1][0], 'browser.open');
  ({ lib, calls } = load(undefined));
  await lib.signInWithApple();
  same(calls[0][1], { provider: 'apple', options: { redirectTo: WEB } });
  assert.ok(!calls.some(x => x[0].startsWith('browser')));
});
test('Apple: provider not enabled -> friendly Cantonese error, no browser opened', async () => {
  const SRC2 = SRC;
  const calls = [];
  const sb = { auth: { signInWithOAuth: async () => ({ data: null, error: { message: 'Unsupported provider: provider is not enabled' } }) } };
  const C = cap(true, 'ios'); C.Plugins = { App: { addListener() {} }, Browser: { open: async () => calls.push('open') } };
  const window = { location: { origin: 'https://limaking1028.github.io', pathname: '/HK-fishing-app/' }, sb, localStorage: {}, Capacitor: C, console };
  vm.runInContext(SRC2, vm.createContext({ window, console, URL, setTimeout, clearTimeout, localStorage: {} }));
  await assert.rejects(window.authLib.signInWithApple(), /Apple 登入暫未開通/);
  assert.strictEqual(calls.length, 0);
});

const {transform} = require('../scripts/ios/transform');
test('test iOS disables providers/mail/OTP at API boundary and accepts exact test PKCE callback only', async () => {
  const source = transform('lib/auth.js', SRC, {env:'test'});
  const {lib,calls} = load(cap(true,'ios'),source);
  assert.strictEqual(lib.authRedirectUrl(),'app.hkfishing.ios://auth-test-callback');
  for (const [method,args] of [['sendMagicLink',['a@b.com']],['verifyCode',['a@b.com','123456']],['signUpWithPassword',['a@b.com','fixture']],['sendPasswordReset',['a@b.com']],['signInWithApple',[]],['signInWithGoogle',[]]]) await assert.rejects(lib[method](...args),/測試環境未啟用/);
  assert.strictEqual(calls.length,0);
  await lib.signInWithPassword('a@b.com','offline-fixture');
  assert.strictEqual(calls[0][0],'password'); calls.length=0;
  for (const url of ['app.hkfishing.ios://auth-callback?code=x','app.hkfishing.ios://auth-test-callback.evil?code=x','app.hkfishing.ios://auth-test-callback/path?code=x','app.hkfishing.ios://auth-test-callback#access_token=a&refresh_token=b']) assert.strictEqual(await lib.handleNativeAuthUrl(url),false);
  assert.strictEqual(calls.length,0);
  await lib.handleNativeAuthUrl('app.hkfishing.ios://auth-test-callback?code=fixture');
  same(calls,[['browser.close'],['exchange','fixture']]);
});
test('prod transformed auth keeps mail/OAuth and native callback behavior', async () => {
  const {lib,calls}=load(cap(true,'ios'),transform('lib/auth.js',SRC,{env:'prod'}));
  await lib.sendMagicLink('a@b.com');await lib.signInWithApple();
  assert.strictEqual(calls[0][0],'otp');assert.strictEqual(calls[1][1].provider,'apple');
  assert.strictEqual(await lib.handleNativeAuthUrl('app.hkfishing.ios://auth-callback-evil?code=x'),false);
});
