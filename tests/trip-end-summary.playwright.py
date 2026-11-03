# 結束行程後轉去「🏁 行程已結束」總結頁（記錄頁 banner 結束 + 行程詳情結束 + 0 條魚）；390x844，Supabase 全部 block，測試用假資料
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
    if shots: os.makedirs(shots, exist_ok=True); pg.evaluate('scrollTo(0,0)'); pg.wait_for_timeout(200); pg.screenshot(path=f'{shots}/{tag}-{n}-390x844.png')
SETUP = """((withCatch, withTally) => {
  const now = Date.now(), iso = ms => new Date(ms).toISOString();
  state.user = {id:'00000000-0000-0000-0000-0000000000aa', email:null};
  const ended = Array.from({length:3}, (_, i) => ({id:'old'+i, spot:['長洲','青衣','坪洲'][i], method:'岸釣', bait:'蝦', startedAt:iso(now-(i+1)*86400e3-3*3600e3), endedAt:iso(now-(i+1)*86400e3), catchCount:i, totalWeight:0}));
  state.trips = ended.slice();
  state.activeTrip = {id:'t-test', spot:'西貢', method:'岸釣', bait:'蝦', startedAt:iso(now-95*60e3), start_time:iso(now-95*60e3)};
  window.tripsLib.saveActiveTrip(state.activeTrip);
  state.catches = withCatch ? [
    {id:'c1', tripId:'t-test', species:'黑鱲', weight:0.6, length:28, spot:'西貢', date:new Date(now+8*3600e3).toISOString().slice(0,10), time:'10:05', createdAt:iso(now-30*60e3)},
    {id:'c2', tripId:'t-test', species:'連尖', weight:0.3, length:20, spot:'西貢', date:new Date(now+8*3600e3).toISOString().slice(0,10), time:'10:40', createdAt:iso(now-10*60e3)}] : [];
  state.lastCatchId = withCatch ? 'c2' : null;
  const copy = Object.assign({}, state.activeTrip);
  state.trips = [copy].concat(ended);
  window.dbEndTrip = async (id, endedAt) => { state.__ended = {id, endedAt}; return true; };
  window.dbLoadTrips = async () => [Object.assign({}, copy, state.__ended ? {endedAt: state.__ended.endedAt, catchCount: (withCatch?2:0)+(withTally?5:0), totalWeight: withCatch?0.9:0} : {})].concat(ended);
  window.tripConditions = async () => null; window.tallySync = async () => {};
  window.renderScoreCard = async () => {};
  if (withTally) { _tally.data['t-test'] = {'黑鱲': 3, '連尖': 2}; }
  window.confirm = () => true;
})"""
VIS = "[...document.querySelectorAll('button')].filter(b=>b.offsetParent).map(b=>b.innerText.trim())"
def run(p, entry, withCatch, withTally=False):
    b = p.chromium.launch(); c = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, service_workers='block', is_mobile=True, has_touch=True)
    pg = c.new_page(); errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/*', lambda r, *_: r.abort() if 'supabase.co' in r.request.url else r.continue_())
    pg.goto(f'http://127.0.0.1:{srv.server_port}/index.html'); pg.wait_for_timeout(2500)
    pg.click('text=唔登入，先睇潮汐同天氣'); pg.wait_for_timeout(800)
    pg.evaluate(SETUP + '(' + ('true' if withCatch else 'false') + ',' + ('true' if withTally else 'false') + ')')
    name = entry + ('' if withCatch else '-0catch') + ('-tally' if withTally else '')
    if entry == 'record':
        pg.evaluate("switchView('record'); state.formSuccess = true; renderRecordView(); renderActiveTripBanner()"); pg.wait_for_timeout(1000)
        shot(pg, name + '-1-before-end'); pg.click('.atb-end')
    else:
        pg.evaluate("renderActiveTripBanner(); switchView('trips'); openTripDetail('t-test')"); pg.wait_for_timeout(1000)
        shot(pg, name + '-1-before-end'); pg.click('#view-trips button:has-text("結束行程")')
    pg.wait_for_timeout(1500)
    shot(pg, name + '-2-after-end')
    if before: b.close(); return
    act = pg.evaluate("[...document.querySelectorAll('.view.active')].map(v=>v.id)")
    check(act == ['view-trips'], name + ': 得一個 active view = view-trips ' + str(act))
    txt = pg.inner_text('#view-trips')
    check('🏁' in txt and '行程已結束' in txt, name + ': 標題「🏁 行程已結束」')
    check('總時長' in txt and '總魚獲' in txt and '總重量' in txt and (('個魚種' in txt) == withCatch), name + ': 總時長／總魚獲／總重量（有魚先有魚種數）')
    if withCatch:
        check('黑鱲' in txt and '連尖' in txt and '魚獲清單' in txt, name + ': 魚獲清單有黑鱲、連尖')
        check('共 2 個魚種' in txt, name + ': 2 個魚種')
    else:
        check(('這次行程還沒有魚獲' in txt) != withTally, name + ': 「這次行程還沒有魚獲」' + ('有計數時唔顯示' if withTally else '0 條魚冇計數時顯示'))
        check('共 0 個魚種' not in txt, name + ': 冇「共 0 個魚種」')
    check(not pg.evaluate("(()=>{const t=document.getElementById('toast');return !!(t&&t.classList.contains('show')&&/行程已結束/.test(t.textContent))})()"), name + ': 轉去總結頁冇「行程已結束」toast')
    btns = pg.evaluate(VIS)
    check(sum('開始新行程' in t for t in btns) == 1 and sum('開始行程' in t for t in btns) == 0, name + ': 得一粒「開始新行程」 ' + str(btns))
    check(not any('計數' in t for t in btns), name + ': 冇快速計數掣')
    if withTally:
        check('快速計數' in txt and '3 條' in txt and '2 條' in txt, name + ': 顯示快速計數結果（黑鱲 3 條、連尖 2 條）')
        check('5' in pg.inner_text('.trip-stats-grid'), name + ': 總魚獲包括計數 5 條')
    else:
        check('快速計數' not in txt, name + ': 冇計數時唔顯示快速計數區')
    check(not any('記錄下一條' in t for t in btns), name + ': 冇「記錄下一條」')
    check(pg.evaluate('state.formSuccess') is False, name + ': formSuccess 已清')
    pg.click('#view-trips button:has-text("查看我的魚獲")'); pg.wait_for_timeout(600)
    if withTally:   # 非剛結束嘅行程詳情維持原樣：仍顯示句子同計數掣
        pg.evaluate("switchView('trips'); openTripDetail('t-test')"); pg.wait_for_timeout(500)
        t2 = pg.inner_text('#view-trips')
        check('這次行程還沒有魚獲' in t2 and '修改計數' in t2 and '行程已結束' not in t2, name + ': 普通行程詳情不變')
        pg.evaluate("closeTripDetail(); switchView('my')"); pg.wait_for_timeout(400)
    check(pg.evaluate("[state.view, state.justEndedTripId, state.tripDetailId]") == ['my', None, None], name + ': 離開後清 justEndedTripId')
    pg.evaluate("switchView('record')"); pg.wait_for_timeout(600)
    check('魚獲已記錄' not in pg.inner_text('#view-record'), name + ': 返記錄頁冇舊成功頁')
    check(not errs, name + ': no page errors ' + str(errs))
    b.close()
with sync_playwright() as p:
    run(p, 'record', True); run(p, 'trip', True); run(p, 'record', False); run(p, 'trip', False); run(p, 'record', False, True); run(p, 'trip', False, True)
print('RESULT', 'OK' if not fails else 'FAILS: ' + str(len(fails)))
sys.exit(1 if fails else 0)
