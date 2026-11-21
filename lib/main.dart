import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// DIAGNOSTIC BUILD - not the real app. Bisects the Xiaomi 13 / HyperOS 3.0
// instant-crash: screen 1 is pure Flutter (no WebView is ever created);
// the buttons create a WebView only when tapped.
void main() {
  runApp(const DiagApp());
}

class DiagApp extends StatelessWidget {
  const DiagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '诊断版',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const DiagHome(),
    );
  }
}

class DiagHome extends StatelessWidget {
  const DiagHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('诊断版 - 第一步')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '如果你能看到这一屏，说明纯 Flutter 界面没问题。\n\n'
              '请依次点下面两个按钮，把每个的结果告诉我：是打开了网页，还是点了一闪就退。',
              style: TextStyle(fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WebTestPage(net: true)),
              ),
              child: const Text('测试 1：网页视图打开 example.com'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WebTestPage(net: false)),
              ),
              child: const Text('测试 2：网页视图打开内置地铁页'),
            ),
          ],
        ),
      ),
    );
  }
}

class WebTestPage extends StatelessWidget {
  const WebTestPage({super.key, required this.net});
  final bool net;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(net ? '测试 1：联网页' : '测试 2：内置页')),
      body: InAppWebView(
        initialUrlRequest: net
            ? URLRequest(url: WebUri('https://example.com'))
            : null,
        initialFile: net ? null : 'assets/web/index.html',
        initialSettings: InAppWebViewSettings(
          useHybridComposition: false,
          javaScriptEnabled: true,
        ),
      ),
    );
  }
}
