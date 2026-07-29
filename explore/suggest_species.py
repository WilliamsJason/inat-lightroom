"""
suggest_species.py
~~~~~~~~~~~~~~~~~~
Ask iNaturalist's computer vision model what is in a photo, *before* creating
any observation.

This prototypes the picker the Lightroom plugin will show: the user selects a
photo, we render a small JPEG, and we offer a ranked list of candidate taxa
plus a "common ancestor" fallback so they can deliberately come in at a
coarser rank (genus, family, order) when the species-level call is a guess.

Usage
-----
    python suggest_species.py --photo "C:\\path\\to\\photo.jpg" \\
        --lat 47.80693 --lng -122.21465

    # score an observation that already has photos attached
    python suggest_species.py --observation-id 386157650
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from feasibility_test import read_exif, render_for_upload
from inat_api import InatApi, InatApiError
from inat_auth import AuthError

#: Ranks offered as "come in at this level instead" choices, coarse to fine.
RANK_ORDER = [
    "kingdom",
    "phylum",
    "class",
    "order",
    "family",
    "subfamily",
    "tribe",
    "genus",
    "species",
    "subspecies",
]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Get species suggestions for a photo from iNaturalist's vision model."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--photo", help="Path to a local image file.")
    source.add_argument(
        "--observation-id",
        type=int,
        help="Score an existing observation's photos instead of a local file.",
    )
    parser.add_argument("--lat", type=float, help="Latitude, improves ranking.")
    parser.add_argument("--lng", type=float, help="Longitude, improves ranking.")
    parser.add_argument("--date", help="Observed date YYYY-MM-DD, improves ranking.")
    parser.add_argument(
        "--max-dimension",
        type=int,
        default=1024,
        help="Resize the long edge before scoring (default: 1024). The vision "
        "model works on a small image, so there is no reason to send more.",
    )
    parser.add_argument(
        "--no-geo",
        action="store_true",
        help="Deliberately omit coordinates, to compare pure visual ranking "
        "against the geo-informed ranking.",
    )
    parser.add_argument("--json", action="store_true", help="Dump the raw response.")
    return parser.parse_args(argv)


def print_suggestions(rows: list[dict[str, Any]]) -> None:
    if not rows:
        print("  (no suggestions returned)")
        return
    header = f"  {'#':>2}  {'score':>7}  {'vision':>7}  {'geo':>7}  {'rank':<10} taxon"
    print(header)
    print("  " + "-" * (len(header) + 12))
    for index, row in enumerate(rows, start=1):
        common = row.get("common_name") or ""
        label = row.get("name") or "?"
        if common:
            label = f"{label}  ({common})"

        def fmt(value: Any) -> str:
            return f"{value:7.2f}" if isinstance(value, (int, float)) else " " * 7

        print(
            f"  {index:>2}  {fmt(row.get('combined_score'))}  "
            f"{fmt(row.get('vision_score'))}  {fmt(row.get('frequency_score'))}  "
            f"{str(row.get('rank') or ''):<10} {label}"
        )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    try:
        api = InatApi()
    except AuthError as exc:
        print(f"Authentication failed: {exc}", file=sys.stderr)
        return 1

    # ---- Score ---------------------------------------------------------
    if args.observation_id:
        print(f"Scoring observation {args.observation_id}…")
        try:
            payload = api.suggest_species_for_observation(args.observation_id)
        except InatApiError as exc:
            print(f"Scoring failed: {exc}", file=sys.stderr)
            return 1
    else:
        photo_path = Path(args.photo)
        if not photo_path.is_file():
            print(f"Photo not found: {photo_path}", file=sys.stderr)
            return 1

        exif = read_exif(photo_path)
        latitude = args.lat if args.lat is not None else exif.get("latitude")
        longitude = args.lng if args.lng is not None else exif.get("longitude")
        observed_on = args.date or (exif.get("observed_on") or "")[:10] or None
        if args.no_geo:
            latitude = longitude = None

        scoring_path = photo_path
        if args.max_dimension:
            scoring_path = render_for_upload(
                photo_path, args.max_dimension, 90, Path(__file__).parent / ".render"
            )

        size_kb = scoring_path.stat().st_size / 1024
        print(f"Scoring {scoring_path.name} ({size_kb:.0f} KB)")
        print(f"  coordinates : {latitude}, {longitude}")
        print(f"  observed on : {observed_on}")

        try:
            payload = api.suggest_species_for_image(
                scoring_path,
                latitude=latitude,
                longitude=longitude,
                observed_on=observed_on,
            )
        except InatApiError as exc:
            print(f"Scoring failed: {exc}", file=sys.stderr)
            return 1

    if args.json:
        print(json.dumps(payload, indent=2, default=str))
        return 0

    # ---- Ranked candidates ---------------------------------------------
    rows = api.summarise_suggestions(payload)
    print(f"\n{'=' * 72}")
    print("RANKED SUGGESTIONS")
    print("=" * 72)
    print_suggestions(rows)

    # ---- Common ancestor -------------------------------------------------
    print(f"\n{'=' * 72}")
    print("SAFE FALLBACK (iNaturalist's own common ancestor)")
    print("=" * 72)
    ancestor = (payload.get("common_ancestor") or {}).get("taxon") or {}
    if ancestor:
        common = ancestor.get("preferred_common_name") or ""
        print(
            f"  {ancestor.get('name')} ({ancestor.get('rank')})"
            + (f"  [{common}]" if common else "")
        )
        print(
            "  This is the most specific taxon the model is confident about "
            "across\n  all candidates -- a sensible default selection in the picker."
        )
    else:
        print("  None returned. The model had no confident shared ancestor,")
        print("  which usually means the candidates are spread across families.")

    # ---- Rank ladder ------------------------------------------------------
    top = rows[0] if rows else None
    if top and top.get("taxon_id"):
        print(f"\n{'=' * 72}")
        print("RANK LADDER FOR THE TOP SUGGESTION")
        print("=" * 72)
        print("  The plugin can offer any of these as the level to come in at:\n")
        full = api.get_taxon(top["taxon_id"])
        chain = (full.get("ancestors") or []) + [full]
        for entry in chain:
            rank = entry.get("rank") or ""
            if rank and rank not in RANK_ORDER:
                continue
            common = entry.get("preferred_common_name") or ""
            print(
                f"   [{entry.get('id'):>8}] {rank:<10} {entry.get('name'):<28}"
                + (f" {common}" if common else "")
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
