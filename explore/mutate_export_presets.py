"""Prove the ExportPresets tests catch what they claim to.

This module reads a file format nobody documented, off a path nobody
documented, and hands the result to an export session. Every mutation here is
a plausible misreading whose only symptom in Lightroom is an upload that
looks fine and is not what the preset said.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

TARGET = Path(__file__).parent.parent / "plugin" / "pinned.lrplugin" / "ExportPresets.lua"

MUTATIONS = [
    (
        "reads only the appData root, missing presets stored with the catalog",
        "  local folder = catalogFolder()\n  if folder then",
        "  local folder = catalogFolder()\n  if false then",
    ),
    (
        "reads only the catalog root, missing everyone's normal presets",
        "  local appData = LrPathUtils.getStandardFilePath(\"appData\")\n  if appData then",
        "  local appData = LrPathUtils.getStandardFilePath(\"appData\")\n  if false then",
    ),
    (
        "looks only at the top of the preset folder, missing User Presets",
        "ExportPresets.MAX_DEPTH = 3",
        "ExportPresets.MAX_DEPTH = 1",
    ),
    (
        "treats a watermark preset as an export preset",
        "  if parsed.type ~= wantedType then",
        "  if false then",
    ),
    (
        "lists the same preset once per root it appears in",
        "      elseif entry.id and not seen[entry.id] then",
        "      elseif entry.id then",
    ),
    (
        "offers presets that export to Email, which cannot render a file",
        "        if entry.provider ~= ExportPresets.FILE_PROVIDER then",
        "        if false then",
    ),
    (
        "drops unusable presets instead of explaining them",
        "        presets[#presets + 1] = entry",
        "        if entry.usable then presets[#presets + 1] = entry end",
    ),
    (
        "lets a preset choose the export provider, handing photos elsewhere",
        "  exportServiceProvider = true,",
        "  exportServiceProvider = false,",
    ),
    (
        "lets a preset move the render destination, so the files are lost",
        "  export_destinationType = true,\n  export_destinationPathPrefix = true,",
        "  export_destinationType = false,\n  export_destinationPathPrefix = false,",
    ),
    (
        "lets a preset re-import every uploaded photo into the catalog",
        "  reimportExportedPhoto = true,",
        "  reimportExportedPhoto = false,",
    ),
    (
        "lets a preset halt the render with a collision dialog",
        "  collisionHandling = true,",
        "  collisionHandling = false,",
    ),
    (
        "lets a DNG preset send iNaturalist something it cannot read",
        "  format = true,",
        "  format = false,",
    ),
    (
        "lets a preset send the keyword hierarchy back to iNaturalist",
        "  metadata_keywordOptions = true,",
        "  metadata_keywordOptions = false,",
    ),
    (
        "forgets the LR_ prefix, so Lightroom ignores every preset key",
        '    settings["LR_" .. key] = entry',
        "    settings[key] = entry",
    ),
    (
        "reads the width in long edge mode, shrinking uploads to a stale value",
        "    local result = {\n      pixels  = height,",
        "    local result = {\n      pixels  = width,",
    ),
    (
        "says nothing about the size value the preset's mode ignores",
        "    if width and height and width ~= height then",
        "    if false then",
    ),
    (
        "calls a size difference out even when there is none",
        "    if width and height and width ~= height then",
        "    if width and height then",
    ),
    (
        "reports a full-size preset as some resolution it does not have",
        "  if not value.size_doConstrain then",
        "  if false then",
    ),
    (
        "misses a watermark that has been deleted, so uploads lose it silently",
        "  if available and available[id] == nil then",
        "  if false then",
    ),
    (
        "warns about a watermark that is perfectly fine",
        "  if available and available[id] == nil then",
        "  if available then",
    ),
    (
        "treats the built-in copyright watermark as a real one",
        "  if id == ExportPresets.BUILT_IN_WATERMARK then",
        "  if false then",
    ),
    (
        "warns about watermarks on presets that do not use one",
        "  if not value.useWatermark then return nil end",
        "  if false then return nil end",
    ),
    (
        "reads the resource key instead of the title a person should see",
        '  local text = title:match("^%$%$%$/[^=]*=(.*)$")\n  return text or title',
        "  return title",
    ),
    (
        "returns a half-read preset when the file is truncated",
        '      return nil, index, "unterminated table"',
        "      return result, index",
    ),
    (
        "reads a nested list of tables as if it were flat",
        '  if char == "{" then\n    return parseTable(text, index)\n  end',
        '  if char == "{" then\n    local _, stop = text:find("^[^}]*}", index)\n'
        "    return {}, (stop or index) + 1\n  end",
    ),
    (
        "loses the escape in a Windows path, so the value is wrong",
        '      if c == "\\\\" then\n        out[#out + 1] = text:sub(position + 1, position + 1)\n'
        "        position = position + 2",
        '      if false then\n        out[#out + 1] = text:sub(position + 1, position + 1)\n'
        "        position = position + 2",
    ),
    (
        "reads numbers as the strings they are written as",
        "  if number and tonumber(number) then\n    return tonumber(number), afterNumber",
        "  if number and tonumber(number) then\n    return number, afterNumber",
    ),
    (
        "scans an unknown constructor to the next comma, landing inside it",
        "    if text:sub(index, index) == \"(\" then",
        "    if false then",
    ),
    (
        "accepts any file extension, reading whatever else is in the folder",
        "        if ExportPresets.EXTENSIONS[extension] then",
        "        if true then",
    ),
]


def main() -> int:
    original = TARGET.read_text(encoding="utf-8")
    survivors = []

    try:
        for description, old, new in MUTATIONS:
            if old not in original:
                print(f"SKIP  {description}\n      (anchor not found -- fix the script)")
                survivors.append(description)
                continue

            TARGET.write_text(original.replace(old, new, 1), encoding="utf-8")

            result = subprocess.run(
                [sys.executable, "-m", "pytest", "test_export_presets_lua.py",
                 "test_render_photo_lua.py", "-q", "--no-header", "-x",
                 "--tb=no", "-p", "no:cacheprovider"],
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
        TARGET.write_text(original, encoding="utf-8")

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
