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

  // SVG 曲線（中文化時間軸 + 米單位 + 大 marker + 標籤 chip）
  function curveSvg(points, width, height, opts) {
    opts = opts || {};
    if (!points || points.length === 0) return '';
    const heights = points.map(p => p.height);
    const minH = Math.min(...heights);
    const maxH = Math.max(...heights);
    const range = maxH - minH || 1;
    const padding = 8;
    const leftAxis = 30;        // 左邊 height 刻度寬度（加大放「米」字）
    const timeAxisH = 18;       // 底部時間軸高度
    const topPad = 18;          // 預留 NOW / 高潮 label 空間
    const plotW = width - leftAxis - 4;
    const plotH = height - padding - topPad - timeAxisH;
    const stepX = plotW / (points.length - 1);

    // 1. 曲線 path
    const pathD = points.map((p, i) => {
      const x = leftAxis + i * stepX;
      const y = topPad + (1 - (p.height - minH) / range) * plotH;
      return (i === 0 ? 'M' : 'L') + x.toFixed(1) + ',' + y.toFixed(1);
    }).join(' ');
    // 2. Fill area
    const fillD = pathD + ` L ${(leftAxis+plotW).toFixed(1)},${(topPad+plotH).toFixed(1)} L ${leftAxis},${(topPad+plotH).toFixed(1)} Z`;

    // 3. Height 刻度（max / mid / min，附「米」單位）
    const gridLines = [
      { y: topPad,                label: maxH.toFixed(1) },
      { y: topPad + plotH/2,      label: ((maxH+minH)/2).toFixed(1) },
      { y: topPad + plotH,        label: minH.toFixed(1) }
    ];

    // 4. 時間軸（中文化）
    const baseMs = points[0].ms;
    const totalMs = points[points.length - 1].ms - baseMs;
    const timeLabels = [
      { ratio: 0,    text: '現在'  },
      { ratio: 0.25, text: '+6時'  },
      { ratio: 0.5,  text: '+12時' },
      { ratio: 0.75, text: '+18時' },
      { ratio: 1,    text: '+24時' }
    ];

    // 5. 高 / 低潮 markers（opts.events = [{ms, height, type}]）
    //    大 ▲▼ icon + 白色 outline + 白底圓角 label chip 顯示「HH:MM 高度」
    //    高潮 → label 喺 marker 上面；低潮 → 喺下面
    //    NOW chip 固定左上角，與高潮 label 同區域 → 加避讓邏輯
    let hasNowChip = (opts.nowMs !== undefined);
    const eventMarkers = (opts.events || []).map(e => {
      const ratio = (e.ms - baseMs) / totalMs;
      if (ratio < -0.05 || ratio > 1.05) return '';
      const x = leftAxis + Math.max(0, Math.min(1, ratio)) * plotW;
      const y = topPad + (1 - (e.height - minH) / range) * plotH;
      const isHigh = e.type === 'high';
      const color = isHigh ? '#f97316' : '#0d9488';
      const sym = isHigh ? '▲' : '▼';
      const timeStr = formatTime(e.ms);
      const hStr = e.height.toFixed(2);
      const labelText = `${timeStr} ${hStr}`;
      const labelH = 13;
      const charW = 5.4;
      const labelW = labelText.length * charW + 8;
      // 預設位置：高潮 → marker 上面；低潮 → 下面
      let labelCy = isHigh ? y - 14 : y + 18;
      // 避讓 NOW chip（左上角 ~ width 90, y 0-18 區域）：
      // 高潮 label 喺 plot 前 1/4 + 落入 NOW chip 區域 → 改放 marker 下方
      const nowChipW = hasNowChip ? 90 : 0;
      const nowChipX1 = 4, nowChipX2 = 4 + nowChipW;
      if (isHigh && x >= nowChipX1 && x <= nowChipX2 && labelCy < 20) {
        labelCy = y + 18;
      }
      // 限制喺 plot 範圍（避免出界）
      const minY = topPad + labelH / 2 + 2;
      const maxY = topPad + plotH - labelH / 2 - 2;
      labelCy = Math.max(minY, Math.min(maxY, labelCy));
      const labelX = x - labelW / 2;
      return `
      <rect x="${labelX.toFixed(1)}" y="${(labelCy - labelH/2).toFixed(1)}" width="${labelW.toFixed(1)}" height="${labelH}" rx="2.5"
            fill="white" fill-opacity="0.96" stroke="${color}" stroke-width="0.8"/>
      <text x="${x.toFixed(1)}" y="${(labelCy + 0.5).toFixed(1)}" font-size="8" fill="${color}" text-anchor="middle" font-weight="700" dominant-baseline="middle">${labelText}</text>
      <text x="${x.toFixed(1)}" y="${(y + 5).toFixed(1)}" font-size="14" fill="${color}" text-anchor="middle" font-weight="900"
            stroke="white" stroke-width="3.5" paint-order="stroke" stroke-linejoin="round">${sym}</text>
    `;
    }).join('');

    // 6. 現在位置 marker（紅色虛線 + 圓點喺實際時間位置；中文 chip label 固定左上角）
    let nowMarker = '';
    if (opts.nowMs !== undefined) {
      const nowRatio = Math.max(0, Math.min(1, (opts.nowMs - baseMs) / totalMs));
      const nowX = leftAxis + nowRatio * plotW;
      const idx = Math.round(nowRatio * (points.length - 1));
      const nowY = topPad + (1 - (points[idx].height - minH) / range) * plotH;
      const nowH = points[idx].height.toFixed(2);
      const nowLabelText = `現在 ${nowH} 米`;
      const labelH = 14;
      const charW = 5.4;
      const labelW = nowLabelText.length * charW + 8;
      // 固定喺 SVG 左上角（x=4, y=2），唔再跟隨 nowX
      const labelX = 4;
      const labelY = 2;
      nowMarker =
        `<line x1="${nowX.toFixed(1)}" y1="${topPad}" x2="${nowX.toFixed(1)}" y2="${(topPad+plotH).toFixed(1)}" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2" />`
        + `<circle cx="${nowX.toFixed(1)}" cy="${nowY.toFixed(1)}" r="4" fill="#ef4444" stroke="white" stroke-width="2" />`
        + `<rect x="${labelX.toFixed(1)}" y="${labelY.toFixed(1)}" width="${labelW.toFixed(1)}" height="${labelH}" rx="3" fill="#ef4444" fill-opacity="0.96" stroke="white" stroke-width="0.8"/>`
        + `<text x="${(labelX + labelW/2).toFixed(1)}" y="${(labelY + labelH/2 + 0.5).toFixed(1)}" font-size="9" fill="white" text-anchor="middle" font-weight="800" dominant-baseline="middle">${nowLabelText}</text>`;
    }

    // 7. 組裝 SVG
    const gridSvg = gridLines.map(g =>
      `<line x1="${leftAxis}" y1="${g.y.toFixed(1)}" x2="${width-2}" y2="${g.y.toFixed(1)}" stroke="#e5e7eb" stroke-width="0.5" />`
      + `<text x="2" y="${(g.y+3).toFixed(1)}" font-size="8" fill="#888">${g.label} 米</text>`
    ).join('');
    const timeSvg = timeLabels.map(t => {
      const x = leftAxis + t.ratio * plotW;
      const yAxis = topPad + plotH;
      return `<line x1="${x.toFixed(1)}" y1="${yAxis.toFixed(1)}" x2="${x.toFixed(1)}" y2="${(yAxis+3).toFixed(1)}" stroke="#999" stroke-width="0.5" />`
        + `<text x="${x.toFixed(1)}" y="${(yAxis+13).toFixed(1)}" font-size="8" fill="#666" text-anchor="middle">${t.text}</text>`;
    }).join('');

    return `<svg viewBox="0 0 ${width} ${height}" style="width:100%;height:auto;display:block">
      <rect x="${leftAxis}" y="${topPad}" width="${plotW}" height="${plotH}" fill="#f0fafa" rx="3" />
      ${gridSvg}
      <path d="${fillD}" fill="#0a6e7a" fill-opacity="0.15" />
      <path d="${pathD}" fill="none" stroke="#0a6e7a" stroke-width="1.8" stroke-linejoin="round" />
      ${eventMarkers}
      ${nowMarker}
      ${timeSvg}
    </svg>`;
  }

  // ============================================================
  // 全部 6 站 metadata（含經緯度 + 中文名）
  // ============================================================
  function getAllStations() {
    return loadData().stationList || [];
  }
  function getStationMeta(code) {
    const list = getAllStations();
    return list.find(s => s.code === code) || null;
  }

  // ============================================================
  // 今日潮差 + 釣況建議
  // ============================================================
  function getTidalRangeToday(stationCode, nowMs) {
    const events = getEventsAround(stationCode, nowMs);
    if (!events.length) return 0;
    const d = new Date(nowMs);
    const todayKey = dateKey(nowMs);
    const todayEvents = events.filter(e => {
      const ed = new Date(e.ms);
      return dateKey(ed.getTime()) === todayKey;
    });
    if (todayEvents.length < 2) return 0;
    const heights = todayEvents.map(e => e.height);
    return Math.max(...heights) - Math.min(...heights);
  }
  function getFishingAdvice(stationCode, nowMs) {
    const t = getCurrentTide(stationCode, nowMs);
    const range = getTidalRangeToday(stationCode, nowMs);
    const adv = [];
    // 潮差分類
    if (range >= 1.5) adv.push({ icon: '🔥', text: '大潮（潮差 ' + range.toFixed(2) + 'm）→ 水流強，磯釣/防波堤最佳' });
    else if (range < 1.0) adv.push({ icon: '⚠️', text: '小潮（潮差 ' + range.toFixed(2) + 'm）→ 水流弱，魚獲較難' });
    else adv.push({ icon: '✅', text: '中潮（潮差 ' + range.toFixed(2) + 'm）→ 正常釣況' });
    // 時段建議
    if (t.trend === 'rising' && t.nextHigh) {
      const minsToHigh = Math.round((t.nextHigh.ms - nowMs) / 60000);
      if (minsToHigh > 0 && minsToHigh <= 120) {
        adv.push({ icon: '🎯', text: '距高潮 ' + minsToHigh + ' 分鐘 → 魚覓食活躍，最佳時段！' });
      }
    }
    if (t.trend === 'falling' && t.nextLow) {
      const minsToLow = Math.round((t.nextLow.ms - nowMs) / 60000);
      if (minsToLow > 0 && minsToLow <= 120) {
        adv.push({ icon: '🦐', text: '距低潮 ' + minsToLow + ' 分鐘 → 底棲魚類覓食時段' });
      }
    }
    return adv;
  }

  // ============================================================
  // 釣況 emoji helper（給 marker icon）
  // ============================================================
  function tideMarkerIcon(stationCode, height, trend) {
    const meta = getStationMeta(stationCode);
    const name = meta ? meta.name_zh : stationCode;
    const color = trend === 'rising' ? '#f97316' : trend === 'falling' ? '#0d9488' : '#9ca3af';
    const arrow = trend === 'rising' ? '↗' : trend === 'falling' ? '↘' : '→';
    const safeName = (name || '').replace(/[<>"]/g, '');
    const safeH = (height === null || height === undefined) ? '—' : height.toFixed(2);
    return `
      <div class="tide-marker" style="--badge:${color}">
        <div class="tide-marker-icon">📡</div>
        <div class="tide-marker-info">
          <div class="tide-marker-name">${safeName}</div>
          <div class="tide-marker-val">${safeH}m ${arrow}</div>
        </div>
      </div>`;
  }

  // 匯出
  window.tidesLib = {
    loadData,
    getStationForSpot,
    getStationMeta,
    getAllStations,
    getDayEvents,
    getEventsAround,
    getCurrentTide,
    getNextTides,
    getTideCurve24h,
    describeCurrent,
    formatTime,
    formatDateShort,
    curveSvg,
    getTidalRangeToday,
    getFishingAdvice,
    tideMarkerIcon,
  };
})();