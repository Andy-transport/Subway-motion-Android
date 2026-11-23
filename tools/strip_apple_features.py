#!/usr/bin/env python3
"""Strip Apple-only features from the built offline page (Android build).

Changes, applied to the generated index.html only (the Subway-motion
source repo is never modified):
  1. Remove the "Siri 快捷指令" settings row (its icon is the Apple
     Intelligence icon, so this also removes the Apple Intelligence
     entry) and the Siri Shortcuts sub-page it opens. Both are dead ends
     on Android: tapping a shortcut posts to an iOS-only message handler
     that does not exist here. Removal uses a balanced-tag scan so nested
     <div>s inside the sub-page are handled.
  2. Replace the displayed app version with the Android version
     (ANDROID_VERSION below). The web core hardcodes the iOS version in
     its About / What's New spots; Android shows its own.
  3. Store jump: openTransitApp()'s browser fallback opens the Apple
     App Store page. Replace it with a call to the Flutter shell's
     'openStore' handler, which opens the same transit app in the
     phone's own app store (Xiaomi / OPPO / vivo / default store).
  5. Structure feature: KEPT since 2026-11-23 (the user reversed the
     2026-11-22 exclusion after tapping the Settings '车站结构' row
     into the dead panel the old strip left behind: '安卓那个结构图
     打不开'). prepare_web.sh now generates the structure index so
     the panel, its station list and the on-demand CDN image URLs
     work exactly like iOS. This script only asserts the panel and a
     non-empty CDN-backed index survived, and still removes the web
     tab-bar's structure entry when one exists (pre-26E115 pages):
     the Flutter shell owns the tab bar and has no structure tab -
     the feature opens from the Settings row, as on iOS.
  6. Bake the native-bridge shim into the page, right after <head> so
     it runs before every page script. The shell is the official
     webview_flutter (flutter_inappwebview never attached on the
     user's devices - see lib/main.dart), and webview_flutter has no
     document-start user scripts, so the shim ships inside the page:
     it defines window._metroSystemLang (from navigator.language, the
     same Hans/Hant/en mapping the old Dart shim computed from the OS
     locale) and window._metroIsPad = false, and forwards the four
     webkit message handlers the page checks for (tabChanged /
     cityChanged / themeState / langChanged) plus the
     flutter_inappwebview.callHandler surface (used by the patched
     openStore jump) to the shell's JavaScript channels of the same
     names, JSON-encoding each message. cityMenu is deliberately NOT
     defined - its presence is how the page detects the iOS shell.
  7. City capsule fallback: showCityMenu() posts to the iOS shell's
     cityMenu handler when present; its no-handler fallback is a
     legacy two-city toggle (toggleCity: Beijing <-> Shenyang, from
     when those were the only cities). Android has no cityMenu
     handler, so without this patch the transfer/map city capsule can
     only ever bounce between those two cities (reported on device
     2026-11-22; the Settings city list was unaffected). Replace the
     fallback with opening the full web city list - the same
     showCitySub page Settings uses: setTab('more') + showCitySub.
  8. Smooth-zoom interception, appended to the shim (see the
     _metroSmoothZoom block): during a touch gesture on the map,
     svg-pan-zoom's per-frame zoomAtPoint/panBy calls are redirected
     to a virtual state rendered as a CSS transform on the <svg>
     (GPU bitmap move, the native ZoomImageView principle the user
     pointed at), and the final state is committed to the library
     once on finger-lift for a crisp resting render. Stock behaviour
     outside gestures; self-disables on any error.
     Picking a city there lands back on the transfer tab (the web
     core's switchCity behaviour), where the tap started.
  9. Redemption codes: Android uses its OWN tables (user, 2026-11-23:
     '安卓兑换码重新做'). The iOS creator arrays are emptied (the
     iOS creator codes must not redeem on Android, and no Android
     creator set exists yet), and when the page carries the tester
     arrays (26E123+) their contents are replaced with the Android
     tester set from tools/android_redeem.json (50 code/ID pairs,
     user-supplied 2026-11-23, verified unique). On a pre-123 page
     the tester swap is skipped with a loud note - the delivery
     verification must then not claim the codes are in.

Fails loudly if an expected block is not found, so a future web-core
change cannot silently ship the Siri UI or the iOS version again.
"""
import pathlib
import re
import sys

ANDROID_VERSION = "1.0.4beta"

path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "assets/web/index.html")
html = path.read_text(encoding="utf-8")


