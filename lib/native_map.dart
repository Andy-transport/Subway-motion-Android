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
// Hybrid zoom (user 2026-11-24: "滑动用图，停下后重画矢量"): a
// raster alone softens when zoomed deep, a live vector redraws on
// every frame and lags. So the artwork is ALSO rendered once from
// the same vector source at 8192 px and cut into 1024 px tiles;
// while the user moves, only the base raster is on screen, and
// once the view settles past ~2.6x fit the tiles covering the
// visible region are laid over it — the stopped view is then as
// sharp as the vector at any practical zoom, without ever asking
// the phone to redraw the vector itself (which would also render
// station names in the phone's own font instead of the artwork's).
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
    this.t2,
  });

  final String file;

  /// SVG viewBox: [x, y, width, height] in map coordinates.
  final List<double> vb;

  /// Raster size in pixels: [width, height].
  final List<int> px;

  /// Optional high-resolution tile layer (hybrid zoom, user
  /// 2026-11-24): while the user drags or pinches, the base raster
  /// above moves as one GPU layer; once the view settles zoomed in,
  /// tiles rendered from the same vector source at 8192 px are laid
  /// over the visible region so station names stay sharp.
  final MapT2? t2;

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
      t2: MapT2.fromJson(v['t2']),
    );
  }
}

class MapT2 {
  const MapT2({required this.px, required this.tile, required this.tiles});

  /// Full high-resolution render size in pixels: [width, height].
  final List<int> px;

  /// Tile edge length in high-resolution pixels.
  final int tile;

  /// Kept (non-blank) tiles as "col,row" keys.
  final Set<String> tiles;

  static MapT2? fromJson(Object? v) {
    if (v is! Map) return null;
    final pxRaw = v['px'];
    final tile = v['tile'];
    final tilesRaw = v['tiles'];
    if (pxRaw is! List || pxRaw.length != 2) return null;
    if (tile is! num || tilesRaw is! List) return null;
    return MapT2(
      px: pxRaw.map((e) => (e as num).toInt()).toList(),
      tile: tile.toInt(),
      tiles: tilesRaw.map((e) => e.toString()).toSet(),
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
  Size? _viewport;
  Timer? _settleTimer;
  Set<String> _activeTiles = const <String>{};
  final Map<String, ImageProvider> _tileProviders = <String, ImageProvider>{};

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _tc.removeListener(_onTransformChanged);
    _tc.dispose();
    super.dispose();
  }

  // Hybrid zoom: tiles are plain images, so they can stay up while
  // the user keeps moving; the visible set is only recomputed once
  // the transform has been quiet for a beat (finger lifted, fling
  // over), which is the "redraw sharp when stopped" moment.
  void _onTransformChanged() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 280), _refreshTiles);
  }

  ImageProvider _tileProvider(String name) {
    return _tileProviders.putIfAbsent(
      name,
      () => AssetImage('assets/maps/t2/$name'),
    );
  }

  void _refreshTiles() {
    final t2 = widget.asset.t2;
    final vp = _viewport;
    if (t2 == null || vp == null || _fit <= 0) return;
    final scale = _tc.value.getMaxScaleOnAxis();
    final ratio = scale / _fit;
    Set<String> next = const <String>{};
    if (ratio >= 2.6) {
      // Visible rect in child (base-raster pixel) coordinates. The
      // viewer matrix is translation + uniform scale only.
      final tx = _tc.value.storage[12];
      final ty = _tc.value.storage[13];
      final cx0 = -tx / scale;
      final cy0 = -ty / scale;
      final cx1 = (vp.width - tx) / scale;
      final cy1 = (vp.height - ty) / scale;
      final fx = t2.px[0] / widget.asset.px[0];
      final fy = t2.px[1] / widget.asset.px[1];
      final cols = (t2.px[0] + t2.tile - 1) ~/ t2.tile;
      final rows = (t2.px[1] + t2.tile - 1) ~/ t2.tile;
      var c0 = (cx0 * fx / t2.tile).floor();
      var r0 = (cy0 * fy / t2.tile).floor();
      var c1 = (cx1 * fx / t2.tile).floor();
      var r1 = (cy1 * fy / t2.tile).floor();
      if (c0 < 0) c0 = 0;
      if (r0 < 0) r0 = 0;
      if (c1 > cols - 1) c1 = cols - 1;
      if (r1 > rows - 1) r1 = rows - 1;
      final wanted = <String>{};
      for (var r = r0; r <= r1; r++) {
        for (var c = c0; c <= c1; c++) {
          final key = '$c,$r';
          if (t2.tiles.contains(key)) wanted.add(key);
        }
      }
      next = wanted;
    }
    if (next.length == _activeTiles.length && next.containsAll(_activeTiles)) {
      return;
    }
    // Bound the image cache: tiles that scrolled out of the active
    // set are evicted instead of piling up decoded bitmaps.
    for (final key in _activeTiles.difference(next)) {
      final name = _tileName(key);
      final provider = _tileProviders.remove(name);
      if (provider != null) unawaited(provider.evict());
    }
    setState(() => _activeTiles = next);
  }

  String _tileName(String key) {
    final parts = key.split(',');
    return '${widget.asset.file.replaceAll('.webp', '')}'
        '_t${parts[0]}_${parts[1]}.webp';
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

  List<Widget> _tileWidgets() {
    final t2 = widget.asset.t2;
    if (t2 == null || _activeTiles.isEmpty) return const <Widget>[];
    final kx = widget.asset.px[0] / t2.px[0];
    final ky = widget.asset.px[1] / t2.px[1];
    final out = <Widget>[];
    for (final key in _activeTiles) {
      final parts = key.split(',');
      final c = int.parse(parts[0]);
      final r = int.parse(parts[1]);
      final tw = (c + 1) * t2.tile <= t2.px[0]
          ? t2.tile
          : t2.px[0] - c * t2.tile;
      final th = (r + 1) * t2.tile <= t2.px[1]
          ? t2.tile
          : t2.px[1] - r * t2.tile;
      final name = _tileName(key);
      out.add(
        Positioned(
          left: c * t2.tile * kx,
          top: r * t2.tile * ky,
          width: tw * kx,
          height: th * ky,
          child: Image(
            image: _tileProvider(name),
            fit: BoxFit.fill,
            gaplessPlayback: true,
          ),
        ),
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final tint = widget.dark ? const Color(0xFF1C1C1E) : Colors.white;
    final fg = widget.dark ? Colors.white : Colors.black87;
    Widget mapStack = Stack(
      children: [
        Positioned.fill(
          child: Image.asset(
            'assets/maps/${a.file}',
            fit: BoxFit.fill,
            gaplessPlayback: true,
          ),
        ),
        ..._tileWidgets(),
      ],
    );
    if (widget.dark) {
      mapStack = ColorFiltered(
        colorFilter: const ColorFilter.matrix(kDarkMapMatrix),
        child: mapStack,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _viewport = viewport;
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
                      child: mapStack,
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
