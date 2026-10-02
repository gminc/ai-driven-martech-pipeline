# Day 19 圖二：三張廣告圖、它導去的頁面截圖（其中一段）與 Gemini 列出的落差，文字節錄自 martech_dw.mart_ad_page_gaps（2026-10-02）
# 用法：python3 docs/images/src/day19_results.py（在儲存庫根目錄執行）
# 需要 Pillow 與 Noto Sans CJK 字型（NotoSansCJK-Regular.ttc、NotoSansCJK-Bold.ttc），字型目錄用環境變數 FONT_DIR 指定
import os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
FONT_DIR = os.environ.get('FONT_DIR', '/usr/share/fonts/opentype/noto')
from PIL import Image, ImageDraw, ImageFont
R = os.path.join(FONT_DIR, 'NotoSansCJK-Regular.ttc'); B = os.path.join(FONT_DIR, 'NotoSansCJK-Bold.ttc')
def F(p, s): return ImageFont.truetype(p, s, index=3)
f_title = F(B, 26); f_h = F(B, 17); f_t = F(R, 15); f_s = F(R, 13); f_lab = F(B, 15)
GREEN = (24, 128, 56); GREY = (95, 99, 104); DARK = (32, 33, 36); RED = (197, 34, 31); LINE = (218, 220, 224); ORANGE = (176, 96, 0)
# (顏色, 標記, 落差, 截圖怎麼說, 文字怎麼說)
rows = [
 dict(cid='cr-meta-aut-p1', page='lp-autumn-cotton-1', cap='Meta 秋日專案 → 秋日活動頁（第 1 段）', items=[
   (GREEN, '抓到', '徽章「限定」', '截圖：頁面沒有提到', '文字：頁面沒有提到')]),
 dict(cid='cr-line-evg-p1', page='home-3', cap='LINE 常態素材 → 首頁（第 3 段）', items=[
   (GREEN, '抓到', '徽章「免運」', '截圖：頁面寫「滿 NT$ 600 免運」', '文字：頁面寫「滿 NT$ 600 免運」'),
   (GREEN, '抓到', '標題「純棉短襪」', '截圖：頁面是「日常中筒襪」', '文字：頁面沒有提到'),
   (RED, '漏掉', '賣點「多色可選」', '截圖：抄成「多色選」，沒有列', '文字：抄成「多色選」，有列但對不上答案')]),
 dict(cid='cr-line-trn-r2', page='lp-training-socks-2', cap='LINE 重訓專案 → 重訓活動頁（第 2 段）', items=[
   (GREEN, '抓到', '標題「純棉短襪」', '截圖：引用「厚底毛巾訓練襪」', '文字：引用「厚底毛巾訓練襪」'),
   (ORANGE, '有爭議', '徽章「專案價」', '截圖：引用 NT$ 260', '文字：引用訓練襪 NT$ 260'),
   (RED, '截圖漏掉', '賣點「多色可選」', '截圖：有讀到，沒有列', '文字：頁面沒有提到（抓到）')]),
]
W = 1336; TH = 190; TW = int(1200 * TH / 628); PW = 300; RH = 270; top = 118
img = Image.new('RGB', (W, top + RH * len(rows) + 64), 'white'); d = ImageDraw.Draw(img)
d.text((40, 28), 'Day 19｜廣告圖、它導去的頁面，和 Gemini 列出的落差', font=f_title, fill=DARK)
d.text((40, 70), '左：廣告圖  中：頁面截圖三段裡的一段  右：答案表裡的落差，以及兩種給頁面的方式各引用了什麼頁面證據', font=f_s, fill=GREY)
X2 = 40 + TW + 24; X3 = X2 + PW + 28
for i, r in enumerate(rows):
    y = top + i * RH
    if i: d.line((40, y - 14, W - 40, y - 14), fill=LINE, width=1)
    im = Image.open(f"{ROOT}/creatives/images/{r['cid']}.jpg").convert('RGB').resize((TW, TH))
    img.paste(im, (40, y + 8)); d.rectangle((40, y + 8, 40 + TW, y + 8 + TH), outline=LINE)
    d.text((40, y + TH + 16), r['cid'], font=f_lab, fill=DARK)
    d.text((40, y + TH + 38), r['cap'], font=f_s, fill=GREY)
    pg = Image.open(f"{ROOT}/creatives/landing/{r['page']}.jpg").convert('RGB')
    ph = int(pg.height * PW / pg.width)
    if ph > TH + 44:
        pg = pg.crop((0, 0, pg.width, int(pg.width * (TH + 44) / PW))); ph = TH + 44
    pg = pg.resize((PW, ph)); img.paste(pg, (X2, y + 8)); d.rectangle((X2, y + 8, X2 + PW, y + 8 + ph), outline=LINE)
    yy = y + 8
    for col, tag, gap, a, b in r['items']:
        tw = d.textlength(tag, font=f_lab)
        d.rounded_rectangle((X3, yy, X3 + tw + 20, yy + 26), radius=13, outline=col, width=2)
        d.text((X3 + 10, yy + 3), tag, font=f_lab, fill=col)
        d.text((X3 + tw + 32, yy + 2), gap, font=f_h, fill=DARK)
        d.text((X3 + 4, yy + 32), a, font=f_t, fill=GREY)
        d.text((X3 + 4, yy + 54), b, font=f_t, fill=GREY)
        yy += 84
d.text((40, img.height - 46), '21 個計分落差，給截圖抓到 18 個、給文字抓到 20 個，6 張沒有計分落差的廣告圖只被列了有爭議的名稱差異', font=f_s, fill=GREY)
d.text((40, img.height - 24), '抓到不代表理由正確：導到重訓活動頁的短襪廣告，引用的頁面證據多半是另一個商品', font=f_s, fill=GREY)
img.save(f'{ROOT}/docs/images/day19-consistency-results.jpg', quality=88, optimize=True)
print(img.size)
