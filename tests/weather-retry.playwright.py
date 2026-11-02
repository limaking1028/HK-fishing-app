# v189 天氣錯誤訊息 + 「重新嘗試」smoke：390×844，訪客模式。
# api.open-meteo.com 全部用 mock（指定站回 503，其餘 200）；supabase.co request 記錄並 abort（唔會掂 prod）。
import http.server, threading, functools, os, json
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR', '/tmp')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
fails = []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
OK = json.dumps({'current': {'time': '2026-11-02T22:00', 'temperature_2m': 24, 'relative_humidity_2m': 70, 'precipitation': 0, 'weather_code': 1, 'wind_speed_10m': 12, 'wind_direction_10m': 90, 'pressure_msl': 1015, 'cloud_cover': 20},
                 'hourly': {'time': ['2026-11-02T%02d:00' % h for h in range(24)], 'temperature_2m': [24] * 24, 'precipitation': [0] * 24, 'wind_speed_10m': [12] * 24, 'wind_direction_10m': [90] * 24, 'weather_code': [1] * 24, 'relative_humidity_2m': [70] * 24, 'pressure_msl': [1015] * 24, 'cloud_cover': [20] * 24}})
FAIL4 = ['22.2885', '22.4508', '22.2108', '22.2525']   # 鰂魚涌、大埔滘、長洲、大澳
def run(p, failset, tag):
    b = p.chromium.launch(); c = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, device_scale_factor=2)
    pg = c.new_page(); errs = []; sbreq = []; meteo = []; st = {'fail': failset if failset == 'all' else set(failset)}
    pg.on('pageerror', lambda e: errs.append(str(e)))
    def route(r):
        u = r.request.url
        if 'supabase.co' in u: sbreq.append(u); return r.abort()
        if 'api.open-meteo.com' in u:
            lat = u.split('latitude=')[1].split('&')[0]; meteo.append(lat)
            if st['fail'] == 'all' or lat in st['fail']: return r.fulfill(status=503, body='{"error":true,"reason":"busy"}', content_type='application/json')
            return r.fulfill(status=200, body=OK, content_type='application/json')
        r.continue_()
    pg.route('**/*', route)
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(2500)
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(1000)
    n0 = len(sbreq)
    pg.evaluate("switchMapTab('weather')"); pg.wait_for_timeout(2500)
    if os.environ.get('BEFORE'):
        pg.screenshot(path=f'{shots}/before-main-503-390x844.png'); b.close(); return
    total = len(meteo); nfail = total if failset == 'all' else len(failset)
    t = f'[{tag}] '
    check(pg.locator('.weather-card-error').count() == nfail, t + f'{nfail} 張錯誤卡')
    check(pg.locator('text=暫時攞唔到天氣資料，可能係天氣來源繁忙，稍後再試').count() == nfail, t + '顯示友善訊息')
    check(pg.locator('.weather-err-code').first.inner_text() == '錯誤碼：HTTP 503', t + '細字錯誤碼 HTTP 503')
    check(pg.locator('text=天氣數據取得失敗').count() == 0, t + '冇舊嘅原始訊息')
    check(pg.locator('#weather-retry-btn').count() == 1, t + '重新嘗試掣只出一次')
    body = pg.inner_text('body'); check('免費' not in body, t + '冇「免費」')
    pg.screenshot(path=f'{shots}/after-error-{tag}-390x844.png')
    st['fail'] = set(); meteo.clear()
    pg.evaluate("document.getElementById('weather-retry-btn').click(); window.__dis = document.getElementById('weather-retry-btn') && document.getElementById('weather-retry-btn').disabled")
    check(pg.evaluate('window.__dis') is True, t + '撳咗之後掣 disabled（載入中）')
    pg.wait_for_timeout(2000)
    check(len(meteo) == nfail and (failset == 'all' or sorted(meteo) == sorted(failset)), t + f'只重新攞失敗嘅站（{len(meteo)} 個 request）')
    check(pg.locator('.weather-card-error').count() == 0, t + '失敗卡全部恢復')
    check(pg.locator('.weather-card').count() == total, t + f'仍然有 {total} 張卡')
    check(pg.locator('#weather-retry-btn').count() == 0, t + '全部成功後掣消失')
    pg.screenshot(path=f'{shots}/after-retry-ok-{tag}-390x844.png')
    check(len(sbreq) == n0, t + '訪客模式 0 個 supabase.co call'); check(not errs, t + 'no page errors ' + str(errs))
    b.close()
with sync_playwright() as p:
    if os.environ.get('BEFORE'): run(p, FAIL4, 'before')
    else: run(p, FAIL4, 'partial'); run(p, 'all', 'allfail')
print('RESULT', 'OK' if not fails else 'FAILED %d' % len(fails)); srv.shutdown()
raise SystemExit(1 if fails else 0)
