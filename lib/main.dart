// Subway tools - Android (Flutter shell).
//
// The app is a full-screen WebView over the same offline web core as the
// iOS app (Andy-transport/Subway-motion, web/template.html built by
// web/build_offline.py). CI clones that repo, builds the self-contained
// offline page and drops it into assets/web/ (see tools/prepare_web.sh).
// The page is loaded directly from the bundled assets: it is fully
// self-contained, so no server is needed. A localhost server was tried
// first, but its start() never returns on the user's HyperOS phone
// (verified on device 2026-11-22: 6 s timeout, Future not completed),
// and the old build awaited it in main() before runApp - the app sat
// on the white launch window forever. Do NOT reintroduce a startup
// server await.
//
// Native bridge: the web page detects the iOS shell through
// window.webkit.messageHandlers.cityMenu. Android deliberately does NOT
// provide cityMenu, so the page stays in its own-UI mode (web city menu,
// web search, web settings). Only four handlers are shimmed, each checked
// individually by the page and none of which flips it into iOS mode:
//   tabChanged  -> keep the Flutter glass tab bar in sync
//   cityChanged -> tint the glass bar with the current city's colour
//   themeState  -> switch the glass bar between light / dark glass
//   langChanged -> relabel the glass bar (zh-Hans / zh-Hant / en)
// Siri / Apple Intelligence: the Android build strips the Siri Shortcuts
// settings row and sub-page from the web page at packaging time
// (tools/strip_apple_features.py), and no addShortcut handler exists here.

import 'dart:collection';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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
  const _TabSpec(this.key, this.icon, this.labels);
  final String key;
  final IconData icon;
  // [zh-Hans, zh-Hant, en] - same wording as the web tab bar.
  final List<String> labels;
}

const List<_TabSpec> _tabs = [
  _TabSpec('transfer', Icons.swap_horiz, ['换乘', '換乘', 'Transfer']),
  _TabSpec('map', Icons.map_outlined, ['线路图', '線路圖', 'Map']),
  _TabSpec('stations', Icons.search, ['车站', '車站', 'Stations']),
  _TabSpec('timetable', Icons.schedule, ['时刻表', '時刻表', 'Timetable']),
  // No Structure tab on Android (user, 2026-11-22): the iOS test
  // version has it, but Android stays at five tabs; the structure
  // panel and its image data are stripped from the page at packaging
  // time (tools/strip_apple_features.py, item 5).
  _TabSpec('more', Icons.settings_outlined, ['更多', '更多', 'More']),
];

// City theme colours (same values as the web core per-city themes).
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
};

