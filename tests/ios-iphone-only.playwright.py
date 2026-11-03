# Login screen: 「唔使安裝，手機瀏覽器直接用」 hidden on native iOS (Capacitor mocked), visible on web. Supabase blocked.
import http.server, threading, functools, os, sys
from playwright.sync_api import sync_playwright
root = os.environ.get('APP_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shot_dir = os.environ.get('SHOT_DIR'); tag = os.environ.get('SHOT_TAG', 'after')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(type('Q',(http.server.SimpleHTTPRequestHandler,),{'log_message':lambda *a:None}), directory=root))
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = f'http://127.0.0.1:{srv.server_port}/index.html'
MOCK = "window.Capacitor={isNativePlatform:()=>true,getPlatform:()=>'ios',Plugins:{}};"
HINT = '唔使安裝，手機瀏覽器直接用'
checks = []
def check(n, c): checks.append((n, bool(c))); print(('PASS ' if c else 'FAIL ') + n)
with sync_playwright() as p:
    b = p.chromium.launch()
    for mode in ('web', 'native'):
        ctx = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2)
        if mode == 'native': ctx.add_init_script(MOCK)
        pg = ctx.new_page(); errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.route('**/*', lambda r: r.abort() if 'supabase.co' in r.request.url else r.continue_())
        pg.goto(url); pg.wait_for_selector('.login-subtitle', timeout=15000); pg.wait_for_timeout(800)
        sub = pg.inner_text('.login-subtitle'); ios = pg.evaluate('authLib.isNativeIOS()')
        if shot_dir: pg.screenshot(path=os.path.join(shot_dir, f'{tag}-{mode}-login.png'))
        if mode == 'web':
            check('web: isNativeIOS false', not ios); check('web: hint visible', HINT in sub and pg.is_visible('text=' + HINT))
        else:
            check('native: isNativeIOS true', ios); check('native: hint hidden', HINT not in sub and pg.locator('text=' + HINT).count() == 0)
            check('native: Apple button shown', pg.is_visible('#auth-apple-btn'))
        check(mode + ': subtitle main line kept', '記低每條魚獲、同釣友鬥排行榜' in sub)
        check(mode + ': no page errors', not errs) if not errs else print('errors', errs[:3]) or check(mode + ': no page errors', False)
        ctx.close()
    b.close()
src = open(os.path.join(root, 'index.html'), encoding='utf-8').read()
check('share modal hint gated by isNativeIOS', "authLib.isNativeIOS()) ? '' : '<div style=\"text-align:center;font-size:12px;color:var(--gray-4);margin-top:8px;\">唔使安裝" in src)
pbx = open(os.path.join(root, 'ios/App/App.xcodeproj/project.pbxproj')).read()
check('pbxproj iPhone only', pbx.count('TARGETED_DEVICE_FAMILY = "1";') == 2 and '"1,2"' not in pbx)
f = sum(1 for _, c in checks if not c)
print(f'RESULT: {len(checks)-f}/{len(checks)} passed'); sys.exit(1 if f else 0)
