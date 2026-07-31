#!/usr/bin/env python3
"""Launch BDS B2a Web UI (no MATLAB desktop config required).

Usage:
  python launch_b2a_ui.py
  python launch_b2a_ui.py --port 8787 --no-browser

MATLAB is auto-detected (PATH or standard install dirs).
Override with env:  set B2A_MATLAB=C:\\Program Files\\MATLAB\\R2024b\\bin\\matlab.exe
"""
from __future__ import annotations

import sys
from pathlib import Path

# Ensure package import works when launched from project root
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "python"))

from b2a_ui.server import main  # noqa: E402


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="Launch BDS B2a Web UI")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    main(host=args.host, port=args.port, open_browser=not args.no_browser)
