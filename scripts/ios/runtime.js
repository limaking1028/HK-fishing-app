/* Loaded before every app script in iOS output only. No production fallback. */
(function () {
  'use strict';
  const expected = window.HKF_BUILD;
  const m = window.HKF_MANIFEST;
  function fail() {
    document.documentElement.innerHTML = '<head><meta charset="utf-8"></head><body><h1>環境設定錯誤</h1><p>無法啟動，請重新安裝正確版本。</p></body>';
    window.stop();
    throw new Error('HKF environment refused');
  }
  if (!m || !expected || m.env !== expected.env || m.ref !== expected.ref ||
      m.url !== 'https://' + expected.ref + '.supabase.co' || !m.anonKey || m.anonKey.length < 21) fail();
  if (m.anonKey.startsWith('eyJ')) {
    try {
      const claims = JSON.parse(atob(m.anonKey.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
      if (claims.ref !== expected.ref || claims.role !== 'anon') fail();
    } catch (_) { fail(); }
  } else if (!m.anonKey.startsWith('sb_publishable_')) fail();
  Object.freeze(m);
  const prefix = 'hkf:v2:' + m.env + ':' + m.ref + ':';
  let owner = 'anon';
  const raw = window.localStorage;
  const session = window.sessionStorage;
  const enc = s => encodeURIComponent(String(s));
  const key = (name, who = owner) => prefix + enc(who) + ':' + enc(name);
  const names = store => Array.from({length: store.length}, (_, i) => store.key(i));
  // Only keys with an explicit migration policy may read legacy values in prod.
  const deviceKeys = new Set(['hk_fishing_weight_unit', 'wx_last_good_v1', 'maptiler_key', 'map_show_tide', 'hk-fishing-analytics-consent', 'hkf-seen', 'hkf-share-c']);
  const userKeys = new Set(['hk_fishing_unsynced_v1', 'hk_fishing_catches_v5', 'hk_fishing_tallies_v1', 'hk_fishing_active_trip', 'hk_fishing_username', 'hk-fishing-pinned-species', 'hk_fishing_imported_v1', 'hkf-tutorial-seen']);
  function migrate(name) {
    if (m.env !== 'prod') return null;
    if (deviceKeys.has(name)) return raw.getItem(name);
    if (owner === 'anon' || !userKeys.has(name)) return null;
    if (name === 'hk_fishing_unsynced_v1') {
      try { return JSON.stringify(JSON.parse(raw.getItem(name) || '[]').filter(c => c && c.userId === owner)); } catch (_) { return null; }
    }
    // Ownerless trip/tally data may only belong to the last legacy signed-in user.
    let legacyOwner = raw.getItem('hk_fishing_user_id');
    if (!legacyOwner) {
      try { legacyOwner = JSON.parse(raw.getItem('sb-' + m.ref + '-auth-token') || 'null')?.user?.id; } catch (_) {}
    }
    if (legacyOwner !== owner) return null;
    return raw.getItem(name);
  }
  function adapter(store, persistent) {
    return {
      getItem(name) {
        const k = key(name, deviceKeys.has(name) ? 'device' : owner);
        let v = store.getItem(k);
        if (v === null && persistent) {
          v = migrate(name);
          if (v !== null) store.setItem(k, v);
        }
        return v;
      },
      setItem(name, value) { store.setItem(key(name, deviceKeys.has(name) ? 'device' : owner), String(value)); },
      // Tombstones prevent a preserved legacy value being imported again after sync/delete.
      removeItem(name) { store.setItem(key(name, deviceKeys.has(name) ? 'device' : owner), ''); }
    };
  }
  const authKey = key('session', 'auth');
  const authStorage = {
    getItem(k) {
      if (!k.startsWith(prefix + 'auth:')) throw new Error('Auth storage refused');
      let v = raw.getItem(k);
      if (v === null && m.env === 'prod' && k === authKey) {
        v = raw.getItem('sb-' + m.ref + '-auth-token');
        if (v !== null) raw.setItem(k, v);
      }
      return v;
    },
    setItem(k, v) { if (!k.startsWith(prefix + 'auth:')) throw new Error('Auth storage refused'); raw.setItem(k, v); },
    removeItem(k) { if (!k.startsWith(prefix + 'auth:')) throw new Error('Auth storage refused'); raw.setItem(k, ''); }
  };
  window.HKF = {
    manifest: m, key, local: adapter(raw, true), session: adapter(session, false),
    setOwner(id) { owner = id || 'anon'; },
    legacyCount() { return names(raw).filter(k => /^(hk[_-]|hkf-|sb-|wx_last_good|maptiler_key|map_show_tide)/.test(k)).length; },
    clearOwner() {
      const p = prefix + enc(owner) + ':';
      for (const store of [raw, session]) for (const k of names(store)) if (k.startsWith(p)) store.setItem(k, '');
      for (const name of userKeys) raw.setItem(key(name), '');
      raw.setItem(authKey, '');
    },
    createClient(lib, flowType) {
      if (!lib) throw new Error('Supabase library missing');
      return lib.createClient(m.url, m.anonKey, {auth: {persistSession: true, autoRefreshToken: true,
        storage: authStorage, storageKey: authKey, flowType: flowType || 'pkce', detectSessionInUrl: false}});
    }
  };
})();
