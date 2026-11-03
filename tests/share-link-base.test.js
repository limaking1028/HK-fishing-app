// 分享釣點連結：模擬 capacitor://localhost 同 https origin，抽 index.html 入面嘅 pageShareUrl + doSpotShare 跑
const fs = require('fs'), vm = require('vm'), path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
function grab(name) { const i = src.indexOf((name.startsWith('async') ? '' : 'function ') + name); const j = src.indexOf('\n}\n', i); return src.slice(i, j + 2); }
const code = src.match(/const APP_PUBLIC_URL = .*\n/)[0] + src.match(/function pageShareUrl\(\).*\n/)[0] + grab('async function doSpotShare');
let pass = 0, fail = 0; const check = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); c ? pass++ : fail++; };
async function run(loc) {
  const out = []; const spots = [{ name: '鰂魚涌海濱', lat: 22.2876, lng: 114.2153 }, { name: '西環碼頭', lat: 22.2866, lng: 114.1286 }];
  const ov = { querySelectorAll: () => spots.map((_, i) => ({ dataset: { i } })), classList: { remove() {} } };
  const ctx = { location: loc, _shareSpots: spots, getUserName: () => '阿明', toast() {}, closeSpotShare() {}, prompt() {},
    document: { getElementById: () => ov }, navigator: { share: async (d) => out.push(d.text) } };
  vm.createContext(ctx); vm.runInContext(code, ctx);
  await ctx.doSpotShare(); return { text: out[0], url: ctx.pageShareUrl() };
}
(async () => {
  const cap = await run({ protocol: 'capacitor:', origin: 'capacitor://localhost', pathname: '/' });
  check(cap.url === 'https://limaking1028.github.io/HK-fishing-app/', 'capacitor → 正式網址 ' + cap.url);
  check(cap.text.endsWith('\n\nhttps://limaking1028.github.io/HK-fishing-app/') && !cap.text.includes('capacitor:'), 'capacitor 分享文字結尾係正式網址、冇 capacitor://');
  const cap2 = await run({ protocol: 'capacitor:', origin: 'capacitor://localhost', pathname: '/index.html' });
  check(cap2.url === 'https://limaking1028.github.io/HK-fishing-app/', 'capacitor /index.html → 正式網址');
  const web = await run({ protocol: 'https:', origin: 'https://limaking1028.github.io', pathname: '/HK-fishing-app/' });
  check(web.url === 'https://limaking1028.github.io/HK-fishing-app/', 'https 照舊 origin+pathname');
  const web2 = await run({ protocol: 'http:', origin: 'http://127.0.0.1:8000', pathname: '/index.html' });
  check(web2.url === 'http://127.0.0.1:8000/index.html', 'http 本機照舊 origin+pathname（同改前一樣）');
  const expBody = '🎣 阿明 喺【釣港】分享咗釣點：\n\n📍 鰂魚涌海濱\n📍 西環碼頭\n\n';
  check(cap.text === expBody + cap.url && web.text === expBody + web.url, '分享文字內容不變（只係連結唔同）');
  check(![cap, web, web2].some(r => /22\.28|114\.\d/.test(r.text)), '冇 GPS 座標');
  console.log('RESULT', fail ? 'FAIL' : 'OK', pass + '/' + (pass + fail)); process.exit(fail ? 1 : 0);
})();
