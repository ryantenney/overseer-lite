#!/usr/bin/env python3
"""
Build the search-autocomplete index from TMDB.

Self-hosted equivalent of the autocomplete_warmer Lambda. Writes JSON files
into your frontend's static directory so Caddy (or any static host) can serve
them at /autocomplete-<locale>.json.

Requirements:
    pip install httpx

Usage:
    export TMDB_API_KEY=your_tmdb_v3_key
    python scripts/build-autocomplete-index.py \
        --locale en \
        --out frontend/static/autocomplete-en.json

    # Multiple locales:
    python scripts/build-autocomplete-index.py \
        --locale en --locale es \
        --out-dir frontend/static
"""
import argparse
import json
import os
import sys
from pathlib import Path

# Reuse the shared builder from backend-lambda.
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend-lambda"))

try:
    from autocomplete_index import DEFAULT_TARGET_SIZE, build_index
except ImportError as e:
    print(f"Error importing autocomplete_index: {e}")
    print("Make sure httpx is installed: pip install httpx")
    sys.exit(1)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build TMDB autocomplete index for self-hosted Stellarr"
    )
    parser.add_argument(
        "--locale", action="append", default=None,
        help="Locale code (repeatable). Default: en",
    )
    parser.add_argument(
        "--target-size", type=int, default=DEFAULT_TARGET_SIZE,
        help=f"Items per media type per locale (default: {DEFAULT_TARGET_SIZE})",
    )
    parser.add_argument(
        "--out", type=Path, default=None,
        help="Output file path (single-locale mode)",
    )
    parser.add_argument(
        "--out-dir", type=Path, default=None,
        help="Output directory; files are named autocomplete-<locale>.json",
    )
    args = parser.parse_args()

    api_key = os.environ.get("TMDB_API_KEY")
    if not api_key:
        print("Error: TMDB_API_KEY environment variable is required.")
        return 1

    locales = args.locale or ["en"]

    if args.out and len(locales) > 1:
        print("Error: --out only works with a single --locale; use --out-dir.")
        return 1
    if not args.out and not args.out_dir:
        print("Error: must specify --out or --out-dir.")
        return 1

    if args.out_dir:
        args.out_dir.mkdir(parents=True, exist_ok=True)

    for locale in locales:
        print(f"Building index for {locale}...")
        index = build_index(api_key, locale=locale, target_size=args.target_size)
        payload = json.dumps(index, separators=(",", ":")).encode("utf-8")

        out_path = args.out if args.out else args.out_dir / f"autocomplete-{locale}.json"
        out_path.write_bytes(payload)
        print(
            f"  wrote {out_path} - {len(index['items'])} items, "
            f"{len(payload):,} bytes"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
