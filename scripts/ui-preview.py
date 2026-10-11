#!/usr/bin/env python3
"""UI 預覽截圖（假 Supabase + 示範資料，唔連真實後台）。
用法：python3 scripts/ui-preview.py <輸出資料夾> [網址，預設 http://localhost:8123/index.html]"""
import sys, os, json
from playwright.sync_api import sync_playwright

OUT = sys.argv[1] if len(sys.argv) > 1 else '/tmp/ui'
URL = sys.argv[2] if len(sys.argv) > 2 else 'http://localhost:8123/index.html'
os.makedirs(OUT, exist_ok=True)

STUB = r"""
(function(){
const UID='u1', now=new Date();
const iso=(d)=>{const x=new Date(now.getTime()-d*864e5);return x.toISOString().slice(0,10)};
const sp=[['黃腳鱲','🐠',2.4,'西貢碼頭'],['石狗公','🐡',0.9,'長洲'],['黑鱲','🐟',1.6,'石澳'],['牛屎鱲','🐟',0.4,'流浮山'],['沙鯭','🐡',0.3,'屯門碼頭'],['黃腳鱲','🐠',3.1,'白沙洲'],['釘公','🐟',0.6,'蒲台島'],['泥鯭','🐡',0.7,'青龍頭']];
const catches=sp.map((s,i)=>({id:'c'+i,user_id:UID,species:s[0],species_icon:s[1],weight_kg:s[2],weight_input:s[2],weight_unit:'kg',length:20+i*4,spot:s[3],date:iso(i*2),time:'0'+(6+i)+':30:00',method:'手竿',bait:'蝦',verified:true,notes:i%3==0?'黃昏流水好':'',leaderboard_eligible:i%2==0,ineligible_reason:i%2?'photo_not_fresh':null,trip_id:i<3?'t1':null,created_at:new Date(now.getTime()-i*864e5).toISOString()}));
const trips=[
 {id:'t1',user_id:UID,started_at:new Date(now.getTime()-3*36e5).toISOString(),ended_at:null,spot:'西貢碼頭',method:'手竿',bait:'蝦',latitude:22.38,longitude:114.27,catch_count:3,total_weight_kg:6.1,haul_photos:[]},
 {id:'t0',user_id:UID,started_at:new Date(now.getTime()-5*864e5).toISOString(),ended_at:new Date(now.getTime()-5*864e5+4*36e5).toISOString(),spot:'長洲',method:'投竿',bait:'沙蟲',latitude:22.2,longitude:114.03,catch_count:12,total_weight_kg:8.4,haul_photos:[]},
 {id:'t00',user_id:UID,started_at:new Date(now.getTime()-12*864e5).toISOString(),ended_at:new Date(now.getTime()-12*864e5+5*36e5).toISOString(),spot:'石澳',method:'磯釣',bait:'蝦',latitude:22.23,longitude:114.25,catch_count:5,total_weight_kg:3.2,haul_photos:[]}];
const users=[{id:UID,display_name:'阿釣',email:'demo@example.com',avatar:'🎣'},{id:'u2',display_name:'磯釣王',avatar:'🎣'},{id:'u3',display_name:'海風',avatar:'🎣'}];
const tables={catches,fishing_trips:trips,users,trip_tallies:[{trip_id:'t1',species:'黃腳鱲',qty:24}]};
function qb(name){let rows=tables[name]||[];const q={};
 ['select','eq','or','order','in','is','gte','lte','limit','neq','not','range'].forEach(m=>q[m]=()=>q);
 q.maybeSingle=async()=>({data:rows[0]||null,error:null}); q.single=q.maybeSingle;
 q.then=(res)=>res({data:rows,error:null});
 q.upsert=async()=>({error:null}); q.insert=()=>({select:()=>({single:async()=>({data:{},error:null})}),then:(r)=>r({error:null})}); q.update=()=>({eq:()=>({eq:async()=>({error:null}),select:async()=>({data:[{}],error:null})})}); q.delete=()=>({eq:()=>({eq:async()=>({error:null})})});
 return q;}
const lb=[['磯釣王','黃腳鱲','🐠',4.8,'白沙洲'],['海風','石狗公','🐡',3.9,'長洲'],['阿釣','黃腳鱲','🐠',3.1,'白沙洲'],['釣友小明','黑鱲','🐟',2.7,'石澳']].map((r,i)=>({pos:i+1,catch_id:'x'+i,display_name:r[0],is_mine:r[0]==='阿釣',species:r[1],species_icon:r[2],weight_kg:r[3],spot:r[4],catch_date:iso(i),catch_time:'07:30'}));
const stats=[['磯釣王',48,9,6],['阿釣',31,7,5],['海風',22,5,4]].map((r,i)=>({pos:i+1,display_name:r[0],is_mine:r[0]==='阿釣',catch_count:r[1],spot_count:r[2],species_count:r[3],biggest_kg:4.2}));
const session={user:{id:UID,email:'demo@example.com'},access_token:'x'};
const client={auth:{getSession:async()=>({data:{session}}),getUser:async()=>({data:{user:session.user}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),signOut:async()=>({})},
 from:(n)=>qb(n), rpc:async(n)=>({data:n==='lb_biggest'?lb:n==='lb_stats'?stats:null,error:null}),
 storage:{from:()=>({upload:async()=>({error:null}),getPublicUrl:()=>({data:{publicUrl:''}}),list:async()=>({data:[]}),remove:async()=>({})})}};
window.supabase={createClient:()=>client};
})();
"""
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, has_touch=True, is_mobile=True)
    pg = ctx.new_page(); errs = []
    pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/supabase-js**', lambda r: r.fulfill(body=STUB, content_type='application/javascript'))
    pg.route('**/*tile*', lambda r: r.abort())
    pg.add_init_script("localStorage.setItem('hk-fishing-analytics-consent','yes');localStorage.setItem('sw-cleared-v106','1');")
    # 登入畫面（未登入版本）
    pg2 = ctx.new_page(); pg2.route('**/supabase-js**', lambda r: r.fulfill(body=STUB.replace("session={user","session=null&&{user").replace("getSession:async()=>({data:{session}})","getSession:async()=>({data:{session:null}})"), content_type='application/javascript'))
    pg2.route('**/*tile*', lambda r: r.abort()); pg2.goto(URL); pg2.wait_for_timeout(2200); pg2.screenshot(path=f'{OUT}/00-login.png'); pg2.close()
    pg.goto(URL); pg.wait_for_timeout(3500)
    shots = [('my','01-my'),('trips','02-trips'),('record','03-record'),('leaderboard','04-leaderboard'),('map','05-map')]
    for view, name in shots:
        pg.evaluate(f"switchView('{view}')"); pg.wait_for_timeout(1200)
        pg.screenshot(path=f'{OUT}/{name}.png')
    pg.evaluate("switchView('trips')"); pg.wait_for_timeout(600)
    pg.evaluate("openTripDetail('t0')"); pg.wait_for_timeout(700); pg.screenshot(path=f'{OUT}/06-trip-detail.png')
    pg.evaluate("closeTripDetail && closeTripDetail()")
    pg.evaluate("openTallySheet('t1')"); pg.wait_for_timeout(800); pg.screenshot(path=f'{OUT}/07-tally.png'); pg.evaluate("closeTallySheet()")
    pg.evaluate("openNameDialog()"); pg.wait_for_timeout(800); pg.screenshot(path=f'{OUT}/08-settings.png')
    print('errors:', errs)
    b.close()
