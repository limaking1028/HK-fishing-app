"""Offline notification preferences, routing and SW regression; fake profile/data only."""
import functools,http.server,threading,pathlib
from playwright.sync_api import sync_playwright
root=pathlib.Path(__file__).resolve().parents[1];ios=(root/'ios').is_dir()
types=['record_broken','overtaken','tide_window','lb_chance','trip_open','weekly_summary','inactive']
newkeys=types[2:];labels=['潮汐好時機','上榜機會','行程未結束','每週小結','好耐冇開提醒']
class Handler(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*_):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(root)))
threading.Thread(target=server.serve_forever,daemon=True).start();origin=f'http://127.0.0.1:{server.server_port}'
mock="window.supabase={createClient:()=>({auth:{getSession:async()=>({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})},rpc:async()=>({data:null})})};"
with sync_playwright() as p:
 browser=p.chromium.launch();ctx=browser.new_context(viewport={'width':390,'height':650},is_mobile=True,has_touch=True,service_workers='block')
 pg=ctx.new_page();errors=[];pg.on('pageerror',lambda e:errors.append(str(e)))
 def route(r):
  if r.request.url.startswith(origin+'/'):return r.continue_()
  if '@supabase/supabase-js' in r.request.url:return r.fulfill(content_type='application/javascript',body=mock)
  return r.abort()
 pg.route('**/*',route);pg.add_init_script("localStorage.setItem('sw-cleared-v106','1');localStorage.setItem('hkf-tutorial-seen','1');localStorage.setItem('hk-fishing-analytics-consent','no');")
 pg.goto(origin+'/index.html');pg.evaluate("""() => {
 state.user={id:'prefs-fixture',display_name:'測試釣友'};state.catches=[];state.trips=[];showApp();
 window.fakePrefs=null;window.upserts=[];window.routes=[];window.nativeListeners={};
 window.Capacitor={getPlatform:()=> 'ios',Plugins:{PushNotifications:{addListener:async(n,f)=>{nativeListeners[n]=f},checkPermissions:async()=>({receive:'granted'}),requestPermissions:async()=>({receive:'granted'}),register:async()=>{},unregister:async()=>{}}}};
 window.fakeSb={from(table){const b={select(){return b},eq(){return b},maybeSingle:async()=>({data:fakePrefs}),upsert(row){fakePrefs=structuredClone(row);upserts.push(structuredClone(row));return Promise.resolve({data:row})},update(){return b},then(r){r({data:null})}};return b},rpc:async()=>({data:null})};
 pushLib.init({sb:fakeSb,navigate:data=>routes.push(data)});pushLib.login('prefs-fixture');openNameDialog();
 }""");pg.wait_for_timeout(80)
 actual=pg.evaluate("[...document.querySelectorAll('[id^=push-]')].filter(e=>e.type==='checkbox').map(e=>e.id)")
 assert actual==['push-enabled']+['push-'+t for t in types],actual
 for key,label in zip(newkeys,labels):
  el=pg.locator('#push-'+key);assert label in el.locator('xpath=ancestor::label[1]').inner_text()
  assert el.get_attribute('onchange')==f"pushLib.change('{key}',this.checked)"
  assert el.is_checked() and el.is_disabled()
 for key in types:assert pg.locator('#push-'+key).is_checked()
 print('PASS five IDs/order/labels; no prefs row defaults all seven types on, master off/children disabled')
 pg.locator('#push-enabled').check();pg.wait_for_timeout(80)
 assert all(pg.locator('#push-'+t).is_enabled() for t in types)
 pg.locator('#push-weekly_summary').uncheck();pg.wait_for_timeout(50)
 row=pg.evaluate('upserts.at(-1)');assert all(key in row for key in types);assert row['weekly_summary'] is False and row['enabled'] is True
 print('PASS enabling unlocks children; type upsert preserves all seven independent keys')
 # Native listener and cold URL use the same four-view navigation contract.
 pg.evaluate("nativeListeners.pushNotificationActionPerformed({notification:{data:{view:'map',mapTab:'tide',station:'TAO',latitude:22.3}}})")
 assert pg.evaluate('routes.at(-1)')=={'view':'map','mapTab':'tide','station':'TAO'}
 pg.evaluate("history.replaceState(null,'','?view=trips&private=discard');pushLib.login('prefs-fixture')");pg.wait_for_timeout(80)
 assert pg.evaluate('routes.at(-1)')=={'view':'trips'}
 pg.evaluate("history.replaceState(null,'','?view=leaderboard&lbType=species&lbPeriod=month');pushLib.login('prefs-fixture')");pg.wait_for_timeout(80)
 assert pg.evaluate('routes.at(-1)')=={'view':'leaderboard','lbType':'species','lbPeriod':'month'}
 pg.evaluate("window.goodFrom=fakeSb.from;fakeSb.from=()=>({select(){return this},eq(){return this},maybeSingle:async()=>{throw Error('offline fixture')}});history.replaceState(null,'','?view=my&private=discard');pushLib.login('prefs-fixture')")
 pg.wait_for_timeout(80);assert pg.evaluate('routes.at(-1)')=={'view':'my'}
 pg.evaluate("fakeSb.from=goodFrom;pushLib.login('prefs-fixture')");pg.wait_for_timeout(80)
 if ios:
  pg.set_viewport_size({'width':360,'height':650});assert pg.evaluate("document.getElementById('settings-content').scrollWidth<=360 && document.documentElement.scrollWidth<=innerWidth")
  pg.set_viewport_size({'width':390,'height':650})
  pg.evaluate("""() => {const g=[...document.querySelectorAll('.settings-group')].find(g=>g.querySelector('h2').textContent==='通知');const c=document.getElementById('settings-content');c.scrollBy(0,g.getBoundingClientRect().top-c.getBoundingClientRect().top-12)}""")
  shot=root/'docs/screenshots/push-v205-ios-notifications-390.png';shot.parent.mkdir(parents=True,exist_ok=True);pg.screenshot(path=str(shot),animations='disabled')
 pg.locator('#push-enabled').uncheck();pg.wait_for_timeout(50)
 assert all(pg.locator('#push-'+t).is_disabled() for t in types)
 print('PASS master-off disables children; native/cold routes sanitized; iOS 360px has no horizontal overflow')
 source=(root/'sw.js').read_text()
 for data,expected in [({'view':'map','mapTab':'tide','station':'TAO','longitude':114},'?view=map&mapTab=tide&station=TAO'),({'view':'unknown','mapTab':'invalid'},'?view=leaderboard&lbType=biggest&lbPeriod=all'),({'view':'trips'},'?view=trips')]:
  url=pg.evaluate("""async ({source,data})=>{const handlers={};let opened;const self={registration:{scope:'https://fixture.invalid/app/'},location:{origin:'https://fixture.invalid'},clients:{matchAll:async()=>[],openWindow:async u=>opened=u},addEventListener:(n,f)=>handlers[n]=f};new Function('self','caches','fetch',source)(self,{},()=>{});let promise;handlers.notificationclick({notification:{data,close(){}},waitUntil:p=>promise=p});await promise;return opened}""",{'source':source,'data':data})
  assert url=='https://fixture.invalid/app/'+expected,url
 assert not errors,errors
 print('PASS SW map/tide/trips URL and unknown-view leaderboard fallback; no extra data')
 browser.close()
server.shutdown()
