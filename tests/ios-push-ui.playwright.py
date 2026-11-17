"""Generated prod/test push gate. Offline SDK, native plugin and backend mocks only."""
import functools
import http.server
import os
from pathlib import Path
import subprocess
import threading
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(ROOT/'www')))
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = f'http://127.0.0.1:{server.server_port}'
SDK = """window.backendCalls=[]; window.fakePushPrefs={enabled:true,record_broken:true,overtaken:true};
window.supabase={createClient(){return {
  auth:{getSession:async()=>({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),signOut:async()=>({error:null})},
  from(table){backendCalls.push({table});const q=new Proxy({}, {get(t,key){
    if(key==='then')return resolve=>resolve({data:[]});
    if(key==='maybeSingle')return async()=>({data:table==='notification_prefs'?fakePushPrefs:null});
    if(key==='upsert')return row=>{if(table==='notification_prefs')fakePushPrefs=row;return Promise.resolve({data:row})};
    return ()=>q;
  }});return q},
  rpc:async name=>{backendCalls.push({rpc:name});return {data:null}}
}}};"""
NATIVE = """window.nativeCalls=[];window.browserPermissionCalls=0;window.pushListeners={};
window.Capacitor={isNativePlatform:()=>true,getPlatform:()=> 'ios',Plugins:{App:{addListener(){}},PushNotifications:{
  addListener:async(name,fn)=>{nativeCalls.push('listen:'+name);pushListeners[name]=fn},
  checkPermissions:async()=>{nativeCalls.push('check');return {receive:'granted'}},
  requestPermissions:async()=>{nativeCalls.push('permission');return {receive:'granted'}},
  register:async()=>{nativeCalls.push('register');await pushListeners.registration?.({value:'offline-apns-fixture'})},
  unregister:async()=>{nativeCalls.push('unregister')}
}}};
Object.defineProperty(window,'Notification',{configurable:true,value:{permission:'granted',requestPermission:async()=>{browserPermissionCalls++;return 'granted'}}});"""
PUSH_CALLS = "backendCalls.filter(c=>['notification_prefs','device_tokens'].includes(c.table)||c.rpc==='push_register_device')"
with sync_playwright() as p:
    browser = p.chromium.launch()
    for env in ['prod', 'test']:
        subprocess.run(['npm','run','ios:web'],cwd=ROOT,env={**os.environ,'APP_ENV':env,'HKF_TEST_SUPABASE_ANON_KEY':'sb_publishable_offline_fixture_only'},check=True)
        context=browser.new_context(service_workers='block',viewport={'width':390,'height':844},is_mobile=True,has_touch=True)
        context.add_init_script(NATIVE)
        page=context.new_page(); errors=[];remote=[]
        page.on('pageerror',lambda e:errors.append(str(e)))
        def route(r):
            if r.request.url.startswith(ORIGIN+'/'):return r.continue_()
            if '@supabase/supabase-js' in r.request.url:return r.fulfill(content_type='application/javascript',body=SDK)
            remote.append(r.request.url);return r.abort()
        page.route('**/*',route)
        page.goto(ORIGIN+'/index.html')
        page.wait_for_selector('.login-subtitle')
        assert page.evaluate('HKF_BUILD.pushUi') == (env=='test')
        assert page.evaluate('pushLib.isEnabled()') == (env=='test')
        for selector in ['#push-enabled','#push-record_broken','#push-overtaken','#push-status','#push-explain']:
            assert page.locator(selector).count()==(1 if env=='test' else 0),selector
        assert page.locator('#name-modal fieldset').count()==(1 if env=='test' else 0)
        # Real completion path initializes push after loading the user's offline data.
        page.evaluate("""async () => {
          HKF.setOwner('offline-push-user');
          HKF.local.setItem('hk-fishing-analytics-consent','no');
          HKF.local.setItem('hkf-tutorial-seen','1');
          await completeSignIn({id:'offline-push-user',display_name:'測試釣友'});
        }""")
        assert page.locator('#header').is_visible()
        page.evaluate('openNameDialog()')
        assert page.locator('#name-modal').is_visible()
        if env=='prod':
            page.evaluate("""async () => {
              pushLib.login('offline-push-user');pushLib.refresh();
              await pushLib.afterCatch();await pushLib.enable();
              await pushLib.change('enabled',true);pushLib.dismiss();await pushLib.logout();
            }""")
            page.wait_for_timeout(100)
            assert page.evaluate(PUSH_CALLS)==[]
            assert page.evaluate('nativeCalls')==[]
            assert page.evaluate('browserPermissionCalls')==0
            # A disabled build must skip push logout entirely, even if it never resolves.
            page.evaluate("() => {window.pushLogoutCalls=0;pushLib.logout=()=>{pushLogoutCalls++;return new Promise(()=>{})};}")
            page.evaluate("() => Promise.race([sbLogout(),new Promise((_,reject)=>setTimeout(()=>reject(new Error('logout waited for disabled push')),500))])")
            assert page.evaluate('pushLogoutCalls')==0
            assert page.evaluate(PUSH_CALLS)==[] and page.evaluate('nativeCalls')==[]
            print('PASS prod: notification DOM absent; login/settings/all push entry points make no push queries, RPCs, native calls or permission requests; logout skips cleanup wait')
        else:
            page.wait_for_function("nativeCalls.includes('register') && backendCalls.some(c=>c.rpc==='push_register_device')")
            assert 'permission' not in page.evaluate('nativeCalls')
            assert page.evaluate('browserPermissionCalls')==0
            page.evaluate("fakePushPrefs={enabled:false,record_broken:true,overtaken:true};pushLib.refresh()")
            page.wait_for_function("!document.getElementById('push-enabled').checked")
            page.evaluate('pushLib.afterCatch()')
            assert page.locator('#push-explain').evaluate("el=>el.classList.contains('show')")
            page.evaluate('closeNameDialog()')
            page.locator('#push-explain button[onclick="pushLib.enable()"]').tap()
            page.wait_for_function("nativeCalls.includes('permission') && document.getElementById('push-enabled').checked")
            print('PASS test: notification fieldset retained; startup APNs registration and explicit permission/opt-in still work')
        assert not errors,errors
        assert not any('.supabase.co/' in url for url in remote),remote
        context.close()
    browser.close()
server.shutdown()
