"""Offline record redesign regression. Set SHOT_DIR to write the seven R2 screenshots."""
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


def shot(page, name, target=None):
    if SHOT_DIR:
        directory = Path(SHOT_DIR)
        directory.mkdir(parents=True, exist_ok=True)
        page.clock.run_for(2100)  # Let toast messages clear before capture.
        page.evaluate("document.activeElement?.blur(); window.scrollTo(0, 0); document.getElementById('main').scrollTop = 0")
        if target:
            page.locator(target).evaluate("el => el.scrollIntoView({block:'center', behavior:'instant'})")
        page.mouse.move(0, 0)
        page.screenshot(path=directory / f'{name}.png', animations='disabled')


def fill_time(page, prefix, when):
    page.locator(f'#{prefix}-date').fill(when.date().isoformat())
    page.locator(f'#{prefix}-time').fill(when.strftime('%H:%M'))


def check_species(page):
    hero = page.locator('#view-record .record-hero')
    cards = page.locator('#species-selector > .sp-grid .sp-card')
    search = page.locator('#record-species-search')
    all_button = page.get_by_role('button', name='全部魚種（45） ›')
    sheet = page.locator('#record-species-sheet')
    sheet_cards = sheet.locator('.sp-card:not(.custom-species)')
    expect(hero.locator('img')).to_have_js_property('complete', True)
    assert hero.locator('img').evaluate('img => img.naturalWidth') > 0
    assert hero.evaluate('el => el.offsetHeight') == 150
    expect(page.locator('.record-form-card > #record-trip-prompt').first).to_be_visible()
    expect(cards).to_have_count(8)
    assert cards.evaluate_all('nodes => new Set(nodes.slice(0, 4).map(node => node.offsetTop)).size') == 1
    assert cards.nth(4).evaluate('node => node.offsetTop') > cards.first.evaluate('node => node.offsetTop')
    expect(search).to_have_attribute('placeholder', '搜尋魚種（例如：黃、石斑）')
    expect(all_button).to_be_visible()
    shot(page, 'r2-default-390')
    page.set_viewport_size({'width': 375, 'height': 667})
    assert hero.evaluate('el => el.offsetHeight') == 124
    shot(page, 'r2-default-375')
    page.set_viewport_size({'width': 390, 'height': 844})

    search.fill('黃')
    expect(page.locator('.sp-section-title')).to_have_text('搜尋結果（3）')
    assert set(cards.evaluate_all("nodes => nodes.map(node => node.dataset.species)")) == {'黃腳鱲', '黃立鯧', '黃花'}
    shot(page, 'r2-search-yellow')
    search.fill('石斑')
    assert set(cards.evaluate_all("nodes => nodes.map(node => node.dataset.species)")) == {'沙巴龍躉', '青斑', '芝麻斑'}
    search.fill('無呢種魚')
    expect(page.get_by_text('搵唔到，可以揀「自訂魚種」')).to_be_visible()
    expect(cards.get_by_text('自訂魚種')).to_be_visible()
    page.get_by_role('button', name='清除搜尋').click()
    expect(cards).to_have_count(8)

    all_button.click()
    expect(sheet).to_be_visible()
    expect(sheet_cards).to_have_count(45)
    assert page.evaluate("getComputedStyle(document.documentElement).overflow") == 'hidden'
    all_names = sheet_cards.evaluate_all("nodes => nodes.map(node => node.dataset.species)")
    assert set(all_names) == set(page.evaluate('FISH_SPECIES.filter(f => !f.custom).map(f => f.name)'))
    shot(page, 'r2-sheet-all')
    grouped = []
    for category, count in [('鱲／鯛', 7), ('石斑', 3), ('鱸／泥鯭', 5), ('沙底', 9), ('河口', 6), ('掠食', 8), ('其他', 7)]:
        tab = sheet.locator(f'[data-category="{category}"]')
        expect(tab).to_have_text(f'{category} {count}')
        tab.click()
        expect(sheet_cards).to_have_count(count)
        expect(sheet.locator('.sp-card').last).to_have_accessible_name('自訂魚種')
        grouped.extend(sheet_cards.evaluate_all("nodes => nodes.map(node => node.dataset.species)"))
    assert sorted(grouped) == sorted(all_names)
    sheet.locator('[data-category="石斑"]').click()
    shot(page, 'r2-sheet-grouper')

    card = sheet.locator('[data-species="青斑"]')
    point = card.bounding_box()
    x, y = point['x'] + point['width'] / 2, point['y'] + point['height'] / 2
    cdp = page.context.new_cdp_session(page)
    cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': x, 'y': y}]})
    page.clock.run_for(520)
    cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
    expect(sheet).to_be_visible()
    expect(card.locator('.sp-star')).to_have_text('★')
    expect(sheet.get_by_role('status')).to_have_text('已收藏 青斑')
    assert page.evaluate("JSON.parse(localStorage.getItem('hk-fishing-pinned-species'))") == ['青斑']
    card.click(button='right')
    expect(card.locator('.sp-star')).to_have_count(0)
    card.click(button='right')
    expect(card.locator('.sp-star')).to_have_text('★')
    page.mouse.click(15, 80)
    expect(sheet).to_have_count(0)
    expect(cards.first).to_have_attribute('data-species', '青斑')
    expect(cards.first.locator('.sp-star')).to_be_visible()
    assert page.evaluate("getComputedStyle(document.documentElement).overflow") != 'hidden'

    all_button.click()
    sheet.locator('#sp-sheet-search').fill('黃')
    expect(sheet_cards).to_have_count(3)
    sheet.locator('[data-species="黃腳鱲"]').click()
    expect(sheet).to_have_count(0)
    expect(page.locator('.sp-chosen strong')).to_have_text('黃腳鱲')
    expect(search).to_have_count(0)
    shot(page, 'r2-selected')
    page.get_by_role('button', name='更改', exact=True).click()
    expect(search).to_be_visible()
    expect(cards).to_have_count(8)

    page.evaluate("""FISH_SPECIES.push({name:'測試新魚種', icon:'🐟'}); renderSpeciesSelector();""")
    page.get_by_role('button', name='全部魚種（46） ›').click()
    sheet.locator('[data-category="其他"]').click()
    expect(sheet_cards).to_have_count(8)
    expect(sheet.locator('[data-species="測試新魚種"]')).to_be_visible()
    page.keyboard.press('Escape')
    expect(sheet).to_have_count(0)
    page.evaluate('FISH_SPECIES.pop(); renderSpeciesSelector();')


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
    check_species(page)

    prompt.get_by_role('button', name='開始行程').click()
    date = page.locator('#trip-start-date')
    time = page.locator('#trip-start-time')
    card = page.locator('#trip-astro-info')
    confirm = page.locator('#trip-picker-confirm')
    error = page.locator('#trip-start-error')
    expect(page.locator('#view-trips .record-hero')).to_have_count(0)
    expect(page.locator('#view-record .record-hero')).to_be_hidden()
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
    confirm.click()
    page.clock.run_for(400)
    expect(details).to_be_visible()
    assert page.evaluate('savedTrip.started_at') == '2026-11-20T15:42:00.000Z'
    assert page.evaluate('conditionsAt') == int(chosen.timestamp() * 1000)
    assert page.evaluate('window.tripsLib.tripDurationSec(state.activeTrip)') >= 7200
    expect(page.locator('#record-details-summary')).to_have_text('西貢公眾碼頭 · 01:42 · 磯釣 · 生蝦')
    assert details.evaluate("""el => !el.open && el.previousElementSibling.id === 'test-mode-box' && el.nextElementSibling.matches('button[onclick="submitCatch()"]')""")
    expect(prompt).to_have_count(0)
    expect(page.locator('#catch-time')).to_be_hidden()
    shot(page, 'r2-trip-details-collapsed', '#record-details')

    details.locator('summary').click()
    for selector in ['#gps-btn', '#catch-date', '#catch-time', '#astro-info', '#catch-method', '#catch-bait']:
        expect(details.locator(selector)).to_be_visible()
    page.locator('#species-selector .sp-card[data-species="黃腳鱲"]').click()
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
      const {species, spot, method, bait, date, time, tripId, latitude, longitude} = savedCatch;
      return {species, spot, method, bait, date, time, tripId, latitude, longitude};
    }''')
    assert payload == dict(species='黃腳鱲', spot='西貢公眾碼頭', method='磯釣', bait='生蝦', date='2026-11-21',
                           time='01:43', tripId='offline-trip', latitude=22.381, longitude=114.274), payload
    expect(page.locator('#view-record .record-hero')).to_have_count(0)
    page.locator('#score-card-wrap').evaluate("el => el.style.minHeight = '480px'")
    page.locator('#main').evaluate("el => el.scrollTop = 150")
    assert page.locator('#main').evaluate("el => el.scrollTop") > 0
    page.get_by_role('button', name='記錄下一條').click()
    expect(page.locator('#main')).to_have_js_property('scrollTop', 0)
    expect(page.locator('#active-trip-banner.active-trip-record')).to_be_in_viewport(ratio=1)
    expect(page.locator('#catch-weight')).to_have_value('')
    page.locator('#main').evaluate("el => el.scrollTop = 230")
    expect(page.locator('#atb-timer')).to_be_in_viewport(ratio=1)
    assert page.evaluate("[state.selectedSpecies, (state.customSpot || state.selectedSpot), (state.customMethod || state.selectedMethod), (state.customBait || state.selectedBait)]") == [
        None, '西貢公眾碼頭', '磯釣', '生蝦']
    assert page.evaluate("tripsLib.tripDurationSec(state.activeTrip)") > 3600
    page.locator('#record-species-search').fill('無匹配')
    page.get_by_role('button', name='自訂魚種', exact=True).click()
    page.locator('#custom-species').fill('示範魚種')
    expect(page.locator('.sp-chosen #custom-species')).to_have_value('示範魚種')
    page.locator('#catch-weight').fill('0.6')
    page.locator('#view-record button[onclick="submitCatch()"]').click()
    assert page.evaluate('savedCatch.species') == '示範魚種'
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
print('PASS record redesign: HK time, 12 h limit, GPS/astro, collapsed submission, species search/categories/pins/custom, hero, edit mode, prompt, 0 console errors')
