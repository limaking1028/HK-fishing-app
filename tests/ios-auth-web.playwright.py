# Web smoke: real index.html in Chromium, all Supabase calls blocked. Proves web auth config unchanged.
import http.server, threading, functools, os, sys
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = f'http://127.0.0.1:{srv.server_port}/index.html'
blocked = []
with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_page()
    def route(r):
        if 'supabase.co' in r.request.url: blocked.append(r.request.url); return r.abort()
        r.continue_()
    pg.route('**/*', route)
    errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.goto(url); pg.wait_for_timeout(2500)
    res = pg.evaluate("""() => ({redir: authLib.authRedirectUrl(), flow: authLib.authFlowType(), ios: authLib.isNativeIOS(),
       sbFlow: window.sb && window.sb.auth && window.sb.auth.flowType, cap: typeof window.Capacitor})""")
    b.close()
print(res, 'blocked supabase requests:', len(blocked), 'page errors:', errs)
ok = res['redir'] == f'http://127.0.0.1:{srv.server_port}/index.html' and res['flow'] == 'implicit' and not res['ios'] and res['sbFlow'] in ('implicit', None)
print('PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)
