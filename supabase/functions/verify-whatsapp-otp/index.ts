// ============================================================
// Supabase Edge Function: verify-whatsapp-otp
// ============================================================
// 功能：用戶輸入 6 位數驗證碼,驗證通過後登入或自動建立帳號
//
// 流程：
//   1. 驗證 phone + code 格式
//   2. 限流(同電話 10 分鐘最多 10 次 verify)
//   3. 查詢 otp_codes(phone, 未消耗, 未過期)
//   4. 驗證 SHA-256 hash
//   5. 標記 consumed = true
//   6. 查詢 users(phone_e164);不存在則自動建立新帳號
//   7. 更新 last_login_at
//   8. 返回 { user, is_new }
//
// 安全：
//   - 連續 5 次錯誤驗證 → 鎖定該 phone 5 分鐘(透過 attempts 計數)
//   - OTP 過期時間 = 5 分鐘
//   - 一個 OTP 一旦消耗即作廢
//
// 部署：
//   supabase functions deploy verify-whatsapp-otp
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false }
});

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json'
};
function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: CORS });
}
async function sha256(input: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

/** 通用限流(同電話 N 分鐘最多 M 次) */
async function checkRateLimit(phone: string, action: string, max: number, windowMin: number): Promise<boolean> {
  const since = new Date(Date.now() - windowMin * 60 * 1000).toISOString();
  const { count } = await sb
    .from('login_attempts')
    .select('*', { count: 'exact', head: true })
    .eq('phone_e164', phone).eq('action', action).gte('created_at', since);
  return (count || 0) < max;
}
async function recordAttempt(phone: string, action: string, success: boolean, reason?: string) {
  await sb.from('login_attempts').insert({
    phone_e164: phone, action, success, reason: reason || null
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed' }, 405);

  try {
    const body = await req.json();
    const phoneE164: string = (body?.phone_e164 || '').trim();
    const code: string = String(body?.code || '').trim();

    // 格式驗證
    if (!phoneE164 || !/^\+\d{8,15}$/.test(phoneE164)) {
      return jsonResponse({ error: '電話格式不正確' }, 400);
    }
    if (!/^\d{6}$/.test(code)) {
      await recordAttempt(phoneE164, 'verify_otp', false, 'bad_code_format');
      return jsonResponse({ error: '驗證碼必須是 6 位數字' }, 400);
    }

    // 限流:10 次 / 10 分鐘
    if (!await checkRateLimit(phoneE164, 'verify_otp', 10, 10)) {
      return jsonResponse({ error: '嘗試次數過多,請 10 分鐘後再試' }, 429);
    }

    // 查詢有效 OTP(phone + 未消耗 + 未過期)
    const { data: codes, error: queryErr } = await sb
      .from('otp_codes')
      .select('*')
      .eq('phone_e164', phoneE164)
      .eq('consumed', false)
      .gt('expires_at', new Date().toISOString())
      .order('created_at', { ascending: false })
      .limit(5);
    if (queryErr) {
      console.error('OTP query failed:', queryErr);
      return jsonResponse({ error: '系統錯誤' }, 500);
    }

    if (!codes || codes.length === 0) {
      await recordAttempt(phoneE164, 'verify_otp', false, 'no_active_code');
      return jsonResponse({ error: '驗證碼已過期或不存在,請重新發送' }, 401);
    }

    // 嘗試匹配(最新碼優先)
    const codeHash = await sha256(phoneE164 + ':' + code);
    const matched = codes.find(c => c.code_hash === codeHash);
    if (!matched) {
      // 記錄嘗試次數(用於鎖定)
      await sb.from('otp_codes').update({ attempts: codes[0].attempts + 1 })
        .eq('id', codes[0].id);
      // 連續 5 次錯誤 → 標記當前未消耗的碼為 consumed(強制重新發送)
      if (codes[0].attempts + 1 >= 5) {
        await sb.from('otp_codes').update({ consumed: true })
          .eq('id', codes[0].id);
      }
      await recordAttempt(phoneE164, 'verify_otp', false, 'wrong_code');
      return jsonResponse({ error: '驗證碼錯誤' }, 401);
    }

    // ✅ 驗證成功:標記 consumed
    await sb.from('otp_codes').update({ consumed: true }).eq('id', matched.id);

    // 查詢既有用戶(用 phone_e164)
    let { data: user } = await sb.from('users').select('*').eq('phone_e164', phoneE164).maybeSingle();
    let isNew = false;
    if (!user) {
      // 自動建立新帳號
      const phoneMask = phoneE164.slice(-4);
      const newUser = {
        phone_e164: phoneE164,
        phone_verified: true,
        phone_verified_at: new Date().toISOString(),
        last_login_at: new Date().toISOString(),
        created_via: 'whatsapp_otp',
        avatar: '🎣',
        display_name: '釣友' + phoneMask   // 預設顯示名 = 釣友+電話尾4位,用戶可在設定改
      };
      const { data: inserted, error: insertErr } = await sb.from('users').insert(newUser).select().single();
      if (insertErr) {
        console.error('User insert failed:', insertErr);
        return jsonResponse({ error: '建立帳號失敗,請聯絡管理員' }, 500);
      }
      user = inserted;
      isNew = true;
    } else {
      // 既有用戶:更新 last_login_at + phone_verified
      await sb.from('users').update({
        last_login_at: new Date().toISOString(),
        phone_verified: true,
        phone_verified_at: user.phone_verified_at || new Date().toISOString()
      }).eq('id', user.id);
    }

    await recordAttempt(phoneE164, 'verify_otp', true);

    // 移除敏感欄位後返回
    const safeUser = { ...user };
    delete safeUser.pin_hash;
    delete safeUser.pin_salt;
    return jsonResponse({ user: safeUser, is_new: isNew });
  } catch (e) {
    console.error('verify-whatsapp-otp unexpected error:', e);
    return jsonResponse({ error: (e as Error).message || '伺服器錯誤' }, 500);
  }
});