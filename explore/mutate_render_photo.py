"""Prove the RenderPhoto tests catch what they claim to.

Every mutation here is a plausible mistake whose only symptom in Lightroom is
a file that uploads perfectly and is wrong.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

TARGET = Path(__file__).parent.parent / "plugin" / "inat.lrplugin" / "RenderPhoto.lua"

MUTATIONS = [
    (
        "renders through the publish-style provider that cannot use a temp folder",
        'LR_exportServiceProvider   = "com.adobe.ag.export.file"',
        'LR_exportServiceProvider   = "com.adobe.lightroom.export.flickr"',
    ),
    (
        "writes the render into the user's own folders",
        'LR_export_destinationPathPrefix = options.folder,',
        'LR_export_destinationPathPrefix = "/home/tester/Pictures",',
    ),
    (
        "goes back to the tempFolder type the host rejected",
        'LR_export_destinationType       = "specificFolder",',
        'LR_export_destinationType       = "tempFolder",',
    ),
    (
        "renders into a subfolder the caller does not know about",
        "LR_export_useSubfolder          = false",
        "LR_export_useSubfolder          = true",
    ),
    (
        "re-imports every uploaded photo back into the catalog",
        "LR_reimportExportedPhoto        = false",
        "LR_reimportExportedPhoto        = true",
    ),
    (
        "opens a file browser on the temp folder mid-upload",
        'LR_export_postProcessing        = "doNothing"',
        'LR_export_postProcessing        = "revealInFinder"',
    ),
    (
        "stops the render with a dialog when two photos share a name",
        'LR_collisionHandling       = "rename"',
        'LR_collisionHandling       = "ask"',
    ),
    (
        "silently drops a photo when two share a name",
        'LR_collisionHandling       = "rename"',
        'LR_collisionHandling       = "overwrite"',
    ),
    (
        "tries to render videos it cannot render",
        "LR_includeVideoFiles       = false",
        "LR_includeVideoFiles       = true",
    ),
    (
        "never creates the folder it is about to render into",
        "  LrFileUtils.createAllDirectories(path)\n  return path",
        "  return path",
    ),
    (
        "shares one temp folder between concurrent renders",
        '  local name = "inat-lightroom-" .. tostring(os.time()) ..\n               "-" .. tostring(math.random(100000, 999999))',
        '  local name = "inat-lightroom"',
    ),
    (
        "leaves temp files somewhere the OS will never clean up",
        'local root = LrPathUtils.getStandardFilePath("temp")',
        'local root = LrPathUtils.getStandardFilePath("home")',
    ),
    (
        "does not tell the caller which folder to clean up",
        "  return rendered, failures, folder\nend",
        "  return rendered, failures\nend",
    ),
    (
        "ignores the folder the caller supplied",
        "  local folder = options.folder or RenderPhoto.makeTempFolder()",
        "  local folder = RenderPhoto.makeTempFolder()",
    ),
    (
        "lets a locked file turn a finished upload into an error",
        "  local ok, err = pcall(function()\n    LrFileUtils.delete(folder)\n  end)",
        "  local ok, err = true, nil\n  LrFileUtils.delete(folder)",
    ),
    (
        "tries to delete nothing when there was nothing to render",
        "  if not folder then return false end",
        "",
    ),
    (
        "leaks the temp folder when a suggestion render fails",
        "    RenderPhoto.cleanUp(folder)\n    -- failures can be empty",
        "    -- failures can be empty",
    ),
    (
        "uploads the original format rather than JPEG",
        'LR_format                  = "JPEG"',
        'LR_format                  = "ORIGINAL"',
    ),
    (
        "passes JPEG quality as a percentage",
        "LR_jpeg_quality            = RenderPhoto.QUALITY / 100",
        "LR_jpeg_quality            = RenderPhoto.QUALITY",
    ),
    (
        "sends the full-size original",
        "LR_size_doConstrain        = true",
        "LR_size_doConstrain        = false",
    ),
    (
        "upscales small photos to hit the long edge",
        "LR_size_doNotEnlarge       = true",
        "LR_size_doNotEnlarge       = false",
    ),
    (
        "exports the keyword hierarchy, sending iNaturalist its own taxonomy back",
        'LR_metadata_keywordOptions = "flat"',
        'LR_metadata_keywordOptions = "nested"',
    ),
    (
        "ignores the requested render size",
        "LR_size_maxHeight          = maxPixels,\n    LR_size_maxWidth           = maxPixels,",
        "LR_size_maxHeight          = RenderPhoto.MAX_PX,\n    LR_size_maxWidth           = RenderPhoto.MAX_PX,",
    ),
    (
        "strips location from every upload",
        "LR_removeLocationMetadata  = prefs.render_remove_location or false",
        "LR_removeLocationMetadata  = true",
    ),
    (
        "turns the watermark on without naming one, so none is drawn",
        'settings.LR_watermarking_id = "<simpleCopyrightWatermark>"',
        "settings.LR_watermarking_id = nil",
    ),
    (
        "watermarks every upload",
        "LR_useWatermark            = prefs.render_use_watermark or false",
        "LR_useWatermark            = true",
    ),
    (
        "hardcodes the metadata option instead of honouring the setting",
        'LR_embeddedMetadataOption  = prefs.render_metadata_option or "all"',
        'LR_embeddedMetadataOption  = "copyrightOnly"',
    ),
    (
        "drops the SDK prefix, so Lightroom ignores the size settings entirely",
        "LR_size_resizeType         =",
        "size_resizeType         =",
    ),
    (
        "builds an export session even when there is nothing to render",
        "  if not photos or #photos == 0 then\n    return {}, {}, nil\n  end",
        "  photos = photos or {}",
    ),
    (
        "treats the rendition as the first loop value, ignoring the index",
        "    local rendition = second or first",
        "    local rendition = first",
    ),
    (
        "ignores waitForRender's success flag, so an error message becomes a path",
        "    local ok, pathOrMessage = rendition:waitForRender()\n    if ok then",
        "    local ok, pathOrMessage = rendition:waitForRender()\n    if true then",
    ),
    (
        "loses which photo each rendered file came from",
        "rendered[#rendered + 1] = { photo = rendition.photo, path = pathOrMessage }",
        "rendered[#rendered + 1] = { path = pathOrMessage }",
    ),
    (
        "swallows render failures without logging them",
        '      logger:warn("Render failed: " .. reason)',
        "      local _ = reason",
    ),
    (
        "renders a full-size image just to ask the computer vision a question",
        "  local rendered, failures, folder = RenderPhoto.render({ photo }, {\n    maxPixels = RenderPhoto.SUGGEST_MAX_PX,\n  })",
        "  local rendered, failures, folder = RenderPhoto.render({ photo }, {})",
    ),
    (
        "shows the user the literal text nil when Lightroom gives no reason",
        "      local reason = pathOrMessage and tostring(pathOrMessage)\n                     or RenderPhoto.FAILED_MESSAGE",
        "      local reason = tostring(pathOrMessage)",
    ),
    (
        "returns no reason when a render yields no renditions at all",
        "    return nil, failures[1] or RenderPhoto.FAILED_MESSAGE",
        "    return nil, failures[1]",
    ),
    (
        "reports success after a failed suggestion render",
        "  if #rendered == 0 then",
        "  if false then",
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
                [sys.executable, "-m", "pytest", "test_render_photo_lua.py", "-q",
                 "--no-header", "-x", "--tb=no", "-p", "no:cacheprovider"],
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
