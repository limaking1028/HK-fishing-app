// 天氣評分跟天文台風級（node --test）：邊界、PROPOSAL 6 個例子（4級 0 分）、顯示風級 = 評分風級
const test = require('node:test'), assert = require('node:assert');
global.window = {}; require('../lib/weather.js'); const L = window.weatherLib;
const base = { precip: 0, pressure: 1015, weatherCode: 1, temp: 24 };
const score = w => L.getFishingWeatherScore(Object.assign({}, base, w));

test('風級邊界（先四捨五入到整數 km/h）', () => {
  for (const [k, lv, name] of [[12.4, 2, '輕微'], [12.5, 3, '和緩'], [19.4, 3, '和緩'], [19.5, 4, '和緩'], [30.4, 4, '和緩'], [30.5, 5, '清勁'], [40.5, 6, '強風'], [51.5, 7, '強風'], [1.4, 0, '無風'], [117.4, 11, '暴風'], [118, 12, '颶風']]) {
    const b = L.beaufortLevel(k); assert.strictEqual(b.level, lv, k + ' km/h'); assert.strictEqual(b.name, name, k + ' km/h');
  }
});
test('每級風分數：0–2級 +25、3級 +15、4級 0、5級 −25、6級 −30、7級+ −40', () => {
  // 其他條件：雨 0（+15）、氣壓 1015（+15）→ 基本 80
  for (const [k, s] of [[1, 100], [12.4, 100], [12.5, 95], [19.4, 95], [19.5, 80], [30.4, 80], [30.5, 55], [40.5, 50], [51.5, 40], [80, 40]]) assert.strictEqual(score({ windSpeed: k }).score, s, k + ' km/h');
});
test('PROPOSAL 6 個例子（4級 0 分）', () => {
  assert.strictEqual(score({ windSpeed: 22.4 }).score, 80);                       // 西貢
  assert.strictEqual(score({ windSpeed: 19.8 }).score, 80);                       // 鰂魚涌
  assert.strictEqual(score({ windSpeed: 8, weatherCode: 0, temp: 25 }).score, 100);
  assert.strictEqual(score({ windSpeed: 35, precip: 4, pressure: 1008, weatherCode: 63, temp: 22 }).score, 10);
  const th = score({ windSpeed: 25, precip: 12, pressure: 1004, weatherCode: 95, temp: 27 });
  assert.strictEqual(th.score, 15); assert.ok(['較差', '不建議'].includes(th.label), th.label);
  const dz = score({ windSpeed: 10, precip: 0.1, weatherCode: 51, temp: 25 });
  assert.strictEqual(dz.score, 100); assert.ok(dz.reasons.some(r => r.text.startsWith('微量雨')));
  assert.ok(!dz.reasons.some(r => r.text.includes('無降雨')));
});
test('雷暴：評級最多「較差」', () => {
  const r = score({ windSpeed: 8, weatherCode: 95 });   // 冇上限會係 80
  assert.strictEqual(r.label, '較差'); assert.ok(r.score <= 44);
});
test('降雨文字', () => {
  assert.deepStrictEqual([0, 0.1, 0.29, 0.3, 2.9, 3, 45].map(p => L.rainInfo(p).short), ['無降雨', '微量雨', '微量雨', '小雨', '小雨', '大雨', '大雨']);
});
test('顯示風級 = 評分風級，冇舊字眼', () => {
  for (let k = 0; k <= 130; k += 0.3) {
    const b = L.beaufortLevel(k), t = score({ windSpeed: k }).reasons[0].text;
    assert.ok(t.startsWith(`${b.level}級 ${b.name}（${Math.round(k)} km/h）`), k + ': ' + t);
    assert.ok(!/微風|中風/.test(t), t);
  }
});

// 暴雨：用 hourly 同一個香港鐘數嘅雨量（≥ 30mm −25，取代大雨 −15）
const raw = (cur, hp) => ({ current: { time: '2026-11-03T11:30', precipitation: cur, wind_speed_10m: 8, weather_code: 63, pressure_msl: 1015, temperature_2m: 24 },
  hourly: hp === undefined ? undefined : { time: ['2026-11-03T10:00', '2026-11-03T11:00', '2026-11-03T12:00'], precipitation: hp } });
test('暴雨：hourly 29.9 vs 30（揀返 11:00 嗰格），唔同大雨疊加', () => {
  const a = L.parseWeather(raw(8, [99, 29.9, 99])).now, b = L.parseWeather(raw(8, [0, 30, 0])).now;
  assert.strictEqual(a.precipHour, 29.9); assert.strictEqual(b.precipHour, 30);
  const sa = L.getFishingWeatherScore(a), sb = L.getFishingWeatherScore(b);
  assert.strictEqual(L.rainInfo(a.precip, a.precipHour).short, '大雨'); assert.strictEqual(L.rainInfo(b.precip, b.precipHour).short, '暴雨');
  assert.strictEqual(sa.score - sb.score, 10);   // −15 → −25
  assert.ok(sb.reasons.some(r => r.text.startsWith('暴雨')) && !sb.reasons.some(r => r.text.startsWith('大雨')));
  assert.ok(sb.reasons.some(r => r.text === '暴雨（過去一小時 30.0 mm，達黃雨標準），不建議出釣'));
  assert.strictEqual(L.rainInfo(9, 35).text, '暴雨（過去一小時 35.0 mm，達黃雨標準），不建議出釣');
  assert.ok(!/嗰個鐘|唔好/.test(L.rainInfo(9, 35).text));
});
test('冇 hourly／舊 cache（冇 precipHour）：照 15 分鐘雨量分級，唔出錯', () => {
  const n = L.parseWeather(raw(8)).now; assert.strictEqual(n.precipHour, null);
  assert.strictEqual(L.rainInfo(n.precip, n.precipHour).short, '大雨');
  const old = { time: 0, temp: 24, precip: 0.1, weatherCode: 1, windSpeed: 8, pressure: 1015 };   // v192 cache 格式
  assert.strictEqual(L.getFishingWeatherScore(old).score, 100); assert.strictEqual(L.rainInfo(old.precip, old.precipHour).short, '微量雨');
});
