#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"add_left_stick_ui_navigation: {message}")


if len(sys.argv) != 2:
    fail("usage: add_left_stick_ui_navigation.py GENERATED_SOURCE")

path = pathlib.Path(sys.argv[1])
source = path.read_text()

needle = '''                GAVUIAction uiAction{};
                const bool uiWasVisible = gav_ui_visible(uiOverlay) != 0;
'''
replacement = '''                // Treat the left stick as repeatable UI navigation while the
                // headset panel is open. In browser mode this becomes cursor
                // movement; in the player/file panels it behaves like the D-pad.
                // Keeping this conversion here avoids changing the established
                // hidden-UI seek/volume mappings.
                static double nextLeftStickUINav = 0.0;
                const double leftStickNow = CACurrentMediaTime();
                if (gav_ui_visible(uiOverlay) && leftStickNow >= nextLeftStickUINav) {
                    const float deadzone = 0.28f;
                    bool moved = false;
                    if (std::fabs(controls.leftX) > deadzone) {
                        controls.uiNavX += controls.leftX > 0.0f ? 1 : -1;
                        moved = true;
                    }
                    if (std::fabs(controls.leftY) > deadzone) {
                        // GameController +Y is up; UI navigation uses -1 for up.
                        controls.uiNavY += controls.leftY > 0.0f ? -1 : 1;
                        moved = true;
                    }
                    if (moved) {
                        // 25 Hz repeat feels cursor-like without making ordinary
                        // menu/file navigation uncontrollably fast.
                        nextLeftStickUINav = leftStickNow + 0.040;
                    }
                }

                GAVUIAction uiAction{};
                const bool uiWasVisible = gav_ui_visible(uiOverlay) != 0;
'''

count = source.count(needle)
if count != 1:
    fail(f"expected exactly one UI action block, found {count}")

path.write_text(source.replace(needle, replacement, 1))
