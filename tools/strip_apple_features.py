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

Fails loudly if an expected block is not found, so a future web-core
change cannot silently ship the Siri UI or the iOS version again.
"""
import pathlib
import re
import sys

ANDROID_VERSION = "1.0.0A"

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
# 2. The Siri sub-page itself.
html = remove_balanced(html, '<div class="more-sub" v-show="showSiriSub">')

assert "showSiriSub = true" not in html, "Siri row still present"
assert 'v-show="showSiriSub"' not in html, "Siri sub-page still present"

# 3. Displayed version -> Android version. Three spots use the
# {v: '...'} binding (About rows + What's New title); the What's New
# row value and the What's New version badge carry it as plain text.
html, n_v = re.subn(r"\{v: '[^']+'\}", "{v: '" + ANDROID_VERSION + "'}", html)
assert n_v >= 3, f"expected >=3 version bindings, found {n_v}"
html, n_badge = re.subn(
    r'(<span class="more-new-ver">)[^<]+(</span>)',
    r"\g<1>" + ANDROID_VERSION + r"\g<2>",
    html,
)
assert n_badge == 1, f"expected 1 What's New badge, found {n_badge}"
row = html.find('@click="showWhatsNewSub = true"')
assert row != -1, "What's New row not found"
val = html.find('<span class="more-row-value">', row)
assert val != -1, "What's New row value not found"
end = html.find("</span>", val)
html = html[:val] + '<span class="more-row-value">' + ANDROID_VERSION + html[end:]

path.write_text(html, encoding="utf-8")
print(
    "strip_apple_features: Siri row + sub-page removed, version set to",
    ANDROID_VERSION,
    f"({n_v} bindings + badge + row) in",
    path,
)
