// 釣港 分享預覽 Worker（v166；v173 加：分享連結打開次數總數，冇 IP／位置）
// GET /c/<token> → 回傳有 og:title / og:description / og:image 嘅 HTML，再跳去 App（APP_URL?c=<token>）。
// 只用 anon key 調用公開 RPC share_catch_get（佢只回傳 魚種／重量／釣點／地區／日期／排名）。
// 永不使用 service-role key。冇用戶名、GPS、備註、相。

const TOKEN_RE = /^[A-Za-z0-9_-]{12}$/;
const SRC_RE = /^[a-z]{1,10}$/;   // v173：?src=fb/ig/yt/wa…（伺服器再用白名單過濾）
// v173：預覽機械人（WhatsApp／FB／Telegram 等）讀預覽唔計，只計真人打開
const BOT_RE = /bot|crawl|spider|facebookexternalhit|facebookcatalog|whatsapp|telegram|twitterbot|slackbot|discord|linkedin|skype|line\/|preview|headless/i;

export function isBot(ua) { return !ua || BOT_RE.test(ua); }

async function trackOpen(env, src) {
  // 只送事件名同來源；冇 IP、冇 UA、冇 token
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  await fetch(base + '/rest/v1/rpc/track_event', {
    method: 'POST',
    headers: { 'content-type': 'application/json', apikey: env.SUPABASE_ANON_KEY, authorization: 'Bearer ' + env.SUPABASE_ANON_KEY },
    body: JSON.stringify({ p_event: 'share_open', p_src: src }),
  }).catch(() => {});
}

const PERIOD = { all: '全部時間', year: '今年', quarter: '今季', month: '今個月' };

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"'`]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;', '`': '&#96;' }[c]));
}
function fmtKg(kg) {
  const n = Number(kg);
  if (!isFinite(n) || n <= 0) return '';
  return (n < 1 ? Math.round(n * 1000) + 'g' : n.toFixed(2).replace(/\.?0+$/, '') + 'kg') + '（' + (n * 1000 / 604.79).toFixed(1) + ' 斤）';   // v166：同 App 分享文字一致（1 斤 = 604.79 克）
}
function bestRank(ranks) {
  return (Array.isArray(ranks) ? ranks : [])
    .filter(r => r && Number.isInteger(r.rank) && r.rank > 0 && PERIOD[r.period])
    .sort((a, b) => a.rank - b.rank)[0] || null;
}

export function buildMeta(d) {
  // d = share_catch_get 結果（或 null）
  if (!d || typeof d !== 'object' || !d.species) {
    return { title: '釣港 🎣 香港釣魚記錄＋排行榜', desc: '記低每條魚獲，同釣友鬥排行榜。撳入嚟睇！' };
  }
  const w = fmtKg(d.weight_kg);
  const r = bestRank(d.ranks);
  const title = '🎣 ' + String(d.species).slice(0, 30) + (w ? ' ' + w : '') + (r ? '｜' + PERIOD[r.period] + '第 ' + r.rank + ' 名' : '');
  const place = String(d.area || d.spot || '').slice(0, 40);
  const date = /^\d{4}-\d{2}-\d{2}$/.test(String(d.date || '')) ? d.date : '';
  const desc = [place, date].filter(Boolean).join('・') + (place || date ? '，' : '') + '撳入釣港睇排行榜';
  return { title, desc };
}

export function renderHtml({ title, desc, image, pageUrl, target }) {
  const t = esc(title), d = esc(desc), img = esc(image), u = esc(pageUrl), to = esc(target);
  return '<!doctype html><html lang="zh-HK"><head><meta charset="utf-8">'
    + '<meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>' + t + '</title>'
    + '<meta name="description" content="' + d + '">'
    + '<meta property="og:type" content="website">'
    + '<meta property="og:site_name" content="釣港">'
    + '<meta property="og:title" content="' + t + '">'
    + '<meta property="og:description" content="' + d + '">'
    + '<meta property="og:url" content="' + u + '">'
    + '<meta property="og:image" content="' + img + '">'
    + '<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:type" content="image/jpeg">'
    + '<meta name="twitter:card" content="summary_large_image">'
    + '<meta name="twitter:title" content="' + t + '"><meta name="twitter:description" content="' + d + '"><meta name="twitter:image" content="' + img + '">'
    + '<meta http-equiv="refresh" content="0;url=' + to + '">'
    + '<meta name="robots" content="noindex">'
    + '</head><body style="font-family:sans-serif;text-align:center;padding:40px 16px;">'
    + '<h1 style="font-size:20px;">' + t + '</h1><p>' + d + '</p>'
    + '<p><a href="' + to + '">打開釣港 App</a></p>'
    + '<script>location.replace(' + JSON.stringify(target).replace(/</g, '\\u003c') + ');</script>'
    + '</body></html>';
}

async function fetchShare(env, token) {
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  const res = await fetch(base + '/rest/v1/rpc/share_catch_get', {
    method: 'POST',
    headers: { 'content-type': 'application/json', apikey: env.SUPABASE_ANON_KEY, authorization: 'Bearer ' + env.SUPABASE_ANON_KEY },
    body: JSON.stringify({ p_token: token }),
  });
  if (!res.ok) return null;
  const j = await res.json().catch(() => null);
  return j && typeof j === 'object' && !Array.isArray(j) ? j : null;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const app = String(env.APP_URL || '').replace(/\/?$/, '/');
    const image = app + 'og-image-v2.jpg';
    if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405 });
    const m = url.pathname.match(/^\/c\/([^/]+)\/?$/);
    const token = m && TOKEN_RE.test(m[1]) ? m[1] : null;
    let data = null;
    if (token) { try { data = await fetchShare(env, token); } catch (e) { data = null; } }
    const rawSrc = (url.searchParams.get('src') || '').toLowerCase();
    const src = SRC_RE.test(rawSrc) ? rawSrc : null;
    const target = token && data ? app + '?c=' + token + (src ? '&src=' + src : '') : app;
    if (token && data && request.method === 'GET' && !isBot(request.headers.get('user-agent')) && ctx && ctx.waitUntil) {
      ctx.waitUntil(trackOpen(env, src));
    }
    const html = renderHtml({ ...buildMeta(data), image, pageUrl: token && data ? url.origin + '/c/' + token : app, target });
    return new Response(request.method === 'HEAD' ? null : html, {
      status: 200,
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'public, max-age=300',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
      },
    });
  },
};
