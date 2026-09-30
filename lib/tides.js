/* ============================================================
 *  lib/tides.js — 香港潮汐預報（純前端、離線可用）
 *
 *  數據源：香港天文台 HKO 年度潮汐表（已預載入 2026）
 *  公式：高低潮間餘弦插值（cosine interpolation）
 *        h(t) = h_lo + (h_hi - h_lo) × (1 - cos(π × dt/dur)) / 2
 *
 *  全域：window.tidesLib
 *  依賴：無（內嵌 tide-data.json）
 * ============================================================ */
(function() {
  'use strict';

  // 內嵌數據（避免額外 fetch，SW 會快取）
  let _DATA = null;
  function loadData() {
    if (_DATA) return _DATA;
    // 由內嵌的 <script id="tide-data-json"> 讀取
    try {
      const el = document.getElementById('tide-data-json');
      if (el) _DATA = JSON.parse(el.textContent);
      else _DATA = { stations: {}, spotMap: [], year: 2026 };
    } catch (e) {
      console.warn('tidesLib: 載入 tide-data.json 失敗', e);
      _DATA = { stations: {}, spotMap: [], year: 2026 };
    }
    return _DATA;
  }

  // ============================================================
  // 釣點 → 潮汐站映射
  // ============================================================
  function getStationForSpot(spot) {
    if (!spot) return 'QUB';  // 預設鰂魚涌
    const data = loadData();
    for (const { p, s } of data.spotMap) {
      for (const kw of p) {
        if (spot.includes(kw)) return s;
      }
    }
    return 'QUB';  // 預設
  }

  // ============================================================
  // 日期工具
  // ============================================================
  function dateKey(ms) {
    const d = new Date(ms);
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    return mm + dd;
  }
  function timeHHMM(ms) {
    const d = new Date(ms);
    return String(d.getHours()).padStart(2, '0') + String(d.getMinutes()).padStart(2, '0');
  }
  function makeDateMs(year, mmdd, hhmm) {
    const month = parseInt(mmdd.slice(0, 2), 10) - 1;
    const day = parseInt(mmdd.slice(2, 4), 10);
    const hour = parseInt(hhmm.slice(0, 2), 10);
    const min = parseInt(hhmm.slice(2, 4), 10);
    return new Date(year, month, day, hour, min, 0, 0).getTime();
  }
  function getYear() { return new Date().getFullYear(); }

  // ============================================================
  // 取高低潮事件（指定站 + 日期，跨午夜的話取前後日合併）
  // ============================================================
  function getDayEvents(stationCode, ms) {
    const data = loadData();
    const station = data.stations[stationCode];
    if (!station) return [];
    const d = new Date(ms);
    const year = d.getFullYear();
    const key = dateKey(ms);
    const dayData = station.days.find(x => x.d === key);
    if (!dayData) return [];
    return dayData.e.map(([t, h]) => ({
      ms: makeDateMs(year, key, t),
      height: h
    }));
  }

  // 取跨日嘅前後合併事件（保證有上/下一個潮汐）
  function getEventsAround(stationCode, ms) {
    const events = [];
    const before = new Date(ms - 86400000);
    const after = new Date(ms + 86400000);
    events.push(...getDayEvents(stationCode, before.getTime()));
    events.push(...getDayEvents(stationCode, ms));
    events.push(...getDayEvents(stationCode, after.getTime()));
    events.sort((a, b) => a.ms - b.ms);
    return events;
  }

  // ============================================================
  // 當前潮汐狀態（插值）
  // ============================================================
  function getCurrentTide(stationCode, nowMs) {
    const events = getEventsAround(stationCode, nowMs);
    if (events.length === 0) {
      return { height: null, trend: 'unknown', trendRate: 0, nextHigh: null, nextLow: null };
    }
    // 找包圍 nowMs 嘅前後兩個事件
    let prev = events[0], next = events[1];
    for (let i = 0; i < events.length - 1; i++) {
      if (events[i].ms <= nowMs && events[i+1].ms >= nowMs) {
        prev = events[i];
        next = events[i+1];
        break;
      }
      if (events[i].ms > nowMs) {  // 還未到首個事件
        prev = { ms: nowMs - 3600000, height: events[i].height };
        next = events[i];
        break;
      }
    }
    if (!prev || !next) {
      return { height: events[0].height, trend: 'unknown', trendRate: 0, nextHigh: null, nextLow: null };
    }
    // 餘弦插值
    const totalDur = next.ms - prev.ms;
    const dt = nowMs - prev.ms;
    const ratio = totalDur > 0 ? dt / totalDur : 0;
    const height = prev.height + (next.height - prev.height) * (1 - Math.cos(Math.PI * ratio)) / 2;
    // 趨勢（半小時後對比）
    const futureMs = nowMs + 1800000;
    const futureHeight = prev.height + (next.height - prev.height) * (1 - Math.cos(Math.PI * ((futureMs - prev.ms) / totalDur))) / 2;
    const trend = futureHeight > height ? 'rising' : 'falling';
    const trendRate = ((futureHeight - height) / 0.5).toFixed(2);  // m/hr
    // 下次高/低潮
    const nextHigh = events.find(e => e.ms > nowMs && e.height > (prev.height + next.height) / 2);
    const nextLow = events.find(e => e.ms > nowMs && e.height < (prev.height + next.height) / 2);
    return {
      height: Math.round(height * 100) / 100,
      trend,
      trendRate: parseFloat(trendRate),
      nextHigh: nextHigh ? { ms: nextHigh.ms, height: nextHigh.height } : null,
      nextLow: nextLow ? { ms: nextLow.ms, height: nextLow.height } : null,
    };
  }

  // ============================================================
  // 接落 N 個高低潮
  // ============================================================
  function getNextTides(stationCode, fromMs, count) {
    const events = getEventsAround(stationCode, fromMs);
    const future = events.filter(e => e.ms >= fromMs);
    return future.slice(0, count).map(e => {
      // 判斷高/低潮：相鄰事件中高度較高者為高潮
      const idx = events.indexOf(e);
      const prev = events[idx - 1];
      const next = events[idx + 1];
      const isHigh = (!prev || e.height > prev.height) && (!next || e.height > next.height);
      return {
        ms: e.ms,
        height: e.height,
        type: isHigh ? 'high' : 'low',
      };
    });
  }

  // ============================================================
  // 24 小時潮汐曲線（每小時一個點）
  // ============================================================
  function getTideCurve24h(stationCode, fromMs) {
    const events = getEventsAround(stationCode, fromMs);
    if (events.length === 0) return [];
    const points = [];
    for (let h = 0; h < 24; h++) {
      const t = fromMs + h * 3600000;
      const ct = getCurrentTide(stationCode, t);
      points.push({ ms: t, height: ct.height || 0 });
    }
    return points;
  }

  // ============================================================
  // 格式化
  // ============================================================
  function formatTime(ms) {
    const d = new Date(ms);
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }
  function formatTimeShort(ms) {
    const d = new Date(ms);
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }
  function formatDateShort(ms) {
    const d = new Date(ms);
    const today = new Date();
    today.setHours(0,0,0,0);
    const target = new Date(ms);
    target.setHours(0,0,0,0);
    const diff = (target - today) / 86400000;
    if (diff === 0) return '今日';
    if (diff === 1) return '明日';
    return (d.getMonth()+1) + '/' + d.getDate();
  }

  // ============================================================
  // 簡短描述（給 UI 用）
  // ============================================================
  function describeCurrent(stationCode, nowMs) {
    const t = getCurrentTide(stationCode, nowMs);
    if (t.height === null) return null;
    const trendText = t.trend === 'rising' ? '漲中' : t.trend === 'falling' ? '退中' : '平';
    const nextTxt = t.nextHigh
      ? `→ ${formatTime(t.nextHigh.ms)} 高潮 ${t.nextHigh.height}m`
      : '';
    return {
      height: t.height,
      trend: t.trend,
      trendText,
      trendRate: t.trendRate,
      nextHigh: t.nextHigh,
      nextLow: t.nextLow,
      summary: `${t.height}m ${trendText} ${nextTxt}`,
    };
  }

  // 簡易 SVG 曲線
  function curveSvg(points, width, height) {
    if (!points || points.length === 0) return '';
    const heights = points.map(p => p.height);
    const minH = Math.min(...heights);
    const maxH = Math.max(...heights);
    const range = maxH - minH || 1;
    const stepX = width / (points.length - 1);
    const padding = 4;
    const usableH = height - padding * 2;
    const pathD = points.map((p, i) => {
      const x = i * stepX;
      const y = padding + (1 - (p.height - minH) / range) * usableH;
      return (i === 0 ? 'M' : 'L') + x.toFixed(1) + ',' + y.toFixed(1);
    }).join(' ');
    return `<svg viewBox="0 0 ${width} ${height}" style="width:100%;height:auto;display:block">
      <path d="${pathD}" fill="none" stroke="#0a6e7a" stroke-width="2"/>
      <text x="2" y="11" font-size="9" fill="#666">${maxH.toFixed(1)}m</text>
      <text x="2" y="${height-2}" font-size="9" fill="#666">${minH.toFixed(1)}m</text>
    </svg>`;
  }

  // 匯出
  window.tidesLib = {
    loadData,
    getStationForSpot,
    getDayEvents,
    getCurrentTide,
    getNextTides,
    getTideCurve24h,
    describeCurrent,
    formatTime,
    formatDateShort,
    curveSvg,
  };
})();