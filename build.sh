#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/VroidOverlay.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
SRC="$ROOT_DIR/Sources/VroidOverlay/main.m"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VroidOverlay</string>
    <key>CFBundleIdentifier</key>
    <string>com.inma.vroidoverlay</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>VroidOverlay.icns</string>
    <key>CFBundleName</key>
    <string>VroidOverlay</string>
    <key>CFBundleSignature</key>
    <string>VROD</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

printf 'APPLVROD' > "$APP_DIR/Contents/PkgInfo"

python3 - "$RES_DIR/VroidOverlay.icns" <<'PY'
from math import hypot
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import sys

output_path = Path(sys.argv[1])

def lerp(a, b, t):
    return int(a + (b - a) * t)

def blend(c1, c2, t):
    return tuple(lerp(c1[i], c2[i], t) for i in range(4))

def make_base(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    cx = cy = size / 2.0
    radius = size * 0.47
    inner = (255, 104, 172, 255)
    outer = (196, 30, 117, 255)
    highlight = (255, 190, 225, 180)
    for y in range(size):
        for x in range(size):
            dx = (x + 0.5 - cx) / radius
            dy = (y + 0.5 - cy) / radius
            dist = min(1.0, hypot(dx, dy))
            t = dist ** 0.78
            r, g, b, a = blend(inner, outer, t)
            # soft top-left highlight
            hx = max(0.0, 1.0 - (((x - size * 0.33) ** 2 + (y - size * 0.28) ** 2) ** 0.5) / (size * 0.62))
            ha = int(highlight[3] * (hx ** 1.8))
            r = min(255, r + int((highlight[0] - r) * (ha / 255.0)))
            g = min(255, g + int((highlight[1] - g) * (ha / 255.0)))
            b = min(255, b + int((highlight[2] - b) * (ha / 255.0)))
            alpha = 255 if dist <= 1.0 else 0
            px[x, y] = (r, g, b, alpha)

    # ring shadow
    ring = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dr = ImageDraw.Draw(ring)
    dr.ellipse((size * 0.045, size * 0.045, size * 0.955, size * 0.955), outline=(255, 255, 255, 40), width=max(1, size // 72))
    ring = ring.filter(ImageFilter.GaussianBlur(radius=max(1, size // 160)))
    img = Image.alpha_composite(img, ring)
    return img

def add_face(img):
    size = img.size[0]
    d = ImageDraw.Draw(img)
    cx = cy = size / 2.0
    face_w = size * 0.38
    face_h = size * 0.46
    skin = (249, 230, 221, 255)
    shadow = (234, 198, 190, 255)
    hair = (255, 64, 145, 230)
    face_box = (cx - face_w / 2, cy - face_h / 2 + size * 0.03, cx + face_w / 2, cy + face_h / 2)
    d.ellipse(face_box, fill=skin)
    d.ellipse((face_box[0] + size * 0.02, face_box[1] + size * 0.01, face_box[2] - size * 0.02, face_box[3] - size * 0.03), outline=shadow, width=max(1, size // 96))
    # hair cap
    d.pieslice((cx - size * 0.30, cy - size * 0.33, cx + size * 0.30, cy + size * 0.16), start=180, end=360, fill=hair)
    for offset in [-0.20, -0.11, -0.02, 0.07, 0.16]:
        top = cy - size * 0.29
        left = cx + size * offset
        d.polygon([(left, top), (left + size * 0.05, top - size * 0.07), (left + size * 0.09, top)], fill=hair)
    # eyes
    eye_y = cy - size * 0.02
    eye_dx = size * 0.07
    eye_r = max(1, size // 42)
    eye_color = (70, 50, 55, 255)
    d.ellipse((cx - eye_dx - eye_r, eye_y - eye_r, cx - eye_dx + eye_r, eye_y + eye_r), fill=eye_color)
    d.ellipse((cx + eye_dx - eye_r, eye_y - eye_r, cx + eye_dx + eye_r, eye_y + eye_r), fill=eye_color)
    # mouth
    mouth_w = size * 0.12
    mouth_h = size * 0.05
    d.arc((cx - mouth_w / 2, cy + size * 0.11, cx + mouth_w / 2, cy + size * 0.11 + mouth_h), start=10, end=170, fill=(160, 70, 95, 255), width=max(1, size // 120))
    # gloss
    gloss = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.ellipse((size * 0.16, size * 0.10, size * 0.58, size * 0.48), fill=(255, 255, 255, 42))
    gloss = gloss.filter(ImageFilter.GaussianBlur(radius=max(1, size // 40)))
    img = Image.alpha_composite(img, gloss)
    return img

base = add_face(make_base(1024))
base.save(output_path)
PY

cp "$ROOT_DIR/AI.usdc" "$RES_DIR/AI.usdc"
cp -R "$ROOT_DIR/textures" "$RES_DIR/textures"
cp "$ROOT_DIR/openclaw_vroid_bridge.py" "$RES_DIR/openclaw_vroid_bridge.py"

xcrun clang \
    -fobjc-arc \
    -framework Cocoa \
    -framework EventKit \
    -framework SceneKit \
    -framework ModelIO \
    "$SRC" \
    -o "$BIN_DIR/VroidOverlay"

printf '%s\n' "$APP_DIR"
