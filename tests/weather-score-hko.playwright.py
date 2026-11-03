# 暴雨卡：390×844 訪客模式，Open-Meteo 全部 mock（supabase.co abort）。鰂魚涌嗰個鐘 hourly 35mm → 「暴雨」；另一站冇 hourly → 照 15 分鐘雨量；舊 cache 格式唔出錯。
import http.server, threading, functools, os, json
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR', '/tmp')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
ST = json.load(open(os.path.join(root, 'lib/tide-data.json')))['stationList']
fails = []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
def one(i):
    cur = {'time': '2026-11-02T22:15', 'temperature_2m': 24, 'relative_humidity_2m': 90, 'precipitation': 9 if i == 0 else 4, 'weather_code': 65 if i == 0 else 63, 'wind_speed_10m': 18, 'wind_direction_10m': 90, 'pressure_msl': 1008, 'cloud_cover': 100}
    hp = [0] * 24; hp[22] = 35 if i == 0 else 29.9
    d = {'current': cur, 'hourly': {'time': ['2026-11-02T%02d:00' % h for h in range(24)], 'temperature_2m': [24] * 24, 'precipitation': hp, 'wind_speed_10m': [18] * 24, 'wind_direction_10m': [90] * 24, 'weather_code': [63] * 24, 'relative_humidity_2m': [90] * 24, 'pressure_msl': [1008] * 24, 'cloud_cover': [100] * 24}}
    if i == 2: del d['hourly']
    return d
def body(u):
    lats = u.split('latitude=')[1].split('&')[0].split(',')
    arr = [one(next(i for i, s in enumerate(ST) if str(s['lat']) == la)) for la in lats]
    return json.dumps(arr if len(arr) > 1 else arr[0])
def run(p, mode):
    b = p.chromium.launch(); c = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, device_scale_factor=2)
    if mode == 'oldcache':   # v192 格式（冇 precipHour）+ Open-Meteo 503 → 用舊資料
        old = {'%.3f,%.3f' % (s['lat'], s['lng']): {'at': 1, 'data': {'now': {'time': 0, 'temp': 24, 'humidity': 70, 'precip': 0.1, 'weatherCode': 1, 'windSpeed': 8, 'windDir': 90, 'pressure': 1015, 'cloud': 20}, 'hours': []}} for s in ST}
        c.add_init_script('localStorage.setItem("wx_last_good_v1", %s)' % json.dumps(json.dumps(old)))
    pg = c.new_page(); errs = []; reqs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
    def route(r):
        u = r.request.url
        if 'supabase.co' in u: return r.abort()
        if 'api.open-meteo.com' in u:
            reqs.append(u)
            if mode == 'oldcache': return r.fulfill(status=503, body='{}', content_type='application/json')
            return r.fulfill(status=200, body=body(u), content_type='application/json')
        r.continue_()
    pg.route('**/*', route)
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(2500)
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(800)
    pg.evaluate("switchMapTab('weather')"); pg.wait_for_selector('.weather-card', timeout=30000); pg.wait_for_timeout(800)
    cards = pg.locator('.weather-card'); txt = [cards.nth(i).inner_text() for i in range(3)]
    return b, pg, errs, reqs, txt
with sync_playwright() as p:
    b, pg, errs, reqs, txt = run(p, 'new'); t = '[暴雨] '
    check(len(reqs) == 1 and 'hourly=' in reqs[0] and 'precipitation' in reqs[0].split('hourly=')[1].split('&')[0] and 'timezone=Asia/Hong_Kong' in reqs[0], t + '仍然只有 1 個合併請求，帶 hourly precipitation 同 timezone=Asia/Hong_Kong')
    check('暴雨' in txt[0] and '大雨' not in txt[0], t + '第 1 站（嗰個鐘 35mm）顯示暴雨、唔疊大雨')
    check('35.0 mm/小時' in txt[0] and '9.0 mm' not in txt[0], t + '暴雨卡雨量格顯示小時雨量 35.0 mm/小時（唔再顯示 9.0 mm）')
    rs = pg.evaluate("(() => { const s = window.weatherLib.getFishingWeatherScore({time:0,temp:24,precip:9,precipHour:35,weatherCode:65,windSpeed:18,pressure:1008}); return s.reasons.map(r => r.text); })()")
    check('暴雨（過去一小時 35.0 mm，達黃雨標準），不建議出釣' in rs and not any(('嗰個鐘' in r or '唔好' in r) for r in rs), t + '暴雨理由書面語 ' + str([r for r in rs if r.startswith('暴雨')]))
    check('4.0 mm' in txt[1] and '/小時' not in txt[1] and '4.0 mm' in txt[2] and '/小時' not in txt[2], t + '非暴雨卡照舊顯示 15 分鐘 mm')
    check('大雨' in txt[1] and '暴雨' not in txt[1], t + '第 2 站（29.9mm）係大雨')
    check('大雨' in txt[2] and '暴雨' not in txt[2], t + '第 3 站冇 hourly → 照 15 分鐘雨量（大雨）')
    check(not errs, t + 'no page errors ' + str(errs)); check('免費' not in pg.inner_text('body'), t + '冇「免費」')
    pg.locator('.weather-card').first.scroll_into_view_if_needed(); pg.screenshot(path=os.path.join(shots, 'rainstorm-card.png')); b.close()
    b, pg, errs, reqs, txt = run(p, 'oldcache'); t = '[舊 cache] '
    check('微量雨' in txt[0], t + '冇 precipHour 嘅舊 cache 照常顯示 ' + txt[0][:60].replace('\n', ' '))
    check(not errs, t + 'no page errors ' + str(errs)); b.close()
print('RESULT', 'OK' if not fails else 'FAIL ' + str(fails))