// Transit-app store jump: the web page's openTransitApp() knows each
// city's transit app by its Apple App Store id; the Android build patches
// its fallback to call the shell's 'openStore' handler with that id
// (tools/strip_apple_features.py). Apple id -> Android package name.
// Every package name was verified against a real store / listing page on
// 2026-11-20 (Xiaomi store, APKPure, 360, listing mirrors) - do not add
// or change one without a source. Chengdu note: cderg.cocc.cocc_cdids is
// the official 成都地铁; com.zhongren.metrochengdu is a third-party app.
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  InAppWebViewController? _web;
  String _tab = 'map'; // the web page opens on the map, same as iOS
  bool _dark = false;
  String _lang = _systemLangCode();
  Color _accent = _cityAccents['bj']!;
  bool _loaded = false;

  // --- White-screen diagnostics (temporary build, round 3) ---
  // Round 1: the localhost server start() hangs on device. Round 2:
  // file mode + virtual display - onWebViewCreated STILL never fired,
  // on two devices, while plain Flutter widgets render and respond
  // fine. So the platform view itself never attaches. Round 3 crosses
  // the remaining suspects in one build: Impeller is disabled in the
  // manifest (Skia fallback), strip B is a minimal flutter_inappwebview
  // (default settings, no user scripts, plain https URL), strip C is
  // the official webview_flutter. Every step is written to an
  // on-screen log so the outcome names the culprit.
  final List<String> _diag = <String>[];
  late final WebViewController _testC;

  void _log(String msg) {
    final now = DateTime.now();
    final ts =
        '${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    _diag.add('$ts $msg');
    if (_diag.length > 14) _diag.removeAt(0);
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _log('app started - diagnostic build 3 (Impeller off, A/B/C test)');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _log('first frame rendered');
    });
    // Test C controller (official webview_flutter), example.com only.
    _testC = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => _log('C: official page started'),
          onPageFinished: (url) => _log('C: official LOADED'),
          onWebResourceError: (e) =>
              _log('C: official error: ${e.description}'),
        ),
      )
      ..loadRequest(Uri.parse('https://example.com'));
    _log('C: official controller created (dart side)');
  }

  int get _langIndex => _lang == 'zh-Hant' ? 1 : (_lang == 'en' ? 2 : 0);

  // Injected before the page's own scripts run (document start): system
  // language for the page's savedLang(), and the webkit handler shims.
  // NOTE: no cityMenu handler on purpose - see the header comment.
  String get _shimSource {
    final lang = _systemLangCode();
    return '''
window._metroSystemLang = '$lang';
window._metroIsPad = false;
window.webkit = window.webkit || {};
window.webkit.messageHandlers = window.webkit.messageHandlers || {};
(function () {
  function forward(name) {
    return { postMessage: function (m) {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler(name, m);
      }
    } };
  }
  window.webkit.messageHandlers.tabChanged = forward('tabChanged');
  window.webkit.messageHandlers.cityChanged = forward('cityChanged');
  window.webkit.messageHandlers.themeState = forward('themeState');
  window.webkit.messageHandlers.langChanged = forward('langChanged');
})();
''';
  }

  Future<void> _setTab(String key) async {
    setState(() => _tab = key);
    await _web?.evaluateJavascript(
      source: "window.metroApp && window.metroApp.setTab('$key')",
    );
  }

  // Open the transit app (by Apple id from the web page) in this phone's
  // own app store: Xiaomi -> mimarket://, OPPO -> oppomarket:// (its
  // parameter is `packagename`, not `id`), vivo -> vivomarket://, any
  // other brand -> the generic market:// intent, which the phone's
  // default store answers. If the vendor scheme fails, fall back to the
  // generic market intent, then to the app's 应用宝 web page.
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
    final web = _web;
    if (web == null) return false;
    try {
      final handled = await web.evaluateJavascript(
        source: 'window.metroApp ? window.metroApp.goBack() : false',
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
        // Same near-black as the iOS shell: nothing white flashes at the
        // edges or while the page loads.
        backgroundColor: const Color(0xFF0C0F16),
        body: Stack(
          children: [
            Positioned.fill(
              child: InAppWebView(
              initialFile: 'assets/web/index.html',
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: _shimSource,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                geolocationEnabled: true,
                // Virtual display: hybrid composition never created the
                // WebView on the user's HyperOS phone (round 1 log had
                // no 'webview created' line at all).
                useHybridComposition: false,
                supportZoom: false,
                builtInZoomControls: false,
                displayZoomControls: false,
                mediaPlaybackRequiresUserGesture: false,
                transparentBackground: false,
              ),
              onWebViewCreated: (controller) {
                _web = controller;
                _log('webview created: assets file');
                controller.addJavaScriptHandler(
                  handlerName: 'tabChanged',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is String) {
                      final key = args.first as String;
                      if (_tabs.any((t) => t.key == key) && key != _tab) {
                        setState(() => _tab = key);
                      }
                    }
                    return null;
                  },
                );
                controller.addJavaScriptHandler(
                  handlerName: 'cityChanged',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is Map) {
                      final city = (args.first as Map)['city'];
                      final accent = _cityAccents[city];
                      if (accent != null && accent != _accent) {
                        setState(() => _accent = accent);
                      }
                    }
                    return null;
                  },
                );
                controller.addJavaScriptHandler(
                  handlerName: 'themeState',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is Map) {
                      final d = (args.first as Map)['dark'];
                      if (d is bool && d != _dark) {
                        setState(() => _dark = d);
                      }
                    }
                    return null;
                  },
                );
                controller.addJavaScriptHandler(
                  handlerName: 'openStore',
                  callback: (args) {
                    if (args.isNotEmpty) {
                      _openStore(args.first.toString());
                    }
                    return null;
                  },
                );
                controller.addJavaScriptHandler(
                  handlerName: 'langChanged',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is Map) {
                      var l = (args.first as Map)['lang'];
                      if (l == 'system' || l == null) l = _systemLangCode();
                      if (l is String &&
                          ['zh-Hans', 'zh-Hant', 'en'].contains(l) &&
                          l != _lang) {
                        setState(() => _lang = l);
                      }
                    }
                    return null;
                  },
                );
              },
              onLoadStart: (controller, url) {
                _log('load start: $url');
              },
              onLoadStop: (controller, url) {
                _log('load STOP: $url');
                if (!_loaded) setState(() => _loaded = true);
              },
              onProgressChanged: (controller, progress) {
                if (progress == 25 ||
                    progress == 50 ||
                    progress == 75 ||
                    progress == 100) {
                  _log('progress $progress%');
                }
              },
              onConsoleMessage: (controller, consoleMessage) {
                final m = consoleMessage.message;
                _log(
                  'console: ${m.length > 90 ? m.substring(0, 90) : m}',
                );
              },
              onReceivedHttpError: (controller, request, response) {
                if (request.isForMainFrame ?? false) {
                  _log(
                    'HTTP error ${response.statusCode} for ${request.url}',
                  );
                }
              },
              onGeolocationPermissionsShowPrompt: (controller, origin) async {
                final status = await Permission.location.request();
                return GeolocationPermissionShowPromptResponse(
                  origin: origin,
                  allow: status.isGranted,
                  retain: false,
                );
              },
              onReceivedError: (controller, request, error) {
                _log('load ERROR: ${error.type} - ${error.description}');
              },
              ),
            ),
            if (!_loaded)
              const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _GlassTabBar(
                tabs: _tabs,
                current: _tab,
                langIndex: _langIndex,
                dark: dark,
                accent: _accent,
                onTap: _setTab,
              ),
            ),
            // Round-3 differential test strips (temporary build):
            // B = minimal flutter_inappwebview (default settings, no
            // user scripts, https URL), C = official webview_flutter.
            Positioned(
              left: 8,
              right: 8,
              bottom: 96,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'B: inapp 最简配置测试',
                    style: TextStyle(color: Colors.amber, fontSize: 10),
                  ),
                  SizedBox(
                    height: 92,
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri('https://example.com'),
                      ),
                      onWebViewCreated: (c) =>
                          _log('B: inapp minimal created'),
                      onLoadStop: (c, u) => _log('B: inapp minimal LOADED'),
                      onReceivedError: (c, r, e) =>
                          _log('B: inapp error: ${e.type}'),
                    ),
                  ),
                  const Text(
                    'C: 官方 webview 组件测试',
                    style: TextStyle(color: Colors.amber, fontSize: 10),
                  ),
                  SizedBox(
                    height: 92,
                    child: WebViewWidget(controller: _testC),
                  ),
                ],
              ),
            ),
            // Diagnostic overlay (temporary build): load-path log plus
            // two manual load switches for on-device bisection.
            Positioned(
              left: 8,
              right: 8,
              top: MediaQuery.of(context).padding.top + 8,
              child: Container(
                padding: const EdgeInsets.all(8),
                color: const Color(0xCC000000),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '诊断版 - 页面加载日志',
                      style: TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                    for (final line in _diag)
                      Text(
                        line,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            _log('manual: load assets file');
                            _web?.loadFile(
                              assetFilePath: 'assets/web/index.html',
                            );
                          },
                          child: const Text('文件直载'),
                        ),
                        TextButton(
                          onPressed: () {
                            _log('manual: load example.com');
                            _web?.loadUrl(
                              urlRequest: URLRequest(
                                url: WebUri('https://example.com'),
                              ),
                            );
                          },
                          child: const Text('示例页'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating Liquid-Glass-style tab bar.
///
/// Android has no system Liquid Glass (that material is Apple's), so this
/// reproduces its look with Flutter's compositor: a capsule floating over
/// the content, real-time backdrop blur + saturation, a translucent tint,
/// a bright top edge highlight and a soft drop shadow. What it cannot do
/// is Apple's edge refraction (lensing) - the blur approximation is what
/// every Android glassmorphism implementation uses.
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
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              inner: const ColorFilter.matrix(<double>[
                1.15, 0, 0, 0, 0, //
                0, 1.15, 0, 0, 0, //
                0, 0, 1.15, 0, 0, //
                0, 0, 0, 1, 0, //
              ]),
            ),
            child: Container(
              height: 62,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: dark ? 0.62 : 0.58),
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
            Icon(spec.icon, size: 24, color: color),
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
