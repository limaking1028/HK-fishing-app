// Offline tests only: generated ephemeral keys and fake provider responses; nothing is logged.
import { handler, payload, webEndpoint, send } from './index.ts';
import { strict as assert } from 'node:assert';
import webpush from 'npm:web-push@3.6.7';
import { exportPKCS8, generateKeyPair } from 'npm:jose@5.10.0';
Deno.test('internal endpoint rejects unauthenticated and non-POST calls', async () => {
  assert.equal((await handler(new Request('https://local.invalid', {method: 'GET'}))).status, 405);
  assert.equal((await handler(new Request('https://local.invalid', {method: 'POST'}))).status, 401);
});
Deno.test('payload navigation is allowlisted and user endpoints cannot target arbitrary servers', () => {
  const p = payload({id: 'fixture', user_id: 'fixture', type: 'record_broken', title: '釣港', body: '恭喜！你登上重量王者（全期）第 1 名',
    data: {lbType: 'https://malicious.invalid'}, claim_id: 'fixture', attempts: 1, delivered_token_ids: []});
  assert.deepEqual(p.data, {view: 'leaderboard', lbType: 'biggest', lbPeriod: 'all'});
  for (const u of ['http://fcm.googleapis.com/send/x', 'https://127.0.0.1/x', 'https://fcm.googleapis.com.attacker.invalid/x', 'https://user:pass@fcm.googleapis.com/x', 'https://fcm.googleapis.com:444/x']) assert.throws(() => webEndpoint(u));
  assert.equal(webEndpoint('https://web.push.apple.com/Qfixture').hostname, 'web.push.apple.com');
});
Deno.test('Web Push encrypts locally, 410 invalidates and transient errors retry', async () => {
  const original = globalThis.fetch;
  const keys = webpush.generateVAPIDKeys();
  Deno.env.set('VAPID_PUBLIC_KEY', keys.publicKey); Deno.env.set('VAPID_PRIVATE_KEY', keys.privateKey); Deno.env.set('VAPID_SUBJECT', 'mailto:fixture@example.invalid');
  const pair = await crypto.subtle.generateKey({name: 'ECDH', namedCurve: 'P-256'}, true, ['deriveBits']);
  const b64 = (data: Uint8Array) => btoa(String.fromCharCode(...data)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
  const device = {id: 'fixture', token_type: 'webpush', token: JSON.stringify({endpoint: 'https://fcm.googleapis.com/fake-fixture', keys: {p256dh: b64(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))), auth: b64(crypto.getRandomValues(new Uint8Array(16)))}})};
  try {
    for (const [status, expected] of [[201,'ok'],[410,'invalid'],[503,'retry']] as const) {
      globalThis.fetch = async (_input, init) => { assert(init?.body); assert.equal(init?.redirect,'error'); return new Response('',{status}); };
      assert.equal(await send(device, {title:'釣港',body:'測試',data:{view:'leaderboard',lbType:'biggest',lbPeriod:'all'}}), expected);
    }
  } finally { globalThis.fetch = original; for (const key of ['VAPID_PUBLIC_KEY','VAPID_PRIVATE_KEY','VAPID_SUBJECT']) Deno.env.delete(key); }
});
Deno.test('APNs uses HTTP/2 client and correct topic, invalid token is disabled', async () => {
  const original = globalThis.fetch;
  const {privateKey} = await generateKeyPair('ES256', {extractable: true});
  Deno.env.set('APNS_KEY_P8', await exportPKCS8(privateKey)); Deno.env.set('APNS_KEY_ID','FIXTURE'); Deno.env.set('APNS_TEAM_ID','FIXTURE'); Deno.env.set('APNS_TOPIC','app.hkfishing.ios'); Deno.env.set('APNS_ENVIRONMENT','production');
  try {
    globalThis.fetch = async (input, init) => {
      assert(String(input).startsWith('https://api.push.apple.com/3/device/')); assert((init as RequestInit & {client?: Deno.HttpClient})?.client);
      assert.equal((init?.headers as Record<string,string>)['apns-topic'], 'app.hkfishing.ios');
      return new Response(JSON.stringify({reason: 'Unregistered'}), {status: 410});
    };
    assert.equal(await send({id:'fixture',token_type:'apns',token:'a'.repeat(64)}, {title:'釣港',body:'測試',data:{view:'leaderboard',lbType:'biggest',lbPeriod:'all'}}),'invalid');
  } finally {globalThis.fetch=original;for(const key of ['APNS_KEY_P8','APNS_KEY_ID','APNS_TEAM_ID','APNS_TOPIC','APNS_ENVIRONMENT']) Deno.env.delete(key);}
});
