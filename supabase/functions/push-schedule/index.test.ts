// Offline only: every fetch is mocked, environment secrets are generated per test.
import {strict as assert} from 'node:assert';
import {handler,hkDay,weatherGood,windMax,tideCandidates,weekendForecast,type TideFile} from './index.ts';
const day = {forecastDate:'20261117',PSR:'低',forecastWind:'東風3至4級',ForecastIcon:50,forecastWeather:'大致天晴。稍後有雲。'};
const source:TideFile = {year:2026,stationList:[{code:'QUB',name:'quarry_bay',name_zh:'鰂魚涌',lat:22.2885,lng:114.213}],spotMap:[],
 stations:{QUB:{days:[{d:'1116',e:[['2300',0.5]]},{d:'1117',e:[['0200',0.3],['0810',1.8],['1400',0.6],['2100',1.6]]},{d:'1118',e:[['0300',0.2]]}]}},extraYears:{}};
const clock = new Date('2026-11-16T12:00:00Z');
Deno.test('good weather and large tide: HK tomorrow uses explicit UTC+8, peak minus two hours',()=>{
 const result=tideCandidates(source,[day],{},clock);
 assert.equal(result.day,'2026-11-17');assert.equal(result.stations[0].good,true);
 assert.equal(result.stations[0].start,'06:10');assert.equal(result.stations[0].end,'08:10');
 assert.equal(hkDay(new Date('2026-11-16T16:01:00Z')),'2026-11-17');
 assert.equal(windMax('東風三至四級，離岸六級'),6);
});
Deno.test('PSR medium, strong wind, rain icon, severe warnings, small range and early peak all reject',()=>{
 for(const forecast of [{...day,PSR:'中'},{...day,forecastWind:'東風6級'},{...day,ForecastIcon:63}]) assert.equal(weatherGood(forecast,{}),false);
 for(const code of ['TC8NE','TC9','TC10','WRAINR','WRAINB'])assert.equal(weatherGood(day,{alert:{code}}),false);
 assert.equal(weatherGood(day,{alert:{code:'TC8NE',actionCode:'CANCEL'}}),true);
 const small=structuredClone(source);small.stations.QUB.days[1].e=[['0200',0.9],['0810',1.5],['1400',1],['2100',1.4]];
 assert.equal(tideCandidates(small,[day],{},clock).stations[0].good,false);
 const boundary=structuredClone(source);boundary.stations.QUB.days[1].e=[['0200',0.4],['0810',1.4],['1400',0.6],['2100',1.2]];assert.equal(tideCandidates(boundary,[day],{},clock).stations[0].good,true);
 const early=structuredClone(source);early.stations.QUB.days[1].e=[['0000',0.3],['0400',1.8],['1200',0.5],['2300',0.2]];
 assert.equal(tideCandidates(early,[day],{},clock).stations[0].good,false);
 const dawn=structuredClone(source);dawn.stations.QUB.days[1].e[1][0]='0610';
 assert.equal(tideCandidates(dawn,[day],{},clock).stations[0].start,'05:00');
});
Deno.test('Dec 31 -> Jan 1 reads extraYears by source station name',()=>{
 const file=structuredClone(source);file.stations.QUB.days=[{d:'1231',e:[['2300',0.4]]}];
 file.extraYears={'2027':{quarry_bay:[{d:'0101',e:[['0200',0.3],['0810',1.8],['1400',0.5],['2100',1.6]]}]}};
 const result=tideCandidates(file,[{...day,forecastDate:'20270101'}],{},new Date('2026-12-31T12:00:00Z'));
 assert.equal(result.day,'2027-01-01');assert.equal(result.stations[0].good,true);assert.equal(result.stations[0].start,'06:10');
});
Deno.test('either weekend day may qualify; warnings override both',()=>{
 const forecasts=[{...day,forecastDate:'20261121',PSR:'中'},{...day,forecastDate:'20261122'}];
 assert.equal(weekendForecast(forecasts,{},new Date('2026-11-20T11:20:00Z')).good,true);
 assert.equal(weekendForecast(forecasts,{alert:{code:'WRAINB'}},new Date('2026-11-20T11:20:00Z')).good,false);
});
Deno.test('missing secret is 401; HKO/source failure quietly skips without any database request',async()=>{
 assert.equal((await handler(new Request('https://fixture.invalid/?job=tide',{method:'POST'}))).status,401);
 const original=globalThis.fetch,previous=Deno.env.get('PUSH_SEND_SECRET'),secret=crypto.randomUUID();
 Deno.env.set('PUSH_SEND_SECRET',secret);let calls=0;
 try {
  globalThis.fetch=async()=>{calls++;return new Response('',{status:503})};
  const r=await handler(new Request('https://fixture.invalid/?job=tide',{method:'POST',headers:{'x-push-secret':secret}}),clock);
  assert.equal(r.status,200);assert.deepEqual(await r.json(),{skipped:'source'});assert.equal(calls,2);
 }finally{globalThis.fetch=original;previous===undefined?Deno.env.delete('PUSH_SEND_SECRET'):Deno.env.set('PUSH_SEND_SECRET',previous)}
});
Deno.test('tide handler passes only public station candidates and map to server RPC',async()=>{
 const original=globalThis.fetch,names=['PUSH_SEND_SECRET','SUPABASE_URL','SUPABASE_SERVICE_ROLE_KEY'],previous=names.map(n=>Deno.env.get(n));
 const secret=crypto.randomUUID();Deno.env.set(names[0],secret);Deno.env.set(names[1],'https://fixture.invalid');Deno.env.set(names[2],crypto.randomUUID());
 let requestData:Record<string,unknown>|undefined;
 try {
  globalThis.fetch=async(input,init)=>{
   const url=String(input);
   let data:unknown;
   if(url.includes('dataType=fnd'))data={weatherForecast:[day]};
   else if(url.includes('dataType=warnsum'))data={};
   else if(url.includes('tide-data.json'))data=source;
   else if(url.endsWith('/rpc/push_tide_candidates_enqueue')){requestData=JSON.parse(String(init?.body));data=1}
   else throw Error('Unexpected request');
   return new Response(JSON.stringify(data),{headers:{'content-type':'application/json'}});
  };
  const r=await handler(new Request('https://fixture.invalid/?job=tide',{method:'POST',headers:{'x-push-secret':secret}}),clock);
  assert.equal(r.status,200);assert.deepEqual(await r.json(),{queued:1});assert.equal(requestData?.p_day,'2026-11-17');
  assert.equal((requestData?.p_stations as Array<{good:boolean}>)[0].good,true);
 } finally {globalThis.fetch=original;names.forEach((n,i)=>previous[i]===undefined?Deno.env.delete(n):Deno.env.set(n,previous[i]!))}
});
