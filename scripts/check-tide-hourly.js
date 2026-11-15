// Local-only schema, attribution, midnight/year boundary and shared-height regression checks.
'use strict';
process.env.TZ='Asia/Hong_Kong';
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const root=path.join(__dirname,'..');
const data=JSON.parse(fs.readFileSync(path.join(root,'lib/tide-data.json')));
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
assert.deepStrictEqual(JSON.parse(html.match(/<script id="tide-data-json"[^>]*>([\s\S]*?)<\/script>/)[1]),data);
const years={};
for(const year of [2026,2027]){
 const raw=fs.readFileSync(path.join(root,`lib/tide-hourly-${year}.json`),'utf8'), d=years[year]=JSON.parse(raw);
 assert.equal(d.year,year);assert.equal(d.unit,'cm');assert.equal(d.tz,'HKT');assert.equal(d.hours,'01-24');
 assert(d.attribution.includes('知識產權擁有人'));assert.deepStrictEqual(Object.keys(d.stations).sort(),['QUB','TPK','CCH','TAO','SPW','TBT','CHK','KCQ'].sort());
 for(const rows of Object.values(d.stations)){
  assert.equal(rows.length,365);for(const row of rows){assert.equal(row.length,24);assert(row.every(v=>Number.isInteger(v)&&v>=-200&&v<=600));}
 }
 console.log(year,Buffer.byteLength(raw),'bytes; 8 × 365 × 24 integer cm PASS');
}
for(const [code,name] of [['CHK','chek_lap_kok'],['KCQ','kwai_chung']]){
 const m=data.stationList.find(s=>s.code===code);assert.equal(m.estimated,false);assert(!m.source);assert.equal(data.stations[code].name,name);
 assert.equal(data.stations[code].days.length,365);assert.equal(data.extraYears['2027'][name].length,365);
}
for(const [c,source] of [['SAI','QUB'],['LAM','CCH'],['TCT','TAO'],['PEN','CCH']]){
 const m=data.stationList.find(s=>s.code===c);assert(m.estimated);assert.equal(m.source,source);assert(!years[2026].stations[c]);
}
const context={window:{dispatchEvent(){}},document:{getElementById:()=>({textContent:JSON.stringify(data)})},console,Event:class{},fetch:async url=>({ok:true,json:async()=>JSON.parse(fs.readFileSync(path.join(root,url)))})};vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(root,'lib/tides.js'),'utf8'),context);
(async()=>{
 const lib=context.window.tidesLib;await lib.ready;
 for(const year of [2026,2027])for(const [code,rows] of Object.entries(years[year].stations)){
  for(let day=0;day<365;day+=13)for(let hour=1;hour<=24;hour++){
   const ms=new Date(year,0,day+1,hour).getTime();assert(Math.abs(lib.getTideHeight(code,ms)-rows[day][hour-1]/100)<1e-9);
  }
 }
 const midnight=new Date(2027,0,1).getTime();
 assert.equal(lib.getTideHeight('QUB',midnight),years[2026].stations.QUB[364][23]/100);
 assert(Math.abs(lib.getTideHeight('QUB',midnight+1800000)-(years[2026].stations.QUB[364][23]+years[2027].stations.QUB[0][0])/200)<1e-9);
 assert.equal(lib.getTideHeight('SAI',midnight),lib.getTideHeight('QUB',midnight));
 assert.equal(lib.getCurrentTide('CHK',midnight).source,'hourly');assert.equal(lib.getCurrentTide('KCQ',midnight).estimated,false);
 assert(lib.isDataValid(midnight));assert(!lib.isDataValid(new Date(2028,0,1).getTime()));assert.equal(lib.getDataYear(),2027);
 for(const code of ['SPW','TBT']){
  const flat=years[2026].stations[code].flat();assert(Math.min(...flat)<0);
  if(code==='TBT')assert(Math.max(...flat)>300);
 }
 // Each official high/low should be reasonably close to the neighbouring hourly samples.
 for(const code of Object.keys(years[2026].stations))for(const day of data.stations[code].days){
  for(const [time,h] of day.e){
   const ms=new Date(2026,+day.d.slice(0,2)-1,+day.d.slice(2),+time.slice(0,2),+time.slice(2)).getTime();
   const actual=lib.getTideHeight(code,ms);assert(Math.abs(actual-h)<0.6,`${code} ${day.d} ${time}: ${actual} / ${h}`);
  }
 }
 const svg=lib.curveSvg([{ms:0,height:-0.12},{ms:3600000,height:3.26}],300,130);
 assert(svg.includes('-0.3 米') && svg.includes('3.5 米'));
 console.log('PASS metadata, event/embed parity, all-station hourly samples, midnight/half-hour/year boundary, estimated mapping, negative/>3m and event sanity');
})().catch(e=>{console.error(e);process.exitCode=1;});
