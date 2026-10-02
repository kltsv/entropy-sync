#!/usr/bin/env python3
"""Project compile; import the shared checker from the pinned History checkout."""
import json
import os
import sys
from pathlib import Path
root = Path(__file__).resolve().parent
config = root / "spec_sources_overrides.json"
if not config.exists():
    config = root / "spec_sources.json"
provider = root / json.loads(config.read_text())["sources"][0]
sys.path.insert(0, str(provider / "tool"))
os.chdir(root)
try:
    from spec_graph import main
except ImportError:
    sys.exit("Run node tool/checkout-history.mjs before project compile")
main()
