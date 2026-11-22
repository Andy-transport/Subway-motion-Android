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
  5. Remove the Structure feature (user, 2026-11-22: Android syncs the
     iOS test version's other updates, but Structure is not added):
     the web tab-bar entry, the #structurePanel block, the embedded
     STRUCTURE_INDEX data (station diagrams, ~20 MB of base64 - the
     page code reads it through `window.STRUCTURE_INDEX || {}` guards,
     so an empty object is safe), and the two changelog lines that
     advertise the feature. (prepare_web.sh already drops the
     structure index before the offline build, so the data normally
     never reaches this script; emptying here is the safety net.)
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
     Picking a city there lands back on the transfer tab (the web
     core's switchCity behaviour), where the tap started.

Fails loudly if an expected block is not found, so a future web-core
change cannot silently ship the Siri UI or the iOS version again.
"""
import pathlib
import re
import sys

ANDROID_VERSION = "1.0.0test3"

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

# 5. Structure feature removal (see header, item 5).
# Web tab-bar entry: up to 26E112 the page's own tab bar carried a
# structure tab (exactly one click target). Since 26E115 the iOS tab
# bar is the system UITabBar and the web markup has no structure tab
# at all. Remove the entry when present; the assert after the panel
# removal below covers both cases.
if html.count("setTab('structure')") == 1:
    html = remove_balanced(
        html, '<div class="tab" :class="{ active: tab===\'structure\' }"'
    )
# The panel itself. (CSS rules and querySelector('#structurePanel')
# references remain in the page; they are dead once the element is
# gone, so the assert checks the DOM id, not the bare word.)
html = remove_balanced(html, '<div id="structurePanel"')
assert 'id="structurePanel"' not in html, "structure panel still present"
assert "setTab('structure')" not in html, "structure tab still present"
# The embedded station-diagram data: two assignments - STRUCTURE_INDEX
# (station -> image file names + sources, ~18 KB) and STRUCTURE_IMGS
# (file name -> data URI, ~20 MB). Replace both objects with an empty
# object; the page code reads them via `window.X || {}` guards, and
# with the panel gone the data is unreachable anyway. JSON-aware brace
# scan: strings may contain braces, base64 payloads contain no quotes.
def empty_assignment(text: str, marker: str) -> tuple[str, int]:
    i = text.find(marker)
    assert i != -1, f"{marker} assignment not found"
    j = text.find("{", i)
    assert j != -1, f"{marker} object start not found"
    depth = 0
    k = j
    in_str = False
    esc = False
    while k < len(text):
        c = text[k]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    assert depth == 0 and k < len(text), f"{marker} object not closed"
    return text[:j] + "{}" + text[k + 1:], k + 1 - j


html, n_idx = empty_assignment(html, "window.STRUCTURE_INDEX = ")
html, n_imgs = empty_assignment(html, "window.STRUCTURE_IMGS = ")
removed_bytes = n_idx + n_imgs
# No size assert on the emptied data: prepare_web.sh drops the
# structure index before the offline build, so both objects normally
# arrive already empty. empty_assignment() above still asserts each
# assignment exists and is replaced, which is the invariant that
# matters here.
# Changelog lines that advertise the removed feature (one physical
# line each in the built page; length-guarded so a future minified
# layout fails loudly instead of eating the script).
for frag in ("「结构」栏目", "结构详情页配备"):
    lines = html.split("\n")
    hits = [ln for ln in lines if frag in ln]
    assert len(hits) == 1 and len(hits[0]) < 5000, f"changelog line not unique/short: {frag}"
    html = "\n".join(ln for ln in lines if frag not in ln)
    assert frag not in html, f"changelog line still present: {frag}"

# 7. City capsule fallback -> full web city list (see header, item 7).
old_toggle = "this.toggleCity();"
assert html.count(old_toggle) == 1, "city capsule toggle fallback not found exactly once"
html = html.replace(old_toggle, "this.setTab('more'); this.showCitySub = true;")
assert "this.toggleCity();" not in html, "city toggle fallback still present"

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
    f"({n_v} ternaries + changelog head + row), structure removed (index data {removed_bytes} bytes) in",
    path,
)
