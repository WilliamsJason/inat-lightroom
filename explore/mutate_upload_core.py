"""Prove the UploadCore tests actually catch the bugs they claim to.

Each mutation is a plausible way of getting the code wrong. A mutation that no
test notices means the test suite is decoration, not verification.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

PLUGIN = Path(__file__).parent.parent / "plugin" / "inat.lrplugin"
TARGETS = {
    "UploadCore": PLUGIN / "UploadCore.lua",
}

MUTATIONS = [
    (
        "UploadCore",
        "only the first photo of the group is linked",
        "    for _, photo in ipairs(photos) do\n      photo:setPropertyForPlugin(_PLUGIN, \"inat_observation_id\"",
        "    for _, photo in ipairs({ photos[1] }) do\n      photo:setPropertyForPlugin(_PLUGIN, \"inat_observation_id\"",
    ),
    (
        "UploadCore",
        "the observation UUID is never written",
        "      if uuid then\n        photo:setPropertyForPlugin(_PLUGIN, \"inat_observation_uuid\", tostring(uuid))\n      end",
        "",
    ),
    (
        "UploadCore",
        "unlink also wipes the user's species guess",
        '  "inat_common_name",\n}',
        '  "inat_common_name",\n  "inat_species_guess",\n}',
    ),
    (
        "UploadCore",
        "unlink forgets the observation ID itself",
        '  "inat_observation_id",\n  "inat_observation_uuid",',
        '  "inat_observation_uuid",',
    ),
    (
        "UploadCore",
        "unlink opens a transaction even with nothing to do",
        "  if not photos or #photos == 0 then return 0 end",
        "",
    ),
    (
        "UploadCore",
        "geoprivacy falls through as nil when unset",
        'geoprivacy = settings.inat_geoprivacy or "open",',
        "geoprivacy = settings.inat_geoprivacy,",
    ),
    (
        "UploadCore",
        "an empty species guess is sent as an empty string",
        "  local value = photo:getPropertyForPlugin(_PLUGIN, id)\n  if value == nil or value == \"\" then return nil end",
        "  local value = photo:getPropertyForPlugin(_PLUGIN, id)\n  if value == nil then return nil end",
    ),
    (
        "UploadCore",
        "location is uploaded regardless of the setting",
        "  if settings.inat_upload_location then",
        "  if true then",
    ),
    (
        "UploadCore",
        "a photo already in this run's group is looked up again",
        "    if seen[uuid] then\n      return seen[uuid], uuid, nil\n    end",
        "",
    ),
    (
        "UploadCore",
        "the recreated observation loses its UUID, splitting the group",
        "  local params = UploadCore.observationParamsFor(settings, photo)\n  if uuid then\n    params.uuid = uuid\n  end",
        "  local params = UploadCore.observationParamsFor(settings, photo)",
    ),
    (
        "UploadCore",
        "a failed update is swallowed instead of warned about",
        "        if warnings then\n          warnings[#warnings + 1] = \"Observation \" .. tostring(existing.id)",
        "        if false then\n          warnings[#warnings + 1] = \"Observation \" .. tostring(existing.id)",
    ),
    (
        "UploadCore",
        "an existing observation is never updated with current details",
        "      local _, updateErr = api:updateObservation(",
        "      local _, updateErr = nil, nil; local _unused = (function() end)(",
    ),
]


def main() -> int:
    backups = {name: path.read_text(encoding="utf-8") for name, path in TARGETS.items()}
    survivors = []

    try:
        for name, description, old, new in MUTATIONS:
            path = TARGETS[name]
            source = backups[name]

            if old not in source:
                print(f"SKIP  {description}\n      (anchor not found -- fix the script)")
                survivors.append(description)
                continue

            path.write_text(source.replace(old, new, 1), encoding="utf-8")

            result = subprocess.run(
                [sys.executable, "-m", "pytest", "test_upload_core_lua.py", "-q",
                 "--no-header", "-x", "--tb=no"],
                cwd=Path(__file__).parent,
                capture_output=True,
                text=True,
            )

            if result.returncode == 0:
                print(f"SURVIVED  {description}")
                survivors.append(description)
            else:
                print(f"caught    {description}")
    finally:
        for name, path in TARGETS.items():
            path.write_text(backups[name], encoding="utf-8")

    print()
    if survivors:
        print(f"{len(survivors)} of {len(MUTATIONS)} mutations survived:")
        for s in survivors:
            print(f"  - {s}")
        return 1

    print(f"All {len(MUTATIONS)} mutations caught.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
