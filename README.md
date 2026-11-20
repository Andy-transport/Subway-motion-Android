# Subway tools — Android

Flutter Android version of Subway tools (the iOS version lives in
[Andy-transport/Subway-motion](https://github.com/Andy-transport/Subway-motion)).

## How it works

- The app itself is a thin Flutter shell: a full-screen WebView plus a
  floating **Liquid-Glass-style tab bar** built in Flutter (backdrop blur +
  saturation, translucent tint, specular top edge, soft shadow). Apple's
  real Liquid Glass material does not exist on Android; this reproduces
  its look, without the edge refraction.
- All metro functionality (12 cities: Beijing, Shenyang, Shanghai, Harbin,
  Dalian, Jinhua, Changzhou, Chongqing, Changchun, Shenzhen, Chengdu,
  Qingdao — maps, route planning, station search, timetables, fares) comes
  from the **same web core** as iOS. At build time, CI clones
  Subway-motion, runs its `web/build_offline.py` to produce the
  self-contained offline page, and bundles it under `assets/web/`, served
  to the WebView through a localhost server. Web-core updates flow into
  Android automatically on the next build; there is no second copy of the
  data to maintain.
- The web page stays in its own-UI mode on Android (no iOS native bridge):
  web city menu, search and settings are used as-is. Only tab / city /
  theme / language changes are forwarded to tint and relabel the glass
  tab bar.

## Differences from iOS

- **No Siri Shortcuts and no Apple Intelligence entry** — the Siri
  settings row and sub-page are stripped from the web page at packaging
  time (`tools/strip_apple_features.py`); the iOS repo is untouched.
- No native per-city splash, Siri, Live Activities or native settings
  screens. Nearby stations use HTML5 geolocation in the WebView.
- The release APK from CI is signed with the debug key (the Flutter
  template default), which is fine for sideload testing.

## Build

Trigger the **Build Android APK** workflow (Actions → workflow_dispatch).
It scaffolds the `android/` platform folder with `flutter create`
(generated files are not committed), prepares the web assets, and builds
`app-release.apk` as a workflow artifact.

Local equivalents, with Flutter installed:

```bash
bash tools/scaffold_android.sh   # generates android/ and patches it
bash tools/prepare_web.sh        # fills assets/web/ from Subway-motion
flutter pub get
flutter build apk --release
```
