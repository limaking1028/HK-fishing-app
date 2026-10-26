/* ============================================================
 *  lib/myStats.js — v142「我的統計」（基本版）
 *  純函式：由用戶自己嘅魚獲同行程計出簡單統計，唔連網、唔寫資料庫
 *  全域：window.myStatsLib.compute(catches, trips, { periodDays, nowMs })
 * ============================================================ */
(function () {
  'use strict';

  const HK_OFFSET = 8 * 3600e3;
  const hkDate = ms => new Date(ms + HK_OFFSET).toISOString().slice(0, 10);

  // 時段（按魚獲時間，香港時間）
  const SLOTS = [
    { key: 'night0', label: '凌晨', range: '00–05', from: 0, to: 5 },
    { key: 'dawn', label: '清晨', range: '05–08', from: 5, to: 8 },
    { key: 'morning', label: '上午', range: '08–12', from: 8, to: 12 },
    { key: 'afternoon', label: '下午', range: '12–16', from: 12, to: 16 },
    { key: 'dusk', label: '黃昏', range: '16–19', from: 16, to: 19 },
    { key: 'night', label: '夜晚', range: '19–24', from: 19, to: 24 }
  ];

  const mainSpot = s => String(s || '').split('（')[0].trim() || '未填釣點';

  function topN(map, n, extra) {
    return Object.keys(map)
      .map(k => Object.assign({ name: k }, map[k]))
      .sort((a, b) => b.n - a.n || (b.maxKg || 0) - (a.maxKg || 0) || a.name.localeCompare(b.name))
      .slice(0, n)
      .map(extra || (x => x));
  }

  function compute(allCatches, allTrips, opts) {
    const o = opts || {};
    const now = o.nowMs || Date.now();
    const sinceDate = o.periodDays ? hkDate(now - o.periodDays * 864e5) : null;
    const sinceMs = o.periodDays ? now - o.periodDays * 864e5 : null;

    const catches = (allCatches || []).filter(c =>
      c && c.isMine && !c.isDemo && c.date && (!sinceDate || c.date >= sinceDate));
    const trips = (allTrips || []).filter(t => {
      if (!t || t.isDemo) return false;
      const st = new Date(t.startedAt || t.started_at).getTime();
      return !isNaN(st) && (!sinceMs || st >= sinceMs);
    });

    // ---- 總覽 ----
    let totalKg = 0;
    const speciesSet = new Set();
    catches.forEach(c => { totalKg += Number(c.weight) || 0; if (c.species) speciesSet.add(c.species); });

    // ---- 出釣表現（只計已結束嘅行程）----
    const linked = {};
    catches.forEach(c => { const id = c.tripId || c.trip_id; if (id) linked[id] = (linked[id] || 0) + 1; });
    const ended = trips.filter(t => t.endedAt || t.ended_at);
    let withFish = 0, fishSum = 0, secSum = 0;
    const tripSpot = {};
    ended.forEach(t => {
      const n = Math.max(Number(t.catchCount || t.catch_count) || 0, linked[t.id] || 0);
      if (n > 0) withFish++;
      fishSum += n;
      const s = new Date(t.startedAt || t.started_at).getTime();
      const e = new Date(t.endedAt || t.ended_at).getTime();
      if (e > s) secSum += Math.min((e - s) / 1000, 24 * 3600);  // 忘記結束嘅行程最多當 24 小時
      const sp = mainSpot(t.spot);
      tripSpot[sp] = (tripSpot[sp] || 0) + 1;
    });
    const tripStats = {
      count: ended.length,
      active: trips.length - ended.length,
      withFish,
      rate: ended.length ? Math.round(withFish / ended.length * 100) : null,
      avgCatch: ended.length ? Math.round(fishSum / ended.length * 10) / 10 : null,
      avgSec: ended.length ? Math.round(secSum / ended.length) : null
    };

    // ---- 每月（最近 6 個月，包括本月）----
    const monthly = [];
    const cur = new Date(now + HK_OFFSET);
    for (let i = 5; i >= 0; i--) {
      const d = new Date(Date.UTC(cur.getUTCFullYear(), cur.getUTCMonth() - i, 1));
      const key = d.toISOString().slice(0, 7);
      monthly.push({ key, label: (d.getUTCMonth() + 1) + '月', n: 0 });
    }
    const allMine = (allCatches || []).filter(c => c && c.isMine && !c.isDemo && c.date);
    allMine.forEach(c => { const m = monthly.find(x => x.key === c.date.slice(0, 7)); if (m) m.n++; });

    // ---- 時段 ----
    const slots = SLOTS.map(s => ({ key: s.key, label: s.label, range: s.range, n: 0 }));
    let timed = 0;
    catches.forEach(c => {
      const m = /^(\d{1,2}):/.exec(c.time || '');
      if (!m) return;
      const h = Number(m[1]);
      const i = SLOTS.findIndex(s => h >= s.from && h < s.to);
      if (i >= 0) { slots[i].n++; timed++; }
    });

    // ---- 釣點、魚種、釣法、魚餌 ----
    const spotMap = {}, spMap = {}, methodMap = {}, baitMap = {};
    catches.forEach(c => {
      const kg = Number(c.weight) || 0;
      const sp = mainSpot(c.spot);
      spotMap[sp] = spotMap[sp] || { n: 0, maxKg: 0 };
      spotMap[sp].n++; spotMap[sp].maxKg = Math.max(spotMap[sp].maxKg, kg);
      if (c.species) {
        spMap[c.species] = spMap[c.species] || { n: 0, maxKg: 0, icon: c.speciesIcon || '🐟' };
        spMap[c.species].n++; spMap[c.species].maxKg = Math.max(spMap[c.species].maxKg, kg);
      }
      if (c.method) { methodMap[c.method] = methodMap[c.method] || { n: 0 }; methodMap[c.method].n++; }
      if (c.bait) { baitMap[c.bait] = baitMap[c.bait] || { n: 0 }; baitMap[c.bait].n++; }
    });

    return {
      catchCount: catches.length,
      totalKg: Math.round(totalKg * 100) / 100,
      speciesCount: speciesSet.size,
      trips: tripStats,
      monthly,
      slots,
      timedCount: timed,
      spots: topN(spotMap, 5, x => Object.assign(x, { trips: tripSpot[x.name] || 0 })),
      species: topN(spMap, 5),
      methods: topN(methodMap, 3),
      baits: topN(baitMap, 3)
    };
  }

  const api = { compute, SLOTS, mainSpot };
  if (typeof window !== 'undefined') window.myStatsLib = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})();
