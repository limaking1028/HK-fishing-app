const CACHE = 'hk-fishing-v180';  // v180: 只快取魚種相（WebP），其他請求一律唔掂
// v180：v102 起 SW 停用（舊版網絡優先快取 index/lib 引起問題）。今次重開，但只處理 photos/*.webp：
//   install 時 precache 魚種相；fetch 只對魚種相 cache-first；其他請求唔 respondWith，行返瀏覽器正常網絡。
//   activate 時刪走所有舊 cache（包括 v101–v179 留低嘅）。
const FISH_PHOTOS = ["./photos/䱛仔.webp", "./photos/三刀.webp", "./photos/左口.webp", "./photos/星點泥鯭.webp", "./photos/梳羅.webp", "./photos/沙巴龍躉.webp", "./photos/沙鑽.webp", "./photos/油蠟.webp", "./photos/泥鯭.webp", "./photos/海狼.webp", "./photos/火點.webp", "./photos/烏頭.webp", "./photos/牙點.webp", "./photos/牛屎鱲.webp", "./photos/牛廣GT.webp", "./photos/牛鰍.webp", "./photos/白鬚公.webp", "./photos/白鱲.webp", "./photos/盲鰽.webp", "./photos/石剎.webp", "./photos/石狗公.webp", "./photos/紅衫魚.webp", "./photos/花鱸.webp", "./photos/赤鱲.webp", "./photos/金鼓.webp", "./photos/釘公.webp", "./photos/雞泡.webp", "./photos/雞魚.webp", "./photos/青斑.webp", "./photos/馬友.webp", "./photos/黃立鯧.webp", "./photos/黃腳鱲.webp", "./photos/黑鱲.webp"];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => Promise.all(FISH_PHOTOS.map(u => c.add(u).catch(() => {}))))   // 一張失敗唔阻 install
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin || !url.pathname.includes('/photos/') || !url.pathname.endsWith('.webp')) return;
  e.respondWith(caches.match(e.request, { ignoreSearch: true }).then(r => r || fetch(e.request).then(res => {
    if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
    return res;
  })));
});
