"""Offline acceptance and optional 390px screenshots for the generated iOS bundles."""
from datetime import datetime
import functools
import http.server
import os
from pathlib import Path
import subprocess
import threading

from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
SHOTS = os.environ.get('SHOT_DIR')
PROFILE = 'offline-v216-user'
SDK = """
const user = {id:'offline-v216-user', email:'fixture@example.com', display_name:'釣友阿明'};
const getSession = () => localStorage.getItem('fixture-session') ? {user} : null;
window.supabase = {createClient() {
  return {
    auth: {
      getSession: async () => ({data:{session:getSession()}}),
      signInWithPassword: async () => {
        localStorage.setItem('fixture-session','1');
        return {data:{session:getSession(),user}};
      },
      signOut: async () => { localStorage.removeItem('fixture-session'); },
      onAuthStateChange: callback => {
        window.fakeAuthEvent = callback;
        return {data:{subscription:{unsubscribe(){}}}};
      }
    },
    from(table) {
      const query = new Proxy({}, {get(_, key) {
        if (key === 'then') return resolve => resolve({data:[],count:0});
        if (key === 'maybeSingle') return async () => ({data:table === 'users' ? user : null});
        return () => query;
      }});
      return query;
    },
    rpc: async () => ({data:null})
  };
}};
"""


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def capture(page, name):
    if SHOTS:
        path = Path(SHOTS) / f'{name}.png'
        path.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=path, animations='disabled')


def login(page):
    page.locator('#auth-email-toggle').click()
    page.locator('#auth-pw-email').fill('fixture@example.com')
    page.locator('#auth-pw-pass').fill('offline-fixture-password')
    page.locator('#auth-pw-btn').click()


def check_first_run(page):
    login(page)
    expect(page.locator('#consent-modal')).to_be_visible()
    expect(page.locator('#tut-layer')).to_be_hidden()
    page.get_by_role('button', name='只記基本資料').click()
    expect(page.locator('#tut-layer')).to_have_attribute('data-step', '1')
    expect(page.get_by_role('button', name='略過教學')).to_have_count(0)
    expect(page.locator('#tut-exit')).to_have_count(0)
    page.mouse.click(10, 60)
    expect(page.locator('#tut-count')).to_have_text('1/8')
    capture(page, 'tutorial-step-one')
    page.locator('.start-trip-btn').click()
    expect(page.locator('#tut-layer')).to_have_attribute('data-step', '2')
    assert page.evaluate('!tutorialSeen()')
    page.reload()
    expect(page.locator('#tut-layer')).to_have_attribute('data-step', '1')
    page.evaluate('sbLogout()')
    expect(page.locator('#auth-email-toggle')).to_be_visible()
    expect(page.locator('#tut-layer')).to_be_hidden()
    page.evaluate("""async () => {
      window.localStorage.setItem('fixture-session', '1');
      await fakeAuthEvent('SIGNED_IN', {user:{id:'offline-v216-user'}});
    }""")
    expect(page.locator('#tut-layer')).to_have_attribute('data-step', '1')
    assert page.evaluate('!tutorialSeen()')


def check_existing_user(page):
    page.evaluate("""owner => {
      HKF.setOwner(owner);
      HKF.local.setItem('hkf-tutorial-seen','1');
      HKF.local.setItem('hk-fishing-analytics-consent','no');
    }""", PROFILE)
    login(page)
    expect(page.locator('#view-my')).to_be_visible()
    expect(page.locator('#tut-layer')).to_be_hidden()
    assert page.evaluate('tutorialSeen()')
    page.locator('.header-settings').click()
    page.get_by_role('button', name='重睇教學').click()
    expect(page.locator('#tut-layer')).to_have_attribute('data-step', '1')
    page.locator('#tut-exit').click()
    expect(page.locator('#tut-layer')).to_be_hidden()
    assert page.evaluate('tutorialSeen()')


