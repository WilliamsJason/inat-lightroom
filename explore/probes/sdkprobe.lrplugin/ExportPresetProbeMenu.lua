--[[
  ExportPresetProbeMenu.lua
  -------------------------
  Can this plugin offer the user's own export presets, and does a preset's
  named watermark survive into LrExportSession?

  A user who watermarks his iNaturalist uploads asked for his own export preset
  instead of the plugin's hardcoded render settings. Dumping the binaries got
  most of the way and stopped at the one thing strings cannot settle.

  What the binaries already answered, so this probe does not have to:

    * Export.lrmodule carries the template browser's data model verbatim --
      `templateType = "Export", templateDirectoryName = "Export Presets"` --
      and ui.dll resolves that folder against `getStandardFilePath ... appData`,
      which is a path token a plugin has.
    * ui.dll branches on AgTemplateBrowser_storePresetsWithCatalog and moves the
      folder next to the catalog, under ZSTR "$$$/AgTemplateBrowserDataModel/
      CatalogBasedPresetFolderName/LightroomSettings=Lightroom Settings". That
      is a *host* preference; LrPrefs is per-plugin and cannot read it, so both
      roots get scanned below rather than one being chosen.
    * LibraryToolkit.dll loads an .lrtemplate with
      `loadstring ... loadfile ... setfenv ... ZSTR ... pcall`, which is what
      step 0 tries from inside a plugin.
    * On this machine the watermark presets on disk carry
      `id = "8D95BD23-F240-46D7-96BA-522AC2F985D4"` and the host's own
      preferences carry `AgExport_watermarking_id` set to the same GUID, byte
      for byte. Export.lrmodule's addRenditionsForPhotos resolves it through
      `AgWatermarking.watermarkFromID`, and the Export dialog has an
      "$$$/AgExport/Watermark/Synopsis/UnknownWM=Unknown watermark" string for
      an id it cannot resolve.

  All of which says a named watermark id *should* work when it comes from a
  preset file. It is still inference from strings, and a feature whose headline
  benefit silently does nothing is worse than no feature, so step 4 renders the
  same photo four ways and compares bytes.

  The renders are the point, so they are built to be comparable: cases (a) to
  (d) hold the photo, the pixel dimensions and the JPEG quality constant, and
  vary only the watermark. Case (e) varies everything at once on purpose -- it
  is a whole user preset -- so it is reported on its own and never compared
  against the others.

  This is a separate plugin from pinned.lrplugin and deliberately shares no
  code with it, so the settings table below is a copy of RenderPhoto's rather
  than a require. A probe that imported the thing it is measuring would answer
  questions about this repo instead of about Lightroom.
--]]

local LrApplication     = import "LrApplication"
local LrDialogs         = import "LrDialogs"
local LrExportSession   = import "LrExportSession"
local LrFileUtils       = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils       = import "LrPathUtils"
local LrProgressScope   = import "LrProgressScope"
local LrTasks           = import "LrTasks"

local Report = require "Report"

-- Held constant across cases (a) to (d), which is what makes a byte-size
-- difference between them mean "the watermark drew" rather than "something
-- else changed".
local PROBE_MAX_PX  = 2048
local PROBE_QUALITY = 90

local BUILT_IN_WATERMARK = "<simpleCopyrightWatermark>"

-- A GUID no preset can own. Whether this raises, falls back or silently
-- renders decides what the plugin must do about a watermark the user deleted
-- after saving the preset that names it.
local MISSING_WATERMARK = "00000000-0000-0000-0000-000000000000"

--------------------------------------------------------------------------------
-- Reading .lrtemplate files
--------------------------------------------------------------------------------

--- Parse a preset file's text the way LibraryToolkit.dll does.
--
-- The file is Lua: `s = { id = ..., title = ZSTR "...", value = { ... } }`.
-- ZSTR is a call, not syntax, so a stub that hands the string back is enough to
-- make the chunk load; setfenv keeps it from reaching anything else.
--
-- @return table, or nil plus the failure text verbatim
local function parsePreset(source)
  if type(loadstring) ~= "function" or type(setfenv) ~= "function" then
    return nil, "loadstring/setfenv not available in this sandbox"
  end

  local chunk, syntaxError = loadstring(source, "lrtemplate")
  if not chunk then return nil, tostring(syntaxError) end

  local env = { ZSTR = function(text) return text end }
  setfenv(chunk, env)

  local ok, runError = pcall(chunk)
  if not ok then return nil, tostring(runError) end
  if type(env.s) ~= "table" then
    return nil, "no table named s (got " .. type(env.s) .. ")"
  end

  return env.s
