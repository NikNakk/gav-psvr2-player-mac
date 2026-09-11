#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"recenter_ui_panel: {message}")


if len(sys.argv) != 2:
    fail("usage: recenter_ui_panel.py GENERATED_SOURCE")

path = pathlib.Path(sys.argv[1])
source = path.read_text()

needle = '''                if (controls.recenter != 0) {
                    anchor.valid = false;
                    std::printf("[controller] recenter requested\\n");
                }
'''
replacement = '''                if (controls.recenter != 0) {
                    anchor.valid = false;
                    // The UI is independently world-anchored. If it is open,
                    // invalidate that anchor too so the next valid xrLocateViews
                    // places the panel in front of the newly centred gaze.
                    if (gav_ui_visible(uiOverlay)) {
                        uiAnchor.valid = false;
                    }
                    std::printf("[controller] recenter requested (video + UI)\\n");
                }
'''

count = source.count(needle)
if count != 1:
    fail(f"expected exactly one recenter block, found {count}")

path.write_text(source.replace(needle, replacement, 1))
