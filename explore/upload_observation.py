"""
upload_observation.py
~~~~~~~~~~~~~~~~~~~~~
Prototype: create an iNaturalist observation and attach a photo.

This script demonstrates the full upload workflow that the Lightroom plugin
will implement in Lua.

Usage
-----
    python upload_observation.py \\
        --photo /path/to/photo.jpg \\
        --species "Quercus robur" \\
        --lat 51.5074 \\
        --lng -0.1278 \\
        --date 2024-05-10 \\
        [--project-id 12345] \\
        [--description "Found near the pond"]

The observation ID is printed to stdout so you can pass it to
sync_observation.py.
"""

from __future__ import annotations

import argparse
import sys

from inat_client import InatClient


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload a photo to iNaturalist.")
    parser.add_argument("--photo", required=True, help="Path to the JPEG file to upload.")
    parser.add_argument(
        "--species",
        required=True,
        help="Species name or search query (e.g. 'Quercus robur').",
    )
    parser.add_argument("--lat", type=float, help="Latitude of the observation.")
    parser.add_argument("--lng", type=float, help="Longitude of the observation.")
    parser.add_argument("--date", required=True, help="Observed date, YYYY-MM-DD.")
    parser.add_argument("--description", default="", help="Optional description text.")
    parser.add_argument(
        "--project-id",
        type=int,
        default=None,
        help="iNaturalist project ID to add the observation to.",
    )
    return parser.parse_args(argv)


def pick_taxon(client: InatClient, query: str) -> dict:
    """Autocomplete *query* and return the best-matching taxon."""
    results = client.autocomplete_taxon(query)
    if not results:
        print(f"No taxa found for '{query}'.", file=sys.stderr)
        sys.exit(1)

    # Print choices
    print(f"\nFound {len(results)} taxon match(es) for '{query}':")
    for i, taxon in enumerate(results[:10]):
        common = taxon.get("preferred_common_name", "")
        common_str = f" ({common})" if common else ""
        print(f"  [{i}] {taxon['name']}{common_str}  [rank: {taxon['rank']}]")

    # Auto-pick the first result; in the plugin this would be a UI dropdown
    chosen = results[0]
    print(f"\nUsing: {chosen['name']} (taxon_id={chosen['id']})")
    return chosen


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    client = InatClient()

    # 1. Resolve taxon
    taxon = pick_taxon(client, args.species)

    # 2. Create the observation
    print("\nCreating observation…")
    observation = client.create_observation(
        taxon_id=taxon["id"],
        observed_on=args.date,
        latitude=args.lat,
        longitude=args.lng,
        description=args.description,
    )
    observation_id: int = observation["id"]
    print(f"  ✓ Observation created: id={observation_id}")
    print(f"    https://www.inaturalist.org/observations/{observation_id}")

    # 3. Upload the photo
    print(f"\nUploading photo: {args.photo}")
    photo_response = client.upload_photo(observation_id, args.photo)
    print(f"  ✓ Photo uploaded: {photo_response}")

    # 4. Optionally add to a project
    if args.project_id is not None:
        print(f"\nAdding to project {args.project_id}…")
        client.add_to_project(observation_id, args.project_id)
        print("  ✓ Added to project.")

    print(f"\nDone. Observation ID to store in Lightroom: {observation_id}")


if __name__ == "__main__":
    main()
