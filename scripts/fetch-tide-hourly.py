"""Build-time HKO HHOT/HLT importer. Validate every response before replacing files.
Usage: python3 scripts/fetch-tide-hourly.py (network required; app never calls HKO).
"""
import calendar, csv, io, json, math, re, urllib.request
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
CODES=['QUB','TPK','CCH','TAO','SPW','TBT','CLK','KCT']
YEARS=[2026,2027]
SOURCE='香港特別行政區政府／香港天文台／DATA.GOV.HK；知識產權擁有人：政府及香港天文台'
def fetch(job):
 kind,code,year=job
 url=f'https://data.weather.gov.hk/weatherAPI/opendata/opendata.php?dataType={kind}&station={code}&year={year}&rformat=csv'
 with urllib.request.urlopen(url,timeout=60) as r:
  if r.status!=200: raise ValueError(url)
  rows=list(csv.reader(io.StringIO(r.read().decode('utf-8-sig'))))
 expected=[(m,d) for m in range(1,13) for d in range(1,calendar.monthrange(year,m)[1]+1)]
 if len(rows)!=len(expected)+1: raise ValueError(f'Incomplete {job}: {len(rows)} rows')
 result=[]
 if kind=='HHOT' and rows[0]!=['MM','DD']+[f'{h:02}' for h in range(1,25)]: raise ValueError('Unexpected HHOT header')
 if kind=='HLT' and rows[0][:4]!=['Month','Date','Time','Height(m)']: raise ValueError('Unexpected HLT header')
 for row,(m,d) in zip(rows[1:],expected):
  if tuple(map(int,row[:2]))!=(m,d): raise ValueError(f'Missing/out-of-order day {job}')
  if kind=='HHOT':
   if len(row)!=26: raise ValueError(f'Missing hours {job}')
   values=[int((Decimal(v)*100).quantize(Decimal('1'),rounding=ROUND_HALF_UP)) for v in row[2:]]
   if not all(-200<=v<=600 for v in values): raise ValueError('Implausible height')
   result.append(values)
  else:
   events=[]
   for t,h in zip(row[2::2],row[3::2]):
    t,h=t.strip(),h.strip()
    if not t and not h: continue
    t=t.zfill(4)
    if not re.fullmatch(r'\d{4}',t) or (int(t[:2])>23 and t!='2400') or int(t[2:])>59 or not h: raise ValueError('Invalid HLT event')
    height=float(h)
    if not math.isfinite(height) or not -2<=height<=6: raise ValueError('Invalid HLT height')
    events.append([t,height])
   if not events: raise ValueError('Missing HLT events')
   result.append({'d':f'{m:02}{d:02}','e':events})
 if kind=='HLT':
  for i,day in enumerate(result):
   midnight=[e for e in day['e'] if e[0]=='2400']
   if midnight:
    if i+1==len(result): raise ValueError('HLT midnight extends beyond requested year')
    day['e']=[e for e in day['e'] if e[0]!='2400']
    result[i+1]['e']=[['0000',e[1]] for e in midnight]+result[i+1]['e']
 return job,result
jobs=[('HHOT',c,y) for y in YEARS for c in CODES]+[('HLT',c,y) for y in YEARS for c in ['CLK','KCT']]
with ThreadPoolExecutor(max_workers=4) as pool: results=dict(pool.map(fetch,jobs))
data=json.loads((ROOT/'lib/tide-data.json').read_text())
for app,official,name in [('CHK','CLK','chek_lap_kok'),('KCQ','KCT','kwai_chung')]:
 data['stations'][app]['name']=name
 data['stations'][app]['days']=results['HLT',official,2026]
 data['extraYears']['2027'][name]=results['HLT',official,2027]
 for meta in [data['stations'][app],next(s for s in data['stationList'] if s['code']==app)]:
  meta.update(name=name,estimated=False,officialStation=official)
  meta.pop('source',None)
data['attribution']=SOURCE
writes={ROOT/'lib/tide-data.json':json.dumps(data,ensure_ascii=False,separators=(',',':'))}
for y in YEARS:
 writes[ROOT/f'lib/tide-hourly-{y}.json']=json.dumps({'year':y,'unit':'cm','tz':'HKT','hours':'01-24','attribution':SOURCE,'officialCodes':{'CHK':'CLK','KCQ':'KCT'},'stations':{({'CLK':'CHK','KCT':'KCQ'}.get(c,c)):results['HHOT',c,y] for c in CODES}},ensure_ascii=False,separators=(',',':'))
p=ROOT/'index.html';html=p.read_text();html,n=re.subn(r'(<script id="tide-data-json"[^>]*>).*?(</script>)',lambda m:m[1]+writes[ROOT/'lib/tide-data.json']+m[2],html,flags=re.S)
if n!=1: raise ValueError('Missing/duplicate embedded event data')
writes[p]=html
# No files are touched until every network response and output has passed validation.
for p,s in writes.items():
 temp=p.with_suffix(p.suffix+'.tmp');temp.write_text(s);temp.replace(p)
print('Validated and wrote 2026/2027 HHOT (8 series/year), CLK/KCT HLT and embedded events')
