const CACHE = 'hk-fishing-v53';  // bump: 排行榜第一名顯示「全港霸主」徽章
const CORE = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png', './apple-touch-icon.png',
  './lib/astronomy.js', './lib/fish-icons.js', './lib/trips.js', './lib/tides.js', './lib/weather.js', './lib/geo.js'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(CORE))
      .catch(() => {})
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  // 清掉所有舊 cache（包括 hk-fishing-v1）
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => {
        console.log('SW clearing old cache:', k);
        return caches.delete(k);
      }))
    ).then(() => self.clients.claim())
  );
});

// 網絡優先，離線用快取
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  // index.html 永遠唔快取，確保最新版本
  if (e.request.url.includes('index.html') || e.request.url.endsWith('/')) {
    e.respondWith(
      fetch(e.request).catch(() => caches.match('./index.html'))
    );
    return;
  }
  e.respondWith(
    fetch(e.request).then(res => {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
      return res;
    }).catch(() => caches.match(e.request).then(r => r || caches.match('./')))
  );
});