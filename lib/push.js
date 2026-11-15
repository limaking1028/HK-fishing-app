/* Push registration is optional: never requests permission during startup. */
(function () {
  'use strict';
  let ctx, uid, prefs, nativeReady, currentToken, pendingRoute;
  const native = () => window.Capacitor?.getPlatform?.() === 'ios';
  const plugin = () => window.Capacitor?.Plugins?.PushNotifications;
  const supported = () => native() ? !!plugin() : 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const checked = async p => { const r = await p; if (r.error) throw r.error; return r.data; };
  const quiet = fn => Promise.resolve().then(fn).catch(() => {});
  const remember = () => { try { localStorage.setItem('hk-push-asked:' + uid, '1'); } catch (_) {} };
  function route(data) {
    const board = ['biggest', 'quantity', 'species'].includes(data?.lbType) ? data.lbType : 'biggest';
    if (!uid) { pendingRoute = { lbType: board }; return; }
    ctx.navigate(board);
  }
  async function storeToken(token, type) {
    const owner = uid;
    if (!owner || !prefs?.enabled) return;
    await checked(ctx.sb.rpc('push_register_device', {
      p_token: token, p_platform: native() ? 'ios' : (document.referrer.startsWith('android-app:') ? 'android' : 'web'), p_token_type: type
    }));
    if (uid === owner) currentToken = token;
  }
  async function initNative() {
    if (nativeReady) return nativeReady;
    nativeReady = (async () => {
      const p = plugin();
      await p.addListener('registration', t => quiet(() => storeToken(t.value, 'apns')));
      await p.addListener('registrationError', () => message('未能登記通知，請稍後喺設定再試。'));
      await p.addListener('pushNotificationActionPerformed', a => route(a.notification.data));
    })();
    return nativeReady;
  }
  async function permission() {
    if (native()) return (await plugin().checkPermissions()).receive === 'granted';
    return Notification.permission === 'granted';
  }
  async function register(ask) {
    if (!uid || !supported()) return false;
    if (native()) {
      await initNative();
      if (ask && !await permission()) await plugin().requestPermissions();
      if (!await permission()) return false;
      await plugin().register();
      return true;
    }
    if (ask && Notification.permission === 'default') await Notification.requestPermission();
    if (Notification.permission !== 'granted') return false;
    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();
    if (!subscription) {
      const key = await checked(ctx.sb.rpc('push_public_config'));
      if (!key) { message('通知尚未設定完成，請稍後再試。'); return false; }
      const encoded = key.replace(/-/g, '+').replace(/_/g, '/');
      const raw = atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, '='));
      subscription = await registration.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: Uint8Array.from(raw, c => c.charCodeAt(0))});
    }
    await storeToken(JSON.stringify(subscription.toJSON()), 'webpush');
    return true;
  }
  function message(text) { const el = document.getElementById('push-status'); if (el) el.textContent = text; }
  function paint() {
    for (const key of ['enabled', 'record_broken', 'overtaken']) {
      const el = document.getElementById('push-' + key);
      if (el) { el.checked = !!prefs?.[key]; el.disabled = !uid || !prefs || !supported(); }
    }
    if (!supported()) message('呢個裝置暫時唔支援通知。');
  }
  async function refresh() {
    if (!uid) return;
    const owner = uid;
    const row = await checked(ctx.sb.from('notification_prefs').select('enabled,record_broken,overtaken').eq('user_id', owner).maybeSingle());
    if (owner !== uid) return;
    prefs = row || {enabled: false, record_broken: true, overtaken: true};
    paint();
  }
  async function change(key, value) {
    if (!uid || !prefs) return;
    const owner = uid;
    try {
      if (key === 'enabled' && value) {
        remember();
        // Permission must stay in the user's click call stack (Safari/iOS).
        const granted = native() ? (await plugin().requestPermissions()).receive === 'granted' : (await Notification.requestPermission()) === 'granted';
        if (!granted) { message('請到系統／瀏覽器設定開啟通知。'); paint(); return; }
      }
      const next = {...prefs, [key]: value};
      await checked(ctx.sb.from('notification_prefs').upsert({user_id: owner, ...next, updated_at: new Date().toISOString()}));
      if (uid !== owner) return;
      prefs = next;
      if (key === 'enabled') {
        if (value && !await register(false)) { paint(); return; }
        else if (!value) {
          await checked(ctx.sb.from('device_tokens').update({enabled: false}).eq('user_id', owner));
          if (native()) await plugin()?.unregister();
          else if ('serviceWorker' in navigator) await (await navigator.serviceWorker.ready).pushManager.getSubscription().then(s => s?.unsubscribe());
        }
      }
      message('通知設定已儲存。');
    } catch (_) { message('通知設定未能完成，請稍後再試。'); }
    paint();
  }
  async function afterCatch() {
    if (!uid || !supported()) return;
    const owner = uid;
    try { if (prefs?.enabled && await permission()) return; } catch (_) { return; }
    if (uid !== owner) return;
    try { if (localStorage.getItem('hk-push-asked:' + uid)) return; } catch (_) { return; }
    remember(); // Closing or declining is final; Settings always remains available.
    document.getElementById('push-explain')?.classList.add('show');
  }
  async function logout() {
    const owner = uid;
    uid = null; prefs = null;
    document.getElementById('push-explain')?.classList.remove('show');
    try {
      if (owner && currentToken) await checked(ctx.sb.from('device_tokens').delete().eq('user_id', owner).eq('token', currentToken));
    } finally {
      currentToken = null;
      if (native()) await plugin()?.unregister();
      else if ('serviceWorker' in navigator) await (await navigator.serviceWorker.ready).pushManager.getSubscription().then(s => s?.unsubscribe());
      paint();
    }
  }
  window.pushLib = {
    init(options) { ctx = options; },
    login(id) { uid = id; prefs = null; quiet(async () => { await refresh(); if (native() && supported()) await initNative(); if (prefs?.enabled && supported() && await permission()) await register(false); if (pendingRoute) { const r = pendingRoute; pendingRoute = null; route(r); } else { const q = new URLSearchParams(location.search); if (q.get('view') === 'leaderboard') route({lbType: q.get('lbType')}); } }); },
    refresh() { quiet(refresh); }, change, afterCatch, logout,
    enable() { document.getElementById('push-explain')?.classList.remove('show'); return change('enabled', true); },
    dismiss() { remember(); document.getElementById('push-explain')?.classList.remove('show'); }
  };
})();
