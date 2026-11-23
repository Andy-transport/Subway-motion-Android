// Native map view for the map tab (user 2026-11-24, "route 2").
//
// The web page's vector maps re-rasterize on every pan/zoom frame
// inside the WebView, which stays laggy on low-end phones no matter
// how the gesture handling is tuned. This view replaces the map tab
// with a platform-rendered raster: each city's map is rendered ONCE
// from the same source SVG (resvg, white background baked in, WebP)
// and bundled as an asset; gestures then move a single GPU layer
// via InteractiveViewer, like a photo in the gallery app.
//
// Interactivity is preserved through the page itself: a tap is
// converted to SVG coordinates and handed to the page's own
// mapTapAt (nearest-station hit test + card state), and the
// endpoint buttons call the page's mapSetEndpoint, which fills the
// transfer planner and switches tabs exactly like a tap inside the
// web map. The line-pin feature of the page's card is not mirrored
// in v1 (endpoint is set by station, the common case).
//
// Dark mode: the page inverts its SVG with the CSS filter
// invert(1) hue-rotate(180deg); the same transform is applied to
// the raster with the equivalent colour matrix.

import 'dart:async';

import 'package:flutter/material.dart';

class MapAsset {
  const MapAsset({
    required this.file,
    required this.vb,
    required this.px,
  });

  final String file;

  /// SVG viewBox: [x, y, width, height] in map coordinates.
  final List<double> vb;

  /// Raster size in pixels: [width, height].
  final List<int> px;

  static MapAsset? fromJson(Object? v) {
    if (v is! Map) return null;
    final file = v['file'];
    final vbRaw = v['vb'];
    final pxRaw = v['px'];
    if (file is! String || vbRaw is! List || pxRaw is! List) return null;
    if (vbRaw.length != 4 || pxRaw.length != 2) return null;
    return MapAsset(
      file: file,
      vb: vbRaw.map((e) => (e as num).toDouble()).toList(),
      px: pxRaw.map((e) => (e as num).toInt()).toList(),
    );
  }
}

/// invert(1) hue-rotate(180deg) as a colour matrix (offsets in
/// 0..255, as Flutter's ColorFilter.matrix expects). Keeps hues
/// while flipping lightness, matching the page's dark-mode map.
const List<double> kDarkMapMatrix = <double>[
  0.574, -1.430, -0.144, 0, 255,
  -0.426, -0.430, -0.144, 0, 255,
  -0.426, -1.430, 0.856, 0, 255,
  0, 0, 0, 1, 0,
];

class NativeMapView extends StatefulWidget {
  const NativeMapView({
    super.key,
    required this.asset,
    required this.dark,
    required this.accent,
    required this.cityLabel,
    required this.searchLabel,
    required this.startLabel,
    required this.destLabel,
    required this.onCapsuleTap,
    required this.onSearchTap,
    required this.onTapSvg,
    required this.onSetEndpoint,
    required this.onDismissCard,
  });

  final MapAsset asset;
  final bool dark;
  final Color accent;
  final String cityLabel;
  final String searchLabel;
  final String startLabel;
  final String destLabel;
  final VoidCallback onCapsuleTap;
  final VoidCallback onSearchTap;

  /// Returns the tapped station's name, or null for empty space.
  final Future<String?> Function(double svgX, double svgY, double rz)
      onTapSvg;
  final void Function(String which) onSetEndpoint;
  final VoidCallback onDismissCard;

  @override
  State<NativeMapView> createState() => _NativeMapViewState();
}

class _NativeMapViewState extends State<NativeMapView> {
  final TransformationController _tc = TransformationController();
  double _fit = 0;
  String? _stationName;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _ensureFit(Size viewport) {
    if (_fit > 0) return;
    final pxW = widget.asset.px[0].toDouble();
    final pxH = widget.asset.px[1].toDouble();
    final fit = (viewport.width / pxW) < (viewport.height / pxH)
        ? viewport.width / pxW
        : viewport.height / pxH;
    _fit = fit;
    final tx = (viewport.width - pxW * fit) / 2;
    final ty = (viewport.height - pxH * fit) / 2;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tc.value = Matrix4.identity()
        ..translate(tx, ty)
        ..scale(fit);
      setState(() {});
    });
  }

  Future<void> _handleTap(Offset local) async {
    final a = widget.asset;
    final svgX = a.vb[0] + local.dx / a.px[0] * a.vb[2];
    final svgY = a.vb[1] + local.dy / a.px[1] * a.vb[3];
    final rz = _fit > 0 ? _tc.value.getMaxScaleOnAxis() / _fit : 1.0;
    final name = await widget.onTapSvg(svgX, svgY, rz);
    if (!mounted) return;
    setState(() => _stationName = name);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final tint = widget.dark ? const Color(0xFF1C1C1E) : Colors.white;
    final fg = widget.dark ? Colors.white : Colors.black87;
    Widget image = Image.asset(
      'assets/maps/${a.file}',
      fit: BoxFit.fill,
      gaplessPlayback: true,
    );
    if (widget.dark) {
      image = ColorFiltered(
        colorFilter: const ColorFilter.matrix(kDarkMapMatrix),
        child: image,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _ensureFit(viewport);
        return Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: widget.dark ? Colors.black : Colors.white,
                child: InteractiveViewer(
                  transformationController: _tc,
                  minScale: _fit > 0 ? _fit * 0.8 : 0.05,
                  maxScale: _fit > 0 ? _fit * 16 : 5,
                  boundaryMargin: const EdgeInsets.all(160),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => unawaited(_handleTap(d.localPosition)),
                    child: SizedBox(
                      width: a.px[0].toDouble(),
                      height: a.px[1].toDouble(),
                      child: image,
                    ),
                  ),
                ),
              ),
            ),
            // City capsule replica (the page's own chip is covered by
            // this view; tapping proxies to the page's showCityMenu).
            Positioned(
              top: 10,
              left: 16,
              child: _GlassPill(
                tint: tint,
                dark: widget.dark,
                onTap: widget.onCapsuleTap,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.cityLabel,
                      style: TextStyle(
                        color: fg,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down, size: 18, color: fg),
                  ],
                ),
              ),
            ),
            // Station search pill replica -> the page's openStations.
            Positioned(
              top: 10,
              right: 16,
              child: _GlassPill(
                tint: tint,
                dark: widget.dark,
                onTap: widget.onSearchTap,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search, size: 19, color: fg),
                    const SizedBox(width: 4),
                    Text(
                      widget.searchLabel,
                      style: TextStyle(color: fg, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
            if (_stationName != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 96,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: widget.dark ? 0.5 : 0.25),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _stationName!,
                          style: TextStyle(
                            color: fg,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          widget.onSetEndpoint('from');
                          setState(() => _stationName = null);
                        },
                        child: Text(
                          widget.startLabel,
                          style: TextStyle(color: widget.accent),
                        ),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: widget.accent,
                        ),
                        onPressed: () {
                          widget.onSetEndpoint('to');
                          setState(() => _stationName = null);
                        },
                        child: Text(widget.destLabel),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, size: 18, color: fg),
                        onPressed: () {
                          widget.onDismissCard();
                          setState(() => _stationName = null);
                        },
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({
    required this.tint,
    required this.dark,
    required this.onTap,
    required this.child,
  });

  final Color tint;
  final bool dark;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tint.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(20),
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.25),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.22 : 0.55),
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}