def check_dialogs(page, env):
    cdp = page.context.new_cdp_session(page)
    cdp.send('Emulation.setSafeAreaInsetsOverride', {'insets': {'top': 47, 'bottom': 34}})
    page.locator('.header-settings').click()
    page.evaluate("""() => {
      window.keyboard = new EventTarget();
      Object.assign(keyboard, {height: innerHeight, offsetTop: 0});
      // Keep the layout viewport unchanged, as when a keyboard overlays the WebView.
      const listeners = visualViewport;
      Object.defineProperty(window, 'visualViewport', {get: () => keyboard});
      keyboard.addEventListener('resize', () => listeners.dispatchEvent(new Event('resize')));
      keyboard.addEventListener('scroll', () => listeners.dispatchEvent(new Event('scroll')));
    }""")
    for name, selector, input_id in [
        ('釣友名稱', '#settings-name-dialog', '#name-input'),
        ('設定／更改密碼', '#settings-password-dialog', '#settings-new-pw'),
    ]:
        page.get_by_role('button', name=name).click()
        sheet = page.locator(selector + ' .modal-sheet')
        top = sheet.bounding_box()['y']
        safe_top = 75 if env == 'test' else 47
        assert top >= safe_top
        page.locator(input_id).tap()
        for height in (660, 570, 490, 420):
            page.evaluate("""height => {
              keyboard.height = height;
              keyboard.dispatchEvent(new Event('resize'));
            }""", height)
            assert sheet.bounding_box()['y'] == top
            for item in page.locator(selector + ' :is(.modal-title, input, button)').all():
                box = item.bounding_box()
                assert box['y'] >= safe_top and box['y'] + box['height'] < height
        if input_id == '#name-input' and env == 'test':
            # Draw the simulated keyboard occlusion in the screenshot only.
            page.evaluate("""() => {
              const keyboardShade = document.createElement('div');
              keyboardShade.id = 'fixture-keyboard';
              keyboardShade.style.cssText = 'position:fixed;inset:420px 0 0;z-index:2000;background:#d1d5dd;color:#353c47;text-align:center;padding:20px';
              keyboardShade.textContent = '模擬鍵盤區域';
              document.body.append(keyboardShade);
            }""")
            capture(page, 'rename-keyboard')
            page.locator('#fixture-keyboard').evaluate('element => element.remove()')
        page.locator(input_id).evaluate('input => input.blur()')
        page.evaluate("keyboard.height = innerHeight; keyboard.dispatchEvent(new Event('resize'))")
        assert sheet.bounding_box()['y'] == top
        page.locator(selector).get_by_role('button', name='取消').click()
    page.locator('.settings-back').click()
    expect(page.locator('#name-modal')).to_be_hidden()


