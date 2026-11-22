#!/usr/bin/env python3
"""Patch the flutter-create generated Android project (CI scaffold step).

- applicationId / namespace -> com.andytransport.metro (matches the iOS
  bundle id; Android and iOS namespaces are independent)
- app label -> "Subway tools"
- versionName -> "1.0.0A" (the letter-suffix version the user uses, same
  style as iOS 1.1.0B; pubspec keeps the semver core 1.0.0+1)
- AGP is deliberately NOT pinned here: flutter_inappwebview_android
  1.1.3 calls getDefaultProguardFile('proguard-android.txt'), which
  AGP 9 removed (CI build #1), while the newest Flutter requires
  AGP >= 9.1.1 (CI build #2, rejecting an 8.9.3 pin). The consistent
  combination is the older toolchain pinned in the workflow
  (Flutter 3.35.7, whose template AGP 8.7.x still has that API).
- <queries> for the store schemes (mimarket / oppomarket / vivomarket /
  market), so Android 11+ package visibility lets the shell open the
  phone's app store for the transit-app jump.
- add location permissions (the web core's nearby-stations feature uses
  HTML5 geolocation; the prompt itself is handled in lib/main.dart)
Fails loudly if an expected pattern is missing.
"""
import pathlib
import re

root = pathlib.Path("android")

gradle = root / "app" / "build.gradle.kts"
if not gradle.exists():
    gradle = root / "app" / "build.gradle"
text = gradle.read_text(encoding="utf-8")
new, n1 = re.subn(r'namespace\s*=\s*"[^"]+"', 'namespace = "com.andytransport.metro"', text)
if n1 == 0:
    new, n1 = re.subn(r"namespace\s+'[^']+'", "namespace 'com.andytransport.metro'", text)
assert n1 == 1, "namespace pattern not found in app gradle file"
new, n2 = re.subn(r'applicationId\s*=\s*"[^"]+"', 'applicationId = "com.andytransport.metro"', new)
if n2 == 0:
    new, n2 = re.subn(r"applicationId\s+'[^']+'", "applicationId 'com.andytransport.metro'", new)
assert n2 == 1, "applicationId pattern not found in app gradle file"
# versionName: insert into defaultConfig right after applicationId. If the
# Flutter Gradle plugin later overrides it from pubspec, the in-app
# displayed version (set by strip_apple_features.py) is still 1.0.0A.
if "versionName" not in new:
    new = new.replace(
        'applicationId = "com.andytransport.metro"',
        'applicationId = "com.andytransport.metro"\n        versionName = "1.0.0test3"',
        1,
    )
gradle.write_text(new, encoding="utf-8")

# Disable R8 minify/shrink for release. R8 ran on the scaffolded project
# and, combined with the MainActivity package mismatch below, stripped the
# launcher activity and most of the Flutter embedding out of the APK
# (builds #3-#6: installs fine, crashes instantly, no UI). Even with the
# package fixed, this sideloaded app gains nothing from shrinking.
if "isMinifyEnabled" not in new and gradle.suffix == ".kts":
    pat = 'signingConfig = signingConfigs.getByName("debug")'
    if pat in new:
        new = new.replace(
            pat,
            pat + "\n            isMinifyEnabled = false\n            isShrinkResources = false",
            1,
        )
        gradle.write_text(new, encoding="utf-8")
        print("patch_android: release minify/shrink disabled")

manifest = root / "app" / "src" / "main" / "AndroidManifest.xml"
mtext = manifest.read_text(encoding="utf-8")
queries = (
    "    <queries>\n"
    '        <intent><action android:name="android.intent.action.VIEW"/>\n'
    '        <data android:scheme="mimarket"/></intent>\n'
    '        <intent><action android:name="android.intent.action.VIEW"/>\n'
    '        <data android:scheme="oppomarket"/></intent>\n'
    '        <intent><action android:name="android.intent.action.VIEW"/>\n'
    '        <data android:scheme="vivomarket"/></intent>\n'
    '        <intent><action android:name="android.intent.action.VIEW"/>\n'
    '        <data android:scheme="market"/></intent>\n'
    "    </queries>\n"
)
if "mimarket" not in mtext:
    # The flutter scaffold already ships a <queries> block (PROCESS_TEXT),
    # so guard on the scheme itself; a second <queries> element is legal
    # and the manifest merger unions them.
    mtext = mtext.replace("<application", queries + "    <application", 1)
mtext, n3 = re.subn(r'android:label="[^"]*"', 'android:label="城轨通"', mtext)
assert n3 == 1, "android:label pattern not found in manifest"
perms = (
    '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>\n'
    '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>\n'
)
if "ACCESS_FINE_LOCATION" not in mtext:
    mtext = mtext.replace("<application", perms + "    <application", 1)
manifest.write_text(mtext, encoding="utf-8")
print("patch_android: applicationId, label and permissions set")

# --- MainActivity package fix (THE launch-crash root cause) ---
# flutter create --org com.andytransport generates MainActivity.kt under
# package com.andytransport.subway_tools, but namespace/applicationId were
# rewritten to com.andytransport.metro above, so the merged manifest's
# ".MainActivity" expands to com.andytransport.metro.MainActivity - a class
# that does not exist. R8 then treats the real MainActivity (and the
# embedding it alone references) as dead code and strips it: the shipped
# APKs contained NO MainActivity and NO FlutterActivity at all, so Android
# died with ClassNotFound the instant the launcher was tapped.
kt_root = root / "app" / "src" / "main" / "kotlin"
found = list(kt_root.rglob("MainActivity.kt"))
assert len(found) == 1, f"expected exactly 1 MainActivity.kt, found {found}"
src = found[0]
ktext = src.read_text(encoding="utf-8")
ktext, n_pkg = re.subn(
    r"^package\s+\S+", "package com.andytransport.metro", ktext, count=1, flags=re.M
)
assert n_pkg == 1, "MainActivity package line not rewritten"
dest_dir = kt_root / "com" / "andytransport" / "metro"
dest_dir.mkdir(parents=True, exist_ok=True)
dest = dest_dir / "MainActivity.kt"
dest.write_text(ktext, encoding="utf-8")
if dest.resolve() != src.resolve():
    src.unlink()
print("patch_android: MainActivity moved to com.andytransport.metro")
