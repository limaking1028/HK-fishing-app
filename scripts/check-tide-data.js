#!/usr/bin/env node
/* ============================================================
 *  scripts/check-tide-data.js — 檢查 index.html 內嵌潮汐數據
 *
 *  用法：
 *    node scripts/check-tide-data.js                       # 結構檢查
 *    node scripts/check-tide-data.js --official=off.json   # 同官方 PDF 提取結果逐日對比
 *    加 --strict：有任何錯誤就非零退出（可放入發布前檢查）
 *
 *  注意：香港潮汐有時一日只得 2–3 個事件，係官方表本身嘅數據，唔係缺漏；
 *        所以結構檢查只會報「完全冇事件」或者「超過 4 個」等真正異常。
 *  off.json 由 scripts/extract-tide-pdf.py 生成。
 * ============================================================ */
'use strict';
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const strict = args.includes('--strict');
const officialArg = (args.find(a => a.startsWith('--official=')) || '').split('=')[1];

// App 站點代碼 → 官方站名（英文，同 PDF 一致）。null = 冇官方表，借用其他站，唔比對
const APP_TO_OFFICIAL = {
  QUB: 'QUARRY BAY', TPK: 'TAI PO KAU', CCH: 'CHEUNG CHAU', TAO: 'TAI O',
  SPW: 'SHEK PIK', TBT: 'TSIM BEI TSUI', CHK: 'CHEK LAP KOK', KCQ: 'KWAI CHUNG',
  SAI: null, LAM: null, PEN: null, TCT: null
};

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const m = /<script id="tide-data-json"[^>]*>([\s\S]*?)<\/script>/.exec(html);
if (!m) { console.error('找不到 <script id="tide-data-json">'); process.exit(2); }
const data = JSON.parse(m[1]);
const year = data.year;
const isLeap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
const expectDays = isLeap ? 366 : 365;
let errors = 0, notes = 0;

console.log(`潮汐數據年份：${year}（應有 ${expectDays} 日）　站數：${Object.keys(data.stations).length}`);

// ---- 結構檢查 ----
for (const code of Object.keys(data.stations)) {
  const days = data.stations[code].days || [];
  const counts = {};
  days.forEach(d => { counts[d.e.length] = (counts[d.e.length] || 0) + 1; });
  const zero = days.filter(d => d.e.length === 0).map(d => d.d);
  const many = days.filter(d => d.e.length > 4).map(d => d.d);
  if (days.length !== expectDays) { errors++; console.log(`❌ ${code}：日數 ${days.length}，應為 ${expectDays}`); }
  if (zero.length) { errors++; console.log(`❌ ${code}：${zero.length} 日完全冇事件：${zero.slice(0, 8).join(' ')}`); }
  if (many.length) { errors++; console.log(`❌ ${code}：${many.length} 日事件超過 4 個：${many.slice(0, 8).join(' ')}`); }
  console.log(`   ${code.padEnd(4)} 每日事件數分佈 ${JSON.stringify(counts)}`);
}

// ---- 同官方 PDF 逐日對比 ----
if (officialArg) {
  const off = JSON.parse(fs.readFileSync(officialArg, 'utf8'));
  console.log(`\n對比官方數據：${officialArg}`);
  for (const code of Object.keys(data.stations)) {
    const name = APP_TO_OFFICIAL[code];
    if (!name) { notes++; console.log(`   ${code.padEnd(4)} 冇官方表，借用其他站（略過）`); continue; }
    if (!off[name]) { errors++; console.log(`❌ ${code}：官方數據入面冇 ${name}`); continue; }
    const od = off[name].days;
    let diffTime = 0, diffHeight = 0, ex = [];
    for (const d of data.stations[code].days) {
      const o = od[d.d] || [];
      const at = d.e.map(x => x[0]).join(','), ot = o.map(x => x[0]).join(',');
      if (at !== ot) { diffTime++; if (ex.length < 4) ex.push(`${d.d} app[${at}] 官方[${ot}]`); continue; }
      if (d.e.some((x, i) => Math.abs(x[1] - o[i][1]) > 0.051)) diffHeight++;
    }
    if (diffTime || diffHeight) errors++;
    console.log(`${diffTime || diffHeight ? '❌' : '✅'} ${code.padEnd(4)} ↔ ${name}：時間不符 ${diffTime} 日，潮高不符 ${diffHeight} 日${ex.length ? '\n      ' + ex.join('\n      ') : ''}`);
  }
}

console.log(errors ? `\n❌ 發現 ${errors} 項問題` : '\n✅ 通過檢查' + (notes ? `（${notes} 個站借用其他站，未比對）` : ''));
if (strict && errors) process.exit(1);
