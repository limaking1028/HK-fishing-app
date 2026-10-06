// ============================================================
// Supabase Edge Function: send-whatsapp-otp
// ============================================================
// 功能：用戶輸入電話後,生成 6 位數驗證碼並通過 WhatsApp Cloud API 發送
//
// 流程：
//   1. 驗證電話格式(E.164)
//   2. 限流檢查(同電話 10 分鐘內最多 5 次 send_otp)
//   3. 隨機生成 6 位數字 OTP
//   4. 計算 SHA-256 hash → 寫入 otp_codes 表
//   5. 通過 Meta WhatsApp Cloud API 發送模板訊息
//   6. 返回 { ok: true, expires_in: 300 }
//
// 部署：
//   supabase functions deploy send-whatsapp-otp
//   supabase secrets set WHATSAPP_ACCESS_TOKEN=xxx WHATSAPP_PHONE_ID=yyy
//
// 環境變數(必設):
//   - WHATSAPP_ACCESS_TOKEN  Meta 永久系統用戶 token
//   - WHATSAPP_PHONE_ID      WhatsApp Business 電話號碼 ID
//   - WHATSAPP_TEMPLATE_NAME 訊息模板名稱(預設 'hk_fishing_otp')
//   - WHATSAPP_LANG_CODE    模板語言(預設 'zh_HK')
//   - SUPABASE_URL         (由 Supabase 自動注入)
//   - SUPABASE_SERVICE_ROLE_KEY (由 Supabase 自動注入)
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

// 環境變數
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WHATSAPP_TOKEN = Deno.env.get('WHATSAPP_ACCESS_TOKEN')!;
const PHONE_ID = Deno.env.get('WHATSAPP_PHONE_ID')!;
const TEMPLATE_NAME = Deno.env.get('WHATSAPP_TEMPLATE_NAME') || 'hk_fishing_otp';
const LANG_CODE = Deno.env.get('WHATSAPP_LANG_CODE') || 'zh_HK';
const API_VERSION = Deno.env.get('WHATSAPP_API_VERSION') || 'v20.0';

const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false }
});

// ============================================================
// 工具函數
// ============================================================

/** 生成 6 位數字 OTP(均勻分布,無 modulo bias) */
function generateOtp(): string {
  const buf = new Uint8Array(4);
  crypto.getRandomValues(buf);
  const n = ((buf[0] << 24 | buf[1] << 16 | buf[2] << 8 | buf[3]) >>> 0);
  // 0-999999 均勻分布
  return String(n % 1_000_000).padStart(6, '0');
}

/** SHA-256 雜湊 */
async function sha256(input: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

/** CORS headers */
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json'
};

/** 統一回傳格式 */
function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: CORS });
}

/** 限流檢查:同一電話 N 分鐘內最多 M 次 */
async function checkRateLimit(phone: string, action: string, max: number, windowMin: number): Promise<{ ok: boolean; retryAfter?: number }> {
  const since = new Date(Date.now() - windowMin * 60 * 1000).toISOString();
  const { count, error } = await sb
    .from('login_attempts')
    .select('*', { count: 'exact', head: true })
    .eq('phone_e164', phone)
    .eq('action', action)
    .gte('created_at', since);
  if (error) {
    console.error('Rate limit query failed:', error);
    return { ok: true }; // fail-open,避免監控故障阻塞用戶
  }
  if ((count || 0) >= max) {
    return { ok: false, retryAfter: windowMin * 60 };
  }
  return { ok: true };
}

/** 記錄 login_attempts(用於稽核 + 限流) */
async function recordAttempt(phone: string, action: string, success: boolean, reason?: string) {
  await sb.from('login_attempts').insert({
    phone_e164: phone,
    action,
    success,
    reason: reason || null
  });
}

/** 通過 Meta WhatsApp Cloud API 發送模板訊息 */
async function sendWhatsAppTemplate(phone: string, code: string): Promise<{ ok: boolean; error?: string; response?: unknown }> {
  // 從 E.164 移除 + 號
  const toNumber = phone.replace(/^\+/, '');
  const url = `https://graph.facebook.com/${API_VERSION}/${PHONE_ID}/messages`;
  const body = {
    messaging_product: 'whatsapp',
    recipient_type: 'individual',
    to: toNumber,
    type: 'template',
    template: {
      name: TEMPLATE_NAME,
      language: { code: LANG_CODE },
      components: [
        {
          type: 'body',
          parameters: [{ type: 'text', text: code }]
        }
      ]
    }
  };
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${WHATSAPP_TOKEN}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(body)
    });
    const result = await resp.json();
    if (!resp.ok) {
      console.error('WhatsApp API error:', JSON.stringify(result));
      return { ok: false, error: result.error?.message || `HTTP ${resp.status}`, response: result };
    }
    return { ok: true, response: result };
  } catch (e) {
    console.error('WhatsApp fetch failed:', e);
    return { ok: false, error: (e as Error).message };
  }
}

// ============================================================
// 主入口
// ============================================================
Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  // 僅允許 POST
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  try {
    const body = await req.json();
    const phoneE164: string = (body?.phone_e164 || '').trim();

    // 格式驗證
    if (!phoneE164 || !/^\+\d{8,15}$/.test(phoneE164)) {
      await recordAttempt(phoneE164 || 'invalid', 'invalid_phone', false, 'bad_format');
      return jsonResponse({ error: '電話格式不正確' }, 400);
    }

    // 環境變數檢查
    if (!WHATSAPP_TOKEN || !PHONE_ID) {
      console.error('Missing WHATSAPP_ACCESS_TOKEN or WHATSAPP_PHONE_ID');
      return jsonResponse({ error: '伺服器配置不完整,請聯絡管理員' }, 500);
    }

    // 限流:同電話 10 分鐘最多 5 次 send_otp
    const rl = await checkRateLimit(phoneE164, 'send_otp', 5, 10);
    if (!rl.ok) {
      return jsonResponse({ error: '請求太密,請 10 分鐘後再試' }, 429);
    }

    // 生成 + hash + 寫入
    const code = generateOtp();
    const codeHash = await sha256(phoneE164 + ':' + code);
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
    const { error: insertErr } = await sb.from('otp_codes').insert({
      phone_e164: phoneE164,
      code_hash: codeHash,
      expires_at: expiresAt,
      purpose: 'login'
    });
    if (insertErr) {
      console.error('OTP insert failed:', insertErr);
      return jsonResponse({ error: '系統錯誤,請稍後再試' }, 500);
    }

    // 發送 WhatsApp
    const sendResult = await sendWhatsAppTemplate(phoneE164, code);
    if (!sendResult.success) {
      await recordAttempt(phoneE164, 'send_otp', false, 'whatsapp_error');
      return jsonResponse({ error: '訊息發送失敗,請確認電話號碼有 WhatsApp 帳號,稍後再試' }, 502);
    }

    // 成功
    await recordAttempt(phoneE164, 'send_otp', true);

    // dev 模式:返回 debug_code(由 dev 時設 WHATSAPP_DEBUG_RETURN_CODE=true 控制)
    const responseData: Record<string, unknown> = { ok: true, expires_in: 300 };
    if (Deno.env.get('WHATSAPP_DEBUG_RETURN_CODE') === 'true') {
      responseData.debug_code = code;
    }
    return jsonResponse(responseData);
  } catch (e) {
    console.error('send-whatsapp-otp unexpected error:', e);
    return jsonResponse({ error: (e as Error).message || '伺服器錯誤' }, 500);
  }
});