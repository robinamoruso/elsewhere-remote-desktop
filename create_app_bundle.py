#!/usr/bin/env python3
import shutil
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
APP_NAME = "Elsewhere.app"
APP_DIR = ROOT / "build" / APP_NAME
CONTENTS = APP_DIR / "Contents"
MACOS = CONTENTS / "MacOS"
RESOURCES = CONTENTS / "Resources"

# 1. Clean previous bundle
if APP_DIR.exists():
    shutil.rmtree(APP_DIR)

MACOS.mkdir(parents=True, exist_ok=True)
RESOURCES.mkdir(parents=True, exist_ok=True)

# 2. Generate Icon
size = 512
img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Squircle background
margin = 30
radius = 100
draw.rounded_rectangle([margin, margin, size - margin, size - margin], radius=radius, fill=(14, 116, 220, 255))

# Screen Bezel
draw.rounded_rectangle([90, 100, 422, 340], radius=16, fill=(15, 23, 42, 255), outline=(255, 255, 255, 120), width=3)
# Screen Display
draw.rounded_rectangle([102, 112, 410, 328], radius=9, fill=(30, 41, 59, 255))

# Stand
draw.polygon([(231, 340), (281, 340), (290, 400), (222, 400)], fill=(71, 85, 105, 255))
draw.rounded_rectangle([190, 400, 322, 415], radius=7, fill=(148, 163, 184, 255))

# Signal / Wifi waves
draw.arc([206, 170, 306, 270], 210, 330, fill=(56, 189, 248, 255), width=9)
draw.arc([226, 190, 286, 250], 210, 330, fill=(56, 189, 248, 255), width=9)
draw.ellipse([246, 235, 266, 255], fill=(56, 189, 248, 255))

iconset_dir = ROOT / "AppIcon.iconset"
iconset_dir.mkdir(exist_ok=True)

sizes = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
]

for s, name in sizes:
    resized = img.resize((s, s), Image.BILINEAR)
    resized.save(iconset_dir / name)

icns_path = RESOURCES / "AppIcon.icns"
subprocess.run(["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_path)], check=True)
shutil.rmtree(iconset_dir)

# 3. Write Info.plist
info_plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Elsewhere</string>
    <key>CFBundleDisplayName</key>
    <string>Elsewhere</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.elsewhere</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Elsewhere</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
"""
(CONTENTS / "Info.plist").write_text(info_plist)

# 4. Compila l'eseguibile Swift direttamente nel bundle
subprocess.run(["swiftc", "-O", str(ROOT / "Elsewhere.swift"), "-o", str(MACOS / "Elsewhere")], check=True)

# Codice server dentro l'app (dati/venv/log restano in ~/.elsewhere)
shutil.copy2(ROOT / "server.py", RESOURCES / "server.py")
shutil.copytree(ROOT / "static", RESOURCES / "static")

# Firma dopo aver copiato tutto (xattr della Scrivania bloccano codesign)
subprocess.run(["xattr", "-cr", str(APP_DIR)], check=True)
subprocess.run(["codesign", "--force", "--deep", "-s", "-", str(APP_DIR)], check=True)
print(f"✅ Bundle creato con successo: {APP_DIR}")

# Installa in /Applications
app_dest = Path("/Applications") / APP_NAME
if app_dest.exists():
    shutil.rmtree(app_dest)
shutil.copytree(APP_DIR, app_dest)
print(f"✅ Installato in: {app_dest}")
