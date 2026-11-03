# 「我的」頁個人最重卡：標題「🎣 我的最重紀錄」+ 細字「個人紀錄，唔代表排行榜名次」；排行榜「重量王者」唔變。390x844，Supabase 全部 block，假資料
# SHOT_DIR=目錄 SHOT_TAG=前綴 出截圖；BEFORE=1 只截圖唔 check
import http.server, threading, functools, os
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR'); tag = os.environ.get('SHOT_TAG', 'x'); before = os.environ.get('BEFORE') == '1'
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
fails = []
def check(c, n):
    print(('PASS ' if c else 'FAIL ') + n)
    if not c: fails.append(n)
SETUP = """(() => {
  state.user = {id:'00000000-0000-0000-0000-0000000000aa', email:null};
  const d = new Date(Date.now()+8*3600e3).toISOString().slice(0,10);
  state.catches = [
    {id:'c1', species:'黑鱲', weight:2.5, length:40, spot:'西貢', date:d, time:'10:05', isMine:true},
    {id:'c2', species:'連尖', weight:0.3, length:20, spot:'西貢', date:d, time:'10:40', isMine:true}];
  state.mySubTab = 'log'; switchView('my');
})"""
LUM = """(c => { const m = c.match(/[\\d.]+/g).map(Number); const f = v => { v/=255; return v<=0.03928? v/12.92 : Math.pow((v+0.055)/1.055, 2.4); }; return 0.2126*f(m[0])+0.7152*f(m[1])+0.0722*f(m[2]); })"""
with sync_playwright() as p:
    b = p.chromium.launch(); c = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, service_workers='block', is_mobile=True, has_touch=True)
    pg = c.new_page(); errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/*', lambda r, *_: r.abort() if 'supabase.co' in r.request.url else r.continue_())
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(2500)
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(800)
    pg.evaluate(SETUP); pg.wait_for_timeout(500)
    card = pg.locator('.biggest-card'); card.scroll_into_view_if_needed(); pg.evaluate('scrollBy(0,-120)'); pg.wait_for_timeout(200)
    if shots: os.makedirs(shots, exist_ok=True); pg.screenshot(path=f'{shots}/{tag}-card-390x844.png')
    if not before:
        t = card.inner_text()
        check(card.count() == 1, '有一張個人最重卡')
        check(pg.locator('.biggest-badge').inner_text().strip() == '🎣 我的最重紀錄', '標題係「🎣 我的最重紀錄」')
        check('個人紀錄，唔代表排行榜名次' in t, '卡內有細字「個人紀錄，唔代表排行榜名次」')
        check('王者' not in t and '👑' not in t, '卡內冇「王者」同 👑')
        check('黑鱲' in t and '2.5' in t, '卡照舊顯示最重一條（黑鱲 2.5）')
        geo = pg.evaluate("(() => { const c = document.querySelector('.biggest-card').getBoundingClientRect(), n = document.querySelector('.biggest-note').getBoundingClientRect(); return {c:[c.left,c.right,c.bottom], n:[n.left,n.right,n.bottom], sw: document.documentElement.scrollWidth}; })()")
        check(geo['n'][0] >= geo['c'][0] and geo['n'][1] <= geo['c'][1] and geo['n'][2] <= geo['c'][2] and geo['sw'] <= 390, '細字喺卡內、冇爆版 ' + str(geo))
        col = pg.evaluate("getComputedStyle(document.querySelector('.biggest-note')).color")
        L1 = pg.evaluate(LUM + '(' + repr(col) + ')')
        # 卡底色：漸變最淺端 #0e8495（最壞情況）同中間 #0a5866，疊 rgba(255,255,255,.08)? 細字唔喺 body 內，直接喺卡底
        # 實際卡底色：收埋細字，喺細字位置截圖，揀最淺（最壞）嗰粒像素計對比
        import io; from PIL import Image
        bb = pg.locator('.biggest-note').bounding_box()
        pg.evaluate("document.querySelector('.biggest-note').style.visibility='hidden'")
        im = Image.open(io.BytesIO(pg.screenshot(clip=bb))).convert('RGB')
        pg.evaluate("document.querySelector('.biggest-note').style.visibility=''")
        worst = max(pg.evaluate(LUM + "('rgb(%d,%d,%d)')" % px) for px in set(im.getdata()))
        ratio = (L1 + 0.05) / (worst + 0.05)
        check(ratio >= 4.5, '細字對比（白字 vs 細字位置最淺卡底色）%.2f:1 ≥ 4.5' % ratio)
        pg.evaluate("switchView('leaderboard')"); pg.wait_for_timeout(800)
        check('重量王者' in pg.locator('.lb-tabs').inner_text(), '排行榜 tab「重量王者」唔變')
        check(not errs, 'no page errors ' + str(errs))
        check('免費' not in pg.inner_text('body'), '冇「免費」')
    b.close()
print('RESULT', 'OK' if not fails else 'FAIL ' + str(fails))
