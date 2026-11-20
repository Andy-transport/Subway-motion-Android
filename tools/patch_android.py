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
        'applicationId = "com.andytransport.metro"\n        versionName = "1.0.0A"',
        1,
    )
gradle.write_text(new, encoding="utf-8")

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
if "<queries>" not in mtext:
    mtext = mtext.replace("<application", queries + "    <application", 1)
mtext, n3 = re.subn(r'android:label="[^"]*"', 'android:label="Subway tools"', mtext)
assert n3 == 1, "android:label pattern not found in manifest"
perms = (
    '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>\n'
    '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>\n'
)
if "ACCESS_FINE_LOCATION" not in mtext:
    mtext = mtext.replace("<application", perms + "    <application", 1)
# Disable Impeller (builds #3/#4 died instantly on the user's Xiaomi 13 /
# HyperOS 3.0 before the first frame; the Skia/OpenGL fallback is the
# standard workaround for Vulkan-driver launch crashes). The meta-data
# belongs inside MainActivity, next to the flutterEmbedding meta-data.
impeller = (
    '\n            <meta-data\n'
    '                android:name="io.flutter.embedding.android.ImpellerEnabled"\n'
    '                android:value="false" />'
)
if "ImpellerEnabled" not in mtext:
    mtext, n4 = re.subn(
        r'(android:name="flutterEmbedding"\s*\n\s*android:value="2"\s*/>)',
        r"\1" + impeller,
        mtext,
    )
    assert n4 == 1, "flutterEmbedding meta-data not found in manifest"
manifest.write_text(mtext, encoding="utf-8")
print("patch_android: applicationId, label and permissions set")
