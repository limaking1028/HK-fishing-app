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
      'hourly=temperature_2m,precipitation,wind_speed_10m,wind_direction_10m,weather_code',
      'forecast_days=1',
      'wind_speed_unit=kmh',
      'timezone=Asia/Hong_Kong'
    ];
    return `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&${params.join('&')}`;
  }

  function getCacheKey(lat, lon) {
    return `${lat.toFixed(3)},${lon.toFixed(3)}`;
  }

  async function fetchWeather(lat, lon) {
    const key = getCacheKey(lat, lon);
    const cached = cache.get(key);
    if (cached && Date.now() - cached.at < CACHE_TTL_MS) {
      return cached.data;
    }
    try {
      const r = await fetch(buildUrl(lat, lon));
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const json = await r.json();
      const data = parseWeather(json);
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
        weatherCode: h.weather_code ? h.weather_code[i] : 0
      });
    }
    return {
      now: {
        time: nowMs,
        temp: c.temperature_2m ?? null,
        humidity: c.relative_humidity_2m ?? null,
        precip: c.precipitation ?? 0,
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
    const iNow = 0;
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
    // 風速評分
    const wK = w.windSpeed || 0;
    if (wK < 12) { score += 25; reasons.push({ icon: '🍃', text: `風力平靜（${wK.toFixed(0)} km/h），精細操作最佳` }); }
    else if (wK < 20) { score += 15; reasons.push({ icon: '🌤️', text: `微風（${wK.toFixed(0)} km/h），釣況良好` }); }
    else if (wK < 30) { score += 0; reasons.push({ icon: '💨', text: `中風（${wK.toFixed(0)} km/h），需加重鉛` }); }
    else { score -= 25; reasons.push({ icon: '🌪️', text: `強風（${wK.toFixed(0)} km/h），不建議出海` }); }
    // 降雨評分
    const pcp = w.precip || 0;
    if (pcp < 0.3) { score += 15; reasons.push({ icon: '☀️', text: '無降雨，視野與水況良好' }); }
    else if (pcp < 3) { score += 5; reasons.push({ icon: '🌦️', text: `小雨（${pcp.toFixed(1)} mm），仍可作釣` }); }
    else { score -= 15; reasons.push({ icon: '🌧️', text: `大雨（${pcp.toFixed(1)} mm），水混魚散` }); }
    // 氣壓評分（魚對氣壓敏感：穩定 1010-1020 最佳）
    const p = w.pressure;
    if (p === null || p === undefined) { /* skip */ }
    else if (p >= 1010 && p <= 1020) { score += 15; reasons.push({ icon: '🎯', text: `氣壓穩定（${p.toFixed(0)} hPa），魚群活躍` }); }
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
    let label, color, bg;
    if (score >= 80) { label = '極佳'; color = '#15803d'; bg = '#dcfce7'; }
    else if (score >= 65) { label = '良好'; color = '#0e7490'; bg = '#cffafe'; }
    else if (score >= 45) { label = '一般'; color = '#b45309'; bg = '#fef3c7'; }
    else if (score >= 25) { label = '較差'; color = '#b91c1c'; bg = '#fee2e2'; }
    else { label = '不建議'; color = '#7f1d1d'; bg = '#fecaca'; }
    return { score, label, color, bg, reasons, weatherIcon: wc.icon, weatherLabel: wc.label };
  }

  // ============================================================
  // 6. 批量取 6 站天氣（parallel fetch）
  // ============================================================
  async function fetchAllStationsWeather(stations) {
    const promises = stations.map(async st => {
      try {
        // tide-data.json stationList 用 `lng`（亦容錯 `lon`）
        const lat = st.lat;
        const lng = st.lng !== undefined ? st.lng : st.lon;
        if (lat === undefined || lng === undefined) {
          throw new Error('站 ' + (st.code || st.name_zh) + ' 缺少 lat/lng');
        }
        const data = await fetchWeather(lat, lng);
        return { station: st, data, error: null };
      } catch (e) {
        return { station: st, data: null, error: e.message };
      }
    });
    return Promise.all(promises);
  }

  // ============================================================
  // 6. 蒲福風級（香港天文台標準）
  //    https://www.hko.gov.hk/tc/inform/ts/wind_beaufort.htm
  // ============================================================
  // [km/h, 名稱(繁體), 簡稱, 顏色]
  const BEAUFORT_TABLE = [
    [1,   '無風',   '無風',   '#9ca3af'],   // 0
    [5,   '軟風',   '軟風',   '#22c55e'],   // 1
    [11,  '輕風',   '輕風',   '#22c55e'],   // 2
    [19,  '微風',   '微風',   '#22c55e'],   // 3
    [28,  '和風',   '和風',   '#84cc16'],   // 4
    [38,  '清風',   '清風',   '#eab308'],   // 5
    [49,  '強風',   '強風',   '#f59e0b'],   // 6
    [61,  '疾風',   '疾風',   '#f97316'],   // 7
    [74,  '大風',   '大風',   '#ef4444'],   // 8
    [88,  '烈風',   '烈風',   '#dc2626'],   // 9
    [102, '暴風',   '暴風',   '#b91c1c'],   // 10
    [Infinity, '颶風', '颶風', '#7f1d1d']  // 11+
  ];
  function beaufortLevel(kmh) {
    const k = Number(kmh) || 0;
    for (let i = 0; i < BEAUFORT_TABLE.length; i++) {
      if (k < BEAUFORT_TABLE[i][0]) {
        return { level: i, name: BEAUFORT_TABLE[i][1], short: BEAUFORT_TABLE[i][2], color: BEAUFORT_TABLE[i][3] };
      }
    }
    return { level: 11, name: '颶風', short: '颶風', color: '#7f1d1d' };
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
  };
})();