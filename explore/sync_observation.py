"""
sync_observation.py
~~~~~~~~~~~~~~~~~~~
Prototype: fetch the latest community determination for an iNaturalist
observation and print the Lightroom keyword hierarchy that would be applied.

This mirrors the "Sync" workflow described in docs/plugin-architecture.md.

Usage
-----
    python sync_observation.py --observation-id 12345678
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone

from inat_client import InatClient


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sync taxon data from an iNaturalist observation."
    )
    parser.add_argument(
        "--observation-id",
        type=int,
        required=True,
        help="The iNaturalist observation ID (stored in Lightroom custom metadata).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output the full observation as JSON instead of a summary.",
    )
    return parser.parse_args(argv)


def build_metadata(observation: dict) -> dict:
    """
    Extract the Lightroom-relevant metadata fields from an observation dict.

    Returns a dict matching the custom metadata schema defined in
    CustomMetadata.lua (see docs/plugin-architecture.md).
    """
    taxon = observation.get("taxon") or {}
    community_taxon = observation.get("community_taxon") or taxon

    return {
        "inat_observation_id": str(observation.get("id", "")),
        "inat_observation_url": (
            f"https://www.inaturalist.org/observations/{observation.get('id', '')}"
        ),
        "inat_taxon_id": str(community_taxon.get("id", "")),
        "inat_taxon_name": community_taxon.get("name", ""),
        "inat_common_name": community_taxon.get("preferred_common_name", ""),
        "inat_quality_grade": observation.get("quality_grade", ""),
        "inat_last_synced": datetime.now(tz=timezone.utc).isoformat(),
    }


def build_keyword_path(taxon: dict) -> list[str]:
    """
    Build an ordered list of ancestor names for Lightroom's keyword hierarchy.

    Example output:
        ["iNaturalist", "Plantae", "Tracheophyta", ..., "Quercus", "Quercus robur"]
    """
    ancestors: list[dict] = taxon.get("ancestors", [])
    # Ancestors are already ordered from kingdom → genus by the iNat API
    path = ["iNaturalist"] + [a["name"] for a in ancestors] + [taxon["name"]]
    return path


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    client = InatClient()

    print(f"Fetching observation {args.observation_id}…")
    observation = client.get_observation(args.observation_id)

    if args.json:
        print(json.dumps(observation, indent=2, default=str))
        return

    # --- Summary output ------------------------------------------------
    taxon = observation.get("taxon") or {}
    community_taxon = observation.get("community_taxon") or taxon

    print(f"\n{'='*60}")
    print(f"Observation:   {observation.get('id')}")
    print(f"Quality grade: {observation.get('quality_grade', 'unknown')}")
    print(f"Observed on:   {observation.get('observed_on', 'unknown')}")
    print(f"Taxon (community): {community_taxon.get('name', '—')}")
    print(f"Common name:   {community_taxon.get('preferred_common_name', '—')}")
    print(f"{'='*60}")

    # --- Keyword path --------------------------------------------------
    if community_taxon:
        full_taxon = client.get_taxon(community_taxon["id"])
        path = build_keyword_path(full_taxon)
        print("\nLightroom keyword hierarchy to apply:")
        indent = ""
        for keyword in path:
            print(f"{indent}{keyword}")
            indent += "  "

    # --- Custom metadata values ----------------------------------------
    metadata = build_metadata(observation)
    print("\nCustom metadata fields to write:")
    for key, value in metadata.items():
        print(f"  {key}: {value!r}")


if __name__ == "__main__":
    main()
