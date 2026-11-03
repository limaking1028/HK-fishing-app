# 分享釣點：連結基底（capacitor:// → 正式網址；http(s) 照舊）＋「📍 附上位置」開關。390×844 訪客、mock 魚獲（supabase.co abort）
import http.server, threading, functools, os, re
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR', '/tmp')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
fails = []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
PUB = 'https://limaking1028.github.io/HK-fishing-app/'
INIT = "window.__shared=[]; Object.defineProperty(navigator,'share',{value: async d => { window.__shared.push(d.text); }, configurable:true});"
MOCK = """(() => { state.catches = [
 {id:'m1',isMine:true,spot:'鰂魚涌海濱',latitude:22.287612,longitude:114.215345,date:'2026-11-01',species:'黑鱲'},
 {id:'m2',isMine:true,spot:'鰂魚涌海濱',latitude:22.287812,longitude:114.215545,date:'2026-11-02',species:'黑鱲'},
 {id:'m3',isMine:true,spot:'西環碼頭',latitude:22.2866,longitude:114.1286,date:'2026-11-02',species:'泥鯭'}]; })()"""
def share(pg, loc):
    pg.evaluate("window.__shared=[]"); pg.evaluate("document.querySelectorAll('#spot-share-modal input[data-i]').forEach(c=>c.checked=true)")
    if loc: pg.check('#spot-share-loc')
    pg.click('text=分享已揀釣點'); pg.wait_for_timeout(300); return pg.evaluate("window.__shared[0]")
with sync_playwright() as p:
    b = p.chromium.launch(); c = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, device_scale_factor=2)
    c.add_init_script(INIT); pg = c.new_page(); errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/*', lambda r: r.abort() if 'supabase.co' in r.request.url else r.continue_())
    base = f'http://127.0.0.1:{srv.server_port}/index.html'
    pg.goto(base); pg.wait_for_timeout(2500); pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(800)
    pg.evaluate(MOCK); pg.evaluate("getUserName = () => '阿明'")
    # 連結基底：用 app 入面嘅 pageShareUrl 原碼，mock location
    f = pg.evaluate("pageShareUrl.toString()")
    def base_for(proto, origin, path): return pg.evaluate("([f,l,u]) => new Function('location','APP_PUBLIC_URL','return ('+f+')()')(l,u)", [f, {'protocol': proto, 'origin': origin, 'pathname': path}, PUB])
    check(base_for('capacitor:', 'capacitor://localhost', '/') == PUB, '[基底] capacitor://localhost/ → 正式網址')
    check(base_for('capacitor:', 'capacitor://localhost', '/index.html') == PUB, '[基底] capacitor://localhost/index.html → 正式網址')
    check(base_for('https:', 'https://limaking1028.github.io', '/HK-fishing-app/') == PUB, '[基底] https 照舊 origin+pathname')
    check(base_for('http:', 'http://127.0.0.1:8000', '/index.html') == 'http://127.0.0.1:8000/index.html', '[基底] http 本機照舊（同改前一樣）')
    # 開框：預設關
    pg.evaluate("openSpotShare()"); pg.wait_for_timeout(300)
    check(not pg.is_checked('#spot-share-loc'), '[開關] 開框預設關')
    check('對方只會見到釣點名稱（唔包括 GPS 位置）' in pg.inner_text('#spot-share-note'), '[開關] 關：說明文字同舊一樣')
    box = pg.locator('#spot-share-loc').bounding_box(); btn = pg.locator('text=分享已揀釣點').bounding_box()
    check(box['y'] < btn['y'] and btn['y'] - box['y'] < 80, '[開關] 開關喺「分享已揀釣點」正上面')
    pg.screenshot(path=os.path.join(shots, 'share-dialog-off.png'))
    off = share(pg, False); here = pg.evaluate("location.origin + location.pathname")
    exp_off = '🎣 阿明 喺【釣港】分享咗釣點：\n\n📍 鰂魚涌海濱\n📍 西環碼頭\n\n' + here
    check(off == exp_off, '[關] 輸出同舊格式一樣（淨名，http 用當前網址）')
    check(not re.search(r'22\.28|114\.\d|google', off), '[關] 冇 GPS／地圖連結')
    pg.evaluate("openSpotShare()"); pg.wait_for_timeout(200); pg.check('#spot-share-loc')
    check('對方會見到釣點名稱同 Google 地圖位置' in pg.inner_text('#spot-share-note'), '[開] 說明文字轉做會見到位置')
    pg.screenshot(path=os.path.join(shots, 'share-dialog-on.png'))
    pg.evaluate("openSpotShare()"); pg.wait_for_timeout(200)
    check(not pg.is_checked('#spot-share-loc') and 'GPS' in pg.inner_text('#spot-share-note'), '[開關] 再開框重設為關')
    on = share(pg, True)
    exp_on = ('🎣 阿明 喺【釣港】分享咗釣點：\n\n📍 鰂魚涌海濱\nhttps://www.google.com/maps/search/?api=1&query=22.28771,114.21545'
              '\n📍 西環碼頭\nhttps://www.google.com/maps/search/?api=1&query=22.28660,114.12860\n\n' + here)
    check(on == exp_on, '[開] 每個釣點下一行 5 位小數 Google 地圖連結')
    check(pg.evaluate("spotMapLink({name:'x',lat:NaN,lng:NaN})") == '' and pg.evaluate("spotMapLink({name:'x'})") == '', '[開] 冇 GPS 嘅釣點唔加連結')
    # capacitor 情況下成段訊息：用 mock 基底取代 pageShareUrl 結果
    pg.evaluate("([f,u]) => { pageShareUrl = () => new Function('location','APP_PUBLIC_URL','return ('+f+')()')({protocol:'capacitor:',origin:'capacitor://localhost',pathname:'/'}, u); }", [f, PUB])
    pg.evaluate("openSpotShare()"); pg.wait_for_timeout(200); cap = share(pg, False)
    check(cap == exp_off.replace(here, PUB) and 'capacitor:' not in cap, '[capacitor] 訊息尾係正式網址、內容不變')
    pg.evaluate("openSpotShare()"); pg.wait_for_timeout(200); cap_on = share(pg, True)
    check(cap_on == exp_on.replace(here, PUB), '[capacitor] 開位置都係正式網址')
    # 其他分享冇 GPS：成績卡／魚獲連結用 appBaseUrl，同排行榜冇釣點（源碼檢查）
    src = open(os.path.join(root, 'index.html'), encoding='utf-8').read()
    check(src.count('google.com/maps/search') == 1 and src.count('spotMapLink(') == 2, '[其他] Google 地圖連結只喺分享釣點用')
    check(not errs, 'no page errors ' + str(errs)); check('免費' not in pg.inner_text('body'), '冇「免費」')
    b.close()
print('RESULT', 'OK' if not fails else 'FAIL ' + str(fails))