def remove_balanced(text: str, start_marker: str, tag: str = "div") -> str:
    start = text.find(start_marker)
    assert start != -1, f"marker not found: {start_marker[:60]}"
    # Walk from the opening tag, tracking nesting depth of <tag> elements.
    i = text.find(f"<{tag}", start)
    assert i != -1, "opening tag not found"
    depth = 0
    j = i
    open_pat = f"<{tag}"
    close_pat = f"</{tag}>"
    while j < len(text):
        nxt_open = text.find(open_pat, j)
        nxt_close = text.find(close_pat, j)
        assert nxt_close != -1, "unbalanced block"
        if nxt_open != -1 and nxt_open < nxt_close:
            depth += 1
            j = nxt_open + len(open_pat)
        else:
            depth -= 1
            j = nxt_close + len(close_pat)
            if depth == 0:
                return text[:i] + text[j:]
    raise AssertionError("unbalanced block: ran off the end")


# 1. Settings row that opens the Siri sub-page.
html = remove_balanced(html, '<div class="more-row" @click="showSiriSub = true">')
# 2. The Siri sub-page itself. Its class list has changed before
# ("more-sub" -> "more-sub more-sub-siri"), so anchor on the v-show
# attribute and take the enclosing <div ...> as the marker.
anchor = html.find('v-show="showSiriSub"')
assert anchor != -1, "Siri sub-page anchor not found"
div_start = html.rfind('<div', 0, anchor)
div_end = html.find('>', anchor)
assert div_start != -1 and div_end != -1, "Siri sub-page div not found"
html = remove_balanced(html, html[div_start:div_end + 1])

assert "showSiriSub = true" not in html, "Siri row still present"
assert 'v-show="showSiriSub"' not in html, "Siri sub-page still present"

# 3. Displayed version -> Android version. Since 26C100 the version is an
# inline tap-to-expand ternary in two spots (settings appver + About):
#   verFull ? 'v1.1.0 (26C101)' : '1.1.0'
# Android's version is a single string, so collapse the ternary to it.
# (The releaseNotes changelog keeps the shared product history as-is.)
html, n_v = re.subn(
    r"verFull \? 'v[^']+' : '[^']+'", "'" + ANDROID_VERSION + "'", html
)
assert n_v == 2, f"expected 2 version ternaries, found {n_v}"
# The What's New detail view renders releaseNotes[relSel].v as its heading
# (the old static badge span no longer exists), so retitle only the FIRST
# (latest) changelog entry to the Android version; its lines describe the
# shared update content, which Android syncs, so they stay.
rn = html.find("releaseNotes")
assert rn != -1, "releaseNotes not found"
head, tail = html[:rn], html[rn:]
tail, n_top = re.subn(r"\{ v: '[^']+'", "{ v: '" + ANDROID_VERSION + "'", tail, count=1)
assert n_top == 1, "latest releaseNotes entry not retitled"
html = head + tail
row = html.find("showWhatsNewSub = true")
assert row != -1, "What's New row not found"
val = html.find('<span class="more-row-value">', row)
assert val != -1, "What's New row value not found"
end = html.find("</span>", val)
html = html[:val] + '<span class="more-row-value">' + ANDROID_VERSION + html[end:]

# 4. Store jump -> Flutter 'openStore' handler (see header, item 3).
old_open = "window.open('https://apps.apple.com/cn/app/id' + id, '_blank');"
new_open = "if (window.flutter_inappwebview) { window.flutter_inappwebview.callHandler('openStore', id); }"
assert html.count(old_open) == 1, "openTransitApp App Store fallback not found exactly once"
html = html.replace(old_open, new_open)

# 5. Structure feature: kept (see header, item 5). Only the web
# tab-bar entry is removed when present (pre-26E115 pages carried
# one; the Flutter shell's five tabs have no structure tab, and the
# feature opens from the Settings row like on iOS).
if html.count("setTab('structure')") == 1:
    html = remove_balanced(
        html, '<div class="tab" :class="{ active: tab===\'structure\' }"'
    )
assert "setTab('structure')" not in html, "structure web tab still present"
assert 'id="structurePanel"' in html, "structure panel missing"
assert "window.STRUCTURE_INDEX = {" in html, "structure index assignment missing"
_i = html.find("window.STRUCTURE_INDEX = ")
_j = html.find("window.STRUCTURE_IMGS", _i)
assert "cdn.jsdelivr.net" in html[_i:_j], "structure index carries no CDN image URLs (index not generated?)"

