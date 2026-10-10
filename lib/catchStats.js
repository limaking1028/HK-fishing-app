/* ============================================================
 * lib/catchStats.js — 魚獲統計數據增強（純前端、無 API）
 *
 * 用途：在 submitCatch 時，靜默補上未來統計需要的維度
 *       - 時間桶（hour/weekday/month/season）
 *       - 月相（phase/illumination/moonAge）
 *       - 太陽位置（sunrise/sunset/goldenHour/phaseOfDay）
 *       - 潮汐（height/trend/hoursToNextHigh/isSpringTide）
 *       - 地理（area/nearestTideStation/distance）
 *       - 天氣為 null，由 async 路徑單獨填入
 *
 * 設計：純函式、同步執行、失敗時返回 null 或部分數據（不 throw）
 *
 * 引用：<script src="./lib/catchStats.js"></script>
 *       暴露 window.catchStatsLib.enrich({...})
 *
 * 依賴：lib/astronomy.js (window.Astro)
 *       lib/tides.js (window.tidesLib)
 *       lib/geo.js (window.geoLib)
 * ============================================================ */

(function() {
  'use strict';

  // ============================================================
  // 季節判定（北半球，月份為 1-based）
  // ============================================================
  function getSeason(month) {
    if (month >= 3 && month <= 5)  return 'spring';
    if (month >= 6 && month <= 8)  return 'summer';
    if (month >= 9 && month <= 11) return 'autumn';
    return 'winter';
  }

  // ============================================================
  // 時段分類（依當日 sunrise/sunset 動態計算）
  // ============================================================
  function phaseOfDay(hour, minute, sunriseMin, sunsetMin) {
    const t = hour * 60 + (minute || 0);
    const sunrise = sunriseMin != null ? sunriseMin : 6 * 60;   // 預設 06:00
    const sunset  = sunsetMin  != null ? sunsetMin  : 18 * 60;  // 預設 18:00

    const goldenMorningStart = sunrise - 60;
    const goldenMorningEnd   = sunrise + 60;
    const goldenEveningStart = sunset - 60;
    const goldenEveningEnd   = sunset + 60;

    if (t < goldenMorningStart)               return 'night';
    if (t < sunrise)                          return 'dawn';
    if (t < goldenMorningEnd)                 return 'golden_morning';
    if (t < 11 * 60)                          return 'morning';
    if (t < 13 * 60)                          return 'noon';
    if (t < 16 * 60)                          return 'afternoon';
    if (t < goldenEveningStart)               return 'late_afternoon';
    if (t < goldenEveningEnd)                 return 'golden_evening';
    if (t < sunset + 60)                      return 'dusk';
    return 'night';
  }

  // HH:MM → 分鐘
  function hhmmToMin(s) {
    if (!s) return null;
    const [h, m] = s.split(':').map(Number);
    return h * 60 + (m || 0);
  }

  // ============================================================
  // 潮汐判定（用今日潮差 vs 全年平均）
  // 香港平均潮差 ≈ 1.0m
  // 大潮：潮差 ≥ 1.5m（初一/十五前後）
  // 中潮：1.0m ≤ 潮差 < 1.5m
  // 小潮：潮差 < 1.0m
  // ============================================================
  function tideCategory(rangeMeters) {
    if (rangeMeters == null) return null;
    if (rangeMeters >= 1.5) return 'spring';   // 大潮
    if (rangeMeters >= 1.0) return 'medium';   // 中潮
    return 'neap';                              // 小潮
  }

  // 距離到下一個潮汐事件（小時，負數 = 已過）
  function hoursToEvent(targetMs, eventMs) {
    if (eventMs == null) return null;
    return Math.round((eventMs - targetMs) / 360000) / 10;  // 保留 1 位小時
  }

  // ============================================================
  // 主函式：enrich
  //
  // input:  { dateStr, timeStr, lat, lng, spot }
  // dateStr: 'YYYY-MM-DD'
  // timeStr: 'HH:MM'
  // output: stats 物件（部分欄位可能為 null）
  // ============================================================
  function enrich(input) {
    if (!input || !input.dateStr || !input.timeStr) return null;

    const result = {};
    try {
      // 解析本地時間（假設香港 UTC+8）
      const [y, mo, d] = input.dateStr.split('-').map(Number);
      const [h, mi]    = input.timeStr.split(':').map(Number);
      const dt = new Date(y, mo - 1, d, h, mi, 0, 0);
      const dtMs = dt.getTime();

      // ========== 時間維度 ==========
      result.temporal = {
        hour: dt.getHours(),
        minute: dt.getMinutes(),
        weekday: dt.getDay(),           // 0=週日, 6=週六
        weekdayName: ['日','一','二','三','四','五','六'][dt.getDay()],
        month: dt.getMonth() + 1,
        season: getSeason(dt.getMonth() + 1),
        isWeekend: dt.getDay() === 0 || dt.getDay() === 6,
        dateISO: dt.toISOString()
      };

      // ========== 月相 ==========
      try {
        if (window.Astro && window.Astro.getMoonPhase) {
          const moon = window.Astro.getMoonPhase(dt);
          result.moon = {
            phaseName: moon.name,         // 新月/眉月/上弦月/...
            phaseEmoji: moon.emoji,
            illuminationPct: moon.illumination,  // 0-100
            moonAgeDays: Math.round(moon.phase * 10) / 10,
            // 簡化分類：dark = 新月/眉月（魚較活躍）
            isDarkMoon: moon.illumination < 30
          };
        }
      } catch (e) { console.warn('catchStats: moon enrichment failed', e); }

      // ========== 太陽位置 ==========
      let sunriseMin = null, sunsetMin = null;
      try {
        if (window.Astro && window.Astro.getSunTimes) {
          const sun = window.Astro.getSunTimes(dt, input.lat, input.lng);
          if (sun && sun.sunrise && sun.sunset) {
            sunriseMin = hhmmToMin(sun.sunrise);
            sunsetMin  = hhmmToMin(sun.sunset);

            const catchMin = h * 60 + mi;
            const fromSunrise = Math.round((catchMin - sunriseMin) / 6) / 10;  // 小時
            const toSunset    = Math.round((sunsetMin - catchMin)  / 6) / 10;

            // Golden Hour：日出後 60min 內 或 日落前 60min 內
            const isGoldenHour =
              (catchMin >= sunriseMin - 60 && catchMin <= sunriseMin + 60) ||
              (catchMin >= sunsetMin - 60  && catchMin <= sunsetMin + 60);

            result.sun = {
              sunrise: sun.sunrise,
              sunset: sun.sunset,
              solarNoon: sun.noon,
              hoursFromSunrise: fromSunrise,
              hoursToSunset: toSunset,
              isGoldenHour: isGoldenHour,
              isDayTime: catchMin >= sunriseMin && catchMin <= sunsetMin,
              phaseOfDay: phaseOfDay(h, mi, sunriseMin, sunsetMin)
            };
          }
        }
      } catch (e) { console.warn('catchStats: sun enrichment failed', e); }

      // 若 sun 計算失敗，補一個預設 phaseOfDay
      if (!result.sun) {
        result.sun = {
          sunrise: null,
          sunset: null,
          isGoldenHour: false,
          isDayTime: h >= 6 && h < 18,
          phaseOfDay: phaseOfDay(h, mi, null, null)
        };
      }

      // ========== 潮汐 ==========
      try {
        if (window.tidesLib && window.tidesLib.describeCurrent) {
          const station = window.tidesLib.getStationForSpot(input.spot);
          const tide = window.tidesLib.describeCurrent(station, dtMs);
          const rangeM = window.tidesLib.getTidalRangeToday
            ? window.tidesLib.getTidalRangeToday(station, dtMs)
            : null;

          if (tide) {
            result.tide = {
              station: station,
              heightM: tide.height,
              trend: tide.trend,                // rising / falling / slack
              trendRate: tide.trendRate,         // m/hr
              hoursToNextHigh: tide.nextHigh ? hoursToEvent(dtMs, tide.nextHigh.ms) : null,
              hoursToNextLow: tide.nextLow ? hoursToEvent(dtMs, tide.nextLow.ms) : null,
              tidalRangeM: rangeM,
              tideType: tideCategory(rangeM),    // spring / medium / neap
              isMidTide: tide.trend === 'slack'
            };
          }
        }
      } catch (e) { console.warn('catchStats: tide enrichment failed', e); }

      // ========== 地理 ==========
      try {
        if (input.spot) {
          result.geo = {
            spotName: input.spot,
            area: null  // area 由 caller 從 getSpotInfo 填入
          };
        }
        if (window.geoLib && input.lat != null && input.lng != null) {
          // 找最近的潮汐站
          const stations = window.tidesLib && window.tidesLib.getAllStations
            ? window.tidesLib.getAllStations() : [];
          if (stations.length > 0) {
            let nearest = null, minDist = Infinity;
            for (const s of stations) {
              if (s.lat == null || s.lng == null) continue;
              const d = window.geoLib.distanceKm(input.lat, input.lng, s.lat, s.lng);
              if (d < minDist) { minDist = d; nearest = s; }
            }
            if (nearest) {
              result.geo.nearestTideStation = nearest.code;
              result.geo.distanceToStationKm = Math.round(minDist * 10) / 10;
            }
          }
        }
      } catch (e) { console.warn('catchStats: geo enrichment failed', e); }

      // ========== 天氣（async 路徑另填） ==========
      result.weather = null;
      result._schemaVersion = 1;
      result._enrichedAt = Date.now();

      return result;
    } catch (e) {
      console.warn('catchStats.enrich 整體失敗', e);
      return null;
    }
  }

  // ============================================================
  // 異步天氣補入（從 weatherLib 抓取後呼叫）
  // 注意：weatherLib.fetchWeather 只支援「當前」天氣（forecast 1 day）
  //       所以歷史魚獲的天氣快照只能為 null（除非用戶當下使用）
  // ============================================================
  async function enrichWeatherAsync(stats, catchLat, catchLng, catchDate) {
    if (!stats || !window.weatherLib || !window.weatherLib.fetchWeather || catchLat == null || catchLng == null) return stats;
    try {
      // 只補當日天氣（未來日期無歷史資料可查）
      const today = new Date();
      today.setHours(0,0,0,0);
      const catchD = catchDate ? new Date(catchDate) : today;
      catchD.setHours(0,0,0,0);
      const isToday = catchD.getTime() === today.getTime();

      if (!isToday) {
        // 歷史魚獲：天氣模組不支援歷史查詢（API 為 forecast-only）
        stats.weather = {
          source: 'unavailable',
          reason: 'historical_not_supported',
          note: 'Open-Meteo free tier 不提供歷史天氣，需付費 API 或本地氣象站'
        };
        return stats;
      }

      const w = await window.weatherLib.fetchWeather(catchLat, catchLng);
      const n = w && w.now;
      if (n) {
        stats.weather = {
          source: 'open-meteo',
          fetchedAt: Date.now(),
          airTempC: n.temp ?? null,
          humidityPct: n.humidity ?? null,
          precipitationMm: n.precip ?? null,
          windSpeedKmh: n.windSpeed ?? null,
          windDirDeg: n.windDir ?? null,
          pressureHpa: n.pressure ?? null,
          cloudCoverPct: n.cloud ?? null,
          weatherCode: n.weatherCode ?? null
        };
      }
    } catch (e) {
      console.warn('catchStats: weather async enrichment failed', e);
    }
    return stats;
  }

  // 暴露
  window.catchStatsLib = {
    enrich,
    enrichWeatherAsync,
    getSeason,
    phaseOfDay,
    tideCategory
  };

  // CommonJS（測試用）
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = window.catchStatsLib;
  }
})();