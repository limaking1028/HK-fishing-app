"""Generated iOS smoke. Offline mocks; every non-local request intercepted."""
import functools, http.server, pathlib, subprocess, threading, os
from playwright.sync_api import sync_playwright
root=pathlib.Path(__file__).resolve().parents[1]
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*_): pass
    def copyfile(self,source,outputfile):
        try: super().copyfile(source,outputfile)
        except (BrokenPipeError,ConnectionResetError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(root/'www')))
threading.Thread(target=server.serve_forever,daemon=True).start()
origin=f'http://127.0.0.1:{server.server_port}'
MOCK="""window.clientCalls=[];window.supabase={createClient(url,key,options){clientCalls.push({url,storageKey:options.auth.storageKey});return {auth:{getSession:async()=>({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})},from(){const b={select(){return b},eq(){return b},gt(){return b},in(){return b},order(){return b},limit(){return b},maybeSingle:async()=>({data:null}),then(r){r({data:null})}};return b;},rpc:async()=>({data:null})}}};"""
with sync_playwright() as p:
    browser=p.chromium.launch()
    for env in ['test','prod']:
        subprocess.run(['node','scripts/build-ios-web.js'],cwd=root,env={**os.environ,'APP_ENV':env,'HKF_TEST_SUPABASE_ANON_KEY':'sb_publishable_offline_fixture_only'},check=True)
        context=browser.new_context(service_workers='block')
        context.add_init_script("window.Capacitor={isNativePlatform:()=>true,getPlatform:()=> 'ios',Plugins:{App:{addListener(){}}}};localStorage.setItem('hk_fishing_unsynced_v1','legacy-sentinel');")
        page=context.new_page(); errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        def route(r):
            if r.request.url.startswith(origin): return r.continue_()
            if '@supabase/supabase-js' in r.request.url: return r.fulfill(content_type='text/javascript',body=MOCK)
            return r.abort()
        page.route('**/*',route)
        page.goto(origin+'/index.html')
        try: page.wait_for_selector('.login-subtitle',timeout=10000)
        except Exception:
            print('BOOT DIAGNOSTIC', errors, page.locator('body').inner_text()[-1200:]); raise
        ref='qyijyrcbzalvqiautvjf' if env=='test' else 'lucizjohiycxdynrkjus'
        assert all(x['url']==f'https://{ref}.supabase.co' for x in page.evaluate('clientCalls'))
        assert page.evaluate('clientCalls.length')>0
        assert page.evaluate("localStorage.getItem('hk_fishing_unsynced_v1')")=='legacy-sentinel'
        assert page.locator('#hkf-test-banner').count()==(1 if env=='test' else 0)
        if env=='test':
            assert page.locator('#auth-google-btn').is_disabled()
            assert page.locator('#auth-apple-btn').is_disabled()
            assert '測試環境未啟用' in page.locator('#auth-google-btn').inner_text()
        assert not errors,errors
        print('PASS generated',env,'native login, selected client, preserved legacy data, banner/provider controls')
        context.close()
    # Missing manifest must stop app before any client can be constructed.
    context=browser.new_context(service_workers='block');page=context.new_page()
    def missing(r):
        if r.request.url.endswith('/hkf-env.js'):return r.fulfill(content_type='text/javascript',body='')
        if '@supabase/supabase-js' in r.request.url:return r.fulfill(content_type='text/javascript',body=MOCK)
        if r.request.url.startswith(origin):return r.continue_()
        return r.abort()
    page.route('**/*',missing);page.goto(origin+'/index.html',wait_until='commit')
    page.get_by_text('環境設定錯誤',exact=True).wait_for()
    assert page.get_by_text('環境設定錯誤',exact=True).is_visible()
    assert page.evaluate('typeof window.HKF')=='undefined'
    assert page.evaluate('!window.clientCalls || clientCalls.length===0')
    print('PASS missing manifest displays error and constructs no Supabase client')
    context.close();browser.close()
server.shutdown()
