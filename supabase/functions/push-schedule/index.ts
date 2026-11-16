/** Secrets (names only): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, PUSH_SEND_SECRET.
 * Optional public source override: TIDE_DATA_URL (not a credential).
 * Future deployment uses --no-verify-jwt; x-push-secret remains mandatory.
 * This file never deploys, schedules cron or reads user coordinates/tokens.
 */
import {createClient} from 'npm:@supabase/supabase-js@2.49.8';
const TIDE_SOURCE = 'https://limaking1028.github.io/HK-fishing-app/lib/tide-data.json';
const FORECAST_SOURCE = 'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=fnd&lang=tc';
const WARNING_SOURCE = 'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=warnsum&lang=tc';
const CODES = ['QUB','TPK','CCH','TAO','SPW','TBT','SAI','KCQ','LAM','CHK','TCT','PEN'];
const env = (name: string) => Deno.env.get(name) || '';
const reply = (status: number, data: object) => new Response(JSON.stringify(data), {status,headers:{'content-type':'application/json'}});
export async function equalSecret(a: string,b: string) {
  if (!a || !b) return false;
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
  const [x,y] = await Promise.all([digest(a),digest(b)]);
  return x.reduce((n,v,i)=>n | (v^y[i]),0) === 0;
}
type Forecast = {forecastDate: string; PSR: string; forecastWind: string; ForecastIcon: number; forecastWeather: string};
type Warnings = Record<string,{code?: string; actionCode?: string}>;
type Station = {code:string;name:string;name_zh:string;lat:number;lng:number;source?:string};
type TideDay = {d:string;e:Array<[string,number]>};
export type TideFile = {year:number;stationList:Station[];spotMap:unknown[];stations:Record<string,{days:TideDay[]}>;extraYears?:Record<string,Record<string,TideDay[]>>};
export const hkDay = (now: Date) => new Date(now.getTime()+8*3600000).toISOString().slice(0,10);
const addDay = (day:string,n:number) => new Date(Date.parse(day+'T00:00:00+08:00')+n*86400000+8*3600000).toISOString().slice(0,10);
const hhmm = (ms:number) => new Date(ms+8*3600000).toISOString().slice(11,16);
export function windMax(wind: string) {
  const digits:Record<string,string> = {'一':'1','二':'2','三':'3','四':'4','五':'5','六':'6','七':'7','八':'8','九':'9','十':'10'};
  const normalized = wind.replace(/[一二三四五六七八九十]/g,c=>digits[c]).replace(/[０-９]/g,c=>String(c.charCodeAt(0)-0xff10));
  const matches = [...normalized.matchAll(/(\d+)(?:\s*(?:至|到|–|-|－)\s*(\d+))?\s*級/g)];
  return matches.length ? Math.max(...matches.flatMap(m=>[Number(m[1]),Number(m[2]||m[1])])) : Infinity;
}
export function dangerous(warnings: Warnings) {
  return Object.values(warnings).some(w=>w && w.actionCode !== 'CANCEL' && (/^TC(?:8|9|10)/.test(w.code||'') || ['WRAINR','WRAINB'].includes(w.code||'')));
}
export function weatherGood(f: Forecast,warnings: Warnings) {
  return ['低','中低'].includes(f.PSR?.trim()) && windMax(f.forecastWind||'')<=5
    && Number.isFinite(Number(f.ForecastIcon)) && !(Number(f.ForecastIcon)>=62 && Number(f.ForecastIcon)<=65) && !dangerous(warnings);
}
export function weatherPhrase(f: Forecast) {
  const first = Array.from((f.forecastWeather||'').split(/[。；.!?]/)[0].trim()).slice(0,12).join('');
  const wind = (f.forecastWind||'').split(/[。，；]/)[0].replace(/\s+/g,'').slice(0,24);
  return [first,wind].filter(Boolean).join('、');
}
function forecastFor(forecasts: Forecast[],day:string) {
  const f = forecasts.find(f=>f.forecastDate===day.replaceAll('-',''));
  if (!f || !f.PSR || !f.forecastWind || !f.forecastWeather || f.ForecastIcon == null) throw new Error('Source unavailable');
  return f;
}
function events(file:TideFile,meta:Station,day:string) {
  const source = file.stationList.find(s=>s.code===(meta.source||meta.code));
  if (!source) return [];
  const year = day.slice(0,4);
  const days = Number(year)===Number(file.year) ? file.stations[source.code]?.days : file.extraYears?.[year]?.[source.name];
  const match = days?.find(d=>d.d===day.slice(5).replace('-',''));
  return (match?.e||[]).flatMap(([time,height])=>{
    if (!/^\d{4}$/.test(time) || Number(time.slice(0,2))>23 || Number(time.slice(2))>59 || !Number.isFinite(Number(height))) return [];
    return [{ms:Date.parse(day+'T'+time.slice(0,2)+':'+time.slice(2)+':00+08:00'),height:Number(height)}];
  }).sort((a,b)=>a.ms-b.ms);
}
export function tideCandidates(file:TideFile,forecasts:Forecast[],warnings:Warnings,now:Date) {
  const day = addDay(hkDay(now),1), f = forecastFor(forecasts,day);
  if (!Array.isArray(file.stationList) || !Array.isArray(file.spotMap) || !file.stations) throw new Error('Source unavailable');
  if (!file.spotMap.every(entry=>{
    if (!entry || typeof entry!=='object') return false;
    const m=entry as {p?:unknown;s?:unknown};
    return Array.isArray(m.p) && m.p.every(p=>typeof p==='string' && p.length>0) && typeof m.s==='string' && CODES.includes(m.s);
  })) throw new Error('Source unavailable');
  const safe = weatherGood(f,warnings), phrase = weatherPhrase(f);
  let available = 0;
  const stations = file.stationList.filter(s=>CODES.includes(s.code)).map(meta=>{
    if (!Number.isFinite(meta.lat) || !Number.isFinite(meta.lng)) throw new Error('Source unavailable');
    const current = events(file,meta,day);
    if (current.length>=2) available++;
    const all = [...events(file,meta,addDay(day,-1)),...current,...events(file,meta,addDay(day,1))];
    const range = current.length ? Math.max(...current.map(e=>e.height))-Math.min(...current.map(e=>e.height)) : 0;
    const lower=Date.parse(day+'T06:00:00+08:00'),upper=Date.parse(day+'T19:00:00+08:00');
    const high = all.find((e,i)=>i>0 && i<all.length-1 && e.ms>=lower && e.ms<=upper && e.height>all[i-1].height && e.height>all[i+1].height);
    const good = !!(safe && range>=1-1e-9 && high);
    return {code:meta.code,name_zh:meta.name_zh,lat:meta.lat,lng:meta.lng,good,phrase,
      start:good ? hhmm(Math.max(high!.ms-2*3600000,Date.parse(day+'T05:00:00+08:00'))) : '',end:good ? hhmm(high!.ms) : ''};
  });
  if (!available) throw new Error('Source unavailable');
  return {day,stations,spotMap:file.spotMap};
}
export function weekendForecast(forecasts:Forecast[],warnings:Warnings,now:Date) {
  const today=hkDay(now), weekday=new Date(today+'T00:00:00Z').getUTCDay();
  const saturday=addDay(today,(6-weekday+7)%7);
  const days=[forecastFor(forecasts,saturday),forecastFor(forecasts,addDay(saturday,1))];
  const good=days.find(f=>weatherGood(f,warnings));
  return {good:!!good,phrase:good ? weatherPhrase(good) : ''};
}
async function getJson(url:string) {
  const parsed=new URL(url);
  if (parsed.protocol!=='https:' || parsed.username || parsed.password) throw new Error('Source unavailable');
  const response=await fetch(parsed,{signal:AbortSignal.timeout(12000),redirect:'error'});
  if (!response.ok) throw new Error('Source unavailable');
  return await response.json();
}
export async function handler(request:Request,now=new Date()):Promise<Response> {
  if (request.method!=='POST') return reply(405,{error:'POST required'});
  if (!await equalSecret(request.headers.get('x-push-secret')||'',env('PUSH_SEND_SECRET'))) return reply(401,{error:'unauthorized'});
  const job=new URL(request.url).searchParams.get('job');
  if (!['tide','inactive'].includes(job||'')) return reply(400,{error:'unknown job'});
  let rpc:string, args:Record<string,unknown>;
  try {
    const [f,w]=await Promise.all([getJson(FORECAST_SOURCE),getJson(WARNING_SOURCE)]);
    if (!Array.isArray(f.weatherForecast) || !w || Array.isArray(w) || typeof w!=='object') throw new Error('Source unavailable');
    if (job==='tide') {
      const data=tideCandidates(await getJson(env('TIDE_DATA_URL')||TIDE_SOURCE),f.weatherForecast,w,now);
      rpc='push_tide_candidates_enqueue'; args={p_day:data.day,p_stations:data.stations,p_spot_map:data.spotMap};
    } else {
      const data=weekendForecast(f.weatherForecast,w,now);
      rpc='push_inactive_enqueue';args={p_weekend_good:data.good,p_phrase:data.phrase};
    }
  } catch (_) { return reply(200,{skipped:'source'}); }
  try {
    const client=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
    const result=await client.rpc(rpc,args);
    if (result.error) return reply(500,{error:'schedule failed'});
    return reply(200,{queued:result.data});
  } catch (_) { return reply(500,{error:'schedule failed'}); }
}
if (import.meta.main) Deno.serve(request=>handler(request));