end

--- The text a person should see for a preset.
--
-- Shipped presets store a resource key -- "$$$/AgExport/Preset/ForEMail=For
-- Email" -- and the user's own store a plain string. The display text is
-- whatever follows the first "=".
local function displayTitle(title)
  if type(title) ~= "string" then return "(untitled)" end
  local text = title:match("^%$%$%$/[^=]*=(.*)$")
  return text or title
end

local function readFile(path)
  local ok, contents = pcall(function()
    return LrFileUtils.readFile(path)
  end)
  if ok and type(contents) == "string" then return contents end

  -- LrFileUtils.readFile is the documented route; io.open is the fallback
  -- because a probe that cannot read the file has nothing else to say.
  local handle = io.open(path, "r")
  if not handle then return nil, "could not open " .. tostring(path) end
  local body = handle:read("*a")
  handle:close()
  return body
end

--- Every file under a directory, depth-limited.
--
-- Depth matters: export presets sit one folder down ("Export Presets/User
-- Presets/Mine.lrtemplate") while watermarks sit directly in their folder, and
-- an unbounded walk of a mis-resolved root could wander a whole home directory.
local function filesUnder(dir, depth, found)
  found = found or {}
  if depth < 0 then return found end

  local ok = pcall(function()
    for entry in LrFileUtils.directoryEntries(dir) do
      if LrFileUtils.exists(entry) == "directory" then
        filesUnder(entry, depth - 1, found)
      else
        found[#found + 1] = entry
      end
    end
  end)
  if not ok then return found end

  table.sort(found)
  return found
end

--------------------------------------------------------------------------------
-- Where Lightroom keeps them
--------------------------------------------------------------------------------

--- The two roots a preset folder can be under, with how each was derived.
local function presetRoots(catalog, folderName)
  local roots = {}

  local appData = LrPathUtils.getStandardFilePath("appData")
  if appData then
    roots[#roots + 1] = {
      label = 'getStandardFilePath("appData")',
      path  = LrPathUtils.child(appData, folderName),
    }
  end

  -- The catalog-adjacent copy, used when the host's
  -- AgTemplateBrowser_storePresetsWithCatalog is on. Scanned unconditionally
  -- because a plugin cannot read that preference: an empty result costs one
  -- directory listing, and missing it costs the user their presets.
  local catalogPath = catalog and catalog:getPath()
  if catalogPath then
    local beside = LrPathUtils.parent(catalogPath)
    if beside then
      roots[#roots + 1] = {
        label = "beside the catalog (Lightroom Settings)",
        path  = LrPathUtils.child(
          LrPathUtils.child(beside, "Lightroom Settings"), folderName),
      }
    end
  end

  return roots
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

--- A directory of our own under the system temp folder, deleted afterwards.
local function makeTempFolder()
  local root = LrPathUtils.getStandardFilePath("temp")
  local path = LrPathUtils.child(root, "inat-preset-probe-"
    .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)))
  LrFileUtils.createAllDirectories(path)
  return path
end