# 7. City capsule fallback -> full web city list (see header, item 7).
old_toggle = "this.toggleCity();"
assert html.count(old_toggle) == 1, "city capsule toggle fallback not found exactly once"
html = html.replace(old_toggle, "this.setTab('more'); this.showCitySub = true;")
assert "this.toggleCity();" not in html, "city toggle fallback still present"

# 9. Redemption code tables -> Android's own (see header, item 9).
import json as _redeem_json

_redeem = _redeem_json.loads(
    pathlib.Path(__file__).with_name("android_redeem.json").read_text(encoding="utf-8")
)


def replace_array_body(text: str, varname: str, items: list) -> str:
    marker = f"var {varname} = ["
    i = text.find(marker)
    assert i != -1, f"{varname} array not found"
    j = text.find("]", i)
    assert j != -1, f"{varname} array not closed"
    body = ", ".join(f"'{v}'" for v in items)
    return text[: i + len(marker)] + body + text[j:]


def array_body(text: str, varname: str) -> list:
    marker = f"var {varname} = ["
    i = text.find(marker)
    assert i != -1, f"{varname} array not found"
    j = text.find("]", i)
    return re.findall(r"'([^']*)'", text[i + len(marker):j])


html = replace_array_body(html, "CREATOR_REDEEM_CODES", [])
html = replace_array_body(html, "CREATOR_IDS", [])
# Assert on the array bodies, not raw strings: a template comment
# legitimately quotes an iOS creator code as a normalization example.
assert array_body(html, "CREATOR_REDEEM_CODES") == [], "creator codes not emptied"
assert array_body(html, "CREATOR_IDS") == [], "creator IDs not emptied"
tester_swapped = False
if "var TESTER_REDEEM_CODES = [" in html:
    html = replace_array_body(html, "TESTER_REDEEM_CODES", _redeem["tester_codes"])
    html = replace_array_body(html, "TESTER_IDS", _redeem["tester_ids"])
    assert array_body(html, "TESTER_REDEEM_CODES") == _redeem["tester_codes"], "tester codes mismatch"
    assert array_body(html, "TESTER_IDS") == _redeem["tester_ids"], "tester IDs mismatch"
    tester_swapped = True
else:
    print("NOTE: no TESTER arrays in page (pre-26E123) - Android tester codes NOT included")

