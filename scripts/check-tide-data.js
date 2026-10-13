#!/usr/bin/env node
/* ============================================================
 *  scripts/check-tide-data.js — 檢查內嵌潮汐數據是否齊全
 *  用法：node scripts/check-tide-data.js [--strict] [--year=2027]
 *    --strict  有任何日子事件少於 4 個就以非零退出（可以放入發布前檢查）
 *    --year=N  檢查指定年份（預設：數據內嵌嘅年份）
 *  正常香港潮汐每日兩高兩低（4 個事件）；少於 4 個代表提取時漏咗事件。
 * ============================================================ */
'use strict';
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const strict = args.includes('--strict');
const yearArg = (args.find(a => a.startsWith('--year=')) || '').split('=')[1];

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const m = /<script id="tide-data-json"[^>]*>([\s\S]*?)<\/script>/.exec(html);
if (!m) { console.error('找不到 <script id="tide-data-json">'); process.exit(2); }
const data = JSON.parse(m[1]);
const year = Number(yearArg) || data.year;
const stations = Object.keys(data.stations || {});

let problems = 0;
console.log(`潮汐數據年份：${data.year}　檢查年份：${year}　站數：${stations.length}`);
for (const code of stations) {
  const days = data.stations[code].days || [];
  const isLeap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  const expected = isLeap ? 366 : 365;
  const short = days.filter(d => d.e.length < 4);
  const missingDays = expected - days.length;
  const bad = short.length + Math.max(0, missingDays);
  problems += bad;
  const sample = short.slice(0, 5).map(d => `${d.d}(${d.e.length})`).join(' ');
  console.log(`${code.padEnd(4)} 日數 ${days.length}/${expected}　少於4個事件 ${short.length} 日${sample ? '　例：' + sample : ''}`);
}
console.log(problems ? `⚠️ 共 ${problems} 項需要留意（缺日或事件不齊）` : '✅ 數據齊全');
if (strict && problems) process.exit(1);
