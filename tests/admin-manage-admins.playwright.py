# v189 後台「管理員管理」smoke：390×844，supabase-js 換成本地 mock（唔會掂 prod）。
import http.server, threading, functools, os, json
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR', '/tmp')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
fails = []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
FOUND, ME, B = '5e4fa205-add7-42d0-9ac4-6a1fe8ab6985', '7f30a44f-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002'
MOCK = """
window.__calls = []; window.__admins = new Set(['%s','%s']);
const NAMES = {'%s':'釣港管理員','%s':'主人','%s':'阿B'};
const R = {
  is_admin: () => true, admin_badges: () => ({pending_reviews:0,new_feedback:0}),
  admin_users: () => Object.keys(NAMES).map(id => ({id, display_name:NAMES[id], created_at:'2026-11-01T00:00:00Z', last_sign_in_at:'2026-11-02T00:00:00Z', is_admin:__admins.has(id), banned:false, catch_count:0, eligible_count:0, trip_count:0})),
  admin_admins_list: () => [...__admins].map(id => ({user_id:id, display_name:NAMES[id], created_at:'2026-11-02T00:00:00Z', protected:id==='%s', is_me:id==='%s'})),
  admin_user_detail: a => ({profile:{id:a.p_user, display_name:NAMES[a.p_user], is_admin:__admins.has(a.p_user), banned:false, providers:['apple'], has_password:false, created_at:'2026-11-01T00:00:00Z', last_sign_in_at:'2026-11-02T00:00:00Z'}, totals:{catches:0,eligible:0,excluded:0,with_photo:0,trips:0,tally_qty:0,usage_min_30d:0,active_days_30d:0}, catches:[], trips:[], feedback:[], audit:[], usage_daily:[]}),
  admin_set_admin: a => { if (!a.p_on && a.p_user==='%s') throw 'cannot remove founding admin'; a.p_on ? __admins.add(a.p_user) : __admins.delete(a.p_user); return null; },
};
window.supabase = { createClient: () => ({
  auth: { getSession: async () => ({data:{session:{user:{id:'%s'}}}}), onAuthStateChange: () => ({data:{subscription:{unsubscribe(){}}}}), signOut: async()=>({}) },
  rpc: async (n, a) => { __calls.push([n, a]); if (!R[n]) return {data:null, error:{message:'Could not find '+n}}; try { return {data:R[n](a||{}), error:null}; } catch (e) { return {data:null, error:{message:String(e)}}; } },
  from: () => { const q = new Proxy({}, {get:(t,k)=> k==='then' ? (r=>r({data:[],error:null})) : (()=>q)}); return q; },
})};
""" % (FOUND, ME, FOUND, ME, B, FOUND, ME, FOUND, ME)
with sync_playwright() as p:
    b = p.chromium.launch(); c = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, device_scale_factor=2)
    pg = c.new_page(); errs = []; sbreq = []
    pg.on('pageerror', lambda e: errs.append(str(e)))
    def route(r):
        u = r.request.url
        if 'supabase-js' in u: return r.fulfill(status=200, content_type='application/javascript', body=MOCK)
        if 'supabase.co' in u: sbreq.append(u); return r.abort()
        r.continue_()
    pg.route('**/*', route)
    pg.goto(f'http://127.0.0.1:{srv.server_port}/admin.html#users'); pg.wait_for_timeout(2500)
    check(pg.locator('#admin-list').is_visible(), '用戶頁顯示管理員名單')
    t = pg.inner_text('#admin-list'); check('管理員（2）' in t and '創始管理員' in t and '你' in t, '名單有 2 位、創始管理員同「你」標籤')
    check('@' not in t, '名單冇電郵')
    pg.screenshot(path=f'{shots}/admin-list-390x844.png')
    pg.evaluate(f"openUser('{B}')"); pg.wait_for_timeout(800)
    check(pg.inner_text('#admin-toggle') == '設為管理員', '非管理員顯示「設為管理員」')
    pg.click('#admin-toggle'); pg.wait_for_timeout(300)
    check(pg.locator('#dlg').is_visible() and '設為管理員？' in pg.inner_text('#dlg'), '確認對話框出現')
    pg.screenshot(path=f'{shots}/admin-confirm-add-390x844.png')
    pg.click('#dno'); pg.wait_for_timeout(300)
    check(not any(x[0] == 'admin_set_admin' for x in pg.evaluate('__calls')), '取消唔會 call RPC')
    pg.click('#admin-toggle'); pg.wait_for_timeout(300); pg.click('#dyes'); pg.wait_for_timeout(800)
    check([x for x in pg.evaluate('__calls') if x[0] == 'admin_set_admin'] == [['admin_set_admin', {'p_user': B, 'p_on': True}]], 'RPC 參數正確（加）')
    check(pg.inner_text('#admin-toggle') == '移除管理員', '加完變「移除管理員」')
    pg.screenshot(path=f'{shots}/admin-detail-after-add-390x844.png')
    pg.click('#admin-toggle'); pg.wait_for_timeout(300); pg.click('#dyes'); pg.wait_for_timeout(800)
    check(pg.inner_text('#admin-toggle') == '設為管理員', '移除成功')
    pg.evaluate(f"openUser('{FOUND}')"); pg.wait_for_timeout(800)
    pg.click('#admin-toggle'); pg.wait_for_timeout(300); pg.click('#dyes'); pg.wait_for_timeout(800)
    check('創始管理員唔可以移除' in pg.inner_text('body') and pg.inner_text('#admin-toggle') == '移除管理員', '移除創始管理員被拒，顯示中文錯誤')
    pg.screenshot(path=f'{shots}/admin-remove-founding-refused-390x844.png')
    check(not errs, 'no page errors ' + str(errs)); check(not sbreq, '0 supabase.co requests')
    b.close()
print('RESULT', 'OK' if not fails else 'FAILED %d' % len(fails)); srv.shutdown()
raise SystemExit(1 if fails else 0)
