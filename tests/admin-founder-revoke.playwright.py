# v190 後台「取消創始編號」smoke：390×844，supabase-js 換成本地 mock（唔會掂 prod）。
# PRE=1：模擬未執行 migration（冇 admin_founder_no／admin_revoke_founder），應該用 lb_founder_nos 顯示掣，撳落顯示「請先執行 migration」。
import http.server, threading, functools, os
from playwright.sync_api import sync_playwright
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shots = os.environ.get('SHOT_DIR', '/tmp')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=root))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
fails = []
def check(cond, msg): print(('PASS ' if cond else 'FAIL ') + msg); cond or fails.append(msg)
FOUND, B, C = '5e4fa205-add7-42d0-9ac4-6a1fe8ab6985', 'bbbbbbbb-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000003'
def mock(pre):
    return """
window.__calls = []; window.__fno = {'%s':1,'%s':3};
const NAMES = {'%s':'釣港管理員','%s':'阿B','%s':'阿C'};
const R = {
  is_admin: () => true, admin_badges: () => ({pending_reviews:0,new_feedback:0}), admin_admins_list: () => [],
  admin_users: () => Object.keys(NAMES).map(id => ({id, display_name:NAMES[id], created_at:'2026-11-01T00:00:00Z', last_sign_in_at:'2026-11-02T00:00:00Z', is_admin:id==='%s', banned:false, catch_count:1, eligible_count:1, trip_count:0})),
  admin_user_detail: a => ({profile:{id:a.p_user, display_name:NAMES[a.p_user], is_admin:a.p_user==='%s', banned:false, providers:['google'], has_password:false, created_at:'2026-11-01T00:00:00Z', last_sign_in_at:'2026-11-02T00:00:00Z'}, totals:{catches:1,eligible:1,excluded:0,with_photo:1,trips:0,tally_qty:0,usage_min_30d:0,active_days_30d:0}, catches:[{id:'cat-'+a.p_user}], trips:[], feedback:[], audit:[], usage_daily:[]}),
  lb_founder_nos: a => { const o = {}; (a.p_ids||[]).forEach(x => { const u = x.slice(4); if (__fno[u]) o[x] = __fno[u]; }); return o; },
};
if (!%s) {
  R.admin_founder_no = a => __fno[a.p_user] ?? null;
  R.admin_revoke_founder = a => { if (a.p_user === '%s') throw 'cannot revoke founding admin'; const n = __fno[a.p_user]; delete __fno[a.p_user]; return n ?? null; };
}
window.supabase = { createClient: () => ({
  auth: { getSession: async () => ({data:{session:{user:{id:'%s'}}}}), onAuthStateChange: () => ({data:{subscription:{unsubscribe(){}}}}), signOut: async()=>({}) },
  rpc: async (n, a) => { __calls.push([n, a]); if (!R[n]) return {data:null, error:{message:'Could not find the function public.'+n}}; try { return {data:R[n](a||{}), error:null}; } catch (e) { return {data:null, error:{message:String(e)}}; } },
  from: () => { const q = new Proxy({}, {get:(t,k)=> k==='then' ? (r=>r({data:[],error:null})) : (()=>q)}); return q; },
})};
""" % (FOUND, B, FOUND, B, C, FOUND, FOUND, 'true' if pre else 'false', FOUND, FOUND)
with sync_playwright() as p:
    b = p.chromium.launch()
    for pre in (False, True):
        tag = '[pre-migration] ' if pre else ''
        c = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, device_scale_factor=2)
        pg = c.new_page(); errs = []; sbreq = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        def route(r, *_, pre=pre):
            u = r.request.url
            if 'supabase-js' in u: return r.fulfill(status=200, content_type='application/javascript', body=mock(pre))
            if 'supabase.co' in u: sbreq.append(u); return r.abort()
            r.continue_()
        pg.route('**/*', route)
        pg.goto(f'http://127.0.0.1:{srv.server_port}/admin.html#users'); pg.wait_for_timeout(2500)
        pg.evaluate(f"openUser('{FOUND}')"); pg.wait_for_timeout(800)
        check(pg.locator('#founder-revoke').count() == 0, tag + '5e4fa205 (#1) 冇「取消創始編號」掣')
        if not pre: pg.screenshot(path=f'{shots}/admin-founder-5e4fa205-hidden-390x844.png')
        pg.evaluate(f"openUser('{C}')"); pg.wait_for_timeout(800)
        check(pg.locator('#founder-revoke').count() == 0, tag + '冇編號嘅用戶冇掣')
        pg.evaluate(f"openUser('{B}')"); pg.wait_for_timeout(800)
        check(pg.locator('#founder-revoke').count() == 1 and '#3' in pg.inner_text('#founder-revoke'), tag + '有編號用戶顯示「取消創始編號 #3」')
        if not pre: pg.screenshot(path=f'{shots}/admin-founder-revoke-button-390x844.png')
        pg.click('#founder-revoke'); pg.wait_for_timeout(300)
        check(pg.locator('#dlg').is_visible() and '取消創始編號 #3？' in pg.inner_text('#dlg') and pg.locator('#dnote').count() == 1, tag + '確認框有標題同原因欄')
        if not pre: pg.screenshot(path=f'{shots}/admin-founder-revoke-confirm-390x844.png')
        pg.click('#dno'); pg.wait_for_timeout(300)
        check(not any(x[0] == 'admin_revoke_founder' for x in pg.evaluate('__calls')), tag + '取消唔會 call RPC')
        pg.click('#founder-revoke'); pg.wait_for_timeout(300); pg.fill('#dnote', '作弊'); pg.click('#dyes'); pg.wait_for_timeout(900)
        calls = [x for x in pg.evaluate('__calls') if x[0] == 'admin_revoke_founder']
        check(calls == [['admin_revoke_founder', {'p_user': B, 'p_reason': '作弊'}]], tag + 'RPC 參數正確')
        if pre:
            check('請先執行 migration-v190-founders-eligible-revoke.sql' in pg.inner_text('body'), tag + '未執行 migration 顯示提示')
            pg.screenshot(path=f'{shots}/admin-founder-revoke-premigration-toast-390x844.png')
        else:
            pg.wait_for_timeout(800); check(pg.locator('#founder-revoke').count() == 0, '取消後掣消失（重新載入詳情）'); check([x[0] for x in pg.evaluate('__calls') if x[0] in ('admin_founder_no','lb_founder_nos')][-1] == 'admin_founder_no', 'migration 後唔使 fallback lb_founder_nos ' + str([x[0] for x in pg.evaluate('__calls')][-8:]))
        check(not errs, tag + 'no page errors ' + str(errs)); check(not sbreq, tag + '0 supabase.co requests')
        c.close()
    b.close()
print('RESULT', 'OK' if not fails else 'FAILED %d' % len(fails)); srv.shutdown()
raise SystemExit(1 if fails else 0)
