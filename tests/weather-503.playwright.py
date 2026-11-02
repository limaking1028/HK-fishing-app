# v192 天氣 503 修正：390×844 訪客模式。api.open-meteo.com 全部 mock；supabase.co 一律 abort（唔會掂 prod）。
# 測：合併 1 個請求嘅對應、503 重試時間、timeout 重試、全失敗顯示舊資料「更新於」、>24 小時警告、第一次用冇資料嘅錯誤卡、catchStats。
import http.server, threading, functools, os, json, time
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR', '/tmp')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
ST = json.load(open(os.path.join(root, 'lib/tide-data.json')))['stationList']
fails = []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
def one(temp):
    return {'current': {'time': '2026-11-02T22:00', 'temperature_2m': temp, 'relative_humidity_2m': 70, 'precipitation': 0, 'weather_code': 1, 'wind_speed_10m': 12, 'wind_direction_10m': 90, 'pressure_msl': 1015, 'cloud_cover': 20},
            'hourly': {'time': ['2026-11-02T%02d:00' % h for h in range(24)], 'temperature_2m': [temp] * 24, 'precipitation': [0] * 24, 'wind_speed_10m': [12] * 24, 'wind_direction_10m': [90] * 24, 'weather_code': [1] * 24, 'relative_humidity_2m': [70] * 24, 'pressure_msl': [1015] * 24, 'cloud_cover': [20] * 24}}
def body_for(u):   # 每個地點嘅溫度 = 10 + 站序號（按 latitude 搵返係邊個站）
    lats = u.split('latitude=')[1].split('&')[0].split(',')
    idx = [next(i for i, s in enumerate(ST) if str(s['lat']) == la) for la in lats]
    arr = [one(10 + i) for i in idx]
    return json.dumps(arr if len(arr) > 1 else arr[0])

def session(p, plan, saved=None, tag=''):
    """plan: list of actions per Open-Meteo request: 'ok' | 503 | 429 | 'hang'"""
    b = p.chromium.launch(); c = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, device_scale_factor=2)
    if saved: c.add_init_script('localStorage.setItem("wx_last_good_v1", %s)' % json.dumps(json.dumps(saved)))
    pg = c.new_page(); st = {'errs': [], 'sb': [], 'req': [], 'hung': []}
    pg.on('pageerror', lambda e: st['errs'].append(str(e)))
    def route(r):
        u = r.request.url
        if 'supabase.co' in u: st['sb'].append(u); return r.abort()
        if 'api.open-meteo.com' in u:
            st['req'].append((time.time(), u)); a = plan[min(len(st['req']) - 1, len(plan) - 1)]
            if a == 'hang': st['hung'].append(r); return
            if a == 'ok': return r.fulfill(status=200, body=body_for(u), content_type='application/json')
            return r.fulfill(status=a, body='{"error":true,"reason":"The service is overloaded"}', content_type='application/json')
        r.continue_()
    pg.route('**/*', route)
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(2500)
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(800)
    st['n0'] = len(st['sb']); st['t0'] = time.time()
    pg.evaluate("switchMapTab('weather')")
    return b, pg, st
def wait_cards(pg, ms):
    pg.wait_for_function("document.querySelector('.weather-list-grid')", timeout=ms)
def temps(pg):
    return pg.evaluate("[...document.querySelectorAll('.weather-card')].map(c => [c.querySelector('.weather-card-name').innerText.replace('📡','').trim(), (c.querySelector('.weather-card-temp')||{}).innerText||''])")
def common_end(b, pg, st, t):
    check(len(st['sb']) == st['n0'], t + '訪客模式 0 個 supabase.co call'); check(not st['errs'], t + 'no page errors ' + str(st['errs']))
    body = pg.inner_text('body'); check('免費' not in body, t + '冇「免費」'); b.close()

