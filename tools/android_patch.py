#!/usr/bin/env python3
"""Правки Android-проекта после `npx cap add android`: разрешения, портрет, ссылки-приглашения,
подпись, номер версии и иконки. Запускается из корня репозитория."""
import os, re, sys, glob

AND = 'android'
MAN = f'{AND}/app/src/main/AndroidManifest.xml'
GRADLE = f'{AND}/app/build.gradle'
run = os.environ.get('GITHUB_RUN_NUMBER', '1')

def sub_file(path, fn):
    s = open(path, encoding='utf-8').read()
    n = fn(s)
    if n == s:
        print('WARN: без изменений', path)
    open(path, 'w', encoding='utf-8').write(n)

# 1) манифест
def man(s):
    if 'android.permission.CAMERA' not in s:
        s = s.replace('</manifest>', '    <uses-permission android:name="android.permission.CAMERA" />\n'
                      '    <uses-feature android:name="android.hardware.camera" android:required="false" />\n</manifest>')
    s = re.sub(r'(<activity\b)', r'\1 android:screenOrientation="portrait"', s, count=1)
    link = ('            <intent-filter>\n'
            '                <action android:name="android.intent.action.VIEW" />\n'
            '                <category android:name="android.intent.category.DEFAULT" />\n'
            '                <category android:name="android.intent.category.BROWSABLE" />\n'
            '                <data android:scheme="https" android:host="qfeter.github.io" android:pathPrefix="/ChessChaos" />\n'
            '            </intent-filter>\n')
    if 'qfeter.github.io' not in s:
        s = s.replace('</activity>', link + '        </activity>', 1)
    return s
sub_file(MAN, man)

# 2) gradle: подпись постоянным ключом (иначе каждое обновление APK пришлось бы ставить поверх с потерей данных) и версия
def gr(s):
    if 'signingConfigs.chaos' not in s:
        ks = os.path.abspath('tools/chesschaos.keystore').replace('\\', '/')
        s = s.replace('buildTypes {', "signingConfigs {\n        chaos {\n            storeFile file('" + ks + "')\n            storeType 'pkcs12'\n            storePassword 'android'\n            keyAlias 'androiddebugkey'\n            keyPassword 'android'\n        }\n    }\n    buildTypes {", 1)
        s = s.replace('minifyEnabled false', 'minifyEnabled false\n            signingConfig signingConfigs.chaos', 1)
    s = re.sub(r'versionCode\s+\d+', f'versionCode {run}', s, count=1)
    s = re.sub(r'versionName\s+"[^"]*"', f'versionName "1.{run}"', s, count=1)
    return s
sub_file(GRADLE, gr)

# 3) иконки
from PIL import Image, ImageFilter, ImageDraw
src = Image.open('icon-512.png').convert('RGB')
res = f'{AND}/app/src/main/res'

def feather_square(img, size):
    im = img.resize((size, size), Image.LANCZOS).convert('RGBA')
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((size * .03, size * .03, size * .97, size * .97), radius=size * .1, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(size * .02))
    im.putalpha(m)
    return im

legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
for d, px in legacy.items():
    out = f'{res}/mipmap-{d}'
    os.makedirs(out, exist_ok=True)
    sq = src.resize((px, px), Image.LANCZOS)
    sq.save(f'{out}/ic_launcher.png')
    rm = Image.new('L', (px * 4, px * 4), 0)
    ImageDraw.Draw(rm).ellipse((0, 0, px * 4 - 1, px * 4 - 1), fill=255)
    rm = rm.resize((px, px), Image.LANCZOS)
    rd = sq.convert('RGBA'); rd.putalpha(rm)
    rd.save(f'{out}/ic_launcher_round.png')
    fg_px = int(px * 108 / 48)  # слой адаптивной иконки: 108dp
    fg = Image.new('RGBA', (fg_px, fg_px), (0, 0, 0, 0))
    art = feather_square(src, int(fg_px * 0.70))
    fg.paste(art, ((fg_px - art.size[0]) // 2, (fg_px - art.size[1]) // 2), art)
    fg.save(f'{out}/ic_launcher_foreground.png')

bg = f'{res}/values/ic_launcher_background.xml'
os.makedirs(os.path.dirname(bg), exist_ok=True)
open(bg, 'w').write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#14072E</color>\n</resources>\n')
# адаптивные иконки Capacitor ссылаются на @mipmap/ic_launcher_foreground, он у нас есть по каждой плотности
for p in glob.glob(f'{res}/mipmap-anydpi-v26/*.xml'):
    print('adaptive:', p)
print('patched OK, versionCode', run)
