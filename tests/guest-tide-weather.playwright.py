# v187 guest smoke: real index.html, logged out. All supabase.co requests are recorded and aborted (nothing reaches prod).
# Proves: tide + weather render for guests; every other tab shows the login prompt; entering/using guest mode makes NO Supabase calls.
import http.server, threading, functools, os, sys
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
sbreq, meteo, fails = [], [], []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
with sync_playwright() as p:
    b = p.chromium.launch(); c = b.new_context(service_workers='block'); pg = c.new_page()
    errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
    def route(r):
        u = r.request.url
        if 'supabase.co' in u: sbreq.append(u); return r.abort()
        if 'open-meteo' in u: meteo.append(u)
        r.continue_()
    pg.route('**/*', route)
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(3000)
    before = list(sbreq)
    check(pg.locator('text=唔登入，先睇潮汐同天氣').count() == 1, 'login screen shows guest button')
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(1500)
    check(pg.evaluate("document.querySelector('#view-map').innerText.includes('潮')") and pg.locator('#view-map .guest-login-prompt').count() == 0, 'tide renders')
    pg.evaluate("switchMapTab('weather')"); pg.wait_for_timeout(6000)
    check(pg.locator('#view-map .guest-login-prompt').count() == 0 and len(pg.evaluate("document.querySelector('#view-map').innerText")) > 50, 'weather renders')
    pg.screenshot(path='/tmp/guest-weather.png')
    pg.click('.weather-card-action >> nth=0'); pg.wait_for_timeout(800)
    check(pg.locator('#view-map .guest-login-prompt').count() == 1, '「在地圖上顯示位置」 -> login prompt')
    pg.evaluate("switchMapTab('weather')"); pg.wait_for_timeout(500)
    pg.evaluate("switchMapTab('map')"); pg.wait_for_timeout(500)
    check(pg.locator('#view-map .guest-login-prompt').count() == 1, 'map sub-tab -> login prompt')
    for v in ['my', 'trips', 'record', 'leaderboard']:
        pg.click(f'.nav-item[data-view="{v}"]'); pg.wait_for_timeout(800)
        check(pg.locator(f'#view-{v} .guest-login-prompt').count() == 1, f'{v} -> login prompt')
    pg.click('.header-settings'); pg.wait_for_timeout(500)
    check(pg.locator('#auth-google-btn').count() == 1, 'header 登入 -> login screen')
    after = sbreq[len(before):]
    b.close()
print('supabase requests on initial load (pre-existing, aborted):', [u.split('?')[0].split('.co')[1] for u in before])
print('supabase requests during guest mode:', after)
print('open-meteo requests:', len(meteo), 'page errors:', errs)
check(after == [], 'no Supabase calls in guest mode')
check(not errs, 'no page errors')
sys.exit(1 if fails else 0)
