"""Offline tests of the real stats tab. Set SHOT_DIR to save 390px screenshots."""
import os
import re
from pathlib import Path

from playwright.sync_api import sync_playwright, expect

ROOT = Path(os.environ.get("STATS_WEB_ROOT", Path(__file__).resolve().parents[1]))
ORIGIN = "http://stats.fixture"
CATCHES = [
    dict(isMine=True, date=f"2026-{i + 6:02d}-01", time=f"{hour}:05",
         spot=spot, species=species, weight=(i + 1) / 10,
         method=["浮波", "沉底", "路亞", "手絲", "磯釣"][i % 5],
         bait=["蝦", "沙蟲", "假餌", "青蟲", "魚仔"][i % 5])
    for i, (hour, spot, species) in enumerate(zip(
        [1, 6, 9, 13, 17, 20],
        ["西貢", "長洲", "青衣", "坪洲", "赤柱", "大澳"],
        ["黑鱲", "連尖", "石狗公", "黃腳鱲", "石斑", "泥鯭"],
    ))
]
# An older month has more fish than any visible month.
CATCHES += [CATCHES[0], CATCHES[0], CATCHES[4]]
TRIPS = [dict(startedAt="2026-11-01T01:00:00Z", endedAt="2026-11-01T03:00:00Z", catchCount=1)]


def render(page, catches, trips):
    page.evaluate("""([catches, trips]) => {
        state.catches = catches;
        state.trips = trips;
        setMySubTab('stats');
    }""", [catches, trips])


def load(page, show_pro=False):
    html = (ROOT / "index.html").read_text(encoding="utf-8")
    # Isolate the stats tab from unrelated sign-in and external assets.
    html = re.sub(r'<script\b[^>]*\bsrc="https?://[^"]+"[^>]*></script>', "", html)
    html = re.sub(r'<link\b[^>]*\bhref="https?://[^"]+"[^>]*>', "", html)
    html = html.replace("document.addEventListener('DOMContentLoaded', init);", "")
    if show_pro:
        html = html.replace("const SHOW_PRO_CARD = false;", "const SHOW_PRO_CARD = true;")

    def serve(route):
        url = route.request.url
        if url == ORIGIN + "/":
            route.fulfill(content_type="text/html; charset=utf-8", body=html)
        elif url.startswith(ORIGIN + "/"):
            path = ROOT / url.removeprefix(ORIGIN + "/").split("?")[0]
            if path.is_file():
                route.fulfill(path=path)
            else:
                route.fulfill(status=204)
        else:
            route.fulfill(status=204)

    page.route("**/*", serve)
    page.clock.set_fixed_time("2026-11-20T12:00:00Z")
    page.goto(ORIGIN + "/")


with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE"))
    context = browser.new_context(
        viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True,
        service_workers="block", locale="zh-HK",
    )
    errors = []

    def new_page():
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
        return page

    page = new_page()
    load(page)
    stats = page.locator(".ms-wrap")
    render(page, [], [])
    expect(stats.locator(".ms-empty")).to_contain_text("未有記錄")
    expect(stats.locator(".ms-pro")).to_have_count(0)
    expect(stats).not_to_contain_text("進階分析")

    render(page, CATCHES, TRIPS)
    expect(stats.locator(".ms-pro, p.ms-sub")).to_have_count(0)
    expect(stats).not_to_contain_text(re.compile("進階分析|付費|解鎖|升級|最多收穫嘅釣法同魚餌"))
    expect(stats.get_by_role("heading", name="釣餌同釣法中魚次數")).to_be_visible()
    expect(stats.locator(".ms-kpi")).to_have_count(4)
    expect(stats.locator(".ms-cols")).to_have_attribute("aria-label", "9月 1 條，10月 2 條，11月 1 條")
    expect(stats.locator(".ms-col em")).to_have_text(["9月", "10月", "11月"])
    assert stats.locator(".ms-col .c").evaluate_all("(bars) => bars.map(bar => bar.style.height)") == [
        "44px", "88px", "44px",
    ]

    def card(title):
        return stats.locator(".ms-card").filter(has=page.get_by_role("heading", name=title))

    expect(card("你最常中魚嘅時段").locator(".ms-name small")).to_have_text(
        ["00–05", "05–08", "08–12", "12–16", "16–19", "19–24"],
    )
    for title in ["收穫最多嘅釣點", "最常釣到嘅魚種"]:
        expect(card(title).locator(".ms-row")).to_have_count(3)
        expect(card(title).locator(".ms-more")).to_have_text("還有 3 項")
    for group in card("釣餌同釣法中魚次數").locator(".ms-two > div").all():
        expect(group.locator(".ms-chip")).to_have_count(3)
        expect(group.locator(".ms-more")).to_have_text("還有 2 項")

    if os.environ.get("SHOT_DIR"):
        shots = Path(os.environ["SHOT_DIR"])
        shots.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=shots / "stats-top-390.png")
        page.locator("#main").evaluate("(main) => main.scrollTop = main.scrollHeight")
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        page.screenshot(path=shots / "stats-bottom-390.png")

    for count in [3, 2]:
        render(page, CATCHES[:count], [])
        expect(stats.locator(".ms-more")).to_have_count(0)
        expect(stats.locator("p.ms-sub")).to_contain_text("未有已結束嘅行程")
        expect(stats.locator(".ms-hint")).to_contain_text("統計只供參考")
    render(page, [{**CATCHES[0], "bait": ""}], [])
    expect(card("釣餌同釣法中魚次數").locator("span.ms-sub")).to_have_text("—")

    enabled = new_page()
    load(enabled, show_pro=True)
    for catches, trips in [(CATCHES, TRIPS), ([], [])]:
        render(enabled, catches, trips)
        pro = enabled.locator(".ms-pro")
        expect(pro.get_by_role("heading", name="進階分析（開發緊）")).to_be_visible()
        expect(pro.get_by_role("button", name="我有興趣")).to_be_visible()

    assert not errors, errors
    browser.close()
    print("PASS stats cleanup (offline, 0 console errors)")
