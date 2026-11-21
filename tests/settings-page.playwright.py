"""Settings UI regression with fake profiles and no external/backend calls."""
import functools,http.server,threading,os,pathlib
from playwright.sync_api import sync_playwright
root=pathlib.Path(__file__).resolve().parents[1]
ios=(root/'ios').is_dir()
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*_): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(root)))
threading.Thread(target=server.serve_forever,daemon=True).start()
origin=f'http://127.0.0.1:{server.server_port}'
mock="""window.supabase={createClient:()=>({auth:{getSession:async()=>({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})},rpc:async()=>({data:null}),from(){const b={select(){return b},eq(){return b},maybeSingle:async()=>({data:null})};return b}})};"""
with sync_playwright() as p:
 b=p.chromium.launch();ctx=b.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True,service_workers='block')
 pg=ctx.new_page();errors=[];pg.on('pageerror',lambda e: errors.append(str(e)))
 def route(r):
  if r.request.url.startswith(origin+'/'):return r.continue_()
  if '@supabase/supabase-js' in r.request.url:return r.fulfill(content_type='application/javascript',body=mock)
  return r.abort()
 pg.route('**/*',route)
 pg.add_init_script("localStorage.setItem('sw-cleared-v106','1');localStorage.setItem('hkf-tutorial-seen','1');localStorage.setItem('hk-fishing-analytics-consent','no');")
 pg.goto(origin+'/index.html');pg.wait_for_timeout(150)
 pg.evaluate("""() => {
 state.user={id:'settings-fixture',display_name:'釣友阿明'};state.catches=[];state.trips=[];showApp();
 document.getElementById('header-username').textContent=getUserName();
 window.setUserName=async value=>{state.user.display_name=value;return true};
 window.renderAll=()=>{};window.renderView=()=>{};
 authLib.updatePassword=async()=>{window.passwordUpdates=(window.passwordUpdates||0)+1};
 if(window.pushLib){pushLib.init({sb,navigate(){}});pushLib.login(state.user.id)}
 }""")
 entry=pg.locator('.header-settings')
 assert '釣友阿明' in entry.inner_text() and '設定' in entry.inner_text() and '改名' not in entry.inner_text()
 assert entry.locator('#founder-badge').count()==1
 entry.click();page=pg.locator('#name-modal');assert page.is_visible()
 # This is the first pointer action in a fresh context; do not prime keyboard modality.
 back=page.locator('.settings-back')
 assert not back.evaluate("el=>el.matches(':focus-visible')")
 assert back.evaluate("el=>getComputedStyle(el).outlineStyle")=='none'
 assert back.evaluate("el=>getComputedStyle(el).boxShadow")=='none'
 assert page.locator('.settings-bar h1').evaluate('(el)=>document.activeElement===el')
 assert page.locator('.settings-bar h1').evaluate("el=>getComputedStyle(el).outlineStyle")=='none'
 assert page.locator('.settings-bar h1').evaluate("el=>getComputedStyle(el).boxShadow")=='none'

 assert page.locator('.settings-back').inner_text()=='‹ 返回'
 headings=page.locator('h2').all_text_contents()
 expected=['個人資料','使用偏好']+(['通知'] if ios else [])+['私隱','幫助','帳戶','資料管理']
 assert headings==expected,headings
 rect=page.bounding_box();assert rect['x']==0 and rect['y']==0 and rect['width']==390 and rect['height']==844
 assert pg.locator('#settings-version').inner_text()=='釣港 v203'
 if ios:
  # Real env() emulation plus the transform's matching variables: safe area counted once.
  cdp=ctx.new_cdp_session(pg)
  cdp.send('Emulation.setSafeAreaInsetsOverride',{'insets':{'top':47}})
  pg.evaluate("document.documentElement.style.setProperty('--hkf-safe-top','47px');document.documentElement.style.setProperty('--hkf-banner-height','75px')")
  safe=page.bounding_box();assert safe['y']==75 and safe['height']==769
  back_top=page.locator('.settings-back').bounding_box()['y']
  assert abs(back_top-(75+12))<=2,back_top
  assert pg.evaluate("getComputedStyle(document.querySelector('.settings-bar')).paddingTop")=='12px'
  # Production has no transform variables and retains the native safe-area padding.
  pg.evaluate("document.documentElement.style.removeProperty('--hkf-safe-top');document.documentElement.style.removeProperty('--hkf-banner-height')")
  assert pg.evaluate("getComputedStyle(document.querySelector('.settings-bar')).paddingTop")=='59px'
  cdp.send('Emulation.setSafeAreaInsetsOverride',{'insets':{'top':0}})
  assert pg.evaluate("getComputedStyle(document.querySelector('.settings-bar')).paddingTop")=='12px'
  cdp.detach()

 # Reader focus starts on the page heading; keyboard navigation still highlights Back.
 assert page.locator('.settings-bar h1').evaluate('(el)=>document.activeElement===el')
 pg.keyboard.press('Tab');pg.keyboard.press('Shift+Tab')
 assert page.locator('.settings-back').evaluate("el=>el.matches(':focus-visible')")
 assert page.locator('.settings-back').evaluate("el=>getComputedStyle(el).outlineWidth")=='2px'
 assert page.locator('.settings-back').evaluate("el=>getComputedStyle(el).outlineOffset")=='2px'
 assert page.locator('.settings-back').evaluate("el=>getComputedStyle(el).boxShadow")=='none'
 page.locator('.settings-back').click();pg.wait_for_timeout(100);assert page.is_hidden()
 entry.click();pg.evaluate('history.back()');pg.wait_for_timeout(100);assert page.is_hidden()
 entry.click();pg.get_by_role('button',name='釣友名稱').click()
 pg.locator('#name-input').fill('新釣友');pg.locator('#settings-name-dialog').get_by_role('button',name='保存',exact=True).click()
 pg.wait_for_timeout(50);assert page.is_visible() and not pg.locator('#settings-name-dialog').is_visible()
 assert pg.locator('#settings-current-name').inner_text()=='新釣友'
 pg.locator('#pref-weight-unit').select_option('jin');assert pg.locator('#settings-current-unit').inner_text()=='斤'
 toggle=pg.locator('#analytics-toggle-btn');assert not toggle.is_checked();toggle.check();assert pg.evaluate('getAnalyticsConsent()')
 page.locator('.settings-back').click();pg.wait_for_timeout(100);entry.click();assert toggle.is_checked()
 toggle.uncheck();assert pg.evaluate('getAnalyticsConsent()') is False
 pg.get_by_role('button',name='設定／更改密碼').click()
 for id in ['settings-new-pw','settings-pw-btn','settings-pw-msg']:assert pg.locator('#settings-password-dialog #'+id).count()==1
 pg.locator('#settings-new-pw').fill('fixture-password-not-sent');pg.locator('#settings-pw-btn').click()
 pg.wait_for_timeout(50);assert pg.evaluate('passwordUpdates')==1 and '成功' in pg.locator('#settings-pw-msg').inner_text()
 pg.locator('#settings-password-dialog').get_by_role('button',name='取消').click()
 if ios:
  for id in ['push-enabled','push-record_broken','push-overtaken']:
   el=pg.locator('#'+id);assert el.count()==1 and el.get_attribute('type')=='checkbox' and 'pushLib.change(' in el.get_attribute('onchange')
 else:assert page.locator('[id^="push-"]').count()==0
 pg.set_viewport_size({'width':360,'height':780})
 assert pg.evaluate("document.documentElement.scrollWidth<=innerWidth && document.getElementById('settings-content').scrollWidth<=360")
 pg.evaluate("document.getElementById('settings-content').scrollTop=500")
 page.locator('.settings-back').click();pg.wait_for_timeout(100);entry.click();assert pg.evaluate("document.getElementById('settings-content').scrollTop")==0
 privacy_url = 'https://limaking1028.github.io/HK-fishing-app/privacy.html'
 privacy = pg.get_by_role('link', name='私隱政策', exact=True)
 assert privacy.get_attribute('href') == privacy_url
 assert privacy.get_attribute('target') == '_blank'
 pg.evaluate("""ios => {
   window.privacyCalls = [];
   window.open = (...args) => window.privacyCalls.push(args);
   if (ios) window.Capacitor = {
     isNativePlatform: () => true,
     getPlatform: () => 'ios',
     Plugins: {Browser: {open: async ({url}) => window.privacyCalls.push([url])}}
   };
 }""", ios)
 original_url = pg.url
 privacy.click()
 assert pg.evaluate('window.privacyCalls') == ([[privacy_url]] if ios else [[privacy_url, '_blank', 'noopener']])
 assert pg.url == original_url and privacy.is_visible()
 # Full settings-page screenshot, fixture user and preferences. Exactly 390 CSS px wide.
 pg.set_viewport_size({'width':390,'height':1400});pg.evaluate("document.getElementById('settings-content').scrollTop=0")
 path=root/'docs/screenshots'/('settings-page-v203-'+('ios' if ios else 'web')+'-390.png');path.parent.mkdir(parents=True,exist_ok=True)
 frame=pg.locator('#settings-version').bounding_box()
 pg.set_viewport_size({'width':390,'height':int(frame['y']+frame['height']+33)})
 pg.wait_for_timeout(3200) # Let normal success toasts disappear before the review screenshot.
 pg.screenshot(path=str(path),animations='disabled')
 page.locator('.settings-back').click();pg.wait_for_timeout(100)
 pg.evaluate('state.user=null');entry.click();assert page.is_hidden() and pg.locator('#auth-google-btn').is_visible()
 assert not errors,errors
 b.close()
server.shutdown()
print('PASS settings: entry/groups/fullscreen/back+history/name/unit/consent/password/version/360px/push IDs/guest; screenshot uses fixture data')
