/* ============================================================
 * Route I++: 天氣模組（Open-Meteo API + 30 min memory cache）
 * 香港大埔滘、鰂魚涌、長洲、大澳、石壁、尖鼻咀 6 站
 * ============================================================ */
(function() {
  'use strict';

  const CACHE_TTL_MS = 30 * 60 * 1000;  // 30 分鐘 cache
  const cache = new Map();               // key = "lat,lon" -> { at, data }

  // ============================================================
  // 1. Open-Meteo API fetch + parse
  // ============================================================
  function buildUrl(lat, lon) {
    const params = [
      'current=temperature_2m,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m,pressure_msl,cloud_cover',
      'hourly=temperature_2m,precipitation,wind_speed_10m,wind_direction_10m,weather_code,relative_humidity_2m,pressure_msl,cloud_cover',
      'forecast_days=1',
      'wind_speed_unit=kmh',
      'timezone=Asia/Hong_Kong'
    ];
    return `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&${params.join('&')}`;
  }

  function getCacheKey(lat, lon) {
    return `${lat.toFixed(3)},${lon.toFixed(3)}`;
  }

  // v192：每次請求 10 秒 timeout；503／5xx／timeout／網絡錯誤 1s、3s、8s 後重試（最多 3 次）。
  //   429（超出用量上限）同其他 4xx 唔重試：等幾秒都唔會解封，只會加重負擔。
  const RETRY_DELAYS_MS = [1000, 3000, 8000];
  const TIMEOUT_MS = 10000;
  const LS_KEY = 'wx_last_good_v1';   // localStorage：{ "lat,lon": { at, data } }
  async function fetchJsonRetry(url) {
    for (let attempt = 0; ; attempt++) {
      let err;
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
      try {
        const r = await fetch(url, { signal: ctrl.signal });
        if (r.ok) return await r.json();
        err = new Error('HTTP ' + r.status);
        if (r.status < 500) throw Object.assign(err, { noRetry: true });
      } catch (e) {
        if (e.noRetry) throw e;
        err = e.name === 'AbortError' ? new Error('逾時') : e;
      } finally {
        clearTimeout(timer);
      }
      if (attempt >= RETRY_DELAYS_MS.length) throw err;
      await new Promise(res => setTimeout(res, RETRY_DELAYS_MS[attempt]));
    }
  }

  function loadSaved() {
    try { return JSON.parse(localStorage.getItem(LS_KEY)) || {}; } catch (e) { return {}; }
  }
  function saveGood(entries) {   // entries: [[key, data], ...]
    try {
      const all = loadSaved(); const at = Date.now();
      entries.forEach(([k, d]) => { all[k] = { at, data: d }; });
      localStorage.setItem(LS_KEY, JSON.stringify(all));
    } catch (e) { /* 私隱模式／爆容量：唔影響顯示 */ }
  }

  async function fetchWeather(lat, lon) {
    const key = getCacheKey(lat, lon);
    const cached = cache.get(key);
    if (cached && Date.now() - cached.at < CACHE_TTL_MS) {
      return cached.data;
    }
    try {
      const data = parseWeather(await fetchJsonRetry(buildUrl(lat, lon)));
      cache.set(key, { at: Date.now(), data });
      return data;
    } catch (e) {
      console.warn('Open-Meteo fetch failed for', lat, lon, e);
      // fallback to stale cache (if any)
      if (cached) return cached.data;
      throw e;
    }
  }

  function parseWeather(json) {
    const c = json.current || {};
    const h = json.hourly || {};
    const hourlyTimes = h.time || [];
    const nowMs = c.time ? new Date(c.time).getTime() : Date.now();
    // hourly 從 hour 0 開始（即 nextHour 起跳）
    const hours = [];
    for (let i = 0; i < hourlyTimes.length && i < 24; i++) {
      hours.push({
        ms: new Date(hourlyTimes[i] + (hourlyTimes[i].endsWith('Z') ? '' : '+08:00')).getTime(),
        temp: h.temperature_2m ? h.temperature_2m[i] : null,
        precip: h.precipitation ? h.precipitation[i] : 0,
        windSpeed: h.wind_speed_10m ? h.wind_speed_10m[i] : 0,
        windDir: h.wind_direction_10m ? h.wind_direction_10m[i] : 0,
        weatherCode: h.weather_code ? h.weather_code[i] : 0,
        humidity: h.relative_humidity_2m ? h.relative_humidity_2m[i] : null,
        pressure: h.pressure_msl ? h.pressure_msl[i] : null,
        cloud: h.cloud_cover ? h.cloud_cover[i] : null
      });
    }
    return {
      now: {
        time: nowMs,
        temp: c.temperature_2m ?? null,
        humidity: c.relative_humidity_2m ?? null,
        precip: c.precipitation ?? 0,   // Open-Meteo current = 前 15 分鐘雨量
        // 暴雨用嗰個鐘嘅雨量：hourly 入面同 current 同一個香港鐘數（timezone=Asia/Hong_Kong，time 字串頭 13 位 "YYYY-MM-DDTHH"）
        precipHour: (() => { const i = c.time ? hourlyTimes.findIndex(t => String(t).slice(0, 13) === String(c.time).slice(0, 13)) : -1;
          const v = i >= 0 && h.precipitation ? h.precipitation[i] : null; return typeof v === 'number' ? v : null; })(),
        weatherCode: c.weather_code ?? 0,
        windSpeed: c.wind_speed_10m ?? 0,
        windDir: c.wind_direction_10m ?? 0,
        pressure: c.pressure_msl ?? null,
        cloud: c.cloud_cover ?? null
      },
      hours
    };
  }

  // ============================================================
  // 2. WMO weather code → emoji + 中文標籤
  // ============================================================
  function weatherCodeInfo(code) {
    if (code === 0) return { icon: '☀️', label: '晴' };
    if (code <= 3) return { icon: '⛅', label: '多雲' };
    if (code === 45 || code === 48) return { icon: '🌫️', label: '霧' };
    if (code <= 57) return { icon: '🌦️', label: '毛毛雨' };
    if (code <= 67) return { icon: '🌧️', label: '雨' };
    if (code <= 77) return { icon: '🌨️', label: '雪' };
    if (code <= 82) return { icon: '🌦️', label: '陣雨' };
    if (code <= 86) return { icon: '🌨️', label: '雪陣' };
    if (code <= 99) return { icon: '⛈️', label: '雷暴' };
    return { icon: '🌤️', label: '—' };
  }

  // ============================================================
  // 3. 風向 (deg) → 中文方位 + 箭頭
  // ============================================================
  function windCompass(deg) {
    // 0 = 北, 90 = 東, 180 = 南, 270 = 西（8 方位）
    const dirs = ['北','東北','東','東南','南','西南','西','西北'];
    const arrows = ['↓','↙','←','↖','↑','↗','→','↘'];
    const idx = Math.round(deg / 45) % 8;
    return { dir: dirs[idx], arrow: arrows[idx], deg: Math.round(deg) };
  }

  // ============================================================
  // 4. 24h 風速 sparkline SVG（簡化版曲線，藍色漸層）
  // ============================================================
  function windSparklineSvg(hours, width, height) {
    if (!hours || hours.length === 0) return '';
    const speeds = hours.map(h => h.windSpeed);
    const maxS = Math.max(...speeds, 10);
    const minS = 0;
    const range = maxS - minS || 1;
    const padL = 4, padR = 4, padT = 10, padB = 14;
    const plotW = width - padL - padR;
    const plotH = height - padT - padB;
    const stepX = plotW / (hours.length - 1);

    const pathD = hours.map((p, i) => {
      const x = padL + i * stepX;
      const y = padT + (1 - (p.windSpeed - minS) / range) * plotH;
      return (i === 0 ? 'M' : 'L') + x.toFixed(1) + ',' + y.toFixed(1);
    }).join(' ');
    const fillD = pathD + ` L ${(padL+plotW).toFixed(1)},${(padT+plotH).toFixed(1)} L ${padL},${(padT+plotH).toFixed(1)} Z`;

    // 時間軸標記（每 6 小時）
    const tickIndices = [0, 6, 12, 18, 23];
    const tickSvg = tickIndices.map(i => {
      const x = padL + i * stepX;
      const hour = new Date(hours[i].ms).getHours();
      return `<line x1="${x.toFixed(1)}" y1="${(padT+plotH).toFixed(1)}" x2="${x.toFixed(1)}" y2="${(padT+plotH+3).toFixed(1)}" stroke="#94a3b8" stroke-width="0.5"/>`
        + `<text x="${x.toFixed(1)}" y="${(padT+plotH+12).toFixed(1)}" font-size="8" fill="#64748b" text-anchor="middle">${String(hour).padStart(2,'0')}</text>`;
    }).join('');

    // NOW 標記（第 1 點 ~ 下一個整點）
    let iNow = 0;
    const nowTs = Date.now();
    hours.forEach((p, i) => { if (p.ms <= nowTs) iNow = i; });
    const xNow = padL + iNow * stepX;
    const yNow = padT + (1 - (hours[iNow].windSpeed - minS) / range) * plotH;

    // 最大風 marker
    let iMax = 0, maxV = -1;
    hours.forEach((p, i) => { if (p.windSpeed > maxV) { maxV = p.windSpeed; iMax = i; } });
    const xMax = padL + iMax * stepX;
    const yMax = padT + (1 - (hours[iMax].windSpeed - minS) / range) * plotH;

    return `<svg viewBox="0 0 ${width} ${height}" style="width:100%;height:auto;display:block">
      <path d="${fillD}" fill="#3b82f6" fill-opacity="0.15"/>
      <path d="${pathD}" fill="none" stroke="#3b82f6" stroke-width="1.6" stroke-linejoin="round"/>
      <circle cx="${xNow.toFixed(1)}" cy="${yNow.toFixed(1)}" r="2.5" fill="#ef4444" stroke="white" stroke-width="1.2"/>
      <circle cx="${xMax.toFixed(1)}" cy="${yMax.toFixed(1)}" r="2.5" fill="#f97316" stroke="white" stroke-width="1.2"/>
      <text x="${(xMax+4).toFixed(1)}" y="${(yMax-3).toFixed(1)}" font-size="8" fill="#f97316" font-weight="700">${maxV.toFixed(0)}</text>
      ${tickSvg}
    </svg>`;
  }

  // ============================================================
  // 5. 釣魚指數（風+雨+壓綜合評分 0-100）
  // ============================================================
  function getFishingWeatherScore(w) {
    let score = 50;
    const reasons = [];
    // 風速評分：同畫面風級用同一張天文台表（beaufortLevel，先四捨五入到整數 km/h）
    const bf = beaufortLevel(w.windSpeed || 0), wTxt = `${bf.level}級 ${bf.name}（${bf.kmh} km/h）`;
    if (bf.level <= 2) { score += 25; reasons.push({ icon: '🍃', text: `${wTxt}，風力平靜，適合精細操作` }); }
    else if (bf.level === 3) { score += 15; reasons.push({ icon: '🌤️', text: `${wTxt}，釣況良好` }); }
    else if (bf.level === 4) { reasons.push({ icon: '💨', text: `${wTxt}，有小浪，需加重鉛` }); }
    else if (bf.level === 5) { score -= 25; reasons.push({ icon: '🌬️', text: `${wTxt}，風大，磯釣同出海要小心` }); }
    else if (bf.level === 6) { score -= 30; reasons.push({ icon: '🌪️', text: `${wTxt}，強風，不建議出海／磯釣` }); }
    else { score -= 40; reasons.push({ icon: '🌪️', text: `${wTxt}，風勢太大，不建議出釣` }); }
    // 降雨評分（文字同天氣卡細字共用 rainInfo）
    const rain = rainInfo(w.precip, w.precipHour);
    score += rain.score; reasons.push({ icon: rain.icon, text: rain.text });
    // 氣壓評分（魚對氣壓敏感：穩定 1010-1020 最佳）
    const p = w.pressure;
    if (p === null || p === undefined) { /* skip */ }
    else if (p >= 1010 && p <= 1020) { score += 15; reasons.push({ icon: '🎯', text: `氣壓穩定（${p.toFixed(0)} hPa），魚群或較活躍` }); }
    else if (p < 1000 || p > 1025) { score -= 10; reasons.push({ icon: '📉', text: `氣壓異常（${p.toFixed(0)} hPa），魚不咬餌` }); }
    // 天氣現象（雷暴大扣）
    const wc = weatherCodeInfo(w.weatherCode || 0);
    if (w.weatherCode >= 95) { score -= 20; reasons.push({ icon: '⛈️', text: '雷暴，請勿出海/磯釣' }); }
    // 氣溫（太熱太冷都差）
    const t = w.temp;
    if (t !== null && t !== undefined) {
      if (t < 15) { score -= 5; reasons.push({ icon: '🥶', text: `偏冷（${t.toFixed(1)}°C），魚活性低` }); }
      else if (t > 32) { score -= 5; reasons.push({ icon: '🥵', text: `酷熱（${t.toFixed(1)}°C），魚躲深水` }); }
    }

    score = Math.max(0, Math.min(100, Math.round(score)));
    if (w.weatherCode >= 95) score = Math.min(score, 44);   // 雷暴：評級最多「較差」
    let label, color, bg;
    if (score >= 80) { label = '極佳'; color = '#15803d'; bg = '#dcfce7'; }
    else if (score >= 65) { label = '良好'; color = '#0e7490'; bg = '#cffafe'; }
    else if (score >= 45) { label = '一般'; color = '#b45309'; bg = '#fef3c7'; }
    else if (score >= 25) { label = '較差'; color = '#b91c1c'; bg = '#fee2e2'; }
    else { label = '不建議'; color = '#7f1d1d'; bg = '#fecaca'; }
    return { score, label, color, bg, reasons, weatherIcon: wc.icon, weatherLabel: wc.label };
  }

  // ============================================================
  // 6. 批量取所有站天氣（v192：合併做 1 個多地點請求，避免同時開 12 條連線）
  //    全部失敗時用 localStorage 最後一次成功嘅資料（result.savedAt = 儲存時間 ms）
  // ============================================================
  async function fetchAllStationsWeather(stations) {
    const out = stations.map(st => {
      // tide-data.json stationList 用 `lng`（亦容錯 `lon`）
      const lat = st.lat, lng = st.lng !== undefined ? st.lng : st.lon;
      if (lat === undefined || lng === undefined) {
        return { station: st, data: null, error: '站 ' + (st.code || st.name_zh) + ' 缺少 lat/lng' };
      }
      const key = getCacheKey(lat, lng), c = cache.get(key);
      if (c && Date.now() - c.at < CACHE_TTL_MS) return { station: st, data: c.data, error: null };
      return { station: st, data: null, error: null, lat, lng, key };
    });
    const need = out.filter(r => r.key);
    if (need.length) {
      try {
        let json = await fetchJsonRetry(buildUrl(need.map(r => r.lat).join(','), need.map(r => r.lng).join(',')));
        if (!Array.isArray(json)) json = [json];   // 只得 1 個地點時 API 回單一物件
        if (json.length !== need.length) throw new Error('回傳數目不符');
        need.forEach((r, i) => { r.data = parseWeather(json[i]); cache.set(r.key, { at: Date.now(), data: r.data }); });
        saveGood(need.map(r => [r.key, r.data]));
      } catch (e) {
        console.warn('Open-Meteo batch fetch failed', e);
        const saved = loadSaved();
        need.forEach(r => {
          const c = cache.get(r.key), sv = saved[r.key];
          if (c) r.data = c.data;                                  // 30 分鐘外嘅記憶體 cache
          else if (sv && sv.data) { r.data = sv.data; r.savedAt = sv.at; }
          else r.error = e.message;
        });
      }
    }
    return out.map(r => ({ station: r.station, data: r.data, error: r.data ? null : r.error, savedAt: r.savedAt }));
  }

  // ============================================================
  // 6. 蒲福風級（香港天文台標準）
  //    https://www.hko.gov.hk/tc/inform/ts/wind_beaufort.htm
  // ============================================================
  // [km/h, 名稱(繁體), 簡稱, 顏色]
  // 天文台蒲福氏風級（https://www.hko.gov.hk/tc/education/weather/wind-and-pressure/00112a-Beaufort_Land_Sea_Criterion.html）
  // [上限（唔包），天文台描述術語，簡稱，顏色]；風速先四捨五入到整數 km/h 再對
  const BEAUFORT_TABLE = [
    [2,   '無風', '無風', '#9ca3af'],   // 0：< 2
    [7,   '輕微', '輕微', '#22c55e'],   // 1：2–6
    [13,  '輕微', '輕微', '#22c55e'],   // 2：7–12
    [20,  '和緩', '和緩', '#22c55e'],   // 3：13–19
    [31,  '和緩', '和緩', '#84cc16'],   // 4：20–30
    [41,  '清勁', '清勁', '#eab308'],   // 5：31–40
    [52,  '強風', '強風', '#f59e0b'],   // 6：41–51
    [63,  '強風', '強風', '#f97316'],   // 7：52–62
    [76,  '烈風', '烈風', '#ef4444'],   // 8：63–75
    [88,  '烈風', '烈風', '#dc2626'],   // 9：76–87
    [104, '暴風', '暴風', '#b91c1c'],   // 10：88–103
    [118, '暴風', '暴風', '#991b1b'],   // 11：104–117
    [Infinity, '颶風', '颶風', '#7f1d1d']  // 12：≥ 118
  ];
  function beaufortLevel(kmh) {
    const k = Math.round(Number(kmh) || 0);
    const i = BEAUFORT_TABLE.findIndex(r => k < r[0]);
    return { level: i, name: BEAUFORT_TABLE[i][1], short: BEAUFORT_TABLE[i][2], color: BEAUFORT_TABLE[i][3], kmh: k };
  }

  // 降雨分級（mm；Open-Meteo current = 前 15 分鐘總和）：評分理由同天氣卡細字共用
  // hourMm：嗰個鐘嘅雨量（hourly）；≥ 30mm（天文台黃雨標準）當暴雨，取代大雨；冇 hourly（例如舊 cache）就照 15 分鐘雨量分級
  function rainInfo(mm, hourMm) {
    const p = Number(mm) || 0;
    if (typeof hourMm === 'number' && hourMm >= 30) return { score: -25, icon: '⛈️', short: '暴雨', text: `暴雨（過去一小時 ${hourMm.toFixed(1)} mm，達黃雨標準），不建議出釣` };
    if (p <= 0) return { score: 15, icon: '☀️', short: '無降雨', text: '無降雨，視野與水況良好' };
    if (p < 0.3) return { score: 15, icon: '🌂', short: '微量雨', text: `微量雨（${p.toFixed(1)} mm），影響輕微` };
    if (p < 3) return { score: 5, icon: '🌦️', short: '小雨', text: `小雨（${p.toFixed(1)} mm），仍可作釣` };
    return { score: -15, icon: '🌧️', short: '大雨', text: `大雨（${p.toFixed(1)} mm），水混魚散` };
  }

  // 匯出
  window.weatherLib = {
    fetchWeather,
    fetchAllStationsWeather,
    weatherCodeInfo,
    windCompass,
    windSparklineSvg,
    getFishingWeatherScore,
    beaufortLevel,
    rainInfo,
    parseWeather,
  };
})();