#!/usr/bin/env python3
"""Patch the flutter-create generated Android project (CI scaffold step).

- applicationId / namespace -> com.andytransport.metro (matches the iOS
  bundle id; Android and iOS namespaces are independent)
- app label -> "Subway tools"
- versionName -> "1.0.0A" (the letter-suffix version the user uses, same
  style as iOS 1.1.0B; pubspec keeps the semver core 1.0.0+1)
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
mtext, n3 = re.subn(r'android:label="[^"]*"', 'android:label="Subway tools"', mtext)
assert n3 == 1, "android:label pattern not found in manifest"
perms = (
    '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>\n'
    '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>\n'
)
if "ACCESS_FINE_LOCATION" not in mtext:
    mtext = mtext.replace("<application", perms + "    <application", 1)
manifest.write_text(mtext, encoding="utf-8")
print("patch_android: applicationId, label and permissions set")
