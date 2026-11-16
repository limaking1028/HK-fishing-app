"""Offline tutorial regression: python tests/tutorial-highlight.playwright.py.
Optional SHOT_DIR writes mobile screenshots; no backend requests are allowed.
"""
import functools
import http.server
import os
from pathlib import Path
import threading
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(ROOT)))
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f'http://127.0.0.1:{server.server_port}'
SHOT_DIR = os.environ.get('SHOT_DIR')

def check_target(pg, step, sub=None):
    pg.wait_for_timeout(250)
    actual = pg.evaluate('''() => {
      const target = tutorialTarget(), card = document.getElementById('tut-card');
      const r = target && target.getBoundingClientRect(), c = card.getBoundingClientRect();
      const vv = window.visualViewport;
      return {step:state.tutorial.step, sub:state.tutorial.sub,
        count:document.querySelectorAll('.tut-target').length,
        correct:!!target && target.classList.contains('tut-target'),
        old:!!document.querySelector('#tut-d1,#tut-d2,#tut-d3,#tut-d4,#tut-ring'),
        hint:document.getElementById('tut-hint').textContent === tutorialHint(),
        visible:!card.hidden && c.top >= (vv ? vv.offsetTop : 0) && c.bottom <= (vv ? vv.offsetTop + vv.height : innerHeight),
        overlap:r && r.left < c.right && r.right > c.left && r.top < c.bottom && r.bottom > c.top,
        dim:document.getElementById('tut-dim').hidden,
        color:getComputedStyle(target).outlineColor, outline:getComputedStyle(target).outlineWidth, animation:getComputedStyle(target).animationName};
    }''')
    assert actual['step'] == step, actual
    if sub:
        assert actual['sub'] == sub, actual
    assert actual['count'] == 1 and actual['correct'] and not actual['old'], actual
    assert actual['outline'] == '3px' and actual['color'] == 'rgb(255, 224, 102)', actual
    assert actual['hint'] and actual['visible'] and actual['dim'] and not actual['overlap'], actual
    pg.evaluate('''() => {
      document.getElementById('main').scrollBy(0, 45);
      window.scrollBy(0, 45); document.scrollingElement.scrollTop += 20;
    }''')
    assert pg.evaluate("tutorialTarget().classList.contains('tut-target') && document.querySelectorAll('.tut-target').length === 1")
    assert pg.locator('#tut-card').is_visible()
    # A rerender replaces the target node: highlight must attach to the new node.
    if step == 1:
        pg.evaluate('renderTripsView()')
        pg.wait_for_timeout(100)
        assert pg.evaluate("tutorialTarget().classList.contains('tut-target') && document.querySelectorAll('.tut-target').length === 1")
    pg.evaluate('tutorialPaint()')
    pg.wait_for_timeout(100)
    if SHOT_DIR:
        Path(SHOT_DIR).mkdir(parents=True, exist_ok=True)
        pg.screenshot(path=f'{SHOT_DIR}/{pg.viewport_size["width"]}-{step}-{sub or "main"}.png')

def check_touch_gestures(pg):
    pg.wait_for_timeout(350)
    result = pg.evaluate("""() => {
      const nav = document.querySelector('#bottom-nav [data-view="leaderboard"]');
      const card = document.getElementById('tut-card');
      const before = JSON.stringify([state.view, state.tutorial.step, state.tutorial.sub]);
      function send(type, y) {
        const touch = new Touch({identifier:1, target:nav, clientX:200, clientY:y});
        const event = new TouchEvent(type, {bubbles:true, cancelable:true,
          touches:type === 'touchend' ? [] : [touch], changedTouches:[touch]});
        return nav.dispatchEvent(event);
      }
      const startAllowed = send('touchstart', 200);
      const moveAllowed = send('touchmove', 260);
      const scrollEndAllowed = send('touchend', 260);
      const scrollNudge = card.classList.contains('tut-nudge');
      const scrollUnchanged = JSON.stringify([state.view, state.tutorial.step, state.tutorial.sub]) === before;
      send('touchstart', 200);
      const tapAllowed = send('touchend', 200);
      const tapNudge = card.classList.contains('tut-nudge');
      const tapUnchanged = JSON.stringify([state.view, state.tutorial.step, state.tutorial.sub]) === before;
      return {startAllowed, moveAllowed, scrollEndAllowed, scrollNudge, scrollUnchanged,
        tapAllowed, tapNudge, tapUnchanged};
    }""")
    assert result == dict(startAllowed=True, moveAllowed=True, scrollEndAllowed=True,
                          scrollNudge=False, scrollUnchanged=True, tapAllowed=False,
                          tapNudge=True, tapUnchanged=True), result
    pg.wait_for_timeout(350)

def check_lock(pg):
    before = pg.evaluate('({view:state.view, step:state.tutorial.step, sub:state.tutorial.sub})')
    nav = pg.locator('#bottom-nav [data-view="leaderboard"]')
    pg.evaluate("window.__nudges = 0; document.getElementById('tut-card').addEventListener('animationstart', () => window.__nudges++, {once:true})")
    nav.click(force=True)
    pg.wait_for_function('window.__nudges > 0')
    assert pg.evaluate('({view:state.view, step:state.tutorial.step, sub:state.tutorial.sub})') == before
    pg.evaluate("""() => {
      const input = document.createElement('input'); input.id = 'outside-input';
      document.body.appendChild(input); input.focus();
    }""")
    assert not pg.locator('#outside-input').evaluate('el => el === document.activeElement')
    for name in ['click', 'mousedown', 'touchend', 'pointerup']:
        assert pg.locator('#outside-input').evaluate('(el, name) => !el.dispatchEvent(new Event(name, {bubbles:true, cancelable:true}))', name)
    for key in ['Enter', ' ']:
        assert pg.locator('#outside-input').evaluate('(el, key) => !el.dispatchEvent(new KeyboardEvent("keydown", {key, bubbles:true, cancelable:true}))', key)
    pg.evaluate("document.getElementById('outside-input').remove()")
    # Visible dialogs stay operable, including nested controls.
    assert pg.evaluate("""() => {
      const modal = document.createElement('div'); modal.className = 'modal-overlay show';
      modal.innerHTML = '<button>OK</button>'; document.body.appendChild(modal);
      const allowed = modal.firstChild.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true}));
      modal.remove(); return allowed;
    }""")
    # A real wheel scroll still reaches the page during the lock.
    pg.evaluate("document.body.style.minHeight = '2400px'; window.scrollTo(0, 0)")
    pg.mouse.move(200, 300)
    pg.mouse.wheel(0, 150)
    pg.wait_for_timeout(400)
    assert pg.evaluate('window.scrollY > 0')
    pg.evaluate("document.body.style.minHeight = ''; tutorialPaint()")

def check_blocked_uploads(pg, action):
    choosers = []
    handler = lambda chooser: choosers.append(chooser)
    pg.on('filechooser', handler)
    try:
        getattr(pg.locator('#view-record button[onclick*="catch-photo-gallery"]'), action)()
        pg.wait_for_timeout(50)
        assert pg.locator('#tut-card').evaluate("el => el.classList.contains('tut-nudge')")
        assert not choosers and pg.evaluate('state.tutorial.step') == 6
        for input_id in ['catch-proof', 'catch-photo-gallery']:
            pg.wait_for_timeout(350)
            pg.evaluate('(id) => document.getElementById(id).click()', input_id)
            pg.wait_for_timeout(50)
            assert not choosers and pg.evaluate('state.tutorial.step') == 6
            assert pg.locator('#tut-card').evaluate("el => el.classList.contains('tut-nudge')")
    finally:
        pg.remove_listener('filechooser', handler)
    pg.wait_for_timeout(350)

def choose_upload(pg, selector, input_id, action, photo):
    with pg.expect_file_chooser() as pending:
        getattr(pg.locator(selector).first, action)()
    chooser = pending.value
    assert chooser.element.get_attribute('id') == input_id
    assert not pg.locator('#tut-card').evaluate("el => el.classList.contains('tut-nudge')")
    chooser.set_files(photo)

def clean(pg):
    assert pg.evaluate("!document.querySelector('.tut-target') && document.getElementById('tut-layer').hidden")

with sync_playwright() as p:
    browser = p.chromium.launch(**({'executable_path':os.environ['CHROMIUM']} if os.environ.get('CHROMIUM') else {}))
    for width, height, touch in [(375, 667, False), (390, 844, True)]:
        ctx = browser.new_context(viewport={'width':width,'height':height}, is_mobile=touch, has_touch=touch, service_workers='block')
        action = 'tap' if touch else 'click'
        pg = ctx.new_page()
        errors = []
        pg.on('pageerror', lambda e: errors.append(str(e)))
        # Including supabase.co: neither the real SDK nor any external API is contacted.
        pg.route('**/*', lambda r: r.continue_() if r.request.url.startswith(URL + '/') else r.abort())
        pg.add_init_script("localStorage.setItem('hk-fishing-analytics-consent','no'); localStorage.setItem('sw-cleared-v106','1'); localStorage.setItem('hkf-tutorial-seen','1');")
        pg.goto(URL + '/index.html')
        pg.evaluate("state.user={id:'tutorial-test'}; state.catches=[]; state.trips=[]; showApp(); setupGlobalHandlers(); startTutorial();")
        check_target(pg, 1)
        check_touch_gestures(pg)
        check_lock(pg)
        pg.locator('.start-trip-btn').click()
        check_target(pg, 2, 'gps')
        pg.evaluate('tutorialGpsSettled(null)')
        check_target(pg, 2, 'method')
        pg.locator('#trip-method-select').select_option(index=1)
        check_target(pg, 2, 'bait')
        pg.locator('#trip-bait-select').select_option(index=1)
        check_target(pg, 3)
        pg.locator('#view-trips button[onclick="confirmStartTrip();"]').click()
        check_target(pg, 4)
        pg.locator('#species-selector .sp-card').first.click()
        check_target(pg, 5)
        pg.locator('#catch-weight').focus()
        pg.set_viewport_size({'width':width, 'height':440})
        check_target(pg, 5)
        pg.set_viewport_size({'width':width, 'height':height})
        pg.locator('#catch-weight').fill('1.2')
        check_target(pg, 6)
        # Force a visible target beside the bottom card: the card must move above it.
        pg.evaluate("""() => {
          const target = tutorialTarget(), r = target.getBoundingClientRect();
          target.style.transform = 'translateY(' + (innerHeight - 90 - r.bottom) + 'px)';
          tutorialPlace(target);
        }""")
        assert pg.evaluate("document.getElementById('tut-card').getBoundingClientRect().bottom < tutorialTarget().getBoundingClientRect().top")
        pg.evaluate("tutorialTarget().style.transform = ''; tutorialPaint()")
        pg.wait_for_timeout(100)
        photo={'name':'practice.svg','mimeType':'image/svg+xml','buffer':b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="teal"/></svg>'}
        check_blocked_uploads(pg, action)
        choose_upload(pg, '#view-record .photo-upload', 'catch-photo', action, photo)
        check_target(pg, 7)
        choose_upload(pg, '#proof-upload', 'catch-proof', action, photo)
        check_target(pg, 8)
        pg.locator('#view-record button[onclick="submitCatch()"]').click()
        pg.wait_for_timeout(100)
        assert pg.locator('#tut-done').is_visible()
        assert pg.locator('#tut-card').is_hidden()
        assert pg.evaluate("!document.querySelector('.tut-target') && !document.getElementById('tut-dim').hidden")
        pg.locator('#tut-done-btn').click()
        clean(pg)
        pg.evaluate('startTutorial()')
        check_target(pg, 1)
        pg.locator('#tut-skip').click()
        clean(pg)
        pg.locator('#bottom-nav [data-view="leaderboard"]').click()
        assert pg.evaluate("state.view === 'leaderboard' && !tutorialLockInstalled")
        # Reduced motion applies to the actual highlight, too.
        pg.emulate_media(reduced_motion='reduce')
        pg.evaluate('startTutorial()')
        check_target(pg, 1)
        assert pg.evaluate("getComputedStyle(tutorialTarget()).animationName") == 'none'
        check_touch_gestures(pg)
        check_lock(pg)
        pg.evaluate('tutorialHide()')
        clean(pg)
        assert not errors, errors
        print(f'PASS {width}x{height}: {action} filechoosers 6→7→8 / blocked gallery and wrong-step input / steps 1–8 / GPS-method-bait / scroll / DOM replacement / keyboard resize / done / skip / hide / reduced motion')
        ctx.close()
    browser.close()
server.shutdown()
