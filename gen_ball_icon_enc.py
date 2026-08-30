# -*- coding: utf-8 -*-
"""ball_icon.h 生成: 悬浮球品牌图标从 图标/app.png 读取, 缩放后 XOR 加密嵌入。
8 字节 rolling key。VCamFloatingBall.m 运行时解码后 imageWithData。
"""
import io
import os

from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "图标", "app.png")
OUT = os.path.join(ROOT, "ball_icon.h")

SIZE = 150  # 悬浮球 50pt * 3x retina
KEY = [0xB7, 0x31, 0xE4, 0x5C, 0x0A, 0x92, 0x6D, 0xF3]

img = Image.open(SRC)
if img.mode != "RGBA":
    img = img.convert("RGBA")
img = img.resize((SIZE, SIZE), Image.LANCZOS)

buf = io.BytesIO()
img.save(buf, format="PNG", optimize=True)
orig = buf.getvalue()
print(f"源图 {SRC}: {Image.open(SRC).size} -> {SIZE}x{SIZE} PNG {len(orig)} bytes")

enc = bytes(b ^ KEY[i & 7] for i, b in enumerate(orig))
assert enc[:4] != b"\x89PNG", "加密后仍是 PNG 魔数?"
print(f"加密后首 4 字节: {enc[:4].hex()} (应无 89504e47)")

lines = []
lines.append("// 悬浮球品牌图标(加密存储, gen_ball_icon_enc.py 生成)")
lines.append("// 源图 图标/app.png, PNG 字节 XOR 8字节 rolling key, 二进制内无 PNG 魔数/IEND 特征,")
lines.append("// 防止 strings/binwalk 直接提取或替换品牌图标; 运行时解码后 imageWithData")
lines.append("#ifndef BALL_ICON_H")
lines.append("#define BALL_ICON_H")
lines.append("")
for i, k in enumerate(KEY):
    lines.append(f"#define VCS_ICON_KEY{i} 0x{k:02X}")
lines.append("")
lines.append(f"#define vcam_ball_icon_png_len {len(enc)}")
lines.append("")
lines.append("static const unsigned char vcam_ball_icon_enc[] = {")
row = []
for b in enc:
    row.append(f"0x{b:02X}")
    if len(row) == 16:
        lines.append(", ".join(row) + ",")
        row = []
if row:
    lines.append(", ".join(row) + ",")
lines.append("};")
lines.append("")
lines.append("#endif // BALL_ICON_H")
lines.append("")

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines))
print(f"ball_icon.h 已重写: {len(enc)} bytes 加密图标")
