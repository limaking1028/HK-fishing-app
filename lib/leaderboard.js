/* ============================================================
 * lib/leaderboard.js — 排行榜上榜條件（同 migration-v109 嘅資料庫規則一致）
 *
 * 上榜條件：
 *   1. 附照片（相簿揀嘅照片都可儲存，但唔計排行榜）
 *   2. 照片係即時影（拍攝時間距離揀相 ≤ 30 分鐘）
 *   3. 有 GPS 定位，而且喺香港範圍內
 *   4. 日期唔係未來，亦唔早過 7 日前
 *   5. 魚種喺列表內（自訂「其他」魚種唔計）
 *   6. 重量唔超過該魚種上限
 *
 * 真正嘅判定喺資料庫 trigger 做（App 唔可以自己決定），呢度只係畀用戶即時睇到提示。
 * 暴露 window.lbLib
 * ============================================================ */
(function () {
  'use strict';
  const MAX_AGE_DAYS = 7;
  const PHOTO_MAX_AGE_SEC = 1800;
  const HK_BOX = { latMin: 22.15, latMax: 22.56, lngMin: 113.85, lngMax: 114.45 };
  // 各魚種重量上限（公斤）。同 migration-v109-leaderboard.sql 嘅 species_limits 一致
  const LIMITS = {
    '泥鯭': 1.5,
    '石狗公': 2,
    '釘公': 1.5,
    '黃腳鱲': 3,
    '雞泡': 2,
    '沙鯭': 0.8,
    '黑鱲': 6,
    '牛屎鱲': 3,
    '三鬚': 1.5,
    '梳羅': 4,
    '牛鰍': 8,
    '油蠟': 3,
    '紅衫魚': 1,
    '盲鰽': 1,
    '金鼓': 1.5,
    '烏頭': 8,
    '沙鑽': 0.5,
    '沙巴龍躉': 20,
    '赤鱲': 15,
    '火點': 3,
    '牙點': 0.5,
    '左口': 10,
    '石蚌': 2,
    '坑鰜': 2,
    '連尖': 30,
    '哨牙妹': 0.3,
    '紅鮋': 2,
    '三刀': 5,
    '細鱗': 1.5,
    '白鬚公': 8,
    '海狼': 3,
    '煙仔': 0.8,
    '馬友': 10,
    '花鱸': 10,
    '星鱸': 5,
    '黃立鯧': 8,
    '石剎': 0.5,
    '黃花': 3,
    '䱛仔': 2,
    '雞魚': 3,
    '牛廣GT': 59,
    '魔鬼魚': 59,
    '青斑': 20,
    '芝麻斑': 30,
    '白鱲': 3,
    '星點泥鯭': 1.5
  };
  const REASONS = {
    no_photo: '冇附照片',
    photo_invalid: '照片唔係喺 App 上載',
    photo_not_fresh: '照片唔係即時影（相簿相片唔計排行榜）',
    no_gps: '冇 GPS 定位',
    outside_hk: '定位唔喺香港範圍',
    date_future: '日期係未來',
    date_old: '日期早過 ' + MAX_AGE_DAYS + ' 日前',
    species_not_listed: '魚種唔喺列表（自訂魚種唔計）',
    weight_too_high: '重量超過該魚種上限',
    legacy: '舊紀錄（未有上榜資料）',
    demo: '示範資料'
  };
  const ORDER = ['no_photo', 'photo_invalid', 'photo_not_fresh', 'no_gps', 'outside_hk', 'date_future', 'date_old', 'species_not_listed', 'weight_too_high'];

  function reasonText(code) { return REASONS[code] || code || ''; }

  /**
   * 檢查一條魚獲，返回 { eligible, reasons: [code...] }（列出所有未達標嘅項目）
   * c: { hasPhoto, photoAgeSec, latitude, longitude, date('YYYY-MM-DD'), species, weight(kg), customSpecies }
   * today: 'YYYY-MM-DD'（本地日期）
   */
  function check(c, today) {
    const bad = [];
    if (!c.hasPhoto) bad.push('no_photo');
    else if (c.photoAgeSec == null || c.photoAgeSec > PHOTO_MAX_AGE_SEC || c.photoAgeSec < -60) bad.push('photo_not_fresh');
    if (c.latitude == null || c.longitude == null) bad.push('no_gps');
    else if (!(c.latitude >= HK_BOX.latMin && c.latitude <= HK_BOX.latMax && c.longitude >= HK_BOX.lngMin && c.longitude <= HK_BOX.lngMax)) bad.push('outside_hk');
    if (c.date && today) {
      if (c.date > today) bad.push('date_future');
      else {
        const lim = new Date(today + 'T00:00:00'); lim.setDate(lim.getDate() - MAX_AGE_DAYS);
        const limStr = lim.getFullYear() + '-' + String(lim.getMonth() + 1).padStart(2, '0') + '-' + String(lim.getDate()).padStart(2, '0');
        if (c.date < limStr) bad.push('date_old');
      }
    }
    const cap = Object.prototype.hasOwnProperty.call(LIMITS, c.species) ? LIMITS[c.species] : null;
    if (c.customSpecies || cap == null) bad.push('species_not_listed');
    else if (!(c.weight > 0) || c.weight > cap) bad.push('weight_too_high');
    bad.sort((a, b) => ORDER.indexOf(a) - ORDER.indexOf(b));
    return { eligible: bad.length === 0, reasons: bad };
  }

  window.lbLib = { MAX_AGE_DAYS, PHOTO_MAX_AGE_SEC, HK_BOX, LIMITS, REASONS, reasonText, check };
  if (typeof module !== 'undefined' && module.exports) module.exports = window.lbLib;
})();
