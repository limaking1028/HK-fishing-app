#!/usr/bin/env python3
"""
scripts/extract-tide-pdf.py — 由天文台「Tide Tables」PDF 提取 12 個官方站嘅逐日潮汐

用法：
  pip install pdfplumber
  python3 scripts/extract-tide-pdf.py TideTable2027.pdf --start-page 11 > official_2027.json

PDF 版面：每個站 6 頁（每頁兩個月），每頁以月曆格式排列（星期一至日）。
輸出：{ "CHEK LAP KOK": { "days": { "0101": [["0143", 0.6], ...], ... } }, ... }
  - 時間為 HKT HHMM；潮高為公尺（PDF 只有一位小數，App 數據多數為兩位）
  - 每日事件已按時間排序；高低潮唔喺呢度判斷（由前端按相鄰事件判斷）
  - 負數潮高（例如 -0.1，石壁站）已支援

同 index.html 內嵌數據對比：node scripts/check-tide-data.js --official=official_2027.json
"""
import argparse, json, logging, re, sys
import pdfplumber

MONTHS = ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', 'JULY',
          'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER']
# 每站 6 頁，由 --start-page 開始按此順序排列（2026 版：第 11 頁起係赤鱲角）
STATION_ORDER = ['CHEK LAP KOK', 'CHEUNG CHAU', 'KO LAU WAN', 'KWAI CHUNG', 'MA WAN',
                 'QUARRY BAY', 'SHEK PIK', 'TAI MUI WAN', 'TAI O', 'TAI PO KAU',
                 'TSIM BEI TSUI', 'WAGLAN ISLAND']


def parse_pages(pdf, start, year_check=None):
    out = {}
    for pg in range(start, start + 6):
        ws = pdf.pages[pg - 1].extract_words()
        heads = []
        for i, w in enumerate(ws):
            if w['text'] in MONTHS:
                yr = next((x['text'] for x in ws[i + 1:i + 3] if re.fullmatch(r'20\d\d', x['text'])), None)
                if yr is None:
                    raise SystemExit(f'第 {pg} 頁：月份 {w["text"]} 搵唔到年份')
                heads.append((w['top'], MONTHS.index(w['text']) + 1, int(yr)))
        heads.sort()
        if not heads:
            raise SystemExit(f'第 {pg} 頁：搵唔到月份標題')
        for bi, (top, mon, yr) in enumerate(heads):
            if year_check and yr != year_check:
                raise SystemExit(f'第 {pg} 頁：年份 {yr} 同指定 {year_check} 唔同')
            bottom = heads[bi + 1][0] if bi + 1 < len(heads) else 10 ** 6
            blk = [w for w in ws if top <= w['top'] < bottom]
            tl = sorted([w for w in blk if w['text'] == 'TIME'], key=lambda w: w['x0'])
            if len(tl) != 7:
                raise SystemExit(f'第 {pg} 頁 {mon} 月：TIME 欄位應有 7 個，實際 {len(tl)}')
            anchors = [w['x0'] for w in tl]
            daynums = []
            for w in blk:
                if re.fullmatch(r'\d{1,2}', w['text']) and w['top'] > top + 40:
                    for ci, a in enumerate(anchors):
                        if a - 30 <= w['x0'] <= a - 2:
                            daynums.append((ci, w['top'], int(w['text'])))
            times = [w for w in blk if re.fullmatch(r'\d{4}', w['text']) and w['top'] > top + 40]
            heights = [w for w in blk if re.fullmatch(r'-?\d\.\d', w['text'])]
            for t in times:
                ci = min(range(7), key=lambda k: abs(t['x0'] - anchors[k]))
                if abs(t['x0'] - anchors[ci]) > 6:
                    continue
                h = [x for x in heights if abs(x['top'] - t['top']) < 2 and 24 <= x['x0'] - anchors[ci] <= 40]
                if len(h) != 1:
                    raise SystemExit(f'第 {pg} 頁 {t["text"]}：搵唔到唯一潮高（{len(h)}）')
                cands = [d for d in daynums if d[0] == ci and d[1] <= t['top'] + 1]
                if not cands:
                    raise SystemExit(f'第 {pg} 頁 {t["text"]}：搵唔到所屬日期')
                day = max(cands, key=lambda d: d[1])[2]
                key = f'{mon:02d}{day:02d}'
                out.setdefault(key, []).append([t['text'], float(h[0]['text'])])
    for k in out:
        out[k].sort(key=lambda e: e[0])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf')
    ap.add_argument('--start-page', type=int, default=11, help='赤鱲角（第一個站）嘅首頁，2026 版為 11')
    ap.add_argument('--year', type=int, default=None, help='檢查 PDF 年份')
    args = ap.parse_args()
    logging.disable(logging.WARNING)  # 隱藏 pdfplumber 字體警告
    pdf = pdfplumber.open(args.pdf)
    result = {}
    for i, name in enumerate(STATION_ORDER):
        result[name] = {'days': parse_pages(pdf, args.start_page + i * 6, args.year)}
    json.dump(result, sys.stdout, ensure_ascii=False)
    print()


if __name__ == '__main__':
    main()
