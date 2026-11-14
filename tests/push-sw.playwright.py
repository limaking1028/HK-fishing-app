"""Offline push regression: no remote requests or real tokens/keys. python tests/push-sw.playwright.py"""
import functools, http.server, pathlib, threading, subprocess
from playwright.sync_api import sync_playwright
root = pathlib.Path(__file__).resolve().parents[1]
base = subprocess.check_output(['git', 'show', 'origin/main:sw.js'], cwd=root).decode()
current = (root/'sw.js').read_text()
assert current.startswith(base), 'Existing SW must be byte-for-byte unchanged'
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
    assert page.evaluate("calls.includes('quantity')")
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
    browser.close()
server.shutdown()
