# 揀完魚種自動捲去「重量」欄（普通記錄 + 行程「記錄下一條」）；390x844，Supabase 全部 block
# SHOT_DIR=目錄 SHOT_TAG=前綴 會出截圖；BEFORE=1 只截圖唔 check（用嚟影修改前）
import http.server, threading, functools, os, sys
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR'); tag = os.environ.get('SHOT_TAG', 'x'); before = os.environ.get('BEFORE') == '1'
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
fails = []
def check(c, n):
    print(('PASS ' if c else 'FAIL ') + n)
    if not c: fails.append(n)
def shot(pg, n):
    if shots: os.makedirs(shots, exist_ok=True); pg.screenshot(path=f'{shots}/{tag}-{n}-390x844.png')
WIN = "(()=>{const r=document.getElementById('catch-weight').getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight})()"
def run(p, flow, species):
    b = p.chromium.launch(); c = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, service_workers='block', is_mobile=True, has_touch=True)
    pg = c.new_page(); errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/*', lambda r, *_: r.abort() if 'supabase.co' in r.request.url else r.continue_())
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(2500)
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(800)
    pg.evaluate("state.user={id:'00000000-0000-0000-0000-0000000000aa',email:null}")
    if flow == 'trip':
        pg.evaluate("state.activeTrip={id:'t1',spot:'西貢',method:'岸釣',bait:'蝦',start_time:new Date().toISOString()}; addCatchInTrip()")
        pg.wait_for_timeout(600); pg.evaluate("state.formSuccess=true; resetForm()")   # 「記錄下一條」 onclick="resetForm()"
    else:
        pg.evaluate("goToView('record')")
    pg.wait_for_timeout(800)
    pg.fill('#catch-notes', '測試備註') if pg.locator('#catch-notes').count() else None
    method = pg.evaluate("(document.getElementById('catch-method')||{}).value||null")
    pg.click('.sp-expand-btn'); pg.wait_for_timeout(400)
    card = pg.locator(f'.sp-card[data-species="{species}"]'); card.scroll_into_view_if_needed(); pg.wait_for_timeout(300)
    y0 = pg.evaluate('scrollY'); shot(pg, f'{flow}-{"other" if species.startswith("其他") else "pick"}-1-before-tap')
    card.click(); pg.wait_for_timeout(900)
    name = flow + (' 其他' if species.startswith('其他') else '')
    shot(pg, f'{flow}-{"other" if species.startswith("其他") else "pick"}-2-after-tap')
    if not before:
        if species.startswith('其他'):
            # 列表收起後頁面變短，瀏覽器會自動將 scrollY 夾到最大值；呢度 check 冇額外捲動（= min(原本位置, 新最大值)）
            y1, ymax = pg.evaluate('[scrollY, document.documentElement.scrollHeight - innerHeight]')
            check(abs(y1 - min(y0, max(0, ymax))) <= 1, name + f': 揀「其他」唔會捲去重量（scrollY {y0}→{y1}，最大 {ymax}）')
            check(pg.locator('#custom-species').is_visible(), name + ': #custom-species 有顯示')
        else:
            check(pg.evaluate(WIN), name + ': 揀完魚種 #catch-weight 喺畫面內')
        notes = pg.evaluate("(document.getElementById('catch-notes')||{}).value")
        check(notes == '測試備註', name + ': 已填嘅備註保留')
        check(pg.evaluate("(document.getElementById('catch-method')||{}).value||null") == method, name + ': 釣法保留 (' + str(method) + ')')
        check(pg.evaluate("document.activeElement && document.activeElement.id") != 'catch-weight' and pg.evaluate("['INPUT','TEXTAREA','SELECT'].indexOf((document.activeElement||{}).tagName)") < 0, name + ': 冇自動 focus（唔彈鍵盤）')
        check(not errs, name + ': no page errors ' + str(errs))
    b.close()
with sync_playwright() as p:
    run(p, 'normal', '連尖'); run(p, 'trip', '連尖'); run(p, 'normal', '其他'); run(p, 'trip', '其他')
print('RESULT', 'OK' if not fails else 'FAILS: ' + str(len(fails)))
sys.exit(1 if fails else 0)
