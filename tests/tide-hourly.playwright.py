"""Offline tide UI regression. python3 tests/tide-hourly.playwright.py"""
import functools,http.server,threading,json,os,datetime,re
from pathlib import Path
from playwright.sync_api import sync_playwright
root=Path(__file__).resolve().parents[1]
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(root)))
threading.Thread(target=server.serve_forever,daemon=True).start()
origin=f'http://127.0.0.1:{server.server_port}'
with sync_playwright() as p:
 browser=p.chromium.launch()
 for width,height in [(375,667),(390,844)]:
  c=browser.new_context(viewport={'width':width,'height':height},is_mobile=True,has_touch=True,timezone_id='Asia/Hong_Kong',service_workers='block')
  pg=c.new_page();errors=[];requests=[]
  pg.on('pageerror',lambda e:errors.append(str(e)))
  def route(r):
   if r.request.url.startswith(origin+'/'):r.continue_()
   else:requests.append(r.request.url);r.abort()
  pg.route('**/*',route)
  pg.add_init_script("localStorage.setItem('sw-cleared-v106','1');")
  pg.goto(origin+'/index.html')
  pg.evaluate("async()=>{await tidesLib.ready; tidesLib.setNowForTest(new Date(2026,10,15,11,30).getTime());showApp();enterGuestMode();switchMapTab('tide');}")
  pg.wait_for_timeout(300)
  assert pg.locator('.tide-card').count()==12
  assert pg.evaluate('state.user===null')
  for code in ['QUB','TPK','CCH','TAO','SPW','TBT','CHK','KCQ']:
   assert pg.locator(f'.tide-card[data-station="{code}"] .tide-card-est').count()==0
  for code in ['SAI','LAM','TCT','PEN']:
   assert pg.locator(f'.tide-card[data-station="{code}"] .tide-card-est').inner_text()=='估算'
  card=pg.locator('.tide-card[data-station="QUB"]');ex=card.locator('.tide-explorer');chart=card.locator('.tide-chart')
  assert ex.get_attribute('data-source')=='hourly'
  expected=pg.evaluate("tidesLib.getTideHeight('QUB',tidesLib.now()).toFixed(2)")
  assert expected+' 米' in card.locator('.tide-explorer-readout').inner_text()
  row=json.loads((root/'lib/tide-hourly-2026.json').read_text())['stations']['QUB'][(datetime.date(2026,11,15)-datetime.date(2026,1,1)).days]
  official=(row[10]+row[11])/200
  assert abs(float(expected)-official)<=0.01000001
  assert pg.evaluate('document.documentElement.scrollWidth<=innerWidth'), 'page must not overflow sideways'
  assert card.locator('.tide-forecast-row').count()==5
  assert chart.evaluate("e=>getComputedStyle(e).touchAction")=='pan-y'
  assert card.locator('.tide-hours').evaluate('e=>e.scrollWidth>e.clientWidth')
  chart.scroll_into_view_if_needed();box=chart.bounding_box();initial=ex.get_attribute('data-selected')
  pg.mouse.move(box['x']+box['width']*.3,box['y']+60);pg.mouse.down()
  pg.mouse.move(box['x']+box['width']*.5,box['y']+62,steps=4);middle=ex.get_attribute('data-selected')
  pg.mouse.move(box['x']+box['width']*.8,box['y']+63,steps=4);pg.mouse.up()
  assert ex.get_attribute('data-selected')!=middle
  # Hold at the right edge to pan the one-day viewport across the three-day rail.
  scroll=chart.evaluate('e=>e.scrollLeft')
  pg.mouse.move(box['x']+box['width']*.5,box['y']+60);pg.mouse.down()
  pg.mouse.move(box['x']+box['width']-8,box['y']+61,steps=4);pg.wait_for_timeout(200);pg.mouse.up()
  assert chart.evaluate('e=>e.scrollLeft')>scroll
  assert ex.get_attribute('data-selected')!=initial
  assert card.locator('.tide-hours [aria-pressed="true"]').count()==1
  card.locator('[data-now]').click();assert ex.get_attribute('data-selected')==initial
  before=ex.get_attribute('data-selected')
  for step,count in [(30,144),(120,36),(60,72)]:
   card.locator(f'[data-step="{step}"]').click()
   assert card.locator('.tide-hours button').count()==count
   assert ex.get_attribute('data-selected')==before
  tile=card.locator('.tide-hours button').nth(40);tile.click()
  assert ex.get_attribute('data-selected')==tile.get_attribute('data-ms')
  card.locator('.tide-hours').evaluate('e=>e.scrollLeft=0');pg.wait_for_timeout(250)
  card.locator('.tide-hours').evaluate('e=>e.scrollLeft=900');pg.wait_for_timeout(200)
  assert card.locator('.tide-hours [aria-pressed="true"]').count()==1
  for day in [1,2]:
   card.locator(f'[data-day="{day}"]').click()
   assert pg.evaluate("ms=>new Date(Number(ms)).getDate()",ex.get_attribute('data-selected'))==15+day
  assert card.locator('.tide-hours .rising').count()>0 and card.locator('.tide-hours .falling').count()>0
  assert '漲' in card.locator('.tide-hours .rising').first.inner_text()
  assert '退' in card.locator('.tide-hours .falling').first.inner_text()
  assert card.locator('.tide-hours .rising').first.evaluate('e=>getComputedStyle(e).borderTopColor')=='rgb(249, 115, 22)'
  assert card.locator('.tide-hours .falling').first.evaluate('e=>getComputedStyle(e).borderTopColor')=='rgb(13, 148, 136)'
  chart.focus();pg.keyboard.press('Home');assert ex.get_attribute('data-selected')==initial
  pg.keyboard.press('ArrowRight');assert int(ex.get_attribute('data-selected'))==int(initial)+3600000
  cpage=pg.locator('#view-map');assert all(t in cpage.inner_text() for t in ['香港天文台','香港特別行政區政府','DATA.GOV.HK','Chart Datum','知識產權擁有人'])
  for date in [30,31]:
   pg.evaluate(f"tidesLib.setNowForTest(new Date(2026,11,{date},23,30).getTime());renderMapTideList(document.getElementById('view-map'))")
   card=pg.locator('.tide-card[data-station="QUB"]');ex=card.locator('.tide-explorer');card.locator('[data-day="2"]').click()
   assert ex.get_attribute('data-source')=='hourly'
   assert pg.evaluate('ms=>new Date(Number(ms)).getFullYear()',ex.get_attribute('data-selected'))==2027
   assert pg.evaluate('ms=>new Date(Number(ms)).getDate()',ex.get_attribute('data-selected'))==date-29
  pg.emulate_media(reduced_motion='reduce');card.locator('[data-now]').click()
  assert ex.get_attribute('data-selected')==str(pg.evaluate('tidesLib.now()'))
  assert not any('data.weather.gov.hk' in u or 'data.gov.hk' in u for u in requests)
  if os.environ.get('SHOT_DIR'):
   Path(os.environ['SHOT_DIR']).mkdir(parents=True,exist_ok=True);card.scroll_into_view_if_needed();pg.screenshot(path=f'{os.environ["SHOT_DIR"]}/{width}-tides.png')
  assert not errors,errors
  print(f'PASS {width}x{height}: 12 guest cards, hourly height, drag, reset, strip, intervals, day chips, cross-year, gestures CSS, reduced-motion, attribution')
  c.close()
 # A failed local hourly fetch must retain a usable, visibly labelled estimate.
 c=browser.new_context(service_workers='block');pg=c.new_page()
 pg.route('**/*',lambda r:r.abort() if not r.request.url.startswith(origin+'/') or 'tide-hourly-' in r.request.url else r.continue_())
 pg.goto(origin+'/index.html');pg.evaluate("async()=>{await tidesLib.ready;tidesLib.setNowForTest(new Date(2026,10,15,12).getTime());showApp();enterGuestMode();switchMapTab('tide');}")
 assert pg.locator('.tide-card-est').count()==12
 assert pg.locator('.tide-explorer').first.get_attribute('data-source')=='cosine'
 assert '估算' in pg.locator('.tide-explorer-readout').first.inner_text()
 print('PASS failed local files: cosine fallback explicitly labelled on all cards')
 c.close();browser.close()
server.shutdown()
