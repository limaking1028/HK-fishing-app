from pathlib import Path
import subprocess,json,re
from playwright.sync_api import sync_playwright
root=Path(__file__).resolve().parents[1]
s=(root/'index.html').read_text()
code=s[s.index('async function saveScoreCard()'):s.index('function closeShareModal()',s.index('async function saveScoreCard()'))]
with sync_playwright() as p:
 b=p.chromium.launch();page=b.new_page();page.set_content('<html><body></body></html>')
 page.evaluate('''() => {
 window.state={scoreCard:{dataUrl:document.createElement('canvas').toDataURL('image/png')}};
 window.scoreCardReady=()=>!!state.scoreCard;
 window.authLib={isNativeIOS:()=>false};window.events=[];
 document.addEventListener('click',e=>{if(e.target.tagName==='A'){e.preventDefault();events.push({download:e.target.download,href:e.target.href});}});
 }''')
 page.add_script_tag(content=code)
 page.evaluate('saveScoreCard()')
 assert page.evaluate('events[0].download')=='diaogang-score.png'
 assert page.evaluate('events[0].href===state.scoreCard.dataUrl')
 print('PASS non-iOS preserves anchor download and PNG data URL')
 page.evaluate('''() => {
 events=[];authLib.isNativeIOS=()=>true;
 window.Capacitor={Plugins:{Filesystem:{writeFile:async o=>{events.push({write:o});return {uri:'file:///cache/fixture.png'}},deleteFile:async o=>events.push({delete:o})},Share:{share:async o=>{events.push({share:o});}}}};
 }''')
 page.evaluate('saveScoreCard()')
 e=page.evaluate('events');assert len(e)==3 and 'write' in e[0] and 'share' in e[1] and 'delete' in e[2]
 assert e[0]['write']['directory']=='CACHE' and not e[0]['write']['data'].startswith('data:')
 assert e[1]['share']['files']==['file:///cache/fixture.png']
 assert e[2]['delete']['path']==e[0]['write']['path']
 print('PASS iOS writes raw PNG base64 to CACHE, shares file URI, then removes temporary file')
 for failure in ['missing','write','share']:
  page.evaluate('''failure=>{
    document.getElementById('score-card-save-fallback')?.remove();events=[];
    if(failure==='missing') {Capacitor.Plugins={};return;}
    Capacitor.Plugins={Filesystem:{writeFile:async o=>{if(failure==='write')throw Error('fixture');return {uri:'file:///cache/fixture.png'}},deleteFile:async o=>events.push('deleted')},Share:{share:async()=>{throw Error('fixture')}}};
  }''',failure)
  page.evaluate('saveScoreCard()')
  assert page.locator('#score-card-save-fallback img').get_attribute('src')==page.evaluate('state.scoreCard.dataUrl')
  assert '長按' in page.locator('#score-card-save-fallback').inner_text()
  assert page.locator('#score-card-save-fallback img').evaluate("e=>e.style.userSelect")=='auto'
  assert '-webkit-touch-callout:default' in code
  if failure=='share': assert page.evaluate("events.includes('deleted')")
  page.locator('#score-card-save-fallback button').click()
  assert page.locator('#score-card-save-fallback').count()==0
 print('PASS missing plugin / write failure / share failure display long-press image fallback with working close')
 for string_rejection in [False,True]:
  page.evaluate("""asString=>{
    events=[];
    Capacitor.Plugins={Filesystem:{writeFile:async()=>({uri:'file:///cache/fixture.png'}),deleteFile:async()=>events.push('delete')},Share:{share:async()=>{throw asString ? 'Share canceled' : Error('Share canceled')}}};
  }""",string_rejection)
  page.evaluate('saveScoreCard()')
  assert page.locator('#score-card-save-fallback').count()==0
  assert page.evaluate('events')==['delete']
  assert page.evaluate('saveScoreCard.busy') is False
 print('PASS canceled share (Error and string) is silent, removes temp file and releases busy guard')

 page.evaluate('''() => {
 events=[];Capacitor.Plugins={Filesystem:{writeFile:async o=>{events.push('write');return {uri:'file:///cache/fixture.png'}},deleteFile:async()=>events.push('delete')},Share:{share:()=>new Promise(r=>window.finishShare=r)}};
 saveScoreCard();saveScoreCard();
 }''')
 page.wait_for_timeout(30)
 assert page.evaluate('events')==['write']
 page.evaluate('finishShare({})');page.wait_for_timeout(30)
 assert page.evaluate('events')==['write','delete'] and page.evaluate('saveScoreCard.busy') is False
 page.evaluate('state.scoreCard=null;events=[];saveScoreCard()')
 assert page.evaluate('events')==[]
 print('PASS repeated taps are guarded, cleanup waits for sheet close, unready image does nothing')
 b.close()
base=subprocess.check_output(['git','show','origin/ios-capacitor:sw.js'],cwd=root).decode()
current=(root/'sw.js').read_text()
assert current.startswith("const CACHE = 'hk-fishing-v201';")
assert current.split('\n',1)[1].startswith(base.split('\n',1)[1])
assert s.count('id="app-version"')==2 and s.count('>v201</span>')==2
print('PASS both app-version render paths and SW CACHE use v201; original photo caching unchanged')
scripts=[js for attrs,js in re.findall(r'<script([^>]*)>(.*?)</script>',s,re.S) if 'src=' not in attrs and 'application/json' not in attrs]
subprocess.run(['node','-e',"const vm=require('vm'),fs=require('fs');for(const s of JSON.parse(fs.readFileSync(0,'utf8')))new vm.Script(s);console.log('PASS inline JS parses')"],input=json.dumps(scripts),text=True,check=True)
