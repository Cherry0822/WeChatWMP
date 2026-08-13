#!/usr/bin/env python3
import math, os, shutil, subprocess
from PIL import Image, ImageDraw, ImageFilter

S = 1024

def rounded_rect_mask(size, radius):
    m = Image.new('L', size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size[0]-1, size[1]-1], radius=radius, fill=255)
    return m

def v_gradient(size, top, bottom):
    w, h = size
    img = Image.new('RGBA', size)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        c = tuple(int(top[i] + (bottom[i]-top[i])*t) for i in range(3))
        d.line([(0, y), (w, y)], fill=(c[0], c[1], c[2], 255))
    return img

# 1) dark base
top = (22, 27, 48)
bottom = (6, 8, 15)
base = v_gradient((S, S), top, bottom)
mask = rounded_rect_mask((S, S), 215)
canvas = Image.new('RGBA', (S, S), (0,0,0,0))
canvas.paste(base, (0,0), mask)

# 2) flowing glow orbs (Celosia-like)
glow = Image.new('RGBA', (S, S), (0,0,0,0))
gd = ImageDraw.Draw(glow)
for (cx, cy, r, col) in [
    (780, 180, 340, (90, 130, 255, 170)),
    (160, 620, 360, (150, 80, 255, 130)),
    (820, 760, 320, (60, 180, 220, 120)),
]:
    gd.ellipse([cx-r, cy-r, cx+r, cy+r], fill=col)
glow = glow.filter(ImageFilter.GaussianBlur(120))
canvas = Image.alpha_composite(canvas, glow)

# 3) independent glass layers
def glass_layer(size, angle, fill_rgba, border_rgba, blur=10):
    layer = Image.new('RGBA', size, (0,0,0,0))
    ld = ImageDraw.Draw(layer)
    r = 44
    ld.rounded_rectangle([0,0,size[0]-1,size[1]-1], radius=r, fill=fill_rgba)
    if blur:
        layer = layer.filter(ImageFilter.GaussianBlur(blur))
    # crisp border
    bd = ImageDraw.Draw(layer)
    bd.rounded_rectangle([0,0,size[0]-1,size[1]-1], radius=r, outline=border_rgba, width=4)
    # top highlight
    hd = ImageDraw.Draw(layer)
    hd.rounded_rectangle([10,10,size[0]-11,20], radius=6, fill=(255,255,255,120))
    return layer.rotate(angle, resample=Image.BICUBIC, expand=True)

layers = [
    ((760, 360), -12, (255,255,255,44), (255,255,255,150)),
    ((760, 360), 9, (105,150,255,46), (255,255,255,140)),
    ((620, 350), -3, (165,110,255,42), (255,255,255,130)),
]
for i, (size, angle, fill, border) in enumerate(layers):
    lyr = glass_layer(size, angle, fill, border, blur=8)
    # center positions: first two overlap center, third slightly lower
    cx = S//2
    cy = S//2 + (i * 24) - 20
    canvas.paste(lyr, (int(cx-lyr.width/2), int(cy-lyr.height/2)), lyr)

canvas.save('Resources/icon_1024.png')
print('saved icon_1024.png', canvas.size)

# 4) iconset + icns
iconset = 'Resources/AppIcon.iconset'
shutil.rmtree(iconset, ignore_errors=True)
os.makedirs(iconset)
sizes = [16, 32, 128, 256, 512]
for s in sizes:
    for suffix, mult in [('', 1), ('@2x', 2)]:
        px = s * mult
        im = canvas.resize((px, px), Image.LANCZOS)
        im.save(f'{iconset}/icon_{s}x{s}{suffix}.png')
subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', 'Resources/AppIcon.icns'], check=True)
print('saved AppIcon.icns')
