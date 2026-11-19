/* ============================================================
 *  lib/tides.js — 香港潮汐預報（純前端、離線可用）
 *
 *  數據源：香港天文台 HKO 年度潮汐表（已預載入 2026、2027）
 *  高度：官方逐小時天文潮線性插值；本機檔載入失敗時才回退餘弦估算
 *
 *  全域：window.tidesLib
 *  依賴：無（內嵌 tide-data.json）
 * ============================================================ */
(function() {
  'use strict';

  // 高低潮事件內嵌；逐小時高度讀取 repo 靜態檔（不擴大 SW 快取）
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
  // 指定年份嘅逐日數據：data.year 用 station.days；其他年份用 data.extraYears[年][站 name]（借用站同 name 共用）
  function yearDays(data, station, year) {
    if (!data.year || year === data.year) return station.days;
    const ey = data.extraYears && data.extraYears[year];
    return (ey && ey[station.name]) || null;
  }

  // ============================================================
  // 取高低潮事件（指定站 + 日期，跨午夜的話取前後日合併）
  // ============================================================
  function getDayEvents(stationCode, ms) {
    const data = loadData();
    const station = data.stations[stationCode];
    if (!station) return [];
    const d = new Date(ms);
    const year = d.getFullYear();
    const days = yearDays(data, station, year);
    if (!days) return [];  // 冇該年份數據就不顯示（避免顯示錯誤潮汐）
    const key = dateKey(ms);
    const dayData = days.find(x => x.d === key);
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
  function cosineTide(stationCode, nowMs) {
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
    return getTideCurve(stationCode, fromMs, fromMs + 24 * 3600000, 60);
  }

  // ============================================================
  // 未來 N 天潮汐預報（每日高低潮時間+ 潮差），給列表 UI 用
  //   [{ ms, isToday, weekday, highs: [{ms,height}], lows:[...], range: 1.6 }, ...]
  // ============================================================
  // 某一日嘅原始事件（唔判斷高低）；超出數據年份或者冇數據返 []
  function rawEventsOnDate(station, dateObj) {
    const data = loadData();
    if (!station) return [];
    const year = dateObj.getFullYear();
    const days = yearDays(data, station, year);
    if (!days) return [];
    const key = dateKey(dateObj.getTime());
    const dd = days.find(x => x.d === key);
    return dd ? dd.e.map(([t, h]) => ({ ms: makeDateMs(year, key, t), height: h })) : [];
  }

  // 未來 N 日潮汐預報
  // 高低潮判斷：將「前一日 + 當日 + 後一日」事件排成一條連續序列，用相鄰事件比較。
  //   → 跨日都正確（991 個完整日驗證 100% 一致）。
  // 香港潮汐有時一日只得 2–3 個事件（例如只一次高潮），係官方潮汐表本身嘅數據，唔係缺漏。
  // complete = 當日同時有高潮同低潮，先計潮差；只得一種潮汐嘅日子 range 為 null。
  function getForecastDays(stationCode, fromMs, days) {
    const n = days || 5;
    const data = loadData();
    const station = data.stations[stationCode];
    if (!station) return [];
    const startDate = new Date(fromMs);
    startDate.setHours(0, 0, 0, 0);
    const out = [];
    for (let i = 0; i < n; i++) {
      const d = new Date(startDate.getTime() + i * 86400000);
      const key = dateKey(d.getTime());
      const label = (i === 0) ? '今日' : (i === 1) ? '明日' : '';
      const own = rawEventsOnDate(station, d);
      const seq = [
        ...rawEventsOnDate(station, new Date(d.getTime() - 86400000)),
        ...own,
        ...rawEventsOnDate(station, new Date(d.getTime() + 86400000))
      ].sort((a, b) => a.ms - b.ms);
      const evs = own.map(e => {
        const k = seq.findIndex(x => x.ms === e.ms);
        const nb = [seq[k - 1], seq[k + 1]].filter(Boolean);
        let type = 'unknown';
        if (nb.length) {
          if (nb.every(x => e.height > x.height)) type = 'high';
          else if (nb.every(x => e.height < x.height)) type = 'low';
        }
        return { ms: e.ms, height: e.height, type };
      }).sort((a, b) => a.ms - b.ms);   // 按時間先後排列（高低潮交錯）
      const highs = evs.filter(e => e.type === 'high');
      const lows = evs.filter(e => e.type === 'low');
      const hasData = evs.length > 0;
      const complete = highs.length > 0 && lows.length > 0;   // 同時有高潮同低潮，先計潮差
      const allH = evs.map(e => e.height);
      const range = hasData && complete ? (Math.max(...allH) - Math.min(...allH)) : null;
      out.push({
        ms: d.getTime(), date: key, weekday: d.getDay(),
        label, isToday: i === 0, highs, lows, events: evs,
        range, hasData, complete
      });
    }
    return out;
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
    const today = new Date(now());
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

  function tideScale(points, events) {
    const heights = points.map(p=>p.height).concat((events || []).map(e=>e.height));
    return {minH:Math.floor((Math.min(...heights)-0.15)*10)/10,
      maxH:Math.ceil((Math.max(...heights)+0.15)*10)/10};
  }
  // SVG 曲線（中文化時間軸 + 米單位 + 大 marker + 標籤 chip）
  function curveSvg(points, width, height, opts) {
    opts = opts || {};
    if (!points || points.length === 0) return '';
    // Auto scale includes negative heights and peaks above 3m, plus official event markers.
    const {minH,maxH} = tideScale(points, opts.events);
    const range = maxH - minH;
    const clampH = h => Math.max(minH, Math.min(maxH, h));
    const padding = 8;
    const leftAxis = opts.hideAxisLabels ? 18 : 30;        // 左邊 height 刻度寬度（加大放「米」字）
    const timeAxisH = opts.threeDayTicks ? 40 : 18;       // 底部時間軸高度
    const topPad = 18;          // 預留 NOW / 高潮 label 空間
    const plotW = width - leftAxis - (opts.threeDayTicks ? 18 : 4);
    const plotH = height - padding - topPad - timeAxisH;
    const stepX = plotW / (points.length - 1);

    // 1. 曲線 path
    const pathD = points.map((p, i) => {
      const x = leftAxis + i * stepX;
      const y = topPad + (1 - (clampH(p.height) - minH) / range) * plotH;
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

    // 4. 時間軸（中文化）— 用實際時間而唔係相對 +N 時
    const baseMs = points[0].ms;
    const totalMs = points[points.length - 1].ms - baseMs;
    let timeLabels = [
      { ratio: 0,    text: formatTime(baseMs) },
      { ratio: 0.25, text: formatTime(baseMs + 0.25 * totalMs) },
      { ratio: 0.5,  text: formatTime(baseMs + 0.5  * totalMs) },
      { ratio: 0.75, text: formatTime(baseMs + 0.75 * totalMs) },
      { ratio: 1,    text: formatTime(baseMs + totalMs) }
    ];

    if (opts.threeDayTicks) {
      timeLabels = [];
      for (let ms=baseMs; ms<=baseMs+totalMs; ms+=3*3600000) {
        timeLabels.push({ratio:(ms-baseMs)/totalMs,text:formatTime(ms),ms});
      }
    }

    // 5. 高 / 低潮 markers（opts.events = [{ms, height, type}]）
    //    大 ▲▼ icon + 白色 outline + 白底圓角 label chip 顯示「HH:MM 高度」
    //    高潮 → label 喺 marker 上面；低潮 → 喺下面
    const eventMarkers = (opts.events || []).map(e => {
      const ratio = (e.ms - baseMs) / totalMs;
      if (ratio < -0.05 || ratio > 1.05) return '';
      const x = leftAxis + Math.max(0, Math.min(1, ratio)) * plotW;
      const y = topPad + (1 - (clampH(e.height) - minH) / range) * plotH;
      const isHigh = e.type === 'high';
      const color = isHigh ? '#f97316' : '#0d9488';
      const sym = isHigh ? '▲' : '▼';
      const timeStr = formatTime(e.ms);
      const hStr = e.height.toFixed(2);
      const labelText = `${timeStr} ${hStr}`;
      const labelH = opts.largeLabels ? 17 : 13;
      const charW = opts.largeLabels ? 6.6 : 5.4;
      const labelW = labelText.length * charW + 8;
      // Keep the label clear of the symbol. Flip above/below before using a side.
      const minY = topPad + labelH/2, maxY = topPad + plotH - labelH/2;
      const gap = 13 + labelH/2;
      let labelCy = y + (isHigh ? -gap : gap);
      const fits = cy => cy>=minY && cy<=maxY;
      if (!fits(labelCy)) labelCy = y + (isHigh ? gap : -gap);
      let labelX = x-labelW/2;
      if (!fits(labelCy)) {
        labelCy = Math.max(minY,Math.min(maxY,y));
        labelX = x+12+labelW<=width ? x+12 : x-12-labelW;
      }
      if (opts.threeDayTicks) labelX = Math.max(2, Math.min(width-labelW-2, labelX));
      const labelCenterX = labelX+labelW/2;
      return `
      <rect class="tide-event-label" data-event="${e.ms}" x="${labelX.toFixed(1)}" y="${(labelCy - labelH/2).toFixed(1)}" width="${labelW.toFixed(1)}" height="${labelH}" rx="2.5"
            fill="white" fill-opacity="0.96" stroke="${color}" stroke-width="0.8"/>
      <text x="${labelCenterX.toFixed(1)}" y="${(labelCy + 0.5).toFixed(1)}" font-size="${opts.largeLabels ? 10 : 8}" fill="${color}" text-anchor="middle" font-weight="700" dominant-baseline="middle">${labelText}</text>
      <text class="tide-event-symbol" data-event="${e.ms}" x="${x.toFixed(1)}" y="${(y + 5).toFixed(1)}" font-size="14" fill="${color}" text-anchor="middle" font-weight="900"
            stroke="white" stroke-width="3.5" paint-order="stroke" stroke-linejoin="round">${sym}</text>
    `;
    }).join('');

    // 6. 現在位置 marker（紅色虛線 + 圓點喺實際時間位置；中文 chip label 固定左上角）
    let nowMarker = '';
    if (opts.nowMs !== undefined) {
      const nowRatio = Math.max(0, Math.min(1, (opts.nowMs - baseMs) / totalMs));
      const nowX = leftAxis + nowRatio * plotW;
      const idx = Math.round(nowRatio * (points.length - 1));
      const nowY = topPad + (1 - (clampH(points[idx].height) - minH) / range) * plotH;
      const nowH = points[idx].height.toFixed(2);
      const nowLabelText = `現在 ${nowH} 米`;
      const labelH = 14;
      const charW = opts.largeLabels ? 6.6 : 5.4;
      const labelW = nowLabelText.length * charW + 8;
      // 固定喺 SVG 左上角（x=4, y=2），唔再跟隨 nowX
      const labelX = 4;
      const labelY = 2;
      nowMarker =
        `<line x1="${nowX.toFixed(1)}" y1="${topPad}" x2="${nowX.toFixed(1)}" y2="${(topPad+plotH).toFixed(1)}" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2" />`
        + `<circle cx="${nowX.toFixed(1)}" cy="${nowY.toFixed(1)}" r="4" fill="#ef4444" stroke="white" stroke-width="2" />`
        + (opts.hideNowChip ? '' : `<rect x="${labelX.toFixed(1)}" y="${labelY.toFixed(1)}" width="${labelW.toFixed(1)}" height="${labelH}" rx="3" fill="#ef4444" fill-opacity="0.96" stroke="white" stroke-width="0.8"/>`
        + `<text x="${(labelX + labelW/2).toFixed(1)}" y="${(labelY + labelH/2 + 0.5).toFixed(1)}" font-size="9" fill="white" text-anchor="middle" font-weight="800" dominant-baseline="middle">${nowLabelText}</text>`);
    }

    // 7. 組裝 SVG
    const gridSvg = gridLines.map(g =>
      `<line x1="${leftAxis}" y1="${g.y.toFixed(1)}" x2="${width-2}" y2="${g.y.toFixed(1)}" stroke="#e5e7eb" stroke-width="0.5" />`
      + (opts.hideAxisLabels ? '' : `<text x="2" y="${(g.y+3).toFixed(1)}" font-size="${opts.largeLabels ? 10 : 8}" fill="#888">${g.label} 米</text>`)
    ).join('');
    const timeSvg = timeLabels.map(t => {
      const x = leftAxis + t.ratio * plotW;
      const yAxis = topPad + plotH;
      return `<line x1="${x.toFixed(1)}" y1="${yAxis.toFixed(1)}" x2="${x.toFixed(1)}" y2="${(yAxis+3).toFixed(1)}" stroke="#999" stroke-width="0.5" />`
        + `<text class="tide-time-tick" x="${x.toFixed(1)}" y="${(yAxis+13).toFixed(1)}" font-size="${opts.largeLabels ? 10 : 8}" fill="#666" text-anchor="middle">${t.text}</text>`
        + (opts.threeDayTicks && new Date(t.ms).getHours()===0 && t.ratio<1
          ? `<line class="tide-day-divider" x1="${x}" x2="${x}" y1="${topPad}" y2="${yAxis}" stroke="#b8d9dd" stroke-width="1" />
             <text class="tide-date-tick" x="${x+3}" y="${yAxis+30}" font-size="10" fill="#46636b">${new Date(t.ms).getMonth()+1}/${new Date(t.ms).getDate()}（${'日一二三四五六'[new Date(t.ms).getDay()]}）</text>` : '');
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
  // 潮汐數據是否涵蓋指定時間（只內嵌單一年份）
  function isDataValid(ms) {
    const data = loadData();
    const y = new Date(ms == null ? now() : ms).getFullYear();
    return !!hourly[y] && (!data.year || y === data.year || !!(data.extraYears && data.extraYears[y]));
  }
  // 最後涵蓋嘅年份
  function getDataYear() {
    const data = loadData();
    if (!data.year) return null;
    const years = [data.year, ...Object.keys(data.extraYears || {}).map(Number)].filter(y=>hourly[y]);
    return hourlyLoading || !years.length ? Math.max(data.year,...Object.keys(data.extraYears || {}).map(Number)) : Math.max(...years);
  }
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
    if (range >= 1.5) adv.push({ icon: '🔥', text: '大潮（潮差 ' + range.toFixed(2) + 'm）→ 水流強，磯釣／防波堤一般較有利' });
    else if (range < 1.0) adv.push({ icon: '⚠️', text: '小潮（潮差 ' + range.toFixed(2) + 'm）→ 水流弱，魚獲較難' });
    else adv.push({ icon: '✅', text: '中潮（潮差 ' + range.toFixed(2) + 'm）→ 正常釣況' });
    // 時段建議
    if (t.trend === 'rising' && t.nextHigh) {
      const minsToHigh = Math.round((t.nextHigh.ms - nowMs) / 60000);
      if (minsToHigh > 0 && minsToHigh <= 120) {
        adv.push({ icon: '🎯', text: '距高潮 ' + minsToHigh + ' 分鐘 → 魚類或較活躍，可留意（僅供參考）' });
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

  const hourly = {};
  let hourlyLoading = true;
  function isHourlyLoading() { return hourlyLoading; }
  let testNow = null;
  function now() { return testNow == null ? Date.now() : testNow; }
  function setNowForTest(ms) { testNow = ms; }
  // Local static files only; never call the HKO API at runtime.
  const ready = Promise.all([2026, 2027].map(async year => {
    try {
      const r = await fetch('./lib/tide-hourly-' + year + '.json');
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const data = await r.json();
      if (data.year !== year || data.unit !== 'cm' || data.hours !== '01-24') throw new Error('Invalid hourly data');
      hourly[year] = data;
    } catch (e) { console.warn('Hourly tide file unavailable; using labelled estimate', year); }
  })).then(() => { hourlyLoading=false; window.dispatchEvent(new Event('tide-hourly-ready')); });
  function sourceCode(code) { const meta = getStationMeta(code); return meta && meta.source || code; }
  function hourPoint(code, ms) {
    // HHOT columns 01..24: midnight is the previous calendar day's column 24.
    const date = new Date(ms), hour = date.getHours();
    if (hour === 0) date.setDate(date.getDate() - 1);
    const y = date.getFullYear(), data = hourly[y];
    if (!data) return null;
    const index = Math.round((Date.UTC(y, date.getMonth(), date.getDate()) - Date.UTC(y, 0, 1)) / 86400000);
    const row = data.stations[sourceCode(code)] && data.stations[sourceCode(code)][index];
    const value = row && row[(hour || 24) - 1];
    return Number.isInteger(value) ? value / 100 : null;
  }
  function officialHeight(code, ms) {
    const d = new Date(ms); d.setMinutes(0, 0, 0);
    const lower = d.getTime(), a = hourPoint(code, lower);
    if (ms === lower) return a;
    const b = hourPoint(code, lower + 3600000);
    return a == null || b == null ? null : a + (b - a) * (ms - lower) / 3600000;
  }
  function getTideHeight(code, ms) {
    const value = officialHeight(code, ms);
    return value == null ? cosineTide(code, ms).height : value;
  }
  function getCurrentTide(code, ms) {
    ms = ms == null ? now() : ms;
    const value = officialHeight(code, ms), height = value == null ? cosineTide(code, ms).height : value;
    const future = getTideHeight(code, ms + 1800000);
    const upcoming = getNextTides(code, ms, 8);
    return {height:height == null ? null : Math.round(height * 100) / 100,
      trend:height == null || future == null ? 'unknown' : future > height ? 'rising' : 'falling',
      trendRate:height == null || future == null ? 0 : Math.round((future-height)*200)/100,
      nextHigh:upcoming.find(e=>e.type==='high') || null, nextLow:upcoming.find(e=>e.type==='low') || null,
      estimated:!!(getStationMeta(code)||{}).estimated || (value == null && !hourlyLoading),
      source:value == null ? 'cosine' : 'hourly'};
  }
  function getTideCurve(code, fromMs, toMs, stepMinutes) {
    const points = [];
    for (let ms = fromMs; ms <= toMs; ms += (stepMinutes || 60)*60000) {
      const height = getTideHeight(code, ms);
      if (height != null) points.push({ms, height});
    }
    return points;
  }
  function threeDayWindow(ms) {
    const d = new Date(ms == null ? now() : ms); d.setHours(0,0,0,0);
    const end = new Date(d); end.setDate(end.getDate()+3);
    return {fromMs:d.getTime(),toMs:end.getTime()};
  }

  function explorerHtml(code) {
    return `<div class="tide-explorer" data-station="${code}">
      <div class="tide-explorer-days">${['今日','聽日','後日'].map((s,i)=>`<button type="button" data-day="${i}" aria-pressed="${i===0}">${s}</button>`).join('')}<button type="button" data-now>返到而家</button></div>
      <div class="tide-explorer-readout" aria-live="polite"></div>
      <div class="tide-chart-frame"><div class="tide-y-axis" aria-label="潮高刻度"></div><div class="tide-chart" tabindex="0" role="slider" aria-label="潮汐讀取時間：左右箭咀調整，Home 返回而家" aria-valuemin="0" aria-valuemax="4320"><div class="tide-chart-rail"></div></div></div>
      <div class="tide-explorer-interval">間隔 ${[30,60,120].map(n=>`<button type="button" data-step="${n}" aria-pressed="false">${n===30?'30 分鐘':n/60+' 小時'}</button>`).join('')}</div>
      <div class="tide-hours" aria-label="逐時潮高"></div>
    </div>`;
  }
  function mountExplorers(view) {
    view.querySelectorAll('.tide-explorer').forEach(root => {
      const code=root.dataset.station, chart=root.querySelector('.tide-chart'), rail=root.querySelector('.tide-chart-rail');
      const strip=root.querySelector('.tide-hours'), output=root.querySelector('.tide-explorer-readout');
      const start=now(), bounds=threeDayWindow(start), duration=bounds.toMs-bounds.fromMs;
      const width=Math.max(1,chart.clientWidth-36)*3+36, points=getTideCurve(code,bounds.fromMs,bounds.toMs,30);
      const events=getForecastDays(code,bounds.fromMs,3).flatMap(d=>d.events);
      rail.style.width=width+'px';
      const scale=tideScale(points,events), plotH=196-8-18-40;
      const values=[scale.maxH,(scale.maxH+scale.minH)/2,scale.minH];
      root.querySelector('.tide-y-axis').innerHTML=values.map((h,i)=>`<span style="top:${18+i*plotH/2}px">${h.toFixed(1)} 米</span>`).join('');
      rail.innerHTML=curveSvg(points,width,196,{nowMs:start,events,largeLabels:true,hideAxisLabels:true,hideNowChip:true,threeDayTicks:true})+'<div class="tide-read-line"></div>';
      // Reduced-motion's global .01ms duration otherwise enables transition-property: all
      // on these SVG nodes. x/visibility must commit immediately, not retain the old frame.
      rail.querySelectorAll('.tide-event-label,.tide-event-label + text,.tide-time-tick,.tide-date-tick,.tide-read-line').forEach(node=>{
        node.style.transitionProperty='none';
      });
      const line=rail.querySelector('.tide-read-line');
      const eventLabels=Array.from(rail.querySelectorAll('.tide-event-label')).map(label=>({
        label, text:label.nextElementSibling,
        marker:rail.querySelector('.tide-event-symbol[data-event="'+label.dataset.event+'"]'),
        x:Number(label.getAttribute('x')), textX:Number(label.nextElementSibling.getAttribute('x')),
        width:Number(label.getAttribute('width'))
      }));
      function fitVisibleEventLabels() {
        const left=chart.scrollLeft, right=left+chart.clientWidth;
        eventLabels.forEach(entry=>{
          const markerBox=entry.marker.getBBox(), markerX=markerBox.x+markerBox.width/2;
          const visible=markerX>=left && markerX<=right;
          const x=visible ? Math.max(left+2,Math.min(right-entry.width-2,entry.x)) : entry.x;
          entry.label.setAttribute('x',x.toFixed(1));
          entry.text.setAttribute('x',(entry.textX+x-entry.x).toFixed(1));
          entry.label.style.visibility=entry.text.style.visibility=visible?'visible':'hidden';
        });
        rail.querySelectorAll('.tide-time-tick,.tide-date-tick').forEach(tick=>{
          const box=tick.getBBox();
          tick.style.visibility=box.x>=left+1 && box.x+box.width<=right-1?'visible':'hidden';
        });
      }
      chart.addEventListener('scroll',fitVisibleEventLabels,{passive:true});
      let selected=start, interval=60, syncedStripLeft=null;
      try { interval=Number(localStorage.getItem('hkf-tide-interval')) || 60; } catch(e) {}
      if (![30,60,120].includes(interval)) interval=60;
      const xAt=ms=>18+(ms-bounds.fromMs)/duration*(width-36);
      const msAt=x=>bounds.fromMs+(x-18)/(width-36)*duration;
      function select(ms, alignChart, alignStrip) {
        selected=Math.max(bounds.fromMs,Math.min(bounds.toMs-1,ms));
        const tide=getCurrentTide(code,selected), date=new Date(selected);
        const text=(date.getMonth()+1)+'/'+date.getDate()+' '+formatTime(selected)+' · '+(tide.height==null?'—':tide.height.toFixed(2))+' 米 · '+(tide.trend==='rising'?'漲中':tide.trend==='falling'?'退中':'平')+(tide.estimated?' · 估算':'');
        output.textContent=text;
        root.dataset.selected=String(selected); root.dataset.source=tide.source;
        line.style.left=xAt(selected)+'px';
        chart.setAttribute('aria-valuenow',Math.round((selected-bounds.fromMs)/60000));chart.setAttribute('aria-valuetext',text);
        const day=Math.min(2,Math.floor((selected-bounds.fromMs)/86400000));
        root.querySelectorAll('[data-day]').forEach(b=>b.setAttribute('aria-pressed',Number(b.dataset.day)===day));
        const index=Math.min(strip.children.length-1,Math.floor((selected-bounds.fromMs)/(interval*60000)));
        const previous=strip.querySelector('[aria-pressed="true"]');if(previous)previous.setAttribute('aria-pressed','false');
        const tile=strip.children[index];if(tile)tile.setAttribute('aria-pressed','true');
        if(alignChart)chart.scrollLeft=xAt(selected)-chart.clientWidth/2;
        if(alignStrip && tile){strip.scrollLeft=tile.offsetLeft-strip.clientWidth/2+tile.offsetWidth/2;syncedStripLeft=strip.scrollLeft;}
        fitVisibleEventLabels();
      }
      function buildHours() {
        let html='';
        for(let ms=bounds.fromMs;ms<bounds.toMs;ms+=interval*60000){
          const t=getCurrentTide(code,ms), rising=t.trend==='rising';
          html+=`<button type="button" data-ms="${ms}" aria-pressed="false" class="${rising?'rising':'falling'}"><span>${new Date(ms).getDate()}日 ${formatTime(ms)}</span><b>${t.height==null?'—':t.height.toFixed(2)} 米</b><span>${rising?'↗ 漲':'↘ 退'}${t.estimated?' · 估算':''}</span></button>`;
        }
        strip.innerHTML=html;
        root.querySelectorAll('[data-step]').forEach(b=>b.setAttribute('aria-pressed',Number(b.dataset.step)===interval));
      }
      root.querySelectorAll('[data-day]').forEach(b=>b.onclick=()=>{
        const midnight = bounds.fromMs+Number(b.dataset.day)*86400000;
        select(midnight+12*3600000,true,true);
        // Keep midnight's centred time and the complete date inside the viewport.
        chart.scrollLeft = xAt(midnight)-18;
        fitVisibleEventLabels();
      });
      root.querySelector('[data-now]').onclick=()=>select(now(),true,true);
      root.querySelectorAll('[data-step]').forEach(b=>b.onclick=()=>{
        interval=Number(b.dataset.step);try{localStorage.setItem('hkf-tide-interval',String(interval));}catch(e){}
        buildHours();select(selected,false,true);
      });
      strip.onclick=e=>{const b=e.target.closest('[data-ms]');if(b)select(Number(b.dataset.ms),true,true);};
      strip.addEventListener('scroll',()=>{
        if(syncedStripLeft!=null && Math.abs(strip.scrollLeft-syncedStripLeft)<1)return;
        syncedStripLeft=null;
        const middle=strip.scrollLeft+strip.clientWidth/2;
        const tile=Array.from(strip.children).find(b=>b.offsetLeft+b.offsetWidth>=middle);
        if(tile)select(Number(tile.dataset.ms),true,false);
      },{passive:true});
      chart.onkeydown=e=>{
        if(!['ArrowLeft','ArrowRight','Home'].includes(e.key))return;
        e.preventDefault();select(e.key==='Home'?now():selected+(e.key==='ArrowRight'?1:-1)*interval*60000,true,true);
      };
      let gesture=null, panFrame=0;
      function stopGesture() { gesture=null; cancelAnimationFrame(panFrame); panFrame=0; }
      function edgePan() {
        if(!gesture || !gesture.horizontal || !root.isConnected){stopGesture();return;}
        const x=gesture.currentX-chart.getBoundingClientRect().left;
        const direction=x<36?-1:x>chart.clientWidth-36?1:0;
        if(direction){
          chart.scrollLeft+=direction*5;
          select(msAt(x+chart.scrollLeft),false,true);
        }
        panFrame=requestAnimationFrame(edgePan);
      }
      chart.onpointerdown=e=>{if(e.button!==0)return;gesture={id:e.pointerId,x:e.clientX,y:e.clientY,currentX:e.clientX,horizontal:false};};
      chart.onpointermove=e=>{
        if(!gesture || gesture.id!==e.pointerId)return;
        const dx=e.clientX-gesture.x,dy=e.clientY-gesture.y;
        if(!gesture.horizontal){
          if(Math.max(Math.abs(dx),Math.abs(dy))<8)return;
          if(Math.abs(dy)>=Math.abs(dx)){stopGesture();return;}
          gesture.horizontal=true;chart.setPointerCapture(e.pointerId);panFrame=requestAnimationFrame(edgePan);
        }
        gesture.currentX=e.clientX;
        select(msAt(e.clientX-chart.getBoundingClientRect().left+chart.scrollLeft),false,true);
      };
      chart.onpointerup=e=>{
        if(gesture && !gesture.horizontal)select(msAt(e.clientX-chart.getBoundingClientRect().left+chart.scrollLeft),false,true);
        stopGesture();if(chart.hasPointerCapture(e.pointerId))chart.releasePointerCapture(e.pointerId);
      };
      chart.onpointercancel=stopGesture;
      buildHours();select(start,true,true);
    });
  }

  // 匯出
  window.tidesLib = {
    isHourlyLoading, explorerHtml, mountExplorers, ready, now, setNowForTest, getTideHeight, getTideCurve, threeDayWindow,
    loadData,
    getStationForSpot,
    getStationMeta,
    getAllStations,
    isDataValid,
    getDataYear,
    getDayEvents,
    getEventsAround,
    getCurrentTide,
    getNextTides,
    getTideCurve24h,
    getForecastDays,
    describeCurrent,
    formatTime,
    formatDateShort,
    curveSvg,
    getTidalRangeToday,
    getFishingAdvice,
    tideMarkerIcon,
  };
})();