"""Offline record redesign regression. Set SHOT_DIR to write four 390 px screenshots."""
from datetime import datetime, timedelta, timezone
import functools
import http.server
import os
from pathlib import Path
import threading

from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
HK = timezone(timedelta(hours=8))
# Soon after HK midnight so a valid 2-hour backdate also tests crossing dates.
NOW = datetime(2026, 11, 21, 1, 42, tzinfo=HK)
SHOT_DIR = os.environ.get('SHOT_DIR')


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def shot(page, name):
    if SHOT_DIR:
        directory = Path(SHOT_DIR)
        directory.mkdir(parents=True, exist_ok=True)
        page.clock.run_for(2100)  # Let toast messages clear before capture.
        page.evaluate("document.activeElement?.blur(); window.scrollTo(0, 0)")
        page.screenshot(path=directory / f'{name}.png', full_page=True, animations='disabled')


def fill_time(page, prefix, when):
    page.locator(f'#{prefix}-date').fill(when.date().isoformat())
    page.locator(f'#{prefix}-time').fill(when.strftime('%H:%M'))


def run(page, url):
    errors = []
    backend_requests = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.on('console', lambda msg: errors.append(msg.text) if msg.type == 'error' else None)

    def offline(route):
        if route.request.url == url + '/index.html':
            # Leaflet is unrelated to these views. Omit its integrity-checked
            # tags so a fully offline run does not simulate a corrupt CDN file.
            html = (ROOT / 'index.html').read_text()
            html = '\n'.join(line for line in html.splitlines()
                             if 'https://unpkg.com/leaflet@' not in line)
            route.fulfill(status=200, content_type='text/html; charset=utf-8', body=html)
        elif route.request.url.startswith(url + '/'):
            route.continue_()
        else:
            if '.supabase.co/' in route.request.url:
                backend_requests.append(route.request.url)
            route.fulfill(status=200, body='')

    page.route('**/*', offline)
    page.clock.install(time=NOW)
    page.clock.pause_at(NOW + timedelta(seconds=1))
    page.add_init_script("""window.supabase = {createClient: () => ({
        rpc: async () => ({data:false}),
        auth: {getSession: async () => ({data:{session:null}}), onAuthStateChange: () => {}}
    })};
    localStorage.setItem('hk-fishing-analytics-consent','no');
        localStorage.setItem('sw-cleared-v106','1'); localStorage.setItem('hkf-tutorial-seen','1');""")
    page.goto(url + '/index.html')
    page.evaluate("""() => {
      state.user = {id:'record-test'};
      state.catches = []; state.trips = [];
      sb = {rpc: async () => ({data:false})};
      window.dbFindOpenTrip = async () => ({trip:null});
      window.dbLoadTrips = async () => [];
      window.dbAddTrip = async data => {
        window.savedTrip = data;
        return {id:'offline-trip', ...data};
      };
      window.tripConditions = async (_, at) => { window.conditionsAt = at; return null; };
      window.dbAddCatchWithRetry = async item => { window.savedCatch = item; return null; };
      window.renderScoreCard = () => {};
      window.autoDetectSpot = async () => ({type:'local', spot:'西貢公眾碼頭', distance:30});
      window.getPositionRobust = onSuccess => onSuccess({
        coords:{latitude:22.381, longitude:114.274, accuracy:12}
      });
      showApp(); switchView('record');
    }""")
    page.clock.run_for(400)
    prompt = page.locator('#record-trip-prompt')
    details = page.locator('#record-details')
    expect(prompt).to_be_visible()
    expect(details).to_have_count(0)
    for selector in ['#gps-btn', '#catch-date', '#catch-time', '#astro-info', '#catch-method', '#catch-bait']:
        expect(page.locator(selector)).to_be_visible()
    shot(page, 'record-no-trip')

    prompt.get_by_role('button', name='開始行程').click()
    date = page.locator('#trip-start-date')
    time = page.locator('#trip-start-time')
    card = page.locator('#trip-astro-info')
    confirm = page.locator('#trip-picker-confirm')
    error = page.locator('#trip-start-error')
    expect(date).to_have_value('2026-11-21')
    expect(date).to_have_attribute('max', '2026-11-21')
    expect(time).to_have_value('01:42')
    expect(card.locator('.astro-row')).to_be_visible()
    initial_card = card.inner_html()
    page.locator('#trip-gps-btn').click()
    expect(confirm).to_be_enabled()
    assert card.inner_html() != initial_card, 'GPS should change the astronomy coordinates'
    expect(page.locator('#trip-tide-preview')).to_have_count(0)
    fill_time(page, 'trip-start', NOW + timedelta(minutes=10))
    expect(error).to_contain_text('唔可以遲過而家')
    expect(confirm).to_be_disabled()
    page.evaluate('confirmStartTrip()')  # The handler must also reject a direct call.
    assert not page.evaluate('Boolean(window.savedTrip)')

    fill_time(page, 'trip-start', NOW - timedelta(hours=13))
    expect(error).to_have_text('最多只可以補開 12 小時內嘅行程')
    expect(confirm).to_be_disabled()
    page.evaluate('confirmStartTrip()')
    assert not page.evaluate('Boolean(window.savedTrip)')
    # Move the date further back to verify the moon calculation visibly repaints.
    old_moon = card.locator('.astro-item').first.inner_text()
    date.fill('2026-11-07')
    assert card.locator('.astro-item').first.inner_text() != old_moon

    chosen = NOW - timedelta(hours=2)
    fill_time(page, 'trip-start', chosen)
    page.locator('#trip-method-select').select_option('磯釣')
    page.locator('#trip-bait-select').select_option('生蝦')
    expect(confirm).to_be_enabled()
    expect(error).to_be_hidden()
    shot(page, 'trip-start')
    confirm.click()
    page.clock.run_for(400)
    expect(details).to_be_visible()
    assert page.evaluate('savedTrip.started_at') == '2026-11-20T15:42:00.000Z'
    assert page.evaluate('conditionsAt') == int(chosen.timestamp() * 1000)
    assert page.evaluate('window.tripsLib.tripDurationSec(state.activeTrip)') >= 7200
    expect(page.locator('#record-details-summary')).to_have_text('西貢公眾碼頭 · 01:42 · 磯釣 · 生蝦')
    assert details.evaluate("""el => !el.open && el.previousElementSibling.matches('button[onclick="submitCatch()"]')""")
    expect(prompt).to_have_count(0)
    expect(page.locator('#catch-time')).to_be_hidden()
    shot(page, 'record-trip-collapsed')

    details.locator('summary').click()
    for selector in ['#gps-btn', '#catch-date', '#catch-time', '#astro-info', '#catch-method', '#catch-bait']:
        expect(details.locator(selector)).to_be_visible()
    shot(page, 'record-trip-expanded')
    page.locator('#species-selector .sp-card').first.click()
    page.locator('#catch-weight').fill('1.2')
    page.locator('#catch-time').fill('02:00')
    expect(page.locator('#record-date-error')).to_contain_text('唔可以遲過而家')
    page.locator('#view-record button[onclick="submitCatch()"]').click()
    assert not page.evaluate('Boolean(window.savedCatch)')

    page.evaluate('renderRecordView()')
    page.locator('#catch-weight').fill('1.2')
    expect(page.locator('#catch-time')).to_be_hidden()
    page.clock.run_for(61_000)
    page.locator('#view-record button[onclick="submitCatch()"]').click()
    payload = page.evaluate('''() => {
      const {spot, method, bait, date, time, tripId, latitude, longitude} = savedCatch;
      return {spot, method, bait, date, time, tripId, latitude, longitude};
    }''')
    assert payload == dict(spot='西貢公眾碼頭', method='磯釣', bait='生蝦', date='2026-11-21',
                           time='01:43', tripId='offline-trip', latitude=22.381, longitude=114.274), payload
    page.get_by_role('button', name='記錄下一條').click()

    page.evaluate("""state.activeTrip.latitude = null; state.activeTrip.longitude = null; resetForm();""")
    expect(page.locator('#gps-btn')).to_be_visible()
    expect(details.locator('#gps-btn')).to_have_count(0)
    expect(page.locator('#catch-date')).to_be_hidden()
    expect(prompt).to_have_count(0)
    page.evaluate('editActiveTrip()')
    expect(page.locator('#trip-picker-confirm')).to_have_text('儲存變更')
    expect(date).to_have_count(0)
    expect(page.locator('#trip-astro-info')).to_have_count(0)

    page.evaluate("""state.tripPicking = state.editingActiveTrip = false;
      state.activeTrip = null; switchView('record'); resetForm();""")
    prompt.get_by_role('button', name='今日收起行程提示').click()
    expect(prompt).to_have_count(0)
    assert page.evaluate("localStorage.getItem('hkf-record-trip-prompt-dismissed')") == '2026-11-21'
    page.reload()
    page.evaluate("state.user = {id:'record-test'}; showApp(); switchView('record');")
    expect(prompt).to_have_count(0)
    page.clock.run_for(400)
    assert not backend_requests, backend_requests
    assert not errors, errors


with http.server.ThreadingHTTPServer(
    ('127.0.0.1', 0), functools.partial(Handler, directory=str(ROOT))
) as server, sync_playwright() as p:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    options = {'executable_path': os.environ['CHROMIUM']} if os.environ.get('CHROMIUM') else {}
    browser = p.chromium.launch(**options)
    page = browser.new_page(viewport={'width': 390, 'height': 844}, device_scale_factor=1,
                            is_mobile=True, has_touch=True, locale='zh-HK',
                            timezone_id='America/Los_Angeles',
                            service_workers='block')
    run(page, f'http://127.0.0.1:{server.server_port}')
    browser.close()
    server.shutdown()
print('PASS record redesign: HK time, 12 h limit, GPS/astro, collapsed submission, edit mode, prompt, 0 console errors')
