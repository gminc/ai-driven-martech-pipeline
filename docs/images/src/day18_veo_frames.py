# Day 18 圖三：Veo 短片每秒取一格，先用 ffmpeg 取格：ffmpeg -i day18-veo.mp4 -vf "fps=1,scale=400:-1" f_%d.jpg
# 取格的目錄用環境變數 FRAMES_DIR 指定（預設 ~/veo）
# 用法：python3 docs/images/src/day18_veo_frames.py（在儲存庫根目錄執行）
# 需要 Pillow 與 Noto Sans CJK 字型（NotoSansCJK-Regular.ttc、NotoSansCJK-Bold.ttc），字型目錄用環境變數 FONT_DIR 指定
import os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
FONT_DIR = os.environ.get('FONT_DIR', '/usr/share/fonts/opentype/noto')
from PIL import Image, ImageDraw, ImageFont
S=os.path.expanduser(os.environ.get('FRAMES_DIR', '~/veo'))
R=os.path.join(FONT_DIR,'NotoSansCJK-Regular.ttc'); B=os.path.join(FONT_DIR,'NotoSansCJK-Bold.ttc')
F=lambda p,s: ImageFont.truetype(p,s,index=3)
ims=[Image.open(f'{S}/f_{i}.jpg').convert('RGB') for i in range(1,5)]
w,h=ims[0].size; gap=12; W=40*2+w*4+gap*3
img=Image.new('RGB',(W,h+150),'white'); d=ImageDraw.Draw(img)
d.text((40,24),'Day 18 延伸段｜rules 版草稿的畫面描述交給 Veo 3.1 Lite',font=F(B,22),fill=(32,33,36))
d.text((40,60),'cr-meta-evg-p2 第 1 次草稿「洗完澡的第一份溫暖包覆」，4 秒、720p、不含音軌，每秒取一格',font=F(R,14),fill=(95,99,104))
for i,im in enumerate(ims):
    x=40+i*(w+gap); img.paste(im,(x,92)); d.rectangle((x,92,x+w,92+h),outline=(218,220,224))
    d.text((x,92+h+8),f'第 {i+1} 格',font=F(R,13),fill=(95,99,104))
img.save(os.path.join(ROOT,'docs/images/day18-veo-frames.jpg'),quality=88,optimize=True); print(img.size)