# 6. Bridge shim (see header, item 6).
SHIM = """<script>
(function () {
  window._metroAndroidShim = true;
  function send(name, m) {
    var ch = window[name];
    if (ch && typeof ch.postMessage === 'function') {
      try { ch.postMessage(JSON.stringify(m === undefined ? null : m)); } catch (e) {}
    }
  }
  window._metroSystemLang = (function () {
    var l = (navigator.language || 'zh-CN').toLowerCase();
    if (l.indexOf('zh') === 0) {
      return (l.indexOf('tw') >= 0 || l.indexOf('hk') >= 0 || l.indexOf('mo') >= 0 || l.indexOf('hant') >= 0) ? 'zh-Hant' : 'zh-Hans';
    }
    if (l.indexOf('en') === 0) return 'en';
    return 'zh-Hans';
  })();
  window._metroIsPad = false;
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  ['tabChanged', 'cityChanged', 'themeState', 'langChanged'].forEach(function (n) {
    window.webkit.messageHandlers[n] = { postMessage: function (m) { send(n, m); } };
  });
  window.flutter_inappwebview = {
    callHandler: function (name, m) { send(name, m); return Promise.resolve(null); }
  };
})();
// Android smooth zoom (user report 2026-11-22: map pinch/pan "很卡很
// 卡", asked for stepless zoom and supplied a native ZoomImageView
// reference - an ImageView whose gestures only move a Matrix over an
// already-rendered bitmap). Same principle here: svg-pan-zoom's
// per-frame calls during a touch gesture are intercepted and applied
// to a VIRTUAL (zoom, pan) state, rendered as a CSS transform on the
// <svg> element itself - the WebView keeps the map as one rasterised
// layer and the GPU moves/scales that bitmap, so the gesture is
// continuous instead of re-rasterising ~2000 SVG nodes (about 1000
// of them text) every frame. When the last finger lifts, the final
// state is committed to svg-pan-zoom exactly once (zoomAtPoint to
// the virtual zoom, then a panBy correction onto the virtual pan),
// which repaints the vector crisply at the resting position. Any
// error disables the interception for the session and restores the
// stock behaviour.
(function () {
  window._metroSmoothZoom = true;
  var MINZ = 0.5, MAXZ = 60; // page init: default minZoom, maxZoom: 60
  var patchedFor = null, orig = null, dead = false;
  var active = false, svgEl = null;
  var startZ = 0, startPan = null, vZ = 0, vPan = null;
  // The svg's layout rect, captured once when the gesture begins
  // (round 2, 2026-11-23: the user still felt slight lag on build
  // #27). Reading getBoundingClientRect() on every zoomAtPoint call
  // forced a synchronous layout pass over the ~17 MB page each frame,
  // and once the CSS transform is applied the live rect MOVES with
  // the gesture, which also skewed the zoom pivot. The rect cannot
  // change mid-gesture (the svg is fullscreen), so cache it.
  var gRect = null;

  function applyCss() {
    var k = vZ / startZ;
    svgEl.style.transform =
      'translate(' + (vPan.x - k * startPan.x) + 'px,' +
      (vPan.y - k * startPan.y) + 'px) scale(' + k + ')';
  }
  function relPoint(p) {
    var r = (active && gRect) ? gRect : svgEl.getBoundingClientRect();
    return { x: p.x - r.left, y: p.y - r.top };
  }
  function patch(inst) {
    if (patchedFor === inst) return;
    if (patchedFor && orig) {
      try {
        patchedFor.zoomAtPoint = orig.zoomAtPoint;
        patchedFor.panBy = orig.panBy;
      } catch (e) {}
    }
    orig = { zoomAtPoint: inst.zoomAtPoint, panBy: inst.panBy };
    inst.zoomAtPoint = function (z, p) {
      if (!active) return orig.zoomAtPoint.call(inst, z, p);
      var rp = relPoint(p);
      z = Math.min(MAXZ, Math.max(MINZ, z));
      var ox = (rp.x - vPan.x) / vZ, oy = (rp.y - vPan.y) / vZ;
      vPan = { x: rp.x - ox * z, y: rp.y - oy * z };
      vZ = z;
      applyCss();
    };
    inst.panBy = function (d) {
      if (!active) return orig.panBy.call(inst, d);
      vPan = { x: vPan.x + d.x, y: vPan.y + d.y };
      applyCss();
    };
    patchedFor = inst;
  }
  function begin() {
    if (active || dead) return;
    var inst = window.panzoom;
    svgEl = document.querySelector('#svg8');
    if (!inst || !svgEl) return;
    try {
      patch(inst);
      startZ = inst.getZoom();
      startPan = inst.getPan();
    } catch (e) { dead = true; return; }
    if (!isFinite(startZ) || !startPan || !isFinite(startPan.x)) return;
    vZ = startZ;
    vPan = { x: startPan.x, y: startPan.y };
    gRect = svgEl.getBoundingClientRect();
    svgEl.style.transformOrigin = '0 0';
    svgEl.style.transformBox = 'border-box';
    svgEl.style.willChange = 'transform';
    active = true;
  }
  function end() {
    if (!active) return;
    active = false;
    try {
      var inst = window.panzoom;
      if (inst && inst === patchedFor && orig) {
        var r = gRect || svgEl.getBoundingClientRect();
        orig.zoomAtPoint.call(inst, vZ, {
          x: r.left + r.width / 2, y: r.top + r.height / 2
        });
        var now = inst.getPan();
        orig.panBy.call(inst, { x: vPan.x - now.x, y: vPan.y - now.y });
      }
    } catch (e) { dead = true; }
    if (svgEl) {
      svgEl.style.transform = '';
      svgEl.style.willChange = '';
    }
    gRect = null;
  }
  document.addEventListener('touchstart', function (e) {
    var t = e.target;
    if (t && t.closest && t.closest('#svg8')) begin();
  }, { capture: true, passive: true });
  document.addEventListener('touchend', function (e) {
    if (e.touches.length === 0) end();
  }, { capture: true, passive: true });
  document.addEventListener('touchcancel', function (e) {
    if (e.touches.length === 0) end();
  }, { capture: true, passive: true });
})();
</script>
"""
assert "_metroAndroidShim" not in html, "shim already present"
head_pos = html.find("<head>")
assert head_pos != -1, "<head> not found"
insert_at = head_pos + len("<head>")
html = html[:insert_at] + "\n" + SHIM + html[insert_at:]
assert html.count("_metroAndroidShim") == 1, "shim not inserted exactly once"

path.write_text(html, encoding="utf-8")
print(
    "strip_apple_features: Siri row + sub-page removed, store jump patched, version set to",
    ANDROID_VERSION,
    f"({n_v} ternaries + changelog head + row), structure kept (CDN on-demand), "
    f"redeem tables: creator emptied, tester {'swapped to Android set' if tester_swapped else 'NOT swapped (pre-123 page)'} in",
    path,
)
