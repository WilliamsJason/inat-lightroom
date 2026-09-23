--[[
  ExportPresets.lua
  -----------------
  The user's own Lightroom export presets, read off disk.

  A user who watermarks his iNaturalist uploads asked to pick his own export
  preset instead of the plugin's hardcoded render settings. There is no SDK
  call for this -- no LrExportPresets, nothing in LrApplication -- but the
  presets are files, and Lightroom tells us where they are and what they hold.

  WHERE THEY LIVE
  ---------------
  Export.lrmodule carries the template browser's data model verbatim:

      templateType = "Export", templateDirectoryName = "Export Presets"

  and ui.dll resolves that folder against `getStandardFilePath ... appData`,
  which is a path token a plugin already has. That is the same path Lightroom
  itself builds, on Windows and on macOS, so no per-OS special case is needed.

  There is a second location. ui.dll branches on the host preference
  AgTemplateBrowser_storePresetsWithCatalog and moves the folder next to the
  catalog, under ZSTR "$$$/AgTemplateBrowserDataModel/
  CatalogBasedPresetFolderName/LightroomSettings=Lightroom Settings".
  LrPrefs is per-plugin and cannot read a host preference, so both roots are
  scanned unconditionally rather than one being chosen.

  Measured on this machine: the appData root held five presets (four shipped,
  one the user's own under "User Presets"), and the catalog-adjacent root did
  not exist.

  WHY THIS PARSES RATHER THAN EXECUTES
  ------------------------------------
  A .lrtemplate is Lua source: `s = { id = ..., title = ZSTR "...", value = {
  ... } }`. LibraryToolkit.dll loads one with `loadstring ... loadfile ...
  setfenv ... ZSTR ... pcall`, so the obvious approach is to do the same.

  It does not work, and the reason is worth keeping. A probe measured the
  plugin sandbox directly and reported `setfenv nil` and `getfenv nil` while
  `loadstring` was still a function -- so the host's own route cannot be
  reproduced, and a chunk loaded without an environment to confine it would
  run against the plugin's globals. Running the file by assigning `ZSTR` as a
  global and reading back the global `s` was measured working, so both routes
  were available and this one was chosen anyway:

    * a preset file is data the plugin found on disk, and handing data to the
      interpreter to find out what it says is a larger promise than reading it;
    * the sandbox already removed setfenv. Nothing says loadstring stays.

  So the reader below is a table-literal parser. It is recursive rather than
  line-by-line because a watermark preset's `value.items` is a list of tables,
  and a flat matcher reads the inner keys as if they were outer ones.

  WHAT A PRESET IS ALLOWED TO CHANGE
  ----------------------------------
  Everything except the keys in OVERRIDDEN. Those are not preferences, they
  are what makes the render work at all -- the destination the caller then
  reads the file from, JPEG rather than DNG, no re-import of every upload into
  the catalog. Each one's reason is on its line.
--]]

local LrApplication = import "LrApplication"
local LrFileUtils   = import "LrFileUtils"
local LrPathUtils   = import "LrPathUtils"

local logger = require "Log"

local ExportPresets = {}

--- The setting value that means "do not use a preset".
--
-- The empty string rather than nil, because Settings.get returns the default
-- for nil and a popup writes "" when it is on its first row.
ExportPresets.NONE = ""

--- What Lightroom accepts as a preset file.
--
-- Both, because LibraryToolkit.dll's loader tests `pathExtension ...
-- lrtemplate ... agtemplate` before reading one.
ExportPresets.EXTENSIONS = { lrtemplate = true, agtemplate = true }

ExportPresets.PRESET_FOLDER    = "Export Presets"
ExportPresets.WATERMARK_FOLDER = "Watermarks"

-- The folder name Lightroom uses beside the catalog. Display text of
-- "$$$/AgTemplateBrowserDataModel/CatalogBasedPresetFolderName/
-- LightroomSettings=Lightroom Settings".
ExportPresets.CATALOG_FOLDER = "Lightroom Settings"

--- The only export service provider this plugin can render through.
--
-- Measured, and not a formality: of the four presets Lightroom ships, "Burn
-- Full-Sized JPEGs" is com.adobe.ag.export.optical-media and "For Email" is
-- com.adobe.ag.export.email. A user who builds their iNaturalist preset by
-- editing one of those gets a preset this plugin cannot use, which is why
-- list() returns them marked unusable instead of dropping them silently.
ExportPresets.FILE_PROVIDER = "com.adobe.ag.export.file"

--- How deep to walk each root.
--
-- Two, because presets sit one folder down: "Export Presets\User Presets\
-- iNaturalist.lrtemplate". Lightroom lets a user make their own subfolders in
-- that panel, so the walk is not hardcoded to "User Presets".
ExportPresets.MAX_DEPTH = 3

--- Keys a preset may not set, and why the plugin's value has to win.
--
-- Skipped here rather than only overwritten later so that the mapped table is
-- honest about what it is: RenderPhoto applies its own overrides on top as
-- well, and either alone would be enough. Two layers because the cost of a
-- preset silently moving the render destination is an upload of the wrong
-- files, or none.
ExportPresets.OVERRIDDEN = {
  -- A preset saved against a publish service or another plugin names *that*
  -- plugin. LrExportSession then either refuses it or hands the user's photos
  -- to a third-party uploader.
  exportServiceProvider = true,
  exportServiceProviderTitle = true,

  -- The renderer has to find the files afterwards. Presets carry a real
  -- folder on the user's disk, or "chooseLater", which prompts.
  export_destinationType = true,
  export_destinationPathPrefix = true,
  export_destinationPathSuffix = true,
  export_useSubfolder = true,
  export_useParentFolder = true,

  -- Shipped presets say "revealInFinder". That opens a file browser on a temp
  -- folder in the middle of an upload.
  export_postProcessing = true,

  -- Re-import would add a duplicate of every uploaded photo to the catalog.
  reimportExportedPhoto = true,
  reimport_stackWithOriginal = true,
  reimport_stackWithOriginal_position = true,

  -- Presets ship with "ask", which halts the render with a dialog nobody is
  -- waiting on.
  collisionHandling = true,

  -- A rename token set can collapse a whole selection onto one filename. The
  -- files are an implementation detail of an upload and nobody sees them.
  renamingTokensOn = true,
  tokens = true,
  tokenCustomString = true,
  initialSequenceNumber = true,
  extensionCase = true,

  -- iNaturalist takes JPEG. A DNG or TIFF preset carries no jpeg_quality at
  -- all, which is why the plugin supplies the format and the quality floor
  -- even when the rest of the preset is honoured.
  format = true,

  -- Nothing in this plugin renders video. One passed through fails later at
  -- upload, with a message about the wrong thing.
  includeVideoFiles = true,

  -- This plugin writes iNaturalist's taxonomy into the keyword hierarchy.
  -- Exporting that hierarchy sends the community's identification back to
  -- iNaturalist as if it were the user's own.
  metadata_keywordOptions = true,
}

--------------------------------------------------------------------------------
-- Reading a .lrtemplate
--------------------------------------------------------------------------------

local parseValue

local function skipSpace(text, index)
  local _, stop = text:find("^%s*", index)
  return (stop or index - 1) + 1
end

--- The body of a table literal, starting at its "{".
local function parseTable(text, index)
  local result = {}
  index = index + 1

  while true do
    index = skipSpace(text, index)
    local char = text:sub(index, index)

    if char == "" then
      return nil, index, "unterminated table"
    elseif char == "}" then
      return result, index + 1
    elseif char == "," or char == ";" then
      index = index + 1
    else
      local key
      local name, afterName = text:match("^([%a_][%w_]*)%s*=%s*()", index)
      local quoted, afterQuoted =
        text:match('^%[%s*"([^"]*)"%s*%]%s*=%s*()', index)

      if quoted then
        key, index = quoted, afterQuoted
      elseif name then
        key, index = name, afterName
      end

      local value, nextIndex, err = parseValue(text, index)
      if err then return nil, nextIndex, err end

      index = nextIndex
      if key then
        result[key] = value
      else
        result[#result + 1] = value
      end
    end
  end
end

--- One value: a table, a string, a number, a boolean, nil, or a ZSTR call.
function parseValue(text, index)
  index = skipSpace(text, index)
  local char = text:sub(index, index)

  if char == "{" then
    return parseTable(text, index)
  end

  -- ZSTR is a function call in the file, not syntax. Nothing is being called
  -- here, so the name is stepped over and the string behind it taken as the
  -- value -- which is what Lightroom's own ZSTR does with a key it cannot
  -- translate.
  local afterZstr = text:match("^ZSTR%s*()", index)
  if afterZstr then
    index = afterZstr
    char = text:sub(index, index)
  end

  if char == '"' or char == "'" then
    local out, position = {}, index + 1
    while position <= #text do
      local c = text:sub(position, position)
      if c == "\\" then
        out[#out + 1] = text:sub(position + 1, position + 1)
        position = position + 2
      elseif c == char then
        return table.concat(out), position + 1
      else
        out[#out + 1] = c
        position = position + 1
      end
    end
    return nil, position, "unterminated string"
  end

  local number, afterNumber =
    text:match("^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)()", index)
  if number and tonumber(number) then
    return tonumber(number), afterNumber
  end

  local word, afterWord = text:match("^([%a_][%w_%.]*)()", index)
  if word == "true" then return true, afterWord end
  if word == "false" then return false, afterWord end
  if word == "nil" then return nil, afterWord end

  -- A constructor this reader does not know. AgRect(0,0,1,1) and friends
  -- appear in Lightroom's own preference files, and one unknown value is not
  -- worth losing the preset over. The argument list is stepped over by
  -- counting parentheses rather than by scanning to the next comma, because
  -- the arguments contain commas themselves -- doing it the short way left the
  -- reader inside the call and it failed on the closing bracket.
  if word then
    index = skipSpace(text, afterWord)
    if text:sub(index, index) == "(" then
      local depth = 0
      while index <= #text do
        local c = text:sub(index, index)
        if c == "(" then
          depth = depth + 1
        elseif c == ")" then
          depth = depth - 1
          if depth == 0 then return nil, index + 1 end
        end
        index = index + 1
      end
      return nil, index, "unterminated call to " .. word
    end

    local _, stop = text:find("^[^,}]*", afterWord)
    return nil, (stop or afterWord) + 1
  end

  return nil, index, "unexpected character " .. string.format("%q", char)
end

--- Read a preset file's text into a table. Runs no code.
--
-- @return table, or nil plus a reason
function ExportPresets.parse(source)
  if type(source) ~= "string" or source == "" then
    return nil, "the file is empty"
  end

  local start = source:find("[%a_][%w_]*%s*=%s*{")
  if not start then return nil, "no preset table found" end

  local brace = source:find("{", start, true)
  local parsed, _, err = parseTable(source, brace)

  if not parsed then
    return nil, tostring(err or "could not read the preset")
  end
  return parsed
end

--- The text a person should see for a preset.
--
-- Shipped presets store a resource key -- "$$$/AgExport/Preset/ForEMail=For
-- Email" -- and the user's own store a plain string. The display text is
-- whatever follows the first "=".
function ExportPresets.displayTitle(title)
  if type(title) ~= "string" or title == "" then return "(untitled)" end
  local text = title:match("^%$%$%$/[^=]*=(.*)$")
  return text or title
end

--------------------------------------------------------------------------------
-- Finding the files
--------------------------------------------------------------------------------

local function readFile(path)
  if type(LrFileUtils.readFile) == "function" then
    local ok, contents = pcall(LrFileUtils.readFile, path)
    if ok and contents then return contents end
  end

  local handle = io.open(path, "r")
  if not handle then return nil, "could not open the file" end
  local contents = handle:read("*a")
  handle:close()
  return contents
end

--- The catalog's own folder, or nil when there is no catalog to ask.
--
-- Guarded because this is called to build a list for a settings popup, and a
-- plugin that cannot show its settings because the catalog was busy is worse
-- than one that misses a preset folder almost nobody uses.
local function catalogFolder()
  local ok, path = pcall(function()
    return LrApplication.activeCatalog():getPath()
  end)
  if not ok or type(path) ~= "string" or path == "" then return nil end
  return LrPathUtils.parent(path)
end

--- Both places Lightroom keeps a given kind of preset.
function ExportPresets.roots(folderName)
  local roots = {}

  local appData = LrPathUtils.getStandardFilePath("appData")
  if appData then
    roots[#roots + 1] = LrPathUtils.child(appData, folderName)
  end

  local folder = catalogFolder()
  if folder then
    local settings = LrPathUtils.child(folder, ExportPresets.CATALOG_FOLDER)
    roots[#roots + 1] = LrPathUtils.child(settings, folderName)
  end

  return roots
end

local function filesUnder(directory, depth, found)
  found = found or {}
  if depth <= 0 then return found end
  if LrFileUtils.exists(directory) ~= "directory" then return found end

  -- Guarded: a directory can vanish between the check and the walk, and a
  -- settings dialog that raises instead of opening is a bad trade for a
  -- preset folder that is not there any more.
  pcall(function()
    for entry in LrFileUtils.directoryEntries(directory) do
      if LrFileUtils.exists(entry) == "directory" then
        filesUnder(entry, depth - 1, found)
      else
        local extension = tostring(LrPathUtils.extension(entry) or ""):lower()
        if ExportPresets.EXTENSIONS[extension] then
          found[#found + 1] = entry
        end
      end
    end
  end)

  return found
end

ExportPresets.filesUnder = filesUnder

--------------------------------------------------------------------------------
-- What the size keys mean
--------------------------------------------------------------------------------

--- The pixel size a preset actually renders at, and the value it ignores.
--
-- WHY THIS IS NOT JUST "maxWidth x maxHeight": a preset carries both keys
-- whatever its resize mode, so the mode decides which one is real and which is
-- a leftover from however the preset was set up before. The user's own
-- iNaturalist preset is exactly that case -- size_resizeType = "longEdge",
-- size_maxHeight = 2048, size_maxWidth = 1000 -- and the Export dialog shows
-- it as a single box reading 2048.
--
-- Measured three ways, because reading the wrong key would silently upload
-- 1000 px files to a user who asked for 2048:
--
--   * Export.lrmodule's resize synopsis builds its text from the value list
--     `size_maxWidth, size_maxHeight` and then formats
--     "$$$/AgExport/Synopsis/Resize/WidthHeight=Resize to W: ^1 H: ^2 ^3",
--     which anchors ^1 to maxWidth and ^2 to maxHeight. In the same formatter,
--     "$$$/AgExport/Synopsis/Resize/LongEdge=Resize Long Edge to ^2 ^3" and
--     the ShortEdge string both read ^2 -- maxHeight.
--   * The Export dialog shows one box in Long Edge mode, and for that preset
--     it reads 2048, not 1000.
--   * The probe rendered that preset at 619482 bytes, far above the 557475 of
--     a 2048 px baseline render and nowhere near what 1000 px would produce.
--
-- Lightroom's shipped presets cannot settle it -- "For Email" is longEdge with
-- both keys at 500, and the others do not constrain at all -- so the evidence
-- above is what there is.
--
-- The render path does not depend on any of this: it passes resizeType and
-- both size keys through together, untouched, so Lightroom interprets the pair
-- in the mode it was written in. This function exists only to tell the user
-- what their preset will do, which is where a stale value would otherwise look
-- like the real one.
function ExportPresets.effectiveSize(value)
  value = value or {}

  if not value.size_doConstrain then
    return { text = "full size" }
  end

  local units  = value.size_units == "pixels" and "px" or tostring(value.size_units or "px")
  local width  = tonumber(value.size_maxWidth)
  local height = tonumber(value.size_maxHeight)
  local mode   = value.size_resizeType

  local function number(n)
    if not n then return "?" end
    return tostring(math.floor(n + 0.5))
  end

  if mode == "longEdge" or mode == "shortEdge" then
    local label = mode == "longEdge" and "long edge" or "short edge"
    local result = {
      pixels  = height,
      text    = number(height) .. " " .. units .. " " .. label,
    }
    -- Only worth mentioning when the two disagree, which is the case that
    -- looks like a bug from the outside.
    if width and height and width ~= height then
      result.ignored = "the preset also stores a width of " .. number(width)
        .. " " .. units .. ", which " .. label .. " mode ignores"
    end
    return result
  end

  if mode == "megapixels" then
    return { text = tostring(value.size_megapixels or "?") .. " megapixels" }
  end

  if mode == "percentage" then
    return { text = tostring(value.size_percentage or "?") .. "%" }
  end

  -- "wh" and "dimensions" both use the pair.
  return {
    text = number(width) .. " x " .. number(height) .. " " .. units,
  }
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

--- Read one preset file into an entry, or nil plus a reason.
local function entryFor(path, wantedType)
  local source, readError = readFile(path)
  if not source then
    return nil, tostring(readError or "could not read the file")
  end

  local parsed, parseError = ExportPresets.parse(source)
  if not parsed then return nil, parseError end
  if parsed.type ~= wantedType then
    return nil, "not a " .. wantedType .. " preset"
  end

  local value = type(parsed.value) == "table" and parsed.value or {}

  return {
    id       = parsed.id,
    title    = ExportPresets.displayTitle(parsed.title),
    path     = path,
    provider = value.exportServiceProvider,
    value    = value,
  }
end

--- Every export preset on disk, usable or not.
--
-- Unusable ones are returned with `usable = false` and a `reason`, rather than
-- filtered out: a user who cannot find the preset they just made has no way to
-- discover that it is the wrong kind of export, and "it is not listed" is the
-- least informative thing the plugin could tell them.
function ExportPresets.list()
  local presets = {}
  local seen    = {}

  for _, root in ipairs(ExportPresets.roots(ExportPresets.PRESET_FOLDER)) do
    for _, path in ipairs(filesUnder(root, ExportPresets.MAX_DEPTH)) do
      local entry, reason = entryFor(path, "Export")

      if not entry then
        logger:trace("Export presets: skipping " .. tostring(path)
          .. ": " .. tostring(reason))
      elseif entry.id and not seen[entry.id] then
        seen[entry.id] = true

        if entry.provider ~= ExportPresets.FILE_PROVIDER then
          entry.usable = false
          -- Named rather than described: the user chose "Email" or "CD/DVD" in
          -- the Export To popup at the top of the dialog, and that is the
          -- control they have to go back and change.
          entry.reason = "exports to " .. (entry.provider == "com.adobe.ag.export.email"
            and "Email" or entry.provider == "com.adobe.ag.export.optical-media"
            and "CD/DVD" or "another destination")
            .. ", not Hard Drive"
        else
          entry.usable = true
        end

        presets[#presets + 1] = entry
      end
    end
  end

  table.sort(presets, function(a, b)
    return tostring(a.title):lower() < tostring(b.title):lower()
  end)

  return presets
end

--- Every named watermark preset's id, mapped to its title.
--
-- Exists for one reason: a preset can name a watermark that has since been
-- deleted or renamed, and Lightroom does not complain. The probe measured it
-- -- a GUID matching no preset rendered 557475 bytes, byte-identical to no
-- watermark at all, with no error raised. Someone who picked their preset
-- *for* the watermark would go on uploading unwatermarked photos and never be
-- told.
function ExportPresets.watermarks()
  local found = {}

  for _, root in ipairs(ExportPresets.roots(ExportPresets.WATERMARK_FOLDER)) do
    for _, path in ipairs(filesUnder(root, ExportPresets.MAX_DEPTH)) do
      local entry = entryFor(path, "WatermarkingPreset")
      if entry and entry.id then
        found[entry.id] = entry.title
      end
    end
  end

  return found
end

--- The built-in copyright watermark's id.
--
-- Not a named preset and never on disk, so the missing-watermark check below
-- has to know not to look for it.
ExportPresets.BUILT_IN_WATERMARK = "<simpleCopyrightWatermark>"

--- Why a preset's watermark will not draw, or nil when it will.
--
-- @param value      a preset's value table
-- @param available  id -> title, from watermarks(). Passed in so the caller
--                   can read the folder once for a whole list.
function ExportPresets.watermarkProblem(value, available)
  value = value or {}
  if not value.useWatermark then return nil end

  local id = value.watermarking_id
  if id == nil or id == "" then
    return "the preset turns on watermarking without naming a watermark"
  end
  if id == ExportPresets.BUILT_IN_WATERMARK then
    -- Measured: this stamps the IPTC copyright field, and on a photo with no
    -- copyright it draws nothing at all -- 557475 bytes with and without it,
    -- 559988 once a copyright was written.
    return "the preset uses the simple copyright watermark, which draws"
      .. " nothing on a photo with no copyright set"
  end

  if available and available[id] == nil then
    return "the watermark this preset names is no longer in Lightroom, so"
      .. " uploads will not be watermarked"
  end

  return nil
end

--- How to describe a preset's watermark, or nil when it cannot be described.
--
-- nil in exactly the cases watermarkProblem has something to say -- a GUID
-- that resolves to nothing, the built-in copyright watermark, watermarking
-- turned on with nothing named. The warning control is already the right
-- place for those, and two pieces of text describing one broken thing is how
-- one of them ends up wrong: a summary reading "watermarked with X" beside a
-- warning saying it will not draw is worse than a summary that stops early.
--
-- @param value      a preset's value table
-- @param available  id -> title, from watermarks()
function ExportPresets.watermarkText(value, available)
  value = value or {}

  if not value.useWatermark then return "not watermarked" end
  if ExportPresets.watermarkProblem(value, available) then return nil end

  -- A nil listing is "unknown", not "fine": watermarkProblem cannot spot a
  -- deleted watermark without one either, so neither of us can say anything.
  if not available then return nil end

  return "watermarked with " .. tostring(available[value.watermarking_id])
end

--- One preset by its id, or nil.
--
-- Presets are stored by GUID rather than by path because a GUID survives the
-- user renaming or moving the file, and a path does not.
function ExportPresets.find(id)
  if id == nil or id == ExportPresets.NONE then return nil end

  for _, preset in ipairs(ExportPresets.list()) do
    if preset.id == id then return preset end
  end

  return nil
end

--- A preset's value table as LR_-prefixed export settings.
--
-- The keys in a preset file are unprefixed; exportSettings wants them
-- prefixed. That is the whole mapping, minus the keys in OVERRIDDEN.
function ExportPresets.settingsFrom(value)
  local settings = {}

  for key, entry in pairs(value or {}) do
    if not ExportPresets.OVERRIDDEN[key] then
      settings["LR_" .. key] = entry
    end
  end

  return settings
end

return ExportPresets
