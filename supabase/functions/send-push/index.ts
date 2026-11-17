/** Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, PUSH_SEND_SECRET;
 * APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC=app.hkfishing.ios,
 * APNS_ENVIRONMENT=sandbox|production (TestFlight uses production);
 * VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT.
 * Future deployment: --no-verify-jwt, with mandatory x-push-secret authentication below.
 * No Firebase/FCM dependency; no deployment or scheduler is performed here.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.49.8';
import { importPKCS8, SignJWT } from 'npm:jose@5.10.0';
import webpush from 'npm:web-push@3.6.7';
const env = (key: string) => Deno.env.get(key) || '';
const response = (status: number, value: object) => new Response(JSON.stringify(value), {status, headers: {'content-type': 'application/json'}});
async function equalSecret(a: string, b: string) {
  if (!a || !b) return false;
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  const [x, y] = await Promise.all([digest(a), digest(b)]);
  return x.reduce((acc, n, i) => acc | (n ^ y[i]), 0) === 0;
}
type Device = {id: string; token: string; token_type: string};
type Job = {id: string; user_id: string; type: string; title: string; body: string; data: {lbType?: string}; claim_id: string; attempts: number; delivered_token_ids: string[]};
const checked = async (p: PromiseLike<{data: unknown; error: unknown}>) => { const r = await p; if (r.error) throw new Error('database operation failed'); return r.data; };
export function payload(job: Job) {
  const lbType = ['biggest', 'quantity', 'species'].includes(job.data?.lbType || '') ? job.data.lbType : 'biggest';
  return {title: job.title, body: job.body, data: {view: 'leaderboard', lbType, lbPeriod: 'all'}};
}
export function webEndpoint(endpoint: string) {
  const u = new URL(endpoint);
  const hosts = ['fcm.googleapis.com', 'updates.push.services.mozilla.com', 'push.services.mozilla.com', 'web.push.apple.com'];
  // Subscriptions are user-controlled: forbid arbitrary HTTP endpoints and redirects (SSRF).
  if (u.protocol !== 'https:' || u.username || u.password || u.port || !(hosts.includes(u.hostname) || u.hostname.endsWith('.notify.windows.com'))) throw new Error('unsupported push provider');
  return u;
}
let apnsAuth: {token: string; issued: number; keyId: string} | undefined;
async function apnsBearer() {
  const issued = Math.floor(Date.now()/1000), keyId = env('APNS_KEY_ID');
  if (apnsAuth && apnsAuth.keyId === keyId && issued-apnsAuth.issued < 3000) return apnsAuth.token;
  const key = await importPKCS8(env('APNS_KEY_P8').replace(/\\n/g, '\n'), 'ES256');
  const token = await new SignJWT({}).setProtectedHeader({alg: 'ES256', kid: keyId}).setIssuer(env('APNS_TEAM_ID')).setIssuedAt(issued).sign(key);
  apnsAuth = {token, issued, keyId};
  return token;
}
export async function send(device: Device, content: ReturnType<typeof payload>): Promise<'ok' | 'invalid' | 'retry'> {
  if (device.token_type === 'apns') {
    if (!/^[a-f0-9]{64,200}$/i.test(device.token)) return 'invalid';
    const jwt = await apnsBearer();
    const environment = env('APNS_ENVIRONMENT');
    if (!['sandbox', 'production'].includes(environment) || env('APNS_TOPIC') !== 'app.hkfishing.ios') throw new Error('APNs configuration incomplete');
    const host = environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    const client = Deno.createHttpClient({http2: true, http1: false});
    try {
      const result = await fetch(`https://${host}/3/device/${device.token}`, {method: 'POST', client,
        headers: {authorization: `bearer ${jwt}`, 'apns-topic': env('APNS_TOPIC'), 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': String(Math.floor(Date.now()/1000) + 3600)},
        body: JSON.stringify({aps: {alert: {title: content.title, body: content.body}, sound: 'default'}, ...content.data}), signal: AbortSignal.timeout(15000)});
      const reason = await result.json().catch(() => ({}));
      if (result.ok) return 'ok';
      if (result.status === 410 || ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'].includes(reason.reason)) return 'invalid';
      return 'retry';
    } finally { client.close(); }
  }
  if (device.token_type === 'webpush') {
    let sub;
    try { sub = JSON.parse(device.token); webEndpoint(sub.endpoint); if (!sub.keys?.p256dh || !sub.keys?.auth) return 'invalid'; } catch (_) { return 'invalid'; }
    const details = webpush.generateRequestDetails(sub, JSON.stringify(content), {TTL: 3600,
      vapidDetails: {subject: env('VAPID_SUBJECT'), publicKey: env('VAPID_PUBLIC_KEY'), privateKey: env('VAPID_PRIVATE_KEY')}});
    const result = await fetch(details.endpoint, {method: 'POST', headers: details.headers, body: details.body, redirect: 'error', signal: AbortSignal.timeout(15000)});
    await result.body?.cancel();
    return result.ok ? 'ok' : [404, 410].includes(result.status) ? 'invalid' : 'retry';
  }
  return 'invalid';
}
export async function handler(request: Request): Promise<Response> {
  if (request.method !== 'POST') return response(405, {error: 'POST required'});
  if (!await equalSecret(request.headers.get('x-push-secret') || '', env('PUSH_SEND_SECRET'))) return response(401, {error: 'unauthorized'});
  try {
    const client = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {auth: {persistSession: false, autoRefreshToken: false}});
    const jobs = await checked(client.rpc('push_claim_outbox', {p_limit: 20})) as Job[];
    let completed = 0;
    for (const job of jobs) {
      const delivered = new Set(job.delivered_token_ids || []);
      const devices = await checked(client.from('device_tokens').select('id,token,token_type').eq('user_id', job.user_id).eq('enabled', true)) as Device[];
      let retry = false;
      for (const device of devices) {
        if (delivered.has(device.id)) continue;
        const allowed = await checked(client.rpc('push_delivery_allowed', {p_job: job.id, p_claim: job.claim_id, p_device: device.id}));
        if (!allowed) continue; // Authorization refusal is skipped, not a delivery failure.
        try {
          const result = await send(device, payload(job));
          if (result === 'invalid') await checked(client.from('device_tokens').update({enabled: false}).eq('id', device.id).eq('user_id', job.user_id));
          else if (result === 'retry') retry = true;
          else {
            delivered.add(device.id);
            await checked(client.from('notification_outbox').update({delivered_token_ids: [...delivered]}).eq('id', job.id).eq('claim_id', job.claim_id).eq('status', 'sending'));
          }
        } catch (_) { retry = true; } // Never log provider bodies, token values, keys or subscriptions.
      }
      const status = retry ? (job.attempts >= 5 ? 'failed' : 'pending') : delivered.size ? 'sent' : 'skipped';
      await checked(client.from('notification_outbox').update({status, sent_at: delivered.size ? new Date().toISOString() : null,
        send_after: new Date(Date.now() + Math.min(3600, 60 * 2 ** job.attempts) * 1000).toISOString()}).eq('id', job.id).eq('claim_id', job.claim_id).eq('status', 'sending'));
      completed++;
    }
    return response(200, {claimed: jobs.length, completed});
  } catch (_) { return response(500, {error: 'push batch failed'}); }
}
if (import.meta.main) Deno.serve(handler);
