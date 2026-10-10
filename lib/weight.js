/* ============================================================
 * lib/weight.js — 重量單位換算（克 / 公斤 / 斤 / 兩）
 *
 * 標準重量 = 公斤（kg，精確到克）。所有排序、比較、排行榜都用標準重量。
 * 1 斤 = 16 兩 = 604.79 克（香港市制）；1 兩 = 37.7994 克
 *
 * 暴露 window.weightLib
 * ============================================================ */
(function () {
  'use strict';
  const GRAMS = { g: 1, kg: 1000, jin: 604.79, tael: 37.7994 };
  const NAMES = { g: '克', kg: '公斤', jin: '斤', tael: '兩' };
  const DECIMALS = { g: 0, kg: 2, jin: 1, tael: 1 };
  const UNITS = ['kg', 'g', 'jin', 'tael'];
  const MAX_KG = 60;               // 上限（約 100 斤），須同資料庫 weight 約束一致
  const DEFAULT_UNIT = 'kg';
  const PREF_KEY = 'hk_fishing_weight_unit';

  function isUnit(u) { return Object.prototype.hasOwnProperty.call(GRAMS, u); }
  function round3(x) { return Math.round(x * 1000) / 1000; }

  /** 任何單位 → 標準公斤（精確到克） */
  function toKg(value, unit) {
    const v = Number(value);
    if (!isFinite(v) || !isUnit(unit)) return NaN;
    return round3(v * GRAMS[unit] / 1000);
  }
  /** 標準公斤 → 指定單位（未捨入） */
  function fromKg(kg, unit) {
    return Number(kg) * 1000 / GRAMS[isUnit(unit) ? unit : DEFAULT_UNIT];
  }
  /** 舊版「斤」欄位 → 公斤（讀取舊資料用） */
  function jinToKg(jin) { return round3(Number(jin) * GRAMS.jin / 1000); }
  /** 公斤 → 舊版 weight 欄位（斤，2 位小數，最少 0.01 以符合 weight > 0 約束） */
  function legacyJin(kg) { return Math.max(0.01, Math.round(fromKg(kg, 'jin') * 100) / 100); }

  /** 格式化：返回 { value:'1.20', unit:'公斤', text:'1.20 公斤' } */
  function format(kg, unit) {
    const u = isUnit(unit) ? unit : DEFAULT_UNIT;
    const n = Number(kg);
    const v = isFinite(n) ? fromKg(n, u) : 0;
    const value = v.toFixed(DECIMALS[u]);
    return { value, unit: NAMES[u], text: value + ' ' + NAMES[u] };
  }
  /** 其他單位對照，例如「= 1.20 公斤 · 2.0 斤 · 32.0 兩」 */
  function describeOthers(kg, exceptUnit) {
    return UNITS.filter(u => u !== exceptUnit).map(u => format(kg, u).text).join(' · ');
  }

  function getPref() {
    try { const u = localStorage.getItem(PREF_KEY); if (isUnit(u)) return u; } catch (e) {}
    return DEFAULT_UNIT;
  }
  function setPref(u) {
    if (!isUnit(u)) return;
    try { localStorage.setItem(PREF_KEY, u); } catch (e) {}
  }

  window.weightLib = {
    GRAMS, NAMES, UNITS, MAX_KG, DEFAULT_UNIT,
    isUnit, toKg, fromKg, jinToKg, legacyJin, format, describeOthers, getPref, setPref
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = window.weightLib;
})();
