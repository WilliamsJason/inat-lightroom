"""
feasibility_test.py
~~~~~~~~~~~~~~~~~~~
End-to-end feasibility check against the live iNaturalist API.

It walks the exact round trip the Lightroom plugin will need:

    1.  Authenticate and confirm who we are.
    2.  Read capture date / GPS out of the image's EXIF (in the plugin these
        come from the Lightroom catalog instead, but proving we can derive
        them keeps the test self-contained).
    3.  Resolve a species name to a taxon ID.
    4.  Create an observation and capture its ID -- the value the plugin will
        persist in Lightroom custom metadata.
    5.  Attach the photo.
    6.  Read the observation back and confirm the photo landed.
    7.  Update metadata on the observation and confirm the change round-trips.
    8.  Read the current determination and identifications.
    9.  Optionally delete the observation to leave no trace.

Nothing is destructive unless you pass --delete.

Usage
-----
    python feasibility_test.py --photo "C:\\path\\to\\photo.jpg" --species Damselfly

    # dry run -- everything except the writes
    python feasibility_test.py --photo ... --species ... --dry-run
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from inat_api import InatApi, InatApiError, PhotoNotPersisted
from inat_auth import AuthError, whoami

# --------------------------------------------------------------------------
# Console helpers
# --------------------------------------------------------------------------

_step_number = 0


def step(title: str) -> None:
    global _step_number
    _step_number += 1
    print(f"\n{'=' * 72}")
    print(f"STEP {_step_number}: {title}")
    print("=" * 72)


def ok(message: str) -> None:
    print(f"  [OK]   {message}")


def info(message: str) -> None:
    print(f"         {message}")


def fail(message: str) -> None:
    print(f"  [FAIL] {message}")


# --------------------------------------------------------------------------
# EXIF
# --------------------------------------------------------------------------


def read_exif(photo_path: Path) -> dict[str, Any]:
    """Pull capture time and GPS out of an image, if present."""
    try:
        from PIL import Image, ExifTags
    except ImportError:
        info("Pillow not installed; skipping EXIF extraction.")
        return {}

    result: dict[str, Any] = {}
    with Image.open(photo_path) as image:
        result["dimensions"] = f"{image.width} x {image.height}"
        exif = image.getexif()
        if not exif:
            return result

        tag_names = {v: k for k, v in ExifTags.TAGS.items()}

        raw_datetime = exif.get(tag_names.get("DateTimeOriginal")) or exif.get(
            tag_names.get("DateTime")
        )
        if raw_datetime:
            try:
                parsed = datetime.strptime(str(raw_datetime), "%Y:%m:%d %H:%M:%S")
                result["observed_on"] = parsed.strftime("%Y-%m-%d %H:%M:%S")
            except ValueError:
                result["observed_on_raw"] = str(raw_datetime)

        gps = exif.get_ifd(ExifTags.IFD.GPSInfo) if hasattr(ExifTags, "IFD") else None
        if gps:
            gps_names = {v: k for k, v in ExifTags.GPSTAGS.items()}

            def to_degrees(value: Any, ref: Any) -> float | None:
                try:
                    degrees, minutes, seconds = (float(v) for v in value)
                except (TypeError, ValueError):
                    return None
                decimal = degrees + minutes / 60 + seconds / 3600
                if str(ref).upper() in ("S", "W"):
                    decimal = -decimal
                return round(decimal, 7)

            lat = to_degrees(
                gps.get(gps_names.get("GPSLatitude")),
                gps.get(gps_names.get("GPSLatitudeRef")),
            )
            lng = to_degrees(
                gps.get(gps_names.get("GPSLongitude")),
                gps.get(gps_names.get("GPSLongitudeRef")),
            )
            if lat is not None and lng is not None:
                result["latitude"] = lat
                result["longitude"] = lng
    return result


# --------------------------------------------------------------------------
# Export rendering
# --------------------------------------------------------------------------

#: iNaturalist rejects photos larger than this. Camera-original JPEGs from a
#: high-megapixel body routinely exceed it, which is why the plugin must be an
#: Export Service Provider (Lightroom renders a resized JPEG for us) rather
#: than uploading the original file.
INAT_MAX_UPLOAD_BYTES = 20 * 1024 * 1024


def render_for_upload(
    photo_path: Path, max_dimension: int, quality: int, workdir: Path
) -> Path:
    """
    Produce a resized sRGB JPEG, standing in for a Lightroom export preset.

    Returns the path to the rendered file.
    """
    from PIL import Image

    workdir.mkdir(parents=True, exist_ok=True)
    target = workdir / f"{photo_path.stem}_{max_dimension}.jpg"

    with Image.open(photo_path) as image:
        exif_bytes = image.info.get("exif")
        image = image.convert("RGB")
        image.thumbnail((max_dimension, max_dimension), Image.LANCZOS)
        save_kwargs: dict[str, Any] = {"quality": quality, "optimize": True}
        if exif_bytes:
            # Keep EXIF so iNaturalist can read the capture time itself.
            save_kwargs["exif"] = exif_bytes
        image.save(target, "JPEG", **save_kwargs)
    return target


# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Feasibility test for the iNaturalist upload/sync round trip."
    )
    parser.add_argument("--photo", required=True, help="Path to the image file.")
    parser.add_argument(
        "--species",
        default="Odonata",
        help="Species/taxon search string (default: Odonata).",
    )
    parser.add_argument("--taxon-id", type=int, help="Skip the search; use this taxon.")
    parser.add_argument("--lat", type=float, help="Latitude override.")
    parser.add_argument("--lng", type=float, help="Longitude override.")
    parser.add_argument("--date", help="Observed date override (YYYY-MM-DD).")
    parser.add_argument(
        "--description",
        default="Feasibility test for a Lightroom plugin. Please ignore.",
        help="Initial observation description.",
    )
    parser.add_argument(
        "--captive",
        action="store_true",
        help="Mark the observation captive/cultivated so it stays out of the "
        "biodiversity data set. Recommended for throwaway tests.",
    )
    parser.add_argument(
        "--geoprivacy",
        default="obscured",
        choices=["open", "obscured", "private"],
        help="Geoprivacy for the test observation (default: obscured).",
    )
    parser.add_argument(
        "--delete",
        action="store_true",
        help="Delete the observation at the end, leaving no trace.",
    )
    parser.add_argument(
        "--max-dimension",
        type=int,
        default=2048,
        help="Resize the long edge to this many pixels before upload, mimicking "
        "a Lightroom export preset (default: 2048). Use 0 to upload the "
        "original file untouched.",
    )
    parser.add_argument(
        "--quality",
        type=int,
        default=90,
        help="JPEG quality for the rendered upload (default: 90).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do everything except the write operations.",
    )
    return parser.parse_args(argv)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    photo_path = Path(args.photo)
    if not photo_path.is_file():
        fail(f"Photo not found: {photo_path}")
        return 1

    # -- 1. Authenticate -------------------------------------------------
    step("Authenticate")
    try:
        user = whoami()
    except AuthError as exc:
        if args.dry_run:
            info(f"Not authenticated ({exc.args[0].splitlines()[0]})")
            info("Continuing anyway because --dry-run only needs public endpoints.")
        else:
            fail(str(exc))
            return 1
    else:
        ok(f"Signed in as {user.get('login')} (id={user.get('id')})")
        info(f"Existing observations on this account: {user.get('observations_count')}")

    api = InatApi(token="dry-run" if args.dry_run else None)

    # -- 2. Inspect the photo -------------------------------------------
    step("Read photo metadata")
    size_mb = photo_path.stat().st_size / (1024 * 1024)
    info(f"File: {photo_path.name} ({size_mb:.1f} MB)")
    exif = read_exif(photo_path)
    for key, value in exif.items():
        info(f"{key}: {value}")

    if photo_path.stat().st_size > INAT_MAX_UPLOAD_BYTES:
        info(
            f"Original exceeds iNaturalist's ~{INAT_MAX_UPLOAD_BYTES // (1024*1024)} MB "
            "upload limit; it cannot be sent as-is."
        )

    observed_on = args.date or exif.get("observed_on")
    latitude = args.lat if args.lat is not None else exif.get("latitude")
    longitude = args.lng if args.lng is not None else exif.get("longitude")

    if not observed_on:
        fail("No capture date found in EXIF and none supplied via --date.")
        return 1
    ok(f"Observed on: {observed_on}")
    if latitude is None or longitude is None:
        info("No GPS in EXIF. Observation will be created without coordinates.")
        info("(Pass --lat/--lng to supply them.)")
    else:
        ok(f"Coordinates: {latitude}, {longitude}")

    # -- 3. Resolve the taxon -------------------------------------------
    step("Resolve species to a taxon ID")
    if args.taxon_id:
        taxon = api.get_taxon(args.taxon_id)
        ok(f"Using supplied taxon {taxon.get('name')} (id={taxon.get('id')})")
    else:
        matches = api.autocomplete_taxon(args.species)
        if not matches:
            fail(f"No taxa matched '{args.species}'.")
            return 1
        print(f"  Matches for '{args.species}':")
        for index, match in enumerate(matches[:10]):
            common = match.get("preferred_common_name") or "-"
            marker = ">" if index == 0 else " "
            print(
                f"   {marker} [{match['id']:>8}] {match['name']:<32} "
                f"{match.get('rank', ''):<10} {common}"
            )
        taxon = matches[0]
        ok(f"Selected: {taxon['name']} (id={taxon['id']}, rank={taxon.get('rank')})")

    full_taxon = api.get_taxon(taxon["id"])
    keyword_path = api.build_keyword_path(full_taxon)
    info("Lightroom keyword hierarchy this would produce:")
    for depth, keyword in enumerate(keyword_path):
        info(f"{'  ' * depth}{keyword}")

    if args.dry_run:
        print("\n--dry-run set; stopping before any write operations.")
        return 0

    # -- 4. Create the observation ---------------------------------------
    step("Create the observation")
    payload: dict[str, Any] = {
        "taxon_id": taxon["id"],
        "observed_on_string": observed_on,
        "description": args.description,
        "geoprivacy": args.geoprivacy,
        "captive_flag": bool(args.captive),
    }
    if latitude is not None and longitude is not None:
        payload["latitude"] = latitude
        payload["longitude"] = longitude

    try:
        observation = api.create_observation(payload)
    except InatApiError as exc:
        fail(f"Create failed: {exc}")
        return 1

    observation_id = observation.get("id")
    if not observation_id:
        fail(f"No observation ID in response: {json.dumps(observation)[:500]}")
        return 1
    ok(f"Observation created: id={observation_id}")
    info(f"UUID: {observation.get('uuid')}")
    info(f"URL:  https://www.inaturalist.org/observations/{observation_id}")
    print("\n  >>> This ID is what the plugin stores in Lightroom custom metadata. <<<")

    exit_code = 0
    try:
        # -- 5. Attach the photo -----------------------------------------
        step("Upload the photo")
        upload_path = photo_path
        if args.max_dimension:
            workdir = Path(__file__).parent / ".render"
            upload_path = render_for_upload(
                photo_path, args.max_dimension, args.quality, workdir
            )
            rendered_mb = upload_path.stat().st_size / (1024 * 1024)
            ok(
                f"Rendered upload copy: {upload_path.name} "
                f"({rendered_mb:.1f} MB, long edge {args.max_dimension}px, q{args.quality})"
            )
            info("In the plugin, Lightroom's export pipeline produces this file.")
        else:
            info("--max-dimension 0: uploading the original file untouched.")

        try:
            photo = api.upload_observation_photo_verified(
                observation_id, upload_path, on_event=lambda m: info(m)
            )
            ok(f"Photo attached and verified: observation_photo id={photo.get('id')}")
            info(
                "Note: the POST response's photo URLs point at placeholder "
                "images until\n         iNaturalist finishes processing; that "
                "is normal and not an error."
            )
        except PhotoNotPersisted as exc:
            fail(str(exc))
            exit_code = 1
        except InatApiError as exc:
            fail(f"Photo upload failed: {exc}")
            exit_code = 1

        # -- 6. Read it back ---------------------------------------------
        step("Read the observation back by ID")
        fetched = api.get_observation(observation_id)
        ok(f"Fetched observation {fetched.get('id')}")
        info(f"Taxon:         {(fetched.get('taxon') or {}).get('name')}")
        info(f"Observed on:   {fetched.get('observed_on')}")
        info(f"Quality grade: {fetched.get('quality_grade')}")
        info(f"Captive:       {fetched.get('captive')}")
        info(f"Geoprivacy:    {fetched.get('geoprivacy')}")
        info(f"Description:   {fetched.get('description')!r}")
        photos = fetched.get("photos") or []
        attached = api.count_attached_photos(observation_id)
        if attached:
            ok(f"{attached} photo(s) attached (authoritative, via Rails)")
            if not photos:
                info(
                    "The v1 search index still reports 0 photos. It lags by "
                    "minutes;\n         never trust it to confirm an upload."
                )
        else:
            fail("No photos attached to the observation")
            exit_code = 1

        # -- 7. Update metadata ------------------------------------------
        step("Update metadata and verify the change round-trips")
        stamp = datetime.now().astimezone().isoformat(timespec="seconds")
        new_description = f"{args.description} [updated {stamp}]"
        try:
            api.update_observation(
                observation_id,
                {
                    "description": new_description,
                    "positional_accuracy": 25,
                },
            )
            ok("PUT accepted")
        except InatApiError as exc:
            fail(f"Update failed: {exc}")
            exit_code = 1
        else:
            reread = api.get_observation(observation_id)
            if (reread.get("description") or "") == new_description:
                ok("Description change confirmed on re-read")
            else:
                fail(
                    "Description did not round-trip. Got: "
                    f"{reread.get('description')!r}"
                )
                exit_code = 1
            info(f"positional_accuracy: {reread.get('positional_accuracy')}")

        # -- 8. Determination --------------------------------------------
        step("Read the current determination")
        current = api.get_observation(observation_id)
        determination = api.determination(current)
        for key, value in determination.items():
            info(f"{key}: {value}")

        identifications = api.get_identifications(observation_id)
        ok(f"{len(identifications)} identification(s) on this observation")
        for ident in identifications:
            ident_taxon = ident.get("taxon") or {}
            info(
                f"- {ident_taxon.get('name')} ({ident_taxon.get('rank')}) "
                f"by {(ident.get('user') or {}).get('login')} "
                f"[{ident.get('category')}] current={ident.get('current')}"
            )

        if determination.get("taxon_id"):
            det_taxon = api.get_taxon(determination["taxon_id"])
            info("Keyword hierarchy from the current determination:")
            for depth, keyword in enumerate(api.build_keyword_path(det_taxon)):
                info(f"{'  ' * depth}{keyword}")

    finally:
        # -- 9. Clean up --------------------------------------------------
        if args.delete:
            step("Delete the test observation")
            try:
                api.delete_observation(observation_id)
                ok(f"Deleted observation {observation_id}")
            except InatApiError as exc:
                fail(f"Delete failed: {exc}")
                exit_code = 1
        else:
            print(
                f"\nLeaving observation {observation_id} in place. "
                f"Delete it with --delete, or at\n"
                f"  https://www.inaturalist.org/observations/{observation_id}"
            )

    print("\n" + "=" * 72)
    print("RESULT: " + ("ALL CHECKS PASSED" if exit_code == 0 else "SOME CHECKS FAILED"))
    print("=" * 72)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
