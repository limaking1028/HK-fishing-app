# v188 方案 A 登入頁 smoke：390×844，網站模式 + 模擬 isNativeIOS()=true。
# 所有 supabase.co request 都記錄並 abort（唔會掂 prod）；唔會撳任何提交掣。
import http.server, threading, functools, os, sys
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR', '/tmp')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
fails = []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
IOS_MOCK = """
(() => { let v; Object.defineProperty(window, 'authLib', { configurable: true,
  get() { return v; },
  set(x) { if (x) { x.isNativeIOS = () => true; if (!x.signInWithApple) x.signInWithApple = async () => {}; } v = x; } }); })();
"""
def run(p, mode):
    b = p.chromium.launch(); c = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, device_scale_factor=2)
    if mode == 'ios': c.add_init_script(IOS_MOCK)
    pg = c.new_page(); sbreq = []; errs = []
    pg.on('pageerror', lambda e: errs.append(str(e)))
    def route(r):
        if 'supabase.co' in r.request.url: sbreq.append(r.request.url); return r.abort()
        r.continue_()
    pg.route('**/*', route)
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(3000)
    t = f'[{mode}] '
    vis = lambda sel: pg.locator(sel).first.is_visible()
    check(vis('#auth-google-btn') and 'Google' in pg.inner_text('#auth-google-btn'), t + 'Google 掣見到')
    if mode == 'ios':
        check(vis('#auth-apple-btn'), t + 'Apple 掣見到')
        ya = pg.locator('#auth-apple-btn').bounding_box()['y']; yg = pg.locator('#auth-google-btn').bounding_box()['y']
        check(ya < yg, t + 'Apple 排喺 Google 上面')
    else:
        check(not vis('#auth-apple-btn'), t + '網站冇 Apple 掣')
    yg = pg.locator('#auth-google-btn').bounding_box()['y']
    yguest = pg.locator('text=唔登入，先睇潮汐同天氣').bounding_box()['y']
    yem = pg.locator('#auth-email-toggle').bounding_box()['y']
    check(yg < yguest < yem, t + '次序：主掣 → 訪客入口 → 用電郵登入／註冊')
    check(pg.inner_text('#auth-email-toggle').strip() == '用電郵登入／註冊 ›', t + '電郵連結文字')
    check(not vis('#auth-pw-email') and not vis('#auth-pw-pass'), t + '電郵表格預設收埋')
    check(pg.locator('.founder-banner-slot').count() == 1, t + '創始釣友橫額位保留')
    html = pg.content()
    for bad in ['發送登入連結', '改用電郵驗證碼登入', '免費', '亦可用電郵驗證碼']:
        check(bad not in html, t + f'冇「{bad}」')
    pg.screenshot(path=f'{shots}/{"web" if mode == "web" else "ios-mock"}-390x844.png')
    pg.click('#auth-email-toggle'); pg.wait_for_timeout(300)
    check(vis('#auth-tab-login') and vis('#auth-tab-register') and vis('#auth-pw-email') and vis('#auth-pw-pass'), t + '展開後見到 登入／註冊 分頁 + 電郵 + 密碼')
    check('active' in pg.get_attribute('#auth-tab-login', 'class') and pg.inner_text('#auth-pw-btn').strip().endswith('登入'), t + '預設係「登入」分頁')
    check(vis('#auth-forgot-btn') and pg.inner_text('#auth-forgot-btn').strip() == '忘記密碼／用驗證碼登入', t + '「忘記密碼／用驗證碼登入」見到')
    pg.screenshot(path=f'{shots}/{mode}-email-login-390x844.png')
    pg.click('#auth-tab-register'); pg.wait_for_timeout(200)
    check(pg.inner_text('#auth-pw-btn').strip().endswith('註冊') and not vis('#auth-forgot-btn') and pg.get_attribute('#auth-pw-pass', 'autocomplete') == 'new-password', t + '「註冊」分頁 → 註冊掣')
    pg.screenshot(path=f'{shots}/{mode}-email-register-390x844.png')
    pg.click('#auth-tab-login'); pg.wait_for_timeout(200)
    check(pg.inner_text('#auth-pw-btn').strip().endswith('登入'), t + '返「登入」分頁')
    pg.fill('#auth-pw-email', 'demo@example.com')
    pg.click('#auth-forgot-btn'); pg.wait_for_timeout(300)
    check(vis('#auth-send-btn') and '發送驗證碼' in pg.inner_text('#auth-send-btn') and pg.input_value('#auth-email') == 'demo@example.com', t + '驗證碼流程：發送驗證碼掣 + email 帶過去')
    check(vis('#auth-reset-btn'), t + '驗證碼頁仍可寄重設密碼連結')
    pg.screenshot(path=f'{shots}/{mode}-code-390x844.png')
    pg.click('text=← 返回密碼登入'); pg.wait_for_timeout(200)
    check(vis('#auth-pw-email'), t + '返回密碼登入，表格仍展開')
    # 訪客模式：0 個 Supabase call
    before = len(sbreq)
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(1500)
    pg.evaluate("switchMapTab('weather')"); pg.wait_for_timeout(3000)
    guest = sbreq[before:]
    print(t + 'supabase requests during guest mode:', guest)
    check(guest == [], t + '訪客模式 0 個 Supabase call')
    check(not errs, t + f'冇 page error {errs}')
    b.close()
with sync_playwright() as p:
    run(p, 'web'); run(p, 'ios')
print('FAILS:', len(fails)); sys.exit(1 if fails else 0)
