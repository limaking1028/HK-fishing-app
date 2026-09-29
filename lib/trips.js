/* ============================================================
 *  lib/trips.js — Route H 釣魚行程
 *  純前端計時器 + 格式化函式
 *  全域：window.tripsLib
 * ============================================================ */
(function() {
  'use strict';

  // 格式化 秒數 → "HH:MM:SS"
  function formatTimerDisplay(totalSec) {
    const s = Math.max(0, Math.floor(totalSec || 0));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const pad = n => String(n).padStart(2, '0');
    return pad(h) + ':' + pad(m) + ':' + pad(sec);
  }

  // 格式化 時長（給行程列表/詳情用，可省略秒）
  function formatDuration(totalSec, withSeconds) {
    if (!totalSec || totalSec < 0) return withSeconds ? '00:00:00' : '0分鐘';
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;
    if (withSeconds) return formatTimerDisplay(totalSec);
    if (h === 0) return m + '分鐘';
    if (m === 0) return h + '小時';
    return h + '小時' + m + '分';
  }

  // 行程狀態文字
  function tripStatusText(trip, now) {
    if (!trip.ended_at) return '進行中';
    const diff = (now || Date.now()) - new Date(trip.ended_at).getTime();
    const min = Math.floor(diff / 60000);
    if (min < 1) return '剛結束';
    if (min < 60) return min + '分鐘前結束';
    const hr = Math.floor(min / 60);
    if (hr < 24) return hr + '小時前結束';
    const day = Math.floor(hr / 24);
    if (day < 30) return day + '天前結束';
    return new Date(trip.ended_at).toLocaleDateString('zh-HK');
  }

  // 計算行程時長（秒）
  function tripDurationSec(trip, now) {
    const start = new Date(trip.started_at).getTime();
    const end = trip.ended_at ? new Date(trip.ended_at).getTime() : (now || Date.now());
    return Math.max(0, Math.floor((end - start) / 1000));
  }

  // 計算行程內魚獲統計
  function summarizeTripCatches(trip, allCatches) {
    const list = allCatches.filter(c => c.trip_id === trip.id);
    let totalWeight = 0;
    const speciesSet = new Set();
    list.forEach(c => {
      totalWeight += Number(c.weight) || 0;
      if (c.species) speciesSet.add(c.species);
    });
    return {
      count: list.length,
      totalWeight: Math.round(totalWeight * 100) / 100,
      speciesCount: speciesSet.size,
      catches: list
    };
  }

  // localStorage key
  const ACTIVE_KEY = 'hk_fishing_active_trip';

  // 儲存 active trip 到 localStorage（跨 reload 不丟計時）
  function saveActiveTrip(trip) {
    if (!trip) {
      localStorage.removeItem(ACTIVE_KEY);
      return;
    }
    try {
      localStorage.setItem(ACTIVE_KEY, JSON.stringify({
        id: trip.id,
        startedAt: trip.started_at,
        spot: trip.spot || ''
      }));
    } catch (e) {}
  }

  function loadActiveTrip() {
    try {
      const raw = localStorage.getItem(ACTIVE_KEY);
      if (!raw) return null;
      return JSON.parse(raw);
    } catch (e) { return null; }
  }

  function clearActiveTrip() {
    localStorage.removeItem(ACTIVE_KEY);
  }

  // 計時器（外部傳入 tick 函式，回傳 interval id）
  let _timerHandle = null;
  function startTimer(tickFn, intervalMs) {
    stopTimer();
    const ms = intervalMs || 1000;
    _timerHandle = setInterval(() => {
      try { tickFn(); } catch (e) { console.warn('trip timer tick failed', e); }
    }, ms);
    // 立即觸發一次
    try { tickFn(); } catch (e) {}
    return _timerHandle;
  }
  function stopTimer() {
    if (_timerHandle) {
      clearInterval(_timerHandle);
      _timerHandle = null;
    }
  }

  // 匯出
  window.tripsLib = {
    formatTimerDisplay: formatTimerDisplay,
    formatDuration: formatDuration,
    tripStatusText: tripStatusText,
    tripDurationSec: tripDurationSec,
    summarizeTripCatches: summarizeTripCatches,
    saveActiveTrip: saveActiveTrip,
    loadActiveTrip: loadActiveTrip,
    clearActiveTrip: clearActiveTrip,
    startTimer: startTimer,
    stopTimer: stopTimer
  };
})();