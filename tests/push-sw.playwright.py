"""Offline push regression: no remote requests or real tokens/keys. python tests/push-sw.playwright.py"""
import functools, http.server, pathlib, threading, subprocess
from playwright.sync_api import sync_playwright
root = pathlib.Path(__file__).resolve().parents[1]
ios = (root/'ios').is_dir()
stacked_base = 'origin/codex/settings-page-ios' if ios else 'origin/codex/push-1-web'
try:
    base = subprocess.check_output(['git', 'show', stacked_base + ':sw.js'], cwd=root, stderr=subprocess.DEVNULL).decode()
except subprocess.CalledProcessError:
    base = subprocess.check_output(['git', 'show', ('origin/ios-capacitor' if ios else 'origin/main') + ':sw.js'], cwd=root).decode()
current = (root/'sw.js').read_text()
assert current.startswith("const CACHE = 'hk-fishing-v216';")
assert current.split('// Push handlers')[0].split('\n',1)[1] == base.split('// Push handlers')[0].split('\n',1)[1], 'Photo cache logic unchanged'
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(root)))
threading.Thread(target=server.serve_forever, daemon=True).start()
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.route('**/*', lambda r: r.continue_() if r.request.url.startswith(f'http://127.0.0.1:{server.server_port}') else r.abort())
    page.goto(f'http://127.0.0.1:{server.server_port}/lib/push.js')
    page.set_content('''<div id="push-explain"></div><div id="push-status"></div>
        <input id="push-enabled"><input id="push-record_broken"><input id="push-overtaken">''')
    page.evaluate('''() => {
      window.calls=[];window.permissionCalls=0;window.fakePrefs=null;
      Object.defineProperty(window,'Notification',{value:{permission:'default',requestPermission(){permissionCalls++;this.permission='denied';return Promise.resolve('denied');}},configurable:true});
      window.fakeSb={from(table){const builder={select(){return this},eq(){return this},maybeSingle(){return Promise.resolve({data:fakePrefs})},upsert(row){calls.push({table,row});fakePrefs=row;return Promise.resolve({data:row})},update(){return this},delete(){return this},then(resolve){resolve({data:null})}};return builder}};
    }''')
    page.add_script_tag(path=str(root/'lib/push.js'))
    page.evaluate("pushLib.init({sb:fakeSb,navigate:b=>calls.push(b)});pushLib.afterCatch()")
    assert page.evaluate('permissionCalls') == 0
    assert page.locator('#push-explain').get_attribute('class') is None
    page.evaluate("pushLib.login('fixture-user')")
    page.wait_for_timeout(80)
    assert page.evaluate('permissionCalls') == 0
    page.evaluate('pushLib.afterCatch()')
    assert 'show' in page.locator('#push-explain').get_attribute('class')
    assert page.evaluate('permissionCalls') == 0
    page.evaluate('pushLib.enable()')
    assert page.evaluate('permissionCalls') == 1
    page.evaluate('pushLib.afterCatch()')
    assert 'show' not in (page.locator('#push-explain').get_attribute('class') or '')
    assert page.evaluate('permissionCalls') == 1
    print('PASS guest/startup/login never requests permission; confirmed catch explains; click requests; refusal never nags')
    # Native plugin mock verifies no startup prompt, APNs listener registration and routing.
    page.evaluate('''() => {
      window.nativeListeners={}; window.nativeRegistrations=0;
      fakePrefs={enabled:true,record_broken:true,overtaken:true};
      window.Capacitor={getPlatform:()=> 'ios',Plugins:{PushNotifications:{
        addListener:async (name,fn)=>{nativeListeners[name]=fn},checkPermissions:async()=>({receive:'granted'}),
        requestPermissions:async()=>{permissionCalls++;return {receive:'granted'}},register:async()=>{nativeRegistrations++},unregister:async()=>{}
      }}};
      fakeSb.rpc=async (name,args)=>{calls.push({name,args});return {data:null}};
      pushLib.login('fixture-user');
    }''')
    page.wait_for_timeout(100)
    assert page.evaluate('permissionCalls') == 1
    assert page.evaluate('nativeRegistrations') == 1
    page.evaluate("nativeListeners.registration({value:'fixture-only-apns-token'}); nativeListeners.pushNotificationActionPerformed({notification:{data:{lbType:'quantity'}}})")
    page.wait_for_timeout(80)
    assert page.evaluate("calls.some(c=>c.name==='push_register_device')")
    assert page.evaluate("calls.some(c=>c && c.view==='leaderboard' && c.lbType==='quantity')")
    page.evaluate("pushLib.change('overtaken',false)")
    page.wait_for_timeout(80)
    assert page.evaluate('fakePrefs.overtaken') is False
    print('PASS native granted startup registers without asking; APNs listener stores token; notification routes; preference persists')
    # Evaluate SW with mocked globals: exercise actual fetch handlers and notification routing.
    outcome = page.evaluate('''async source => {
      const handlers={}, cacheTouches=[]; let shown, opened;
      const scope={location:{origin:'https://fixture.invalid'},registration:{scope:'https://fixture.invalid/app/',showNotification:async(t,o)=>{shown={t,o}}},
        clients:{matchAll:async()=>[],openWindow:async u=>{opened=u}},addEventListener:(n,fn)=>{handlers[n]=fn}};
      const fakeCaches={match:async()=>null,open:async()=>({put(){}})};
      new Function('self','caches','fetch',source)(scope,fakeCaches,async()=>({ok:false}));
      function fetchHandled(url,method='GET') {let handled=false;handlers.fetch({request:{url,method},respondWith(p){handled=true;p.catch(()=>{})}});return handled;}
      const checks=[!fetchHandled('https://fixture.invalid/app/index.html'),!fetchHandled('https://fixture.invalid/app/lib/push.js'),!fetchHandled('https://foreign.invalid/photos/fish.webp'),!fetchHandled('https://fixture.invalid/photos/fish.webp','POST'),fetchHandled('https://fixture.invalid/app/photos/fish.webp')];
      let promise;handlers.push({data:{json:()=>({title:'釣港',body:'測試',data:{lbType:'quantity',latitude:123}})},waitUntil:p=>promise=p});await promise;
      handlers.notificationclick({notification:{data:{lbType:'quantity'},close(){}},waitUntil:p=>promise=p});await promise;
      return {checks,shown,opened};
    }''', current)
    assert all(outcome['checks'])
    assert outcome['shown']['o']['data'] == {'view':'leaderboard','lbType':'quantity','lbPeriod':'all'}
    assert outcome['opened'] == 'https://fixture.invalid/app/?view=leaderboard&lbType=quantity&lbPeriod=all'
    print('PASS SW preserves photo-only fetch/cache; push displays allowlisted routing data; click opens correct app scope')
    for native_mode in [False, True]:
        for known_token in [False, True]:
            test = browser.new_page()
            test.goto(f'http://127.0.0.1:{server.server_port}/lib/push.js')
            test.set_content('<div id="push-explain"></div><div id="push-status"></div>')
            test.evaluate("""mode => {
              localStorage.clear();window.nativeMode=mode;window.calls=[];window.fakePrefs={enabled:false,record_broken:true,overtaken:true};
              window.devices=[{token:'fixture-current',enabled:false},{token:'fixture-other-device',enabled:true}];
              window.listeners={};window.unsubscriptions=0;window.unregistrations=0;
              window.currentSub={toJSON:()=>({endpoint:'https://fixture.invalid/only-local'}),unsubscribe:async()=>{unsubscriptions++}};
              window.currentToken=mode ? 'fixture-current' : JSON.stringify(currentSub.toJSON());devices[0].token=currentToken;
              Object.defineProperty(window,'Notification',{configurable:true,value:{permission:'granted',requestPermission:async()=> 'granted'}});
              Object.defineProperty(navigator,'serviceWorker',{configurable:true,value:{ready:Promise.resolve({pushManager:{getSubscription:async()=>currentSub}})}});
              if(mode) window.Capacitor={getPlatform:()=> 'ios',Plugins:{PushNotifications:{
                addListener:async(n,f)=>{listeners[n]=f},checkPermissions:async()=>({receive:'granted'}),requestPermissions:async()=>({receive:'granted'}),
                register:async()=>{listeners.registration({value:currentToken})},unregister:async()=>{unregistrations++}
              }}};
              window.mockSb={rpc:async(n,a)=>{calls.push({rpc:n});devices[0].enabled=true;return {data:null}},from(table){
                let action,values,filters=[];const builder={select(){return this},eq(k,v){filters.push([k,v]);return this},
                maybeSingle:async()=>({data:fakePrefs}),upsert(row){fakePrefs=row;return Promise.resolve({data:row})},
                update(row){action='update';values=row;return this},delete(){action='delete';return this},
                then(resolve){calls.push({table,action,filters});if(table==='device_tokens')for(const d of devices){if(filters.some(([k,v])=>k==='token'&&d.token!==v))continue;if(action==='delete')d.enabled=false;else Object.assign(d,values)}resolve({data:null})}};return builder;
              }};
            }""", native_mode)
            test.add_script_tag(path=str(root/'lib/push.js'))
            test.evaluate("pushLib.init({sb:mockSb,navigate(){}});pushLib.login('fixture-owner')")
            test.wait_for_timeout(50)
            if known_token:
                test.evaluate("pushLib.change('enabled',true)")
                test.wait_for_timeout(50)
                assert test.evaluate('devices[0].enabled && devices[1].enabled')
                assert test.evaluate('unsubscriptions===0 && unregistrations===0')
                test.evaluate("localStorage.removeItem('hk-push-asked:fixture-owner');pushLib.afterCatch()")
                assert 'show' not in (test.locator('#push-explain').get_attribute('class') or '')
            test.evaluate('pushLib.logout()')
            assert test.evaluate('devices[1].enabled'), 'Logout must never disable another device'
            if not known_token:
                assert not test.evaluate("calls.some(c=>c.table==='device_tokens')"), 'Unknown current token must perform only local cleanup'
            else:
                assert test.evaluate('!devices[0].enabled')
            test.close()
    print('PASS Web/iOS enable keeps token enabled and subscription active; already-authorized catch does not prompt; logout preserves other devices with/without current token')
    # Test click failures with actual SW code, including navigate rejection and focus rejection.
    for fail_focus in [False, True]:
        result = page.evaluate("""async ({source,failFocus}) => {
          const handlers={},events=[];
          const app={url:'https://fixture.invalid/app/',navigate:async()=>{events.push('navigate');throw Error('fixture navigation failure')},focus:async()=>{events.push('focus');if(failFocus)throw Error('fixture closed window')}};
          const scope={location:{origin:'https://fixture.invalid'},registration:{scope:'https://fixture.invalid/app/'},clients:{matchAll:async()=>[app],openWindow:async()=>events.push('open')},addEventListener:(n,f)=>handlers[n]=f};
          new Function('self','caches','fetch',source)(scope,{},()=>{});
          let p;handlers.notificationclick({notification:{data:{lbType:'quantity'},close(){}},waitUntil:x=>p=x});await p;return events;
        }""", {'source':current,'failFocus':fail_focus})
        assert result == (['navigate','focus','open'] if fail_focus else ['navigate','focus'])
    print('PASS SW navigate failure focuses existing window; if focus also fails opens a new window')
    browser.close()
server.shutdown()
