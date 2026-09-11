#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"add_left_stick_ui_navigation: {message}")


if len(sys.argv) != 2:
    fail("usage: add_left_stick_ui_navigation.py GENERATED_SOURCE")

# The controller snapshot now carries the raw left-stick axes all the way into
# the headset UI. Do not quantize them into D-pad presses here: browser mode
# uses the continuous values for true analog cursor motion. D-pad navigation
# remains available for the player and file-picker panels.
path = pathlib.Path(sys.argv[1])
source = path.read_text()
path.write_text(source)
