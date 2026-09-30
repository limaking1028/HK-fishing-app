/* ============================================================
 * lib/geo.js — 用戶定位 + 最近站推薦（Geolocation API + Haversine）
 * ============================================================ */
(function(){
  // ============================================================
  // 1. Geolocation API 取得用戶位置
  // ============================================================
  // opts: { enableHighAccuracy, timeout, maximumAge, signal }
  // resolve({lat, lng, accuracy, timestamp})
  // reject({code, message}) - code: 'denied' / 'unavailable' / 'timeout' / 'unsupported'
  function getUserLocation(opts) {
    return new Promise((resolve, reject) => {
      if (typeof navigator === 'undefined' || !navigator.geolocation) {
        reject({ code: 'unsupported', message: '此裝置不支援定位' });
        return;
      }
      const options = Object.assign({
        enableHighAccuracy: true,
        timeout: 10000,
        maximumAge: 60000
      }, opts || {});
      navigator.geolocation.getCurrentPosition(
        pos => resolve({
          lat: pos.coords.latitude,
          lng: pos.coords.longitude,
          accuracy: pos.coords.accuracy,
          timestamp: pos.timestamp
        }),
        err => {
          // err.code: 1=PERMISSION_DENIED, 2=POSITION_UNAVAILABLE, 3=TIMEOUT
          const map = {
            1: { code: 'denied', message: '已拒絕定位權限' },
            2: { code: 'unavailable', message: '無法取得位置' },
            3: { code: 'timeout', message: '定位超時' }
          };
          reject(map[err.code] || { code: 'error', message: err.message || '定位失敗' });
        },
        options
      );
    });
  }

  // ============================================================
  // 2. Haversine 距離公式（兩經緯度間嘅 km）
  // ============================================================
  // 用地球平均半徑 6371 km，精度足夠釣魚站推薦（< 0.5% 誤差）
  function distanceKm(lat1, lng1, lat2, lng2) {
    const R = 6371;
    const toRad = d => d * Math.PI / 180;
    const dLat = toRad(lat2 - lat1);
    const dLng = toRad(lng2 - lng1);
    const a = Math.sin(dLat/2)**2 +
              Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
              Math.sin(dLng/2)**2;
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  }

  // 方位角（°，0=北，90=東，便於風向對齊）
  function bearingDeg(lat1, lng1, lat2, lng2) {
    const toRad = d => d * Math.PI / 180;
    const toDeg = r => r * 180 / Math.PI;
    const dLng = toRad(lng2 - lng1);
    const y = Math.sin(dLng) * Math.cos(toRad(lat2));
    const x = Math.cos(toRad(lat1)) * Math.sin(toRad(lat2)) -
              Math.sin(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.cos(dLng);
    const brng = toDeg(Math.atan2(y, x));
    return (brng + 360) % 360;
  }

  // ============================================================
  // 3. 找出最近 N 個站（按距離排序）
  // ============================================================
  // stations: [{code, name_zh, area, lat, lng, ...}]
  // 返回 [{...station, distanceKm, bearingDeg}]
  function getNearestStations(lat, lng, stations, n) {
    if (!Array.isArray(stations)) return [];
    const n2 = n || 3;
    return stations
      .filter(s => typeof s.lat === 'number' && typeof s.lng === 'number')
      .map(s => ({
        ...s,
        distanceKm: distanceKm(lat, lng, s.lat, s.lng),
        bearingDeg: bearingDeg(lat, lng, s.lat, s.lng)
      }))
      .sort((a, b) => a.distanceKm - b.distanceKm)
      .slice(0, n2);
  }

  // ============================================================
  // 4. 格式化距離 + 方位（中文）
  // ============================================================
  // distanceKm < 1 → m；>= 1 → km（一位小數）
  function formatDistance(km) {
    if (km < 1) return Math.round(km * 1000) + ' m';
    if (km < 10) return km.toFixed(1) + ' km';
    return Math.round(km) + ' km';
  }

  function formatBearing(deg) {
    const dirs = ['北','東北','東','東南','南','西南','西','西北'];
    const idx = Math.round(deg / 45) % 8;
    return dirs[idx];
  }

  function formatAccuracy(m) {
    if (!m) return '';
    if (m < 100) return '±' + Math.round(m) + ' m';
    if (m < 1000) return '±' + Math.round(m/10)*10 + ' m';
    return '±' + (m/1000).toFixed(1) + ' km';
  }

  // ============================================================
  // 5. 地理位置分類（陸地/海上 heuristic — 簡單版）
  // ============================================================
  // 香港海域大概範圍（粗略）：緯度 22.15-22.56，經度 113.85-114.45
  // 香港最北：沙頭角 22.553°N；最南：蒲台島 22.155°N
  // 最西：雞翼角 113.85°E；最東：東平洲 114.45°E
  function isLikelyHongKong(lat, lng) {
    return lat >= 22.15 && lat <= 22.56 && lng >= 113.85 && lng <= 114.45;
  }

  // ============================================================
  // Export
  // ============================================================
  window.geoLib = {
    getUserLocation,
    distanceKm,
    bearingDeg,
    getNearestStations,
    formatDistance,
    formatBearing,
    formatAccuracy,
    isLikelyHongKong
  };
})();