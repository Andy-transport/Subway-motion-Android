// Subway tools - Android (Flutter shell).
//
// The app is a full-screen WebView over the same offline web core as
// the iOS app (Andy-transport/Subway-motion, web/template.html built
// by web/build_offline.py). CI clones that repo's test branch, builds
// the self-contained offline page and drops it into assets/web/ (see
// tools/prepare_web.sh); the Android packaging strips the Apple-only
// features and the Structure tab (tools/strip_apple_features.py).
//
// WebView engine: the OFFICIAL webview_flutter. History (all verified
// on the user's phones, 2026-11-22): flutter_inappwebview's platform
// view never attached - onWebViewCreated never fired in hybrid or
// virtual-display mode, with Impeller on or off, on two devices,
// while plain Flutter widgets rendered fine; its localhost server
// start() also hangs on device. webview_flutter created, navigated
// and painted on the same devices in the same build, so the shell was
// rebuilt on it. Renderer: Impeller is enabled (Flutter default) at
// the user's request since the 2026-11-22 load-reduction round - see
// tools/patch_android.py for how to fall back to Skia if the WebView
// ever shows black/white on device.
//
// The page is loaded with loadFlutterAsset, which serves it from the
// appassets origin: localStorage persists and the page's relative
// fetch('trains.json') is served from the bundled assets too.
//
// Native bridge: the web page detects the iOS shell through
// window.webkit.messageHandlers.cityMenu. Android deliberately does
// NOT provide cityMenu, so the page stays in its own-UI mode (web city
// menu, web search, web settings). The packaging step bakes a small
// shim into the page (tools/strip_apple_features.py) that defines
// window._metroSystemLang / window._metroIsPad and forwards four
// webkit handlers plus the 'openStore' callHandler to JavaScript
// channels of the same names registered below:
//   tabChanged  -> keep the Flutter glass tab bar in sync
//   cityChanged -> tint the glass bar with the current city's colour
//   themeState  -> switch the glass bar between light / dark glass
//   langChanged -> relabel the glass bar (zh-Hans / zh-Hant / en)
//   openStore   -> open a transit app in the phone's own app store
// Siri / Apple Intelligence: the Android build strips the Siri
// Shortcuts settings row and sub-page from the web page at packaging
// time, and no addShortcut channel exists here.

import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'native_map.dart';
import 'tab_icons.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SubwayToolsApp());
}

class SubwayToolsApp extends StatelessWidget {
  const SubwayToolsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Subway tools',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

class _TabSpec {
  const _TabSpec(this.key, this.iconKey, this.labels);
  final String key;
  // Key into tabIconBytes (lib/tab_icons.dart): the iOS bar's own
  // glyphs, at the user's request (2026-11-23).
  final String iconKey;
  // [zh-Hans, zh-Hant, en] - same wording as the web tab bar.
  final List<String> labels;
}

const List<_TabSpec> _tabs = [
  _TabSpec('transfer', 'transfer', ['换乘', '換乘', 'Transfer']),
  _TabSpec('map', 'map', ['线路图', '線路圖', 'Map']),
  _TabSpec('stations', 'search', ['车站', '車站', 'Stations']),
  _TabSpec('timetable', 'timetable', ['时刻表', '時刻表', 'Timetable']),
  // No Structure tab on Android (user, 2026-11-22): the iOS test
  // version has it, but Android stays at five tabs; the structure
  // panel and its image data are stripped from the page at packaging
  // time (tools/strip_apple_features.py).
  _TabSpec('more', 'settings', ['更多', '更多', 'More']),
];

// City theme colours (same values as the web core per-city themes).
/// City display names for the native map's capsule replica,
/// [zh-Hans, zh-Hant, English] like the tab labels.
const Map<String, List<String>> _cityNames = {
  'bj': ['北京', '北京', 'Beijing'],
  'sy': ['沈阳', '瀋陽', 'Shenyang'],
  'sh': ['上海', '上海', 'Shanghai'],
  'hb': ['哈尔滨', '哈爾濱', 'Harbin'],
  'dl': ['大连', '大連', 'Dalian'],
  'jh': ['金华', '金華', 'Jinhua'],
  'cz': ['常州', '常州', 'Changzhou'],
  'cq': ['重庆', '重慶', 'Chongqing'],
  'cc': ['长春', '長春', 'Changchun'],
  'sz': ['深圳', '深圳', 'Shenzhen'],
  'cd': ['成都', '成都', 'Chengdu'],
  'qd': ['青岛', '青島', 'Qingdao'],
  'sjz': ['石家庄', '石家莊', 'Shijiazhuang'],
  'tj': ['天津', '天津', 'Tianjin'],
  'wx': ['无锡', '無錫', 'Wuxi'],
};

const List<String> _searchLabels = ['搜车站', '搜車站', 'Search stations'];
const List<String> _startLabels = ['设为起点', '設為起點', 'Set as start'];
const List<String> _destLabels = ['设为终点', '設為終點', 'Set as destination'];

const Map<String, Color> _cityAccents = {
  'bj': Color(0xFF003380),
  'sy': Color(0xFFD4B686),
  'sh': Color(0xFFE60012),
  'hb': Color(0xFFC00030),
  'dl': Color(0xFF0D579A),
  'jh': Color(0xFFD8273D),
  'cz': Color(0xFF0D579A),
  'cq': Color(0xFF007A5E),
  'cc': Color(0xFFE50011),
  'sz': Color(0xFF00A051),
  'cd': Color(0xFF00A3A3),
  'qd': Color(0xFF317C5B),
  'sjz': Color(0xFFE53E30),
  'tj': Color(0xFFCB333B), // 天津 (.tj-theme accent in template.html)
  'wx': Color(0xFFEE2737), // 无锡 (.wx-theme accent in template.html)
};

// Transit-app store jump: the web page's openTransitApp() knows each
// city's transit app by its Apple App Store id; the Android build
// patches its fallback to call the shell's 'openStore' handler with
// that id (tools/strip_apple_features.py). Apple id -> Android
// package name. Every package name was verified against a real store
// / listing page on 2026-11-20 (Xiaomi store, APKPure, 360, listing
// mirrors) - do not add or change one without a source. Chengdu note:
// cderg.cocc.cocc_cdids is the official 成都地铁; com.zhongren.
// metrochengdu is a third-party app.
const Map<String, String> _transitPackages = {
  '1071038870': 'cn.com.bmac.nfc', // 北京一卡通
  '1441271928': 'com.nsmetro.shengjingtong', // 盛京通
  '1202750238': 'com.app.shanghai.metro', // Metro大都会
  '1448467024': 'com.bm.nfccitycard', // 哈尔滨城市通
  '1383655806': 'com.dlmetro.app', // 大连交通e出行
  '6503238645': 'com.bwton.msx.jinhuametro', // 任我行 (金华)
  '1474201266': 'com.bwton.msx.czb', // 常州地铁
  '1491110313': 'com.bwton.msx.cqb', // 渝畅行
  '1481796811': 'com.bwton.msx.ccb', // 长春E出行
  '848926994': 'com.iss.shenzhenmetro', // 深圳地铁
  '1303414976': 'cderg.cocc.cocc_cdids', // 成都地铁
  '1373547573': 'com.sdjictec.qdmetro', // 青岛地铁
  '6444716093': 'com.bwton.sjzmetro', // 石慧行（石家庄）
};

String _systemLangCode() {
  final locale = PlatformDispatcher.instance.locale;
  if (locale.languageCode == 'zh') {
    return locale.scriptCode == 'Hant' ? 'zh-Hant' : 'zh-Hans';
  }
  if (locale.languageCode == 'en') return 'en';
  return 'zh-Hans';
}

// The baked page shim JSON-encodes every bridged message; decode it
// back, falling back to the raw string for non-JSON senders.
Object? _decodeMessage(String message) {
  try {
    return jsonDecode(message);
  } catch (_) {
    return message;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final WebViewController _web;
  String _tab = 'map'; // the web page opens on the map, same as iOS
  bool _dark = false;
  String _lang = _systemLangCode();
  Color _accent = _cityAccents['bj']!;
  bool _loaded = false;
  String? _loadError;
  String _city = 'bj';
  // Beijing has two maps (track layout / schematic); the page owns
  // the choice (More page, persisted) and the shim reports it on the
  // mapState channel. Other cities have a single map.
  String _bjMapType = 'track';
  Map<String, MapAsset>? _mapAssets;

  // The page resolves its "system" theme from the WebView's
  // prefers-color-scheme, which an Android WebView derives from the
  // host app theme - the Flutter scaffold theme is not night-aware,
  // so it reports light forever. The baked-in shim replaces that
  // query with a controllable one; the shell pushes the real
  // platform brightness here (user 2026-11-24: adapt light/dark).
  void _pushSystemDark() {
    final dark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    unawaited(
      _web
          .runJavaScript(
            'window._metroSetSystemDark && '
            'window._metroSetSystemDark(${dark ? 'true' : 'false'})',
          )
          .catchError((Object _) {}),
    );
  }

  @override
  void didChangePlatformBrightness() {
    _pushSystemDark();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // The map's pinch zoom is handled inside the page (svg-pan-zoom).
      // Leaving the WebView's own zoom enabled makes the two fight
      // over every pinch, which felt laggy on device (2026-11-22).
      ..enableZoom(false)
      ..setBackgroundColor(const Color(0xFF0C0F16))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _pushSystemDark();
          },
          onPageFinished: (url) {
            _pushSystemDark();
            if (!_loaded || _loadError != null) {
              setState(() {
                _loaded = true;
                _loadError = null;
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) {
              setState(() => _loadError = error.description);
            }
          },
        ),
      )
      ..addJavaScriptChannel(
        'tabChanged',
        onMessageReceived: (message) {
          final key = _decodeMessage(message.message);
          if (key is String &&
              _tabs.any((t) => t.key == key) &&
              key != _tab) {
            setState(() => _tab = key);
          }
        },
      )
      ..addJavaScriptChannel(
        'cityChanged',
        onMessageReceived: (message) {
          final v = _decodeMessage(message.message);
          if (v is Map) {
            final c = v['city'];
            if (c is String && c != _city) {
              setState(() => _city = c);
            }
            final accent = _cityAccents[v['city']];
            if (accent != null && accent != _accent) {
              setState(() => _accent = accent);
            }
          }
        },
      )
      ..addJavaScriptChannel(
        'mapState',
        onMessageReceived: (message) {
          final v = _decodeMessage(message.message);
          if (v is Map) {
            final t = v['bjType'];
            if (t is String &&
                (t == 'track' || t == 'line') &&
                t != _bjMapType) {
              setState(() => _bjMapType = t);
            }
          }
        },
      )
      ..addJavaScriptChannel(
        'themeState',
        onMessageReceived: (message) {
          final v = _decodeMessage(message.message);
          if (v is Map) {
            final d = v['dark'];
            if (d is bool && d != _dark) {
              setState(() => _dark = d);
            }
          }
        },
      )
      ..addJavaScriptChannel(
        'langChanged',
        onMessageReceived: (message) {
          final v = _decodeMessage(message.message);
          if (v is Map) {
            var l = v['lang'];
            if (l == 'system' || l == null) l = _systemLangCode();
            if (l is String &&
                ['zh-Hans', 'zh-Hant', 'en'].contains(l) &&
                l != _lang) {
              setState(() => _lang = l);
            }
          }
        },
      )
      ..addJavaScriptChannel(
        'openStore',
        onMessageReceived: (message) {
          final v = _decodeMessage(message.message);
          _openStore(v.toString());
        },
      );
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      platform.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (request) async {
          final status = await Permission.location.request();
          return GeolocationPermissionsResponse(
            allow: status.isGranted,
            retain: false,
          );
        },
      );
      // File inputs (the profile page's avatar picker) do nothing in
      // webview_flutter unless the shell answers the file selector;
      // route it to the system picker via file_picker.
      platform.setOnShowFileSelector((params) async {
        final wantImage = params.acceptTypes.any(
          (t) => t.startsWith('image'),
        );
        final result = await FilePicker.platform.pickFiles(
          type: wantImage ? FileType.image : FileType.any,
          allowMultiple: params.mode == FileSelectorMode.openMultiple,
        );
        // The plugin's callback type is Future<List<String>> (not
        // nullable): an empty list is the cancel signal.
        if (result == null) return <String>[];
        final uris = <String>[];
        for (final file in result.files) {
          final path = file.path;
          if (path != null) uris.add(Uri.file(path).toString());
        }
        return uris;
      });
    }
    _web.loadFlutterAsset('assets/web/index.html');
    unawaited(_loadMapAssets());
  }

  // Native map rasters (assets/maps/, rendered from the same source
  // SVGs as the web maps). A missing or unreadable manifest simply
  // leaves the native map off; the web map remains as the fallback.
  Future<void> _loadMapAssets() async {
    try {
      final raw = await rootBundle.loadString('assets/maps/maps.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final out = <String, MapAsset>{};
        decoded.forEach((k, v) {
          final a = MapAsset.fromJson(v);
          if (a != null) out[k.toString()] = a;
        });
        if (mounted && out.isNotEmpty) setState(() => _mapAssets = out);
      }
    } catch (_) {
      // No native maps in this build; nothing to do.
    }
  }

  String get _mapKey =>
      _city == 'bj' ? (_bjMapType == 'line' ? 'bj-line' : 'bj-track') : _city;

  Future<String?> _nativeMapTap(double x, double y, double rz) async {
    try {
      final r = await _web.runJavaScriptReturningResult(
        'JSON.stringify(window.metroApp && window.metroApp.mapTapAt ? '
        'window.metroApp.mapTapAt(${x.toStringAsFixed(1)}, '
        '${y.toStringAsFixed(1)}, ${rz.toStringAsFixed(3)}) : null)',
      );
      final v = _decodeMessage(r.toString());
      return v is String ? v : null;
    } catch (_) {
      return null;
    }
  }

  int get _langIndex => _lang == 'zh-Hant' ? 1 : (_lang == 'en' ? 2 : 0);

  // Composition mode history (all on-device, 2026-11-22): builds up
  // to #24 used TLHC (displayWithHybridComposition: false). Two
  // separate symptoms were traced to that path: (1) page scrolling
  // dead - fixed by the EagerGestureRecognizer below, which applies
  // in both modes; (2) map pinch/pan still "特别卡" on #24 - the
  // page coalesces transforms to one per frame, so the cost is
  // rasterising the multi-MB SVG per frame plus TLHC's texture
  // round-trip. Build #25 switches to full Hybrid Composition so
  // the WebView renders to its own surface (see the inline comment
  // at the parameter). Awaiting the user's on-device comparison.
  Widget _buildWebView() {
    final controllerPlatform = _web.platform;
    if (controllerPlatform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: controllerPlatform,
          // Hybrid Composition (2026-11-22, on-device report on
          // 1.0.4beta: map pinch/pan "特别卡"). The page already
          // coalesces pan/zoom to one transform per animation frame;
          // the cost is rasterising the multi-MB city SVG every frame.
          // Under TLHC each of those frames also makes a texture
          // round-trip through Flutter's compositor, which is the
          // bottleneck for full-screen continuous animation. HC gives
          // the WebView its own Android surface, so frames go straight
          // to SurfaceFlinger. The tab bar / chips are Flutter widgets
          // composited above the surface, which HC supports.
          displayWithHybridComposition: true,
          // Input fix (2026-11-22, on-device report on 1.0.4beta:
          // the transfer results screen would not scroll - taps worked,
          // drags never reached the WebView's own scroller). In TLHC
          // the platform view only receives a pointer sequence after
          // the gesture arena settles; with no recognizers registered
          // the WebView lost vertical drags, so the page's fixed
          // overflow scrollers never moved. An EagerGestureRecognizer
          // makes the WebView claim every pointer that starts on it
          // immediately, restoring native in-page scrolling. The tab
          // bar and top chips are separate widgets above the WebView,
          // so pointers starting on them are unaffected.
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        ),
      );
    }
    return WebViewWidget(controller: _web);
  }

  Future<void> _setTab(String key) async {
    setState(() => _tab = key);
    await _web.runJavaScript(
      "window.metroApp && window.metroApp.setTab('$key')",
    );
  }

  // Swipe the tab bar sideways to switch pages (user 2026-11-24).
  // The drag recognizer sits on the bar itself; item taps keep
  // working because the arena only hands the gesture to the drag
  // once it moves horizontally past the touch slop. Swipe left goes
  // to the next tab, right to the previous, clamped at both ends.
  double _tabDragDx = 0;

  void _onTabBarDragUpdate(DragUpdateDetails d) {
    _tabDragDx += d.delta.dx;
  }

  void _onTabBarDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    var dir = 0;
    if (_tabDragDx <= -40 || v <= -300) {
      dir = 1;
    } else if (_tabDragDx >= 40 || v >= 300) {
      dir = -1;
    }
    _tabDragDx = 0;
    if (dir == 0 || !_loaded || _loadError != null) return;
    final i = _tabs.indexWhere((t) => t.key == _tab);
    if (i < 0) return;
    final j = (i + dir).clamp(0, _tabs.length - 1);
    if (j != i) unawaited(_setTab(_tabs[j].key));
  }

  void _onTabBarDragCancel() {
    _tabDragDx = 0;
  }

  // Open the transit app (by Apple id from the web page) in this
  // phone's own app store: Xiaomi -> mimarket://, OPPO ->
  // oppomarket:// (its parameter is `packagename`, not `id`), vivo ->
  // vivomarket://, any other brand -> the generic market:// intent,
  // which the phone's default store answers. If the vendor scheme
  // fails, fall back to the generic market intent, then to the app's
  // 应用宝 web page.
  Future<void> _openStore(String appleId) async {
    final pkg = _transitPackages[appleId];
    if (pkg == null) return;
    var brand = '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      brand = '${info.brand} ${info.manufacturer}'.toLowerCase();
    } catch (_) {}
    final candidates = <String>[];
    if (brand.contains('xiaomi') ||
        brand.contains('redmi') ||
        brand.contains('poco')) {
      candidates.add('mimarket://details?id=$pkg');
    } else if (brand.contains('oppo') ||
        brand.contains('realme') ||
        brand.contains('oneplus')) {
      candidates.add('oppomarket://details?packagename=$pkg');
    } else if (brand.contains('vivo') || brand.contains('iqoo')) {
      candidates.add('vivomarket://details?id=$pkg');
    }
    candidates.add('market://details?id=$pkg');
    for (final url in candidates) {
      try {
        if (await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        )) {
          return;
        }
      } catch (_) {}
    }
    try {
      await launchUrl(
        Uri.parse('https://sj.qq.com/appdetail/$pkg'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  Future<bool> _handleBack() async {
    try {
      final handled = await _web.runJavaScriptReturningResult(
        'window.metroApp ? window.metroApp.goBack() : false',
      );
      return handled == true || handled == 'true';
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final systemDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    final dark = _dark || (systemDark && !_loaded);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (!await _handleBack()) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        // Page background colour: visible only in the status-bar
        // strip (below) and while the page loads.
        backgroundColor: dark ? const Color(0xFF0C0F16) : Colors.white,
        body: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          ),
          child: Stack(
            children: [
              // The WebView starts BELOW the system status bar
              // (2026-11-23, user's screenshot: '和状态栏冲突'). The
              // web core positions its top UI with
              // env(safe-area-inset-top), which is always 0 in an
              // Android WebView, so the page's header row (city
              // capsule + search pill) slid under the status bar and
              // collided with the clock/icons. iOS reports the real
              // inset to WKWebView; on Android the shell insets the
              // view instead - same visual result. The strip above
              // shows the Scaffold's page-coloured background and the
              // status icons take the matching brightness.
              Positioned(
                left: 0,
                right: 0,
                top: MediaQuery.of(context).padding.top,
                bottom: 0,
                child: _buildWebView(),
              ),
              // Native map (route 2, user 2026-11-24): on the map tab
              // a platform-rendered raster covers the WebView's own
              // vector map, whose per-frame re-rasterization is the
              // map lag. Taps and endpoint picks proxy into the page,
              // so planning behaviour is unchanged. Falls back to the
              // web map whenever no raster exists for the city.
              if (_loaded &&
                  _loadError == null &&
                  _tab == 'map' &&
                  _mapAssets != null &&
                  _mapAssets![_mapKey] != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: MediaQuery.of(context).padding.top,
                  bottom: 0,
                  child: NativeMapView(
                    key: ValueKey('nativemap-$_mapKey'),
                    asset: _mapAssets![_mapKey]!,
                    dark: dark,
                    accent: _accent,
                    cityLabel:
                        (_cityNames[_city] ?? _cityNames['bj']!)[_langIndex],
                    searchLabel: _searchLabels[_langIndex],
                    startLabel: _startLabels[_langIndex],
                    destLabel: _destLabels[_langIndex],
                    onCapsuleTap: () => unawaited(
                      _web.runJavaScript(
                        'window.metroApp && window.metroApp.showCityMenu()',
                      ),
                    ),
                    onSearchTap: () => unawaited(
                      _web.runJavaScript(
                        'window.metroApp && window.metroApp.openStations()',
                      ),
                    ),
                    onTapSvg: _nativeMapTap,
                    onSetEndpoint: (which) => unawaited(
                      _web.runJavaScript(
                        "window.metroApp && window.metroApp.mapSetEndpoint('$which')",
                      ),
                    ),
                    onDismissCard: () => unawaited(
                      _web.runJavaScript(
                        'window.metroApp && (window.metroApp.mapCard = null)',
                      ),
                    ),
                  ),
                ),
            if (!_loaded && _loadError == null)
              const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              ),
            // Shown only if the main frame fails to load: the error
            // text and a retry button, instead of an endless spinner.
            if (_loadError != null)
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.all(16),
                  color: const Color(0xCC000000),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '页面加载失败',
                        style: TextStyle(color: Colors.amber, fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _loadError!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _loadError = null;
                            _loaded = false;
                          });
                          _web.loadFlutterAsset('assets/web/index.html');
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onHorizontalDragUpdate: _onTabBarDragUpdate,
                  onHorizontalDragEnd: _onTabBarDragEnd,
                  onHorizontalDragCancel: _onTabBarDragCancel,
                  child: _GlassTabBar(
                    tabs: _tabs,
                    current: _tab,
                    langIndex: _langIndex,
                    dark: dark,
                    accent: _accent,
                    onTap: _setTab,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating Liquid-Glass-style tab bar.
///
/// Android has no system Liquid Glass (that material is Apple's), so
/// this reproduces its look with Flutter's compositor: a capsule
/// floating over the content, real-time backdrop blur + saturation, a
/// translucent tint, a bright top edge highlight and a soft drop
/// shadow. What it cannot do is Apple's edge refraction (lensing) -
/// the blur approximation is what every Android glassmorphism
/// implementation uses.
class _GlassTabBar extends StatelessWidget {
  const _GlassTabBar({
    required this.tabs,
    required this.current,
    required this.langIndex,
    required this.dark,
    required this.accent,
    required this.onTap,
  });

  final List<_TabSpec> tabs;
  final String current;
  final int langIndex;
  final bool dark;
  final Color accent;
  final void Function(String key) onTap;

  @override
  Widget build(BuildContext context) {
    final tint = dark ? const Color(0xFF1C1C1E) : Colors.white;
    final labelColor = dark ? Colors.white70 : Colors.black54;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.45 : 0.22),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          // Load reduction (2026-11-22): no BackdropFilter here. The
          // live blur re-sampled the WebView backdrop on every frame
          // the map moved - a steady GPU tax that contributed to the
          // freeze on the user's low-end phone. A near-opaque
          // translucent fill keeps the floating-bar look at a
          // fraction of the cost.
          child: Container(
              height: 62,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Colors.white.withValues(alpha: dark ? 0.22 : 0.55),
                  width: 1,
                ),
              ),
              child: Stack(
                children: [
                  // Specular top edge - the bright rim that sells the
                  // glass look.
                  Positioned(
                    top: 0,
                    left: 24,
                    right: 24,
                    child: Container(
                      height: 1.2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0),
                            Colors.white.withValues(alpha: dark ? 0.35 : 0.8),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (final tab in tabs)
                        Expanded(
                          child: _GlassTabItem(
                            spec: tab,
                            label: tab.labels[langIndex],
                            selected: tab.key == current,
                            accent: accent,
                            labelColor: labelColor,
                            onTap: () => onTap(tab.key),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ),
      ),
    );
  }
}

class _GlassTabItem extends StatelessWidget {
  const _GlassTabItem({
    required this.spec,
    required this.label,
    required this.selected,
    required this.accent,
    required this.labelColor,
    required this.onTap,
  });

  final _TabSpec spec;
  final String label;
  final bool selected;
  final Color accent;
  final Color labelColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? accent : labelColor;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.memory(
              tabIconBytes[spec.iconKey]!,
              width: 24,
              height: 24,
              color: color,
              colorBlendMode: BlendMode.srcIn,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
