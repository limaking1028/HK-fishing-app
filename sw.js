const CACHE = 'hk-fishing-v105';  // bump: 新增重量單位切換（兩/斤）
const CORE = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png', './apple-touch-icon.png',
  './lib/astronomy.js', './lib/fish-icons.js', './lib/trips.js', './lib/tides.js', './lib/weather.js', './lib/geo.js',
  './lib/catchStats.js',  // Route L+
  './lib/auth.js'         // Email Magic Link
];

self.addEventListener('install', e => {
  console.log('[SW v101] Installing...');
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(CORE))
      .catch(err => console.warn('[SW v101] cache addAll failed:', err))
      .then(() => {
        console.log('[SW v101] skipWaiting');
        return self.skipWaiting();
      })
  );
});

self.addEventListener('activate', e => {
  console.log('[SW v101] Activating, removing old caches...');
  e.waitUntil(
    caches.keys().then(keys => {
      return Promise.all(
        keys.filter(k => k !== CACHE).map(k => {
          console.log('[SW v101] Deleting old cache:', k);
          return caches.delete(k);
        })
      );
    }).then(() => {
      console.log('[SW v101] claim clients');
      return self.clients.claim();
    })
  );
});

// 網絡優先，離線用快取
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  // index.html (任何 query string) 永遠走網絡,確保最新版本
  if (url.pathname.endsWith('/index.html') || url.pathname.endsWith('/')) {
    e.respondWith(
      fetch(e.request, { cache: 'no-store' })
        .catch(() => caches.match('./index.html'))
    );
    return;
  }
  // 其他檔案:網絡優先,失敗用快取
  e.respondWith(
    fetch(e.request).then(res => {
      // 只 cache 成功嘅 2xx response
      if (res.ok) {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
      }
      return res;
    }).catch(() => caches.match(e.request).then(r => r || caches.match('./')))
  );
});