--- The plugin's own render settings, copied from RenderPhoto.settingsFor.
--
-- Complete rather than interesting: Lightroom's fillInDefaultSettings fills an
-- omitted key from the user's *last export*, so a partial table measures that
-- person's habits instead of the watermark.
local function baseSettings(folder)
  return {
    LR_exportServiceProvider        = "com.adobe.ag.export.file",

    LR_export_destinationType       = "specificFolder",
    LR_export_destinationPathPrefix = folder,
    LR_export_destinationPathSuffix = "",
    LR_export_useSubfolder          = false,

    LR_export_postProcessing        = "doNothing",
    LR_reimportExportedPhoto        = false,
    LR_reimport_stackWithOriginal   = false,

    LR_collisionHandling            = "rename",
    LR_renamingTokensOn             = false,
    LR_tokens                       = "{{image_name}}",
    LR_tokenCustomString            = "",
    LR_initialSequenceNumber        = 1,
    LR_extensionCase                = "lowercase",

    LR_format                       = "JPEG",
    LR_jpeg_quality                 = PROBE_QUALITY / 100,
    LR_jpeg_useLimitSize            = false,
    LR_jpeg_limitSize               = 100,
    LR_export_colorSpace            = "sRGB",

    LR_includeVideoFiles            = false,

    LR_size_doConstrain             = true,
    LR_size_userWantsConstrain      = true,
    LR_size_maxHeight               = PROBE_MAX_PX,
    LR_size_maxWidth                = PROBE_MAX_PX,
    LR_size_resizeType              = "longEdge",
    LR_size_units                   = "pixels",
    LR_size_doNotEnlarge            = true,
    LR_size_resolution              = 72,
    LR_size_resolutionUnits         = "inch",

    LR_outputSharpeningOn           = false,
    LR_outputSharpeningLevel        = 2,
    LR_outputSharpeningMedia        = "screen",

    LR_useWatermark                 = false,
    LR_removeLocationMetadata       = false,
    LR_removeFaceMetadata           = false,
    LR_embeddedMetadataOption       = "all",
    LR_metadata_keywordOptions      = "flat",
  }
end

--- What the plugin would have to impose on any preset the user picks.
--
-- Listed here as a table rather than described in prose because case (e) has
-- to apply exactly this set, and the production code will too.
local function applyOverrides(settings, folder)
  settings.LR_exportServiceProvider        = "com.adobe.ag.export.file"
  settings.LR_export_destinationType       = "specificFolder"
  settings.LR_export_destinationPathPrefix = folder
  settings.LR_export_destinationPathSuffix = ""
  settings.LR_export_useSubfolder          = false
  settings.LR_export_postProcessing        = "doNothing"
  settings.LR_reimportExportedPhoto        = false
  settings.LR_reimport_stackWithOriginal   = false
  settings.LR_collisionHandling            = "rename"
  settings.LR_renamingTokensOn             = false
  settings.LR_tokens                       = "{{image_name}}"
  settings.LR_tokenCustomString            = ""
  settings.LR_extensionCase                = "lowercase"
  settings.LR_format                       = "JPEG"
  settings.LR_includeVideoFiles            = false
  settings.LR_metadata_keywordOptions      = "flat"

  -- A preset saved for DNG or TIFF carries no jpeg_quality at all, and an
  -- omitted key is filled from the user's last export rather than from a
  -- default -- so the quality has to be supplied even when everything else
  -- about the preset is honoured.
  if settings.LR_jpeg_quality == nil then
    settings.LR_jpeg_quality = PROBE_QUALITY / 100
  end

  return settings
end

--- A preset's `value` table as export settings.
--
-- The keys in a preset file are unprefixed; exportSettings wants them
-- LR_-prefixed. That is the whole mapping.
local function settingsFromPreset(value)
  local settings = {}
  for key, entry in pairs(value) do
    settings["LR_" .. key] = entry
  end
  return settings
end

--- Render one photo with one settings table. Returns bytes, path, error.
--
-- MUST be called from inside a task: addRenditionsForPhotos asserts it is not
-- on the main UI task, and asking for renditions() is what starts the export.
local function renderOnce(photo, settings)
  local session = LrExportSession {
    photosToExport = { photo },
    exportSettings = settings,
  }

  for _, rendition in session:renditions() do
    local ok, pathOrMessage = rendition:waitForRender()
    if not ok then
      return nil, nil, tostring(pathOrMessage or "no reason given")
    end

    local attributes = LrFileUtils.fileAttributes(pathOrMessage)
    local size = attributes and attributes.fileSize
    return size, pathOrMessage, nil
  end

  return nil, nil, "no renditions were produced"
end

--------------------------------------------------------------------------------
-- The probe
--------------------------------------------------------------------------------