def check_trip_and_tide(page):
    main = page.locator('#main')
    page.evaluate("switchView('record')")
    page.wait_for_function("document.querySelector('.record-hero img')?.naturalWidth > 0")
    expect(page.locator('.record-hero h2')).to_have_text('記錄新魚獲')
    expect(page.locator('#record-trip-prompt')).to_contain_text('開咗行程，統計會更準')
    capture(page, 'record-no-trip')

    def next_catch():
        page.evaluate("""() => {
          state.formSuccess = true;
          renderRecordView();
          document.querySelector('#score-card-wrap').style.minHeight = '480px';
          document.querySelector('#main').scrollTop = 150;
        }""")
        assert main.evaluate('el => el.scrollTop') > 0
        page.get_by_role('button', name='記錄下一條').click()
        expect(main).to_have_js_property('scrollTop', 0)
        expect(page.locator('#catch-weight')).to_have_value('')

    next_catch()
    page.evaluate("""async () => {
      await tidesLib.ready;
      const trip = {id:'v216-trip', spot:'西貢公眾碼頭', method:'磯釣', bait:'生蝦',
        startedAt:new Date(Date.now()-5071000).toISOString(), latitude:22.38, longitude:114.27};
      state.activeTrip = trip;
      state.trips = [trip];
      state.catches = [{id:'v216-catch',tripId:trip.id,species:'黑鱲',weight:0.85,
        date:'2026-11-21',time:'16:48',spot:trip.spot}];
      renderRecordView();
    }""")
    card = page.locator('#active-trip-banner.active-trip-record')
    expect(card).to_be_in_viewport(ratio=1)
    expect(card.locator('.atb-timer')).to_have_text('01:24:31')
    capture(page, 'active-short-spot')
    page.evaluate("""() => {
      state.activeTrip.spot = '西貢公眾碼頭｜避風塘東面防波堤近燈塔步道盡頭靠海一段再沿岸向南走至第二個觀景平台旁';
      renderRecordView();
    }""")
    expect(card).to_be_in_viewport(ratio=1)
    assert card.locator('.atb-spot').evaluate('el => el.scrollWidth > el.clientWidth')
    for action in ['加魚', '快速計數', '編輯', '結束']:
        expect(card.get_by_role('button', name=action)).to_be_in_viewport(ratio=1)
    capture(page, 'active-long-spot')
    main.evaluate('el => el.scrollTop = 220')
    expect(card.locator('.atb-timer')).to_be_in_viewport(ratio=1)
    next_catch()
    expect(card).to_be_in_viewport(ratio=1)
    expect(card.locator('.atb-timer')).to_have_text('01:24:31')
    assert page.evaluate('[state.selectedSpecies,(state.customMethod || state.selectedMethod),(state.customBait || state.selectedBait)]') == [None, '磯釣', '生蝦']

    page.evaluate("""() => {
      const trip = state.activeTrip;
      trip.spot = '西貢公眾碼頭';
      trip.endedAt = new Date().toISOString();
      state.activeTrip = null;
      state.justEndedTripId = state.tripDetailId = trip.id;
      switchView('trips');
    }""")
    hero = page.locator('.trip-ended-hero')
    expect(hero).to_have_text('行程已結束')
    assert 120 <= hero.bounding_box()['height'] <= 140
    expect(page.locator('.trip-detail-header .trip-stat-num')).to_have_count(3)
    capture(page, 'ended-trip')

    page.evaluate("""() => {
      tidesLib.setNowForTest(Date.now());
      chooseTide();
    }""")
    expect(page.locator('.tide-card')).to_have_count(12)
    expect(page.locator('.tide-card-advice')).to_have_count(0)
    expect(page.get_by_text('潮汐預測（天文潮）由香港天文台提供。', exact=False)).to_have_count(1)
    expect(page.locator('#hkf-test-banner')).to_be_visible()
    capture(page, 'tide-card')


def make_page(browser, origin):
    context = browser.new_context(viewport={'width':390,'height':844}, is_mobile=True,
                                  has_touch=True, service_workers='block', timezone_id='Asia/Hong_Kong')
    page = context.new_page()
    page.clock.set_fixed_time(datetime.fromisoformat('2026-11-21T17:30:00+08:00'))
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))

    def offline(route):
        if route.request.url.startswith(origin + '/'):
            route.continue_()
        elif '@supabase/supabase-js' in route.request.url:
            route.fulfill(content_type='application/javascript', body=SDK)
        else:
            route.abort()

    page.route('**/*', offline)
    page.goto(origin + '/index.html')
    expect(page.locator('#auth-email-toggle')).to_be_visible()
    return page, errors


def main():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
        functools.partial(Handler, directory=str(ROOT / 'www')))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            for env in ('prod', 'test'):
                subprocess.run(['npm', 'run', 'ios:web'], cwd=ROOT, env={
                    **os.environ, 'APP_ENV':env, 'HKF_TEST_SUPABASE_ANON_KEY':'sb_publishable_offline_fixture_only',
                }, check=True)
                if env == 'test':
                    page, errors = make_page(browser, origin)
                    check_first_run(page)
                    assert not errors, errors
                    page.context.close()
                page, errors = make_page(browser, origin)
                check_existing_user(page)
                check_dialogs(page, env)
                if env == 'test':
                    check_trip_and_tide(page)
                assert not errors, errors
                page.context.close()
            browser.close()
    finally:
        server.shutdown()
    print('PASS v216 offline login, tutorial persistence and replay, keyboard, record and tide')


if __name__ == '__main__':
    main()