with sync_playwright() as p:
    # 1. 正常：1 個請求，12 站各自數值
    b, pg, st = session(p, ['ok']); wait_cards(pg, 15000); t = '[normal] '
    check(len(st['req']) == 1, t + f'只發 1 個 Open-Meteo 請求（{len(st["req"])}）')
    check(st['req'][0][1].count(',') >= 2 * (len(ST) - 1), t + '請求帶齊 12 組逗號分隔 lat/lon')
    tt = temps(pg); exp = [(s['name_zh'], '%.1f°C' % (10 + i)) for i, s in enumerate(ST)]
    check([(n, v.replace('\n', '')) for n, v in tt] == exp, t + '每個站顯示自己嘅數值 ' + str(tt[:3]))
    saved = pg.evaluate("JSON.parse(localStorage.getItem('wx_last_good_v1'))")
    check(saved and len(saved) == len(ST) and all('at' in v for v in saved.values()), t + '成功後存入 localStorage 連時間')
    check(pg.locator('.weather-saved-note').count() == 0 and pg.locator('#weather-retry-btn').count() == 0, t + '冇舊資料提示、冇重試掣')
    pg.screenshot(path=f'{shots}/normal-390x844.png'); common_end(b, pg, st, t)

    # 2. 503 一次之後成功：約 1 秒後重試
    b, pg, st = session(p, [503, 'ok']); wait_cards(pg, 15000); t = '[503-then-ok] '
    gap = st['req'][1][0] - st['req'][0][0] if len(st['req']) > 1 else 0
    check(len(st['req']) == 2 and 0.8 <= gap <= 2.0, t + f'第 2 個請求喺 ~1 秒後（{gap:.2f}s）')
    check(pg.locator('.weather-card-error').count() == 0 and pg.locator('.weather-card').count() == len(ST), t + '12 張卡全部正常')
    common_end(b, pg, st, t)

    # 3. 全部失敗 + 有舊資料（2 小時前）：顯示舊數值 +「更新於 HH:MM」
    now = int(time.time() * 1000); data = None
    b0, pg0, st0 = session(p, ['ok']); wait_cards(pg0, 15000)
    data = pg0.evaluate("JSON.parse(localStorage.getItem('wx_last_good_v1'))"); b0.close()
    def aged(ms): return {k: {'at': ms, 'data': v['data']} for k, v in data.items()}
    at2 = now - 2 * 3600 * 1000
    b, pg, st = session(p, [503], saved=aged(at2)); wait_cards(pg, 25000); t = '[allfail-saved] '
    gaps = [round(st['req'][i + 1][0] - st['req'][i][0], 1) for i in range(len(st['req']) - 1)]
    check(len(st['req']) == 4, t + f'1 + 3 次重試 = 4 個請求，間隔 {gaps}（預期 ~1, 3, 8）')
    check(len(gaps) == 3 and abs(gaps[0] - 1) < 0.6 and abs(gaps[1] - 3) < 0.8 and abs(gaps[2] - 8) < 1.2, t + '重試時間大約 1s/3s/8s')
    hk = time.gmtime(at2 / 1000 + 8 * 3600); hhmm = '%02d:%02d' % (hk.tm_hour, hk.tm_min)
    note = pg.locator('.weather-saved-note').inner_text() if pg.locator('.weather-saved-note').count() else ''
    check(f'更新於 {hhmm}' in note and '超過 24 小時' not in note, t + '提示：' + note)
    check(pg.locator('.weather-card-error').count() == 0 and len([1 for n, v in temps(pg) if v]) == len(ST), t + '12 站顯示舊數值')
    check(pg.locator('#weather-retry-btn').count() == 1, t + '有重新嘗試掣')
    pg.screenshot(path=f'{shots}/old-data-390x844.png'); common_end(b, pg, st, t)

    # 4. 舊資料超過 24 小時；同時試 429 唔重試
    at26 = now - 26 * 3600 * 1000
    b, pg, st = session(p, [429], saved=aged(at26)); wait_cards(pg, 15000); t = '[stale-24h+429] '
    hk = time.gmtime(at26 / 1000 + 8 * 3600); exp = '%d月%02d日 %02d:%02d' % (hk.tm_mon, hk.tm_mday, hk.tm_hour, hk.tm_min)
    note = pg.locator('.weather-saved-note').inner_text() if pg.locator('.weather-saved-note').count() else ''
    check(f'更新於 {exp}，資料已超過 24 小時）' in note, t + '提示：' + note)
    check(len(st['req']) == 1, t + f'429 唔重試（{len(st["req"])} 個請求）')
    pg.screenshot(path=f'{shots}/old-data-24h-390x844.png'); common_end(b, pg, st, t)

    # 5. 第一次用、冇舊資料、全失敗：錯誤卡 + 錯誤碼 + 重新嘗試掣；撳掣用 1 個請求恢復
    b, pg, st = session(p, [503]); wait_cards(pg, 25000); t = '[first-use] '
    check(pg.locator('.weather-card-error').count() == len(ST), t + '12 張錯誤卡')
    check(pg.locator('.weather-err-code').first.inner_text() == '錯誤碼：HTTP 503', t + '錯誤碼 HTTP 503')
    check(pg.locator('#weather-retry-btn').count() == 1, t + '有重新嘗試掣')
    pg.screenshot(path=f'{shots}/first-use-error-390x844.png')
    n = len(st['req'])
    pg.evaluate("window.__p = []"); 
    def okroute(r):
        u = r.request.url
        if 'api.open-meteo.com' in u: st['req'].append((time.time(), u)); return r.fulfill(status=200, body=body_for(u), content_type='application/json')
        if 'supabase.co' in u: st['sb'].append(u); return r.abort()
        r.continue_()
    pg.unroute('**/*'); pg.route('**/*', okroute)
    pg.click('#weather-retry-btn'); pg.wait_for_timeout(1500)
    check(len(st['req']) - n == 1, t + '重新嘗試用 1 個請求')
    check(pg.locator('.weather-card-error').count() == 0 and pg.locator('#weather-retry-btn').count() == 0, t + '全部恢復、掣消失')
    common_end(b, pg, st, t)

    # 6. timeout：第一個請求冇回應 → ~10 秒後 abort，再等 1 秒重試成功
    b, pg, st = session(p, ['hang', 'ok']); wait_cards(pg, 20000); t = '[timeout] '
    gap = st['req'][1][0] - st['req'][0][0] if len(st['req']) > 1 else 0
    check(len(st['req']) == 2 and 10.5 <= gap <= 12.5, t + f'~10s timeout + 1s 後重試（{gap:.1f}s）')
    check(pg.locator('.weather-card-error').count() == 0, t + '重試後全部正常')
    common_end(b, pg, st, t)

    # 7. catchStats：fetchWeather(lat,lng) 單點介面照用（503 一次後成功）
    b, pg, st = session(p, [503, 'ok']); pg.wait_for_timeout(300); t = '[catchStats] '
    r = pg.evaluate("""async () => { const now = new Date(Date.now() + 8*3600e3).toISOString();
        const s = await window.catchStatsLib.enrichWeatherAsync({}, 22.2885, 114.213, now.slice(0,10), now.slice(11,16));
        return s.weather; }""")
    check(bool(r) and r.get('source') != 'unavailable', t + 'enrichWeatherAsync 攞到天氣 ' + json.dumps(r, ensure_ascii=False)[:120])
    common_end(b, pg, st, t)
print('RESULT', 'OK' if not fails else 'FAILED %d' % len(fails)); srv.shutdown()
raise SystemExit(1 if fails else 0)