local function probeSandbox(report)
  report:step("Lua sandbox")
  report:add("Step 0 - can a plugin load a .lrtemplate at all?")
  report:addf("  %-24s %s", "loadstring", type(loadstring))
  report:addf("  %-24s %s", "setfenv", type(setfenv))
  report:addf("  %-24s %s", "loadfile", type(loadfile))
  report:addf("  %-24s %s", "pcall", type(pcall))

  -- Tried on a literal that has both things a real preset has: a ZSTR call and
  -- a nested value table. A sandbox that allows loadstring but blocks setfenv
  -- would pass the type checks above and fail here.
  local sample = 's = { id = "X", title = ZSTR "$$$/A/B=Display Name", '
    .. 'type = "Export", value = { jpeg_quality = 0.9 } }'
  local parsed, err = parsePreset(sample)

  if parsed then
    report:addf("  %-24s ok  (title %q -> %q, jpeg_quality %s)",
      "parse a literal", tostring(parsed.title),
      displayTitle(parsed.title), tostring(parsed.value.jpeg_quality))
  else
    report:addf("  %-24s FAILED  %s", "parse a literal", tostring(err))
  end

  report:blank()
  return parsed ~= nil
end

local function probeRoots(report, catalog, folderName, heading)
  report:addf("%s", heading)

  local roots = presetRoots(catalog, folderName)
  local files = {}

  for _, root in ipairs(roots) do
    local exists = LrFileUtils.exists(root.path)
    report:addf("  %s", root.label)
    report:addf("    %s", tostring(root.path))
    report:addf("    exists: %s", tostring(exists))

    if exists == "directory" then
      local found = filesUnder(root.path, 2)
      if #found == 0 then
        report:add("    (empty)")
      end
      for _, path in ipairs(found) do
        report:addf("    %-12s %s", "." ..
          tostring(LrPathUtils.extension(path)), path)
        files[#files + 1] = path
      end
    end
  end

  report:blank()
  return files
end

--- Parse each file and report what it is. Returns the presets that parsed.
local function probeParsing(report, files, wantedType)
  local presets = {}

  for _, path in ipairs(files) do
    local name = LrPathUtils.leafName(path)
    local source, readError = readFile(path)

    if not source then
      report:addf("  %-40s READ FAILED  %s", name, tostring(readError))
    else
      local parsed, err = parsePreset(source)
      if not parsed then
        -- Verbatim: a parse failure's own words are the only thing that says
        -- whether the file is a format this reader does not know or a sandbox
        -- refusing to run it.
        report:addf("  %-40s PARSE FAILED  %s", name, tostring(err))
      else
        local value    = type(parsed.value) == "table" and parsed.value or {}
        local provider = value.exportServiceProvider

        local keyCount = 0
        for _ in pairs(value) do keyCount = keyCount + 1 end

        report:addf("  %-40s %s", name, tostring(parsed.type))
        report:addf("      id       %s", tostring(parsed.id))
        report:addf("      title    %s", displayTitle(parsed.title))
        report:addf("      provider %s", tostring(provider))
        report:addf("      value    %d key(s)", keyCount)

        if parsed.type == wantedType then
          presets[#presets + 1] = {
            path = path, name = name, id = parsed.id,
            title = displayTitle(parsed.title),
            value = value, provider = provider,
          }
        end
      end
    end
  end

  report:blank()
  return presets
end

--- One render case, reported as a labelled line.
local function runCase(report, results, letter, description, photo, settings)
  local took, outcome = Report.timed(function()
    local size, path, err = renderOnce(photo, settings)
    return { size = size, path = path, err = err }
  end)

  outcome = outcome or {}
  local record = {
    letter = letter, description = description,
    size = outcome.size, err = outcome.err, took = took,
  }
  results[letter] = record

  if outcome.err then
    report:addf("  (%s) %-34s FAILED  %s", letter, description,
      tostring(outcome.err))
  else
    report:addf("  (%s) %-34s %9s bytes   %s", letter, description,
      tostring(outcome.size), took)
  end

  return record
end

--- What the five renders mean, spelled out.
--
-- A person reads this and then decides whether to build the feature, so the
-- comparisons are stated rather than left as five numbers to subtract.
local function concludeRenders(report, results, namedId)
  local a, b, c, d = results.a, results.b, results.c, results.d

  report:blank()
  report:add("Conclusion:")

  if not (a and a.size) then
    report:add("  (a) did not render, so nothing can be compared.")
    return
  end

  if not (c and c.size) then
    report:add("  (c) did not render: a named watermark id was rejected"
      .. " outright, or no named watermark preset was found to try.")
  else
    if c.size ~= a.size then
      report:addf("  (c) vs (a): DIFFERENT (%d vs %d bytes)"
        .. " -- the named watermark drew.", c.size, a.size)
    else
      report:addf("  (c) vs (a): IDENTICAL (%d bytes)"
        .. " -- the named watermark did NOT draw. The feature's headline"
        .. " benefit does nothing; do not ship preset watermark pass-through.",
        c.size)
    end

    if b and b.size then
      if c.size ~= b.size then
        report:addf("  (c) vs (b): DIFFERENT (%d vs %d bytes)"
          .. " -- it was watermark %s, not the built-in one.",
          c.size, b.size, tostring(namedId))
      else
        report:addf("  (c) vs (b): IDENTICAL (%d bytes)"
          .. " -- suspicious: the named id may have fallen back to the"
          .. " built-in copyright watermark.", c.size)
      end
    else
      report:add("  (c) vs (b): (b) did not render, so this cannot be told.")
    end
  end

  if not d then
    report:add("  (d) was not run.")
  elseif d.err then
    report:addf("  (d) a GUID matching no preset RAISED: %s", tostring(d.err))
  elseif d.size == a.size then
    report:addf("  (d) a GUID matching no preset SILENTLY SKIPPED the"
      .. " watermark (%d bytes, same as (a)).", d.size)
  elseif b and b.size and d.size == b.size then
    report:addf("  (d) a GUID matching no preset FELL BACK to the built-in"
      .. " watermark (%d bytes, same as (b)).", d.size)
  else
    report:addf("  (d) a GUID matching no preset rendered %d bytes, matching"
      .. " neither (a) nor (b).", d.size)
  end
end

--- The most interesting preset to try in case (e).
--
-- "Most interesting" is the user's own, because that is the thing the feature
-- exists to support and the thing nobody has tested. A shipped preset is the
-- fallback, and the rule that chose it is reported so the result is not read as
-- if a user preset had been exercised.
--
-- Presets naming another export service provider -- the shipped list alone has
-- com.adobe.ag.export.optical-media and .email -- are never candidates. Handing
-- one to LrExportSession either fails outright or routes the photo somewhere
-- else entirely, which is why the production code will have to filter on this
-- too.
local function pickPreset(presets)
  local fileExports = {}
  for _, preset in ipairs(presets) do
    if preset.provider == "com.adobe.ag.export.file" then
      fileExports[#fileExports + 1] = preset
    end
  end

  for _, preset in ipairs(fileExports) do
    if preset.path:find("User Presets", 1, true) then
      return preset, "the user's own"
    end
  end

  for _, preset in ipairs(fileExports) do
    if preset.value.format == "JPEG" then
      return preset, "shipped, JPEG (no user preset found)"
    end
  end

  return fileExports[1], "shipped (no user or JPEG preset found)"
end

local function probeRenders(report, catalog, watermarks, presets)
  report:step("Renders")
  report:add("Step 4 - does a named watermark survive into LrExportSession?")

  local photo = catalog:getTargetPhoto()
  if not photo then
    report:add("  NO PHOTO SELECTED. Select one photo in the Library grid and"
      .. " run this probe again; steps 0-3 above are still valid.")
    report:blank()
    return
  end

  local fileName = photo:getFormattedMetadata("fileName")
  report:addf("  photo: %s", tostring(fileName))
  report:addf("  cases (a)-(d) hold photo, %d px long edge and JPEG quality %d"
    .. " constant, so bytes differ only because of the watermark.",
    PROBE_MAX_PX, PROBE_QUALITY)

  local named = watermarks[1]
  if named then
    report:addf("  named watermark under test: %s = %s",
      tostring(named.title), tostring(named.id))
  else
    report:add("  no named watermark preset found, so (c) cannot be run."
      .. " Make one in Edit Watermarks and run this probe again.")
  end
  report:blank()

  local folder  = makeTempFolder()
  local results = {}

  -- Every case renders into the same throwaway directory, which is deleted
  -- below whatever happens. Collision handling is "rename", so four renders of
  -- one photo become four files rather than one overwritten four times --
  -- which is also what makes the byte sizes comparable at the end.
  local ok, err = LrTasks.pcall(function()
    local settingsA = baseSettings(folder)
    runCase(report, results, "a", "no watermark", photo, settingsA)

    local settingsB = baseSettings(folder)
    settingsB.LR_useWatermark    = true
    settingsB.LR_watermarking_id = BUILT_IN_WATERMARK
    runCase(report, results, "b", "built-in copyright watermark",
      photo, settingsB)

    if named then
      local settingsC = baseSettings(folder)
      settingsC.LR_useWatermark    = true
      settingsC.LR_watermarking_id = named.id
      runCase(report, results, "c", "named watermark preset", photo, settingsC)
    end

    local settingsD = baseSettings(folder)
    settingsD.LR_useWatermark    = true
    settingsD.LR_watermarking_id = MISSING_WATERMARK
    runCase(report, results, "d", "GUID matching no preset", photo, settingsD)
  end)

  if not ok then
    report:addf("  render cases stopped: %s", tostring(err))
  end

  concludeRenders(report, results, named and named.id)

  -- (e) is deliberately not comparable with the others: a whole user preset
  -- changes size, sharpening, quality and watermark at once. It is here to
  -- answer "does a real preset render at all once the overrides are applied",
  -- which is a different question from the watermark one.
  report:blank()
  report:add("Case (e) - a real export preset, mapped and overridden."
    .. " NOT comparable with (a)-(d):")

  local usable, why = pickPreset(presets)

  if not usable then
    report:add("  no file-export preset found to try.")
  else
    report:addf("  preset: %s  (%s -- %s)", usable.title, usable.name, why)
    report:addf("    format %s / useWatermark %s / watermarking_id %s",
      tostring(usable.value.format),
      tostring(usable.value.useWatermark),
      tostring(usable.value.watermarking_id))
    report:addf("    size %sx%s %s / sharpening %s / quality %s",
      tostring(usable.value.size_maxWidth),
      tostring(usable.value.size_maxHeight),
      tostring(usable.value.size_resizeType),
      tostring(usable.value.outputSharpeningOn),
      tostring(usable.value.jpeg_quality))

    local settingsE = applyOverrides(settingsFromPreset(usable.value), folder)
    runCase(report, results, "e", "user preset + overrides", photo, settingsE)
  end

  -- The files were only ever their own byte counts. Deleted whatever happened
  -- above, the way RenderPhoto.cleanUp does, so a probe run does not leave a
  -- pile of JPEGs in the user's temp folder.
  pcall(function() LrFileUtils.delete(folder) end)
  report:blank()
end

local function run(context)
  local catalog = LrApplication.activeCatalog()
  local report  = Report.new("iNat SDK Probe - Export Presets")

  local scope = LrProgressScope {
    title           = "iNat SDK probe: export presets",
    functionContext = context,
  }
  report:track(scope)

  report:add("=== Export preset probe ===")
  report:addf("catalog path: %s", tostring(catalog:getPath()))
  report:blank()

  probeSandbox(report)

  report:step("Preset locations")
  report:add("Step 1 - where the presets are:")
  local presetFiles = probeRoots(report, catalog, "Export Presets",
    "Export presets:")
  local watermarkFiles = probeRoots(report, catalog, "Watermarks",
    "Watermark presets:")

  report:step("Parsing presets")
  report:add("Step 2 - what each export preset file holds:")
  local presets = probeParsing(report, presetFiles, "Export")

  report:step("Parsing watermarks")
  report:add("Step 3 - named watermark presets and their ids:")
  local watermarks = probeParsing(report, watermarkFiles, "WatermarkingPreset")

  probeRenders(report, catalog, watermarks, presets)

  report:add("=== end ===")
  scope:done()
  report:show()
end

LrFunctionContext.postAsyncTaskWithContext("inat_probe_export_presets",
  function(context)
    local ok, err = LrTasks.pcall(run, context)
    if not ok then
      LrDialogs.message("iNat SDK Probe", "Probe failed:\n\n" .. tostring(err)
        .. "\n\nPartial results were written to inat-sdk-probe.txt on the"
        .. " Desktop.", "critical")
    end
  end)
