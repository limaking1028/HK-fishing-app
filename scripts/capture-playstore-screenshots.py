#!/usr/bin/env python3
"""
HK Fishing App — Play Store 截圖自動產生腳本
============================================
- 用 Playwright headless Chromium 自動截 5 個關鍵畫面
- 解析度：1080 × 1920 (Play Store 標準)
- 輸出：screenshots/01-05*.png

使用前：
1. pip install playwright
2. playwright install chromium
3. 設環境變數：
   - HF_TEST_USERNAME: 測試帳號（用於登入）
   - HF_TEST_PIN: 測試 PIN

或者用 --no-login 跳過登入（截公開畫面）。
"""

import os
import sys
import asyncio
from pathlib import Path
from playwright.async_api import async_playwright

BASE_URL = 'https://limaking1028.github.io/HK-fishing-app/'
OUTPUT_DIR = Path(__file__).parent.parent / 'screenshots'
OUTPUT_DIR.mkdir(exist_ok=True)

# 截圖規格：Play Store 要求
WIDTH, HEIGHT = 1080, 1920  # 9:16 直向
DEVICE_SCALE = 2  # 高清（實際渲染 2160×3840）

# 測試帳號（環境變數）
TEST_USERNAME = os.environ.get('HF_TEST_USERNAME', 'demo')
TEST_PIN = os.environ.get('HF_TEST_PIN', '0000')
USE_LOGIN = '--no-login' not in sys.argv


async def login(page):
    """登入測試帳號"""
    if not USE_LOGIN:
        print('⏭️  跳過登入（--no-login）')
        return

    print(f'🔐 登入中：{TEST_USERNAME}')
    await page.goto(BASE_URL, wait_until='networkidle')
    # 等 1 秒確保 SPA 載入
    await page.wait_for_timeout(1500)

    # 檢查是否已登入
    header_user = await page.locator('#header-username').text_content()
    if header_user and header_user.strip():
        print(f'✅ 已登入：{header_user.strip()}')
        return

    # 找登入畫面
    login_visible = await page.locator('#login-screen').is_visible()
    if not login_visible:
        print('⚠️  未見登入畫面，可能已自動登入')
        return

    # 填表 + 提交
    try:
        await page.fill('#auth-username', TEST_USERNAME)
        await page.fill('#auth-pin', TEST_PIN)
        await page.click('#auth-submit')
        await page.wait_for_timeout(3000)
        print('✅ 登入完成')
    except Exception as e:
        print(f'⚠️  登入失敗：{e}')


async def capture_screens():
    print('🚀 啟動 Playwright Chromium...')
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(
            viewport={'width': WIDTH, 'height': HEIGHT},
            device_scale_factor=DEVICE_SCALE,
            user_agent='Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            locale='zh-HK',
        )
        page = await context.new_page()

        # 登入
        await login(page)

        # 1. 我的魚獲（首頁）
        print('📸 截圖 1/5：我的魚獲（首頁）')
        await page.goto(BASE_URL, wait_until='networkidle')
        await page.wait_for_timeout(2000)
        await page.screenshot(path=str(OUTPUT_DIR / '01-my-log.png'))

        # 2. 記錄頁
        print('📸 截圖 2/5：記錄頁（智能輔助）')
        try:
            await page.click('[data-view="record"]')
            await page.wait_for_timeout(2000)
            await page.screenshot(path=str(OUTPUT_DIR / '02-record-form.png'))
        except Exception as e:
            print(f'⚠️  記錄頁截圖失敗：{e}')

        # 3. 地圖頁
        print('📸 截圖 3/5：地圖（GPS 點分佈）')
        try:
            await page.click('[data-view="map"]')
            await page.wait_for_timeout(3000)
            await page.screenshot(path=str(OUTPUT_DIR / '03-map.png'))
        except Exception as e:
            print(f'⚠️  地圖截圖失敗：{e}')

        # 4. 潮汐頁
        print('📸 截圖 4/5：潮汐（5 天預報）')
        try:
            await page.evaluate("window.switchMapTab && window.switchMapTab('tide')")
            await page.wait_for_timeout(2000)
            await page.screenshot(path=str(OUTPUT_DIR / '04-tides.png'))
        except Exception as e:
            print(f'⚠️  潮汐截圖失敗：{e}')

        # 5. 天氣頁
        print('📸 截圖 5/5：天氣（蒲福風級）')
        try:
            await page.evaluate("window.switchMapTab && window.switchMapTab('weather')")
            await page.wait_for_timeout(3500)
            await page.screenshot(path=str(OUTPUT_DIR / '05-weather.png'))
        except Exception as e:
            print(f'⚠️  天氣截圖失敗：{e}')

        await browser.close()
        print('\n✅ 截圖完成！')
        print(f'📁 輸出目錄：{OUTPUT_DIR}')


if __name__ == '__main__':
    asyncio.run(capture_screens())