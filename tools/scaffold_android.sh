#!/bin/bash
# Generate the android/ platform folder with flutter create in CI.
#
# The generated folder contains binary files (gradle wrapper jar, icon
# PNGs) that are never committed; generating it here keeps the repo
# text-only and always in sync with the Flutter version in use. Our own
# lib/ and pubspec.yaml are moved aside first and restored afterwards,
# because flutter create would otherwise overwrite lib/main.dart.
set -e
cd "$(dirname "$0")/.."

mv lib /tmp/app-lib
mv pubspec.yaml /tmp/app-pubspec.yaml
flutter create --platforms=android --project-name subway_tools --org com.andytransport .
rm -rf lib
mv /tmp/app-lib lib
mv /tmp/app-pubspec.yaml pubspec.yaml
python3 tools/patch_android.py
