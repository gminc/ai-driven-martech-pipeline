# Day 18 圖二：點擊率最低的三張圖與兩版草稿，草稿文字節錄自 martech_dw.mart_creative_drafts（2026-10-01 第二輪）
# 用法：python3 docs/images/src/day18_results.py（在儲存庫根目錄執行）
# 需要 Pillow 與 Noto Sans CJK 字型（NotoSansCJK-Regular.ttc、NotoSansCJK-Bold.ttc），字型目錄用環境變數 FONT_DIR 指定
import os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
FONT_DIR = os.environ.get('FONT_DIR', '/usr/share/fonts/opentype/noto')
from PIL import Image, ImageDraw, ImageFont
import re
REPO=ROOT
R=os.path.join(FONT_DIR,'NotoSansCJK-Regular.ttc'); B=os.path.join(FONT_DIR,'NotoSansCJK-Bold.ttc')
def F(p,s): return ImageFont.truetype(p,s,index=3)
f_title=F(B,26); f_h=F(B,19); f_t=F(R,15); f_s=F(R,13); f_lab=F(B,15)
BLUE=(26,115,232); GREEN=(24,128,56); GREY=(95,99,104); DARK=(32,33,36); RED=(197,34,31); LINE=(218,220,224)
rows=[
 dict(cid='cr-meta-evg-p2', ctr='1.58%', ch='Meta 新客', old='一條包得住的大浴巾', oldf='沒有人物｜沒有按鈕｜冷色',
  free=dict(n=2,h='洗完澡的第一份溫暖包覆',s='雙面厚實毛圈 × 480g黃金厚度，溫柔吸水又易乾',b='100%有機棉',c='立即體驗極致舒適',f='有人物｜右下｜暖色',e='大幅增加新客點擊率'),
  rules=dict(n=1,h='洗完澡的第一份溫暖包覆',s='雲林虎尾製 100%有機棉',b='雙面毛圈',c='立即選購',f='有人物｜右下｜暖色',e='提升廣告的點擊率')),
 dict(cid='cr-meta-aut-p1', ctr='1.60%', ch='Meta 新客', old='每天洗臉的純棉毛巾', oldf='沒有人物｜置中｜冷色',
  free=dict(n=2,h='像雲朵般輕柔包覆',s='日本級無撚紗織造，一接觸瞬間吸收水分',b='100%有機棉',c='體驗極致親膚',f='有人物｜右下｜暖色',e='點擊率提升至原本的 1.28 倍'),
  rules=dict(n=1,h='無撚紗瞬吸快乾毛巾',s='100%有機棉織造 越洗越蓬鬆',b='（不放標籤）',c='了解更多',f='有人物｜右下｜暖色',e='廣告點擊率提升至原來的 1.28 倍')),
 dict(cid='cr-line-trn-p1', ctr='1.66%', ch='LINE 新客', old='重訓日的厚底毛巾襪', oldf='沒有人物｜置中｜中性色',
  free=dict(n=1,h='深蹲硬舉 不在鞋內滑動',s='高密度毛圈底 × 足弓支撐帶，極致防滑包覆',b='彰化社頭製',c='搶先體驗強效止滑',f='有人物｜右下｜暖色',e='點擊率提升至原本的 1.28 倍'),
  rules=dict(n=1,h='深蹲硬舉不滑動',s='高密度毛圈與足弓支撐帶，重訓更穩定',b='台灣彰化社頭製',c='了解更多',f='有人物｜右下｜中性色',e='能有效提高廣告點擊率 1.28 倍')),
]
PUFF=r'(極致|強效|黃金|日本級)'
W=1336; TH=200; TW=int(1200*TH/628); RH=290; top=120
img=Image.new('RGB',(W,top+RH*len(rows)+70),'white'); d=ImageDraw.Draw(img)
d.text((40,28),'Day 18｜點擊率最低的三張圖，兩版題目各一份草稿',font=f_title,fill=DARK)
d.text((40,70),'左：原圖（Day 16 AI 讀出來的現況）  中：沒寫品牌規則（free）  右：同一份題目加四條規則（rules），紅字是看完草稿才找到的誇大用語，預期效果為節錄',font=f_s,fill=GREY)
def rich(x,y,txt,font,maxw,base=DARK):
    # draw text with puffery words in red, wrap by width
    parts=re.split(PUFF,txt); cx=x; cy=y; lh=font.size+7
    for p in parts:
        col=RED if re.fullmatch(PUFF,p or '_') else base
        for ch in p:
            w=d.textlength(ch,font=font)
            if cx+w>x+maxw: cx=x; cy+=lh
            d.text((cx,cy),ch,font=font,fill=col); cx+=w
    return cy+lh
CX=[40, 40+TW+40, 40+TW+40+430]; CW=400
for i,r in enumerate(rows):
    y=top+i*RH
    if i: d.line((40,y-14,W-40,y-14),fill=LINE,width=1)
    im=Image.open(f"{REPO}/creatives/images/{r['cid']}.jpg").convert('RGB').resize((TW,TH))
    img.paste(im,(40,y+8)); d.rectangle((40,y+8,40+TW,y+8+TH),outline=LINE)
    d.text((40,y+TH+16),f"{r['cid']}  {r['ch']}  點擊率 {r['ctr']}",font=f_lab,fill=DARK)
    d.text((40,y+TH+40),r['oldf'],font=f_s,fill=GREY)
    for j,(k,col,lab) in enumerate([('free',BLUE,'free（沒寫規則）'),('rules',GREEN,'rules（加四條規則）')]):
        c=r[k]; x=CX[j+1]
        d.rounded_rectangle((x,y+8,x+CW,y+TH+8),radius=10,outline=col,width=2)
        d.text((x+16,y+16),f"{lab}  第 {c['n']} 次",font=f_lab,fill=col)
        yy=rich(x+16,y+44,c['h'],f_h,CW-32)
        yy=rich(x+16,yy+2,c['s'],f_t,CW-32)
        yy=rich(x+16,yy+4,'標籤：'+c['b'],f_t,CW-32,GREY)
        yy=rich(x+16,yy,'按鈕：'+c['c'],f_t,CW-32,GREY)
        yy=rich(x+16,yy+4,c['f'],f_s,CW-32,col)
        yy=rich(x+16,yy,'預期效果：'+c['e'],f_s,CW-32,GREY)
d.text((40,img.height-48),'12 份草稿都加了人物、按鈕都移到右下，引用的都是人物的點擊率倍數 1.28，38 個詞的禁用詞庫兩版都抓到 0 個',font=f_s,fill=GREY)
d.text((40,img.height-26),'沒寫規則的 6 份有 5 份出現「極致」「強效」「黃金」「日本級」，有規則的 6 份都沒有，預期效果寫「1.28 倍」的從 5 份降到 2 份',font=f_s,fill=GREY)
img.save(f'{REPO}/docs/images/day18-drafts-results.jpg',quality=88,optimize=True)
print(img.size)
