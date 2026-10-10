/* ============================================================
 * lib/auth.js — Email + 密碼 / Magic Link / 驗證碼 認證(Supabase Auth)
 *
 * 用途：包裝「Email 發送登入連結 + 偵聽登入狀態」
 *
 *   - sendMagicLink(email)   發送登入連結到 email
 *   - onAuthStateChange(cb)  偵聽 Supabase Auth session 變化
 *   - getCurrentUser()       取得當前已登入的 user(從 users table)
 *   - signOut()              登出
 *
 * 工作流程：
 *   1. 用戶輸入 email → sendMagicLink(email)
 *   2. Supabase 發 email → 用戶撳 link
 *   3. link 帶 access_token 自動登入 → onAuthStateChange 觸發
 *   4. 從 auth.uid() 查 users table 取得 profile(由 trigger 自動建立)
 *
 * 引用：<script src="./lib/auth.js"></script>
 *       暴露 window.authLib.{sendMagicLink, onAuthStateChange, getCurrentUser, signOut}
 *
 * 依賴：window.sb (Supabase client)
 * ============================================================ */

(function() {
  'use strict';

  // ============================================================
  // Email 驗證
  // ============================================================
  function isValidEmail(raw) {
    if (!raw) return false;
    const s = String(raw).trim().toLowerCase();
    return /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i.test(s);
  }

  function maskEmail(email) {
    if (!email || !email.includes('@')) return '';
    const [local, domain] = email.split('@');
    if (local.length <= 2) return local[0] + '***@' + domain;
    return local.slice(0, 2) + '***@' + domain;
  }

  // ============================================================
  // 確保 Supabase client 可用(應對 CDN 偶發載入失敗或初始化 race)
  // ============================================================
  function ensureSb() {
    if (window.sb) return window.sb;
    if (!window.supabase) return null;
    try {
      const url = typeof SB_URL !== 'undefined' ? SB_URL : '';
      const key = typeof SB_KEY !== 'undefined' ? SB_KEY : '';
      if (!url || !key || key.length <= 20) return null;
      window.sb = window.supabase.createClient(url, key, {
        auth: { persistSession: true, autoRefreshToken: true, storage: window.localStorage }
      });
      return window.sb;
    } catch (e) {
      console.warn('ensureSb failed:', e);
      return null;
    }
  }

  function requireSb() {
    const client = ensureSb();
    if (!client) {
      if (!window.supabase) {
        throw new Error('Supabase 函式庫未載入，請檢查網絡或刷新頁面');
      }
      throw new Error('雲端未啟用：缺少 Supabase URL/KEY');
    }
    return client;
  }

  // ============================================================
  // 發送 Magic Link
  // ============================================================
  /**
   * 發送 magic link 到用戶 email
   * @param {string} email
   * @returns {Promise<{ok:true,email:string}>}
   */
  async function sendMagicLink(email) {
    const sb = requireSb();
    const clean = String(email || '').trim().toLowerCase();
    if (!isValidEmail(clean)) throw new Error('Email 格式不正確');

    // 計算 redirect URL:當前頁面(支援 GitHub Pages + Capacitor 包裝)
    const redirectTo = window.location.origin + window.location.pathname.replace(/\/$/, '');

    const { error } = await sb.auth.signInWithOtp({
      email: clean,
      options: {
        emailRedirectTo: redirectTo,
        shouldCreateUser: true   // 第一次會自動建立 auth.users
      }
    });
    if (error) {
      throw new Error(error.message || '發送失敗,請稍後再試');
    }
    return { ok: true, email: clean };
  }

  // ============================================================
  // 用電郵內嘅驗證碼登入（Android App / 手機最穩陣：唔使離開 App 去撳連結）
  // 需要 Supabase Email Template 包含 {{ .Token }}（見 EMAIL_MAGIC_LINK_SETUP.md）
  // ============================================================
  async function verifyCode(email, code) {
    const sb = requireSb();
    const clean = String(email || '').trim().toLowerCase();
    const token = String(code || '').replace(/\s+/g, '');
    if (!isValidEmail(clean)) throw new Error('Email 格式不正確');
    if (!/^\d{6,10}$/.test(token)) throw new Error('請輸入電郵內嘅驗證碼（數字）');
    const { data, error } = await sb.auth.verifyOtp({ email: clean, token, type: 'email' });
    if (error) throw new Error(/expired|invalid/i.test(error.message || '') ? '驗證碼錯誤或已過期，請重新發送' : (error.message || '驗證失敗'));
    return data;
  }


  // ============================================================
  // Email + 密碼 登入 / 註冊 / 重設密碼
  // ============================================================
  function checkPassword(pw) {
    const v = String(pw || '');
    if (v.length < 8) throw new Error('密碼最少 8 個字元');
    if (v.length > 72) throw new Error('密碼最多 72 個字元');
    return v;
  }

  function mapPwError(error) {
    const m = String((error && error.message) || '');
    if (/invalid login credentials/i.test(m)) return '電郵或密碼錯誤（如果你之前只用驗證碼登入，請先用「忘記密碼」設定密碼）';
    if (/email not confirmed/i.test(m)) return '請先去信箱按確認連結，再登入';
    if (/already registered|already been registered/i.test(m)) return '呢個電郵已經註冊，請直接登入';
    if (/password.*(short|weak|least)/i.test(m)) return '密碼太簡單，請用最少 8 個字元';
    if (/rate limit|too many|security purposes/i.test(m)) return '操作太頻密，請稍後再試';
    if (/same.*password|different from the old/i.test(m)) return '新密碼不可以同舊密碼一樣';
    return m || '操作失敗，請稍後再試';
  }

  /** 註冊。返回 { ok, needsConfirm } ；needsConfirm=true 代表要去信箱確認 */
  async function signUpWithPassword(email, password) {
    const sb = requireSb();
    const clean = String(email || '').trim().toLowerCase();
    if (!isValidEmail(clean)) throw new Error('Email 格式不正確');
    const pw = checkPassword(password);
    const redirectTo = window.location.origin + window.location.pathname.replace(/\/$/, '');
    const { data, error } = await sb.auth.signUp({ email: clean, password: pw, options: { emailRedirectTo: redirectTo } });
    if (error) throw new Error(mapPwError(error));
    // 開啟「確認電郵」時，已註冊嘅 email 會回傳空 identities（Supabase 防止洩露用戶是否存在）
    if (data && data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
      throw new Error('呢個電郵已經註冊，請直接登入（忘記密碼可用「忘記密碼」）');
    }
    return { ok: true, needsConfirm: !(data && data.session), email: clean };
  }

  async function signInWithPassword(email, password) {
    const sb = requireSb();
    const clean = String(email || '').trim().toLowerCase();
    if (!isValidEmail(clean)) throw new Error('Email 格式不正確');
    if (!password) throw new Error('請輸入密碼');
    const { data, error } = await sb.auth.signInWithPassword({ email: clean, password: String(password) });
    if (error) throw new Error(mapPwError(error));
    return data;
  }

  /** 寄重設密碼連結 */
  async function sendPasswordReset(email) {
    const sb = requireSb();
    const clean = String(email || '').trim().toLowerCase();
    if (!isValidEmail(clean)) throw new Error('Email 格式不正確');
    const redirectTo = window.location.origin + window.location.pathname.replace(/\/$/, '');
    const { error } = await sb.auth.resetPasswordForEmail(clean, { redirectTo });
    if (error) throw new Error(mapPwError(error));
    return { ok: true, email: clean };
  }

  /** 已登入狀態下設定 / 更改密碼（亦用於重設密碼連結返嚟之後） */
  async function updatePassword(password) {
    const sb = requireSb();
    const pw = checkPassword(password);
    const { error } = await sb.auth.updateUser({ password: pw });
    if (error) throw new Error(mapPwError(error));
    return { ok: true };
  }

  // ============================================================
  // 偵聽登入狀態
  // ============================================================
  /**
   * 註冊一個 callback,當 Supabase Auth session 變化時觸發
   * callback 接收 { event, session } 兩個參數
   *
   * event 可為:'SIGNED_IN' | 'SIGNED_OUT' | 'TOKEN_REFRESHED' | 'USER_UPDATED'
   */
  function onAuthStateChange(cb) {
    const sb = ensureSb();
    if (!sb) return { data: { subscription: { unsubscribe: () => {} } } };
    return sb.auth.onAuthStateChange(cb);
  }

  // ============================================================
  // 取得當前 user(profile from users table)
  // ============================================================
  /**
   * 取得當前已登入用戶嘅 profile(從 users table)
   * 如果 trigger 未跑(極端 race condition),返回 null
   */
  async function getCurrentUser() {
    const sb = ensureSb();
    if (!sb) return null;
    const { data: sessionData } = await sb.auth.getSession();
    const sess = sessionData?.session;
    if (!sess || !sess.user) return null;
    const uid = sess.user.id;
    // trigger 建立 users row 可能慢半拍（首次登入），最多重試 4 次
    for (let i = 0; i < 4; i++) {
      const { data: profile, error } = await sb.from('users').select('*').eq('id', uid).maybeSingle();
      if (error) {
        console.warn('getCurrentUser failed:', error);
        return null;
      }
      if (profile) return profile;
      await new Promise(r => setTimeout(r, 500));
    }
    return null;
  }

  // ============================================================
  // 登出
  // ============================================================
  async function signOut() {
    const sb = ensureSb();
    if (!sb) return;
    try {
      await sb.auth.signOut({ scope: 'local' });
    } catch (e) {
      console.warn('signOut error:', e);
    }
    try {
      localStorage.removeItem('hk_fishing_user_id');
      localStorage.removeItem('hk_fishing_phone_e164');
    } catch (e) {}
  }

  // ============================================================
  // 60 秒發送冷卻(UI 層防止用戶 spam 撳掣)
  // ============================================================
  const COOLDOWN_KEY = 'hk_fishing_magic_cooldown';
  const COOLDOWN_SEC = 60;

  // 舊版 WhatsApp OTP 遺留：index.html 初始化時可能會查詢，保留兼容
  function getRememberedPhone() {
    try { return localStorage.getItem('hk_fishing_phone_e164') || ''; } catch (e) { return ''; }
  }

  function setCooldown(email) {
    try {
      sessionStorage.setItem(COOLDOWN_KEY + ':' + email, String(Date.now() + COOLDOWN_SEC * 1000));
    } catch (e) {}
  }
  function clearCooldown(email) {
    try { sessionStorage.removeItem(COOLDOWN_KEY + ':' + email); } catch (e) {}
  }
  function getCooldownRemain(email) {
    try {
      const v = sessionStorage.getItem(COOLDOWN_KEY + ':' + email);
      if (!v) return 0;
      const remain = Math.ceil((Number(v) - Date.now()) / 1000);
      return remain > 0 ? remain : 0;
    } catch (e) { return 0; }
  }

  // ============================================================
  // 匯出
  // ============================================================
  window.authLib = {
    isValidEmail, maskEmail,
    sendMagicLink, verifyCode, onAuthStateChange,
    signUpWithPassword, signInWithPassword, sendPasswordReset, updatePassword,
    getCurrentUser, signOut,
    getRememberedPhone,
    setCooldown, clearCooldown, getCooldownRemain,
    COOLDOWN_SEC
  };
})();