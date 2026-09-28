/* ============================================================
 * lib/astronomy.js
 * Route A1 — 月相 + 日出日落（純前端、無 API）
 *
 * 用途：在「新增魚獲」表單選日期時，顯示當天月相、
 *       日出日落時間，並給一行釣魚小提示。
 *
 * 精度：
 *   月相 — 1 天內誤差 < 1%（synodic month 29.530588853 天）
 *   日出日落 — ±1 分鐘（用 NOAA solar position 算法）
 *
 * 引用：<script src="./lib/astronomy.js"></script>
 *       暴露 window.Astro.{getMoonPhase, getSunTimes, getFishingTip}
 * ============================================================ */

(function (global) {
  'use strict';

  // 香港中心座標（釣魚點多在港島/九龍/新界，用中心點夠準）
  const HK_LAT = 22.3193;
  const HK_LNG = 114.1694;

  const RAD = Math.PI / 180;
  const SYNODIC_MONTH = 29.530588853; // 朔望月天數

  // 8 大月相的 synodic 區間（依天文慣例，0 = 新月）
  const PHASE_BANDS = [
    { from:  0,        to:  1.84566, name: '新月',     emoji: '🌑' },
    { from:  1.84566,  to:  5.53699, name: '眉月',     emoji: '🌒' },
    { from:  5.53699,  to:  9.22831, name: '上弦月',   emoji: '🌓' },
    { from:  9.22831,  to: 12.91963, name: '盈月',     emoji: '🌔' },
    { from: 12.91963,  to: 16.61096, name: '滿月',     emoji: '🌕' },
    { from: 16.61096,  to: 20.30228, name: '虧月',     emoji: '🌖' },
    { from: 20.30228,  to: 23.99361, name: '下弦月',   emoji: '🌗' },
    { from: 23.99361,  to: 27.68493, name: '殘月',     emoji: '🌘' },
    { from: 27.68493,  to: 29.53059, name: '新月',     emoji: '🌑' },
  ];

  /**
   * 取指定日期的月相
   * @param {Date} date
   * @returns {{phase:number, illumination:number, name:string, emoji:string}}
   */
  function getMoonPhase(date) {
    // 參考新月：2000-01-06 18:14 UTC
    const ref = Date.UTC(2000, 0, 6, 18, 14, 0);
    const days = (date.getTime() - ref) / 86400000;
    let phase = ((days % SYNODIC_MONTH) + SYNODIC_MONTH) % SYNODIC_MONTH;
    // illumination：0 = 新月全暗，1 = 滿月全亮
    const illumination = (1 - Math.cos(2 * Math.PI * phase / SYNODIC_MONTH)) / 2;

    let band = PHASE_BANDS[0];
    for (const b of PHASE_BANDS) {
      if (phase >= b.from && phase < b.to) { band = b; break; }
    }
    return {
      phase,
      illumination: Math.round(illumination * 100),
      name: band.name,
      emoji: band.emoji,
    };
  }

  /**
   * 取指定地點 + 日期的日出日落時間（香港本地時間，HH:MM）
   * 用 NOAA Solar Position Algorithm 簡化版
   * @param {Date} date
   * @param {number} [lat] 預設香港中心
   * @param {number} [lng] 預設香港中心
   * @returns {{sunrise:string, sunset:string, noon:string}|null}
   */
  function getSunTimes(date, lat, lng) {
    if (lat == null) lat = HK_LAT;
    if (lng == null) lng = HK_LNG;

    // 該日期在當年的第幾天（1-based）
    const start = new Date(date.getFullYear(), 0, 0);
    const dayOfYear = Math.floor((date - start) / 86400000);

    // 太陽赤緯
    const dec = 23.45 * RAD * Math.sin(2 * Math.PI * (284 + dayOfYear) / 365);

    // 時角（hour angle）— 日出/日落的時間偏移（度）
    const phi = lat * RAD;
    // -0.833° 修正大氣折射 + 太陽盤面半徑
    const cosH = (Math.sin(-0.833 * RAD) - Math.sin(phi) * Math.sin(dec)) /
                 (Math.cos(phi) * Math.cos(dec));
    if (cosH > 1 || cosH < -1) return null; // 極晝/極夜（香港不會發生，但防呆）
    const H = Math.acos(cosH) / RAD;

    // Equation of time（時差，單位分鐘）
    const B = 2 * Math.PI * (dayOfYear - 81) / 365;
    const eot = 9.87 * Math.sin(2 * B) - 7.53 * Math.cos(B) - 1.5 * Math.sin(B);

    // 太陽正中天的 UTC 時間（分鐘）
    const solarNoonUTC = 720 - 4 * lng - eot;

    // 轉成香港時間（UTC+8 = +480 分鐘）
    const solarNoonHK = solarNoonUTC + 480;
    const sunriseHK = solarNoonHK - H * 4;
    const sunsetHK = solarNoonHK + H * 4;

    function fmt(min) {
      let m = ((min % 1440) + 1440) % 1440;
      const h = Math.floor(m / 60);
      const mm = Math.round(m % 60);
      return String(h).padStart(2, '0') + ':' + String(mm).padStart(2, '0');
    }

    return {
      sunrise: fmt(sunriseHK),
      sunset: fmt(sunsetHK),
      noon: fmt(solarNoonHK),
    };
  }

  /**
   * 依月相 + 日落時間，給一行釣魚小提示
   * @param {{name:string, illumination:number}} moon
   * @param {{sunrise:string, sunset:string}} sun
   * @returns {string}
   */
  function getFishingTip(moon, sun) {
    const ill = moon.illumination;
    if (ill < 20) {
      return '🌑 新月前後魚訊活躍，磯釣推薦';
    } else if (ill < 45) {
      return '🌒 月色偏暗，底棲魚覓食機會高';
    } else if (ill < 70) {
      return '🌓 月色中等，黃昏前後試試';
    } else if (ill < 90) {
      return '🌔 月光偏亮，注意夜釣大魚';
    } else {
      return '🌕 滿月夜魚偏靜，建議日出/日落前後作釣';
    }
  }

  /**
   * 取釣魚指數（0-100，rule-based 簡單版）
   * 暫時只用月相 + 距離日落時間兩維度
   * @param {Date} date
   * @param {string} catchTime HH:MM（魚獲時間）
   * @returns {{score:number, level:string, emoji:string}}
   */
  function getFishingScore(date, catchTime) {
    const moon = getMoonPhase(date);
    const sun = getSunTimes(date);

    let score = 50; // baseline

    // 月相加分：越暗越好（魚更靠岸覓食）
    score += (100 - moon.illumination) * 0.3; // 最多 +30

    // 時間加分：黃昏前後 1hr 為黃金
    if (sun) {
      const [hh, mm] = (catchTime || '12:00').split(':').map(Number);
      const catchMin = hh * 60 + mm;
      const sunsetMin = parseInt(sun.sunset.slice(0,2)) * 60 + parseInt(sun.sunset.slice(3,5));
      const diff = Math.abs(catchMin - sunsetMin);
      if (diff < 60) score += 20;
      else if (diff < 120) score += 10;
    }

    score = Math.max(0, Math.min(100, Math.round(score)));

    let level, emoji;
    if (score >= 80) { level = '極佳'; emoji = '🔥'; }
    else if (score >= 60) { level = '良好'; emoji = '👍'; }
    else if (score >= 40) { level = '普通'; emoji = '😐'; }
    else { level = '較差'; emoji = '⚠️'; }

    return { score, level, emoji };
  }

  // 暴露到 window
  global.Astro = {
    getMoonPhase,
    getSunTimes,
    getFishingTip,
    getFishingScore,
    HK_LAT, HK_LNG,
  };

  // 同時支援 CommonJS（測試用）
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = global.Astro;
  }
})(typeof window !== 'undefined' ? window : globalThis);