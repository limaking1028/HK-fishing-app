"""Privacy link behavior and login layout, with local-only fixtures."""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
from threading import Thread

from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
IOS = (ROOT / 'ios').is_dir()
URL = 'https://limaking1028.github.io/HK-fishing-app/privacy.html'
SDK_MOCK = """window.supabase = {createClient: () => ({
  auth: {
    getSession: async () => ({data: {session: null}}),
    onAuthStateChange: () => ({data: {subscription: {unsubscribe() {}}}})
  },
  rpc: async () => ({data: null}),
  from() {
    const q = {select: () => q, eq: () => q, maybeSingle: async () => ({data: null})};
    return q;
  }
})};"""


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(ROOT)))
Thread(target=server.serve_forever, daemon=True).start()
origin = f'http://127.0.0.1:{server.server_port}'


def route_request(route):
    url = route.request.url
    if url.startswith(origin + '/'):
        route.continue_()
    elif '@supabase/supabase-js' in url:
        route.fulfill(content_type='application/javascript', body=SDK_MOCK)
    elif url == URL:
        route.fulfill(content_type='text/html', body='<title>Privacy policy fixture</title>')
    else:
        route.abort()


try:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        for width, height in [(390, 844), (375, 667)]:
            viewport = {'width': width, 'height': height}
            context = browser.new_context(viewport=viewport, is_mobile=True, has_touch=True,
                                          device_scale_factor=2, service_workers='block')
            context.route('**/*', route_request)
            context.add_init_script("""
                localStorage.setItem('sw-cleared-v106', '1');
                window.privacyCalls = [];
            """)
            if IOS:
                context.add_init_script("""
                    window.Capacitor = {
                      isNativePlatform: () => true,
                      getPlatform: () => 'ios',
                      Plugins: {
                        App: {addListener() {}},
                        Browser: {open: async ({url}) => window.privacyCalls.push([url])}
                      }
                    };
                """)
            page = context.new_page()
            page.goto(origin + '/index.html')
            link = page.get_by_role('link', name='《私隱政策》', exact=True)
            expect(link).to_be_visible()
            expect(link).to_have_attribute('href', URL)
            expect(page.locator('.login-privacy')).to_have_text('繼續使用即表示你同意《私隱政策》')
            expect(page.locator('.auth-step .login-privacy')).to_have_count(0)
            expect(page.locator('.login-card > :last-child')).to_have_class('login-privacy')
            expect(link).to_be_in_viewport(ratio=1)
            assert link.evaluate("el => getComputedStyle(el).textDecorationLine") == 'underline'

            selectors = ['#auth-google-btn', '#auth-email-toggle']
            if IOS:
                selectors.append('#auth-apple-btn')
            for selector in selectors:
                button = page.locator(selector)
                expect(button).to_be_in_viewport(ratio=1)
                assert button.bounding_box()['y'] + button.bounding_box()['height'] <= link.bounding_box()['y']

            shots = os.environ.get('PRIVACY_SHOT_DIR')
            if shots:
                platform = 'ios' if IOS else 'web'
                page.screenshot(path=Path(shots) / f'privacy-login-{platform}-{width}x{height}.png',
                                animations='disabled')

            if not IOS:
                with page.expect_popup() as opened:
                    link.click()
                popup = opened.value
                popup.wait_for_load_state()
                assert popup.url == URL and popup.evaluate('window.opener === null')
                popup.close()

                page.evaluate("() => { window.open = () => { throw new Error('unavailable'); }; }")
                with page.expect_popup() as fallback:
                    link.click()
                popup = fallback.value
                popup.wait_for_load_state()
                assert popup.url == URL
                popup.close()

            page.evaluate("() => { window.open = (...args) => { window.privacyCalls.push(args); return null; }; }")
            page.locator('#auth-email-toggle').click()
            page.locator('#auth-pw-email').fill('privacy-test@example.com')
            link.click()
            expect(page.locator('#auth-pw-email')).to_have_value('privacy-test@example.com')
            page.locator('#auth-forgot-btn').click()
            expect(page.locator('#auth-step-email')).to_be_visible()
            expect(link).to_be_visible()
            link.click()
            expect(page.locator('#auth-email')).to_have_value('privacy-test@example.com')
            page.evaluate("showAuthSentStep('privacy-test@example.com')")
            expect(page.locator('#auth-step-sent')).to_be_visible()
            expect(link).to_be_visible()
            link.click()
            expect(page.locator('#auth-email-display')).to_have_text('pr***@example.com')
            assert page.url == origin + '/index.html'
            expected = [URL] if IOS else [URL, '_blank', 'noopener']
            assert page.evaluate('window.privacyCalls') == [expected] * 3
            assert len(context.pages) == 1
            print(f'PASS {width}x{height}: privacy link in all login steps, no navigation or overlap')
            context.close()
        browser.close()
finally:
    server.shutdown()

