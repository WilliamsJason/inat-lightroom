--[[
  RenderPhoto.lua
  ---------------
  Turning catalog photos into JPEGs, without an export service provider.

  The publish service used to get this for free: Lightroom rendered the photos
  and handed the plugin file paths. With the service gone, the panel has to
  render them itself, and both things it wants to do need a file --
  iNaturalist's computer vision scores an uploaded image, and an observation
  photo is an actual JPEG.

  LrExportSession does that without a provider:

    LrExportSession { photosToExport = ..., exportSettings = ... }
      :countRenditions()   :renditions()

  Two things about it will bite:

    * "AgExportSession:addRenditionsForPhotos: must not call on main UI task"
      -- verbatim from Export.lrmodule. This must run on a task.
    * renditions() is not a passive accessor. Its constant table runs
      progressScope / stopIfCanceled / renderProgressPortion straight into
      startRendering, so asking for the renditions is what begins the export.

  WHY THIS MANAGES ITS OWN TEMP FOLDER
  ------------------------------------
  The obvious answer is export_destinationType = "tempFolder", and it is
  wrong. It was tried, and the host answered:

      export settings are missing the LR_export_destinationPathPrefix

  The reason is in the binary. Lightroom resolves the destination roughly as:

      if kind == "specificFolder" or kind == "chooseLater" then
        dir = settings.export_destinationPathPrefix
      else
        dir = LrPathUtils.getStandardFilePath(kind)   -- "tempFolder" -> nil
      end
      assert(type(dir) == "string",
        "export settings are missing the LR_export_destinationPathPrefix")

  "tempFolder" is handled, but somewhere else -- inside addRenditionsForPhotos,
  and only when the export service provider declares
  exportToTemporaryLocation. That name sits in the binary's list of provider
  callbacks, next to processRenderedPhotos and sectionsForTopOfDialog: it is
  something a plugin's OWN export service provider declares. This plugin
  deliberately no longer has one, so tempFolder is not available to it.

  So the renderer picks its own directory under the system temp folder --
  which is what Lightroom would have done anyway; the binary builds its own
  tempFolder path from getStandardFilePath("temp") plus a UUID -- and cleans
  up after itself.

  The settings below are a complete export preset rather than a handful of
  interesting keys. Lightroom fills in anything missing from the user's last
  export, so leaving a key out does not mean "the default", it means
  "whatever they happened to do last time". Every value here appears in a
  shipped preset inside Export.lrmodule.

  WHY A USER'S OWN EXPORT PRESET CAN BE USED
  ------------------------------------------
  This file used to claim a plugin could only ask for the built-in copyright
  watermark, because it cannot enumerate the user's named watermark presets.
  Half of that was right and the conclusion was wrong. A plugin still cannot
  ask Lightroom for the list -- but the presets are files on disk, and their
  ids can be read from them and handed straight to LrExportSession. Measured
  on Lightroom Classic 14, one photo, byte counts of the rendered JPEG:

      (a) no watermark                      557475
      (b) LR_watermarking_id = "<simpleCopyrightWatermark>"   557475
      (c) a named watermark preset's id     575517
      (d) a GUID matching no preset         557475

  So (c) drew, and drew that watermark rather than the built-in one. (d) is
  the trap: a watermark id that no longer resolves is skipped in silence, with
  no error and an unwatermarked file -- which ExportPresets.watermarkProblem
  exists to catch before the upload rather than after it.

  (b) matching (a) exactly is the other correction. The built-in copyright
  watermark stamps the IPTC copyright field, and the test photo had none, so
  it drew nothing; writing a copyright first and re-rendering gave 559988.
  It worked -- it was simply a no-op for anyone who does not set copyright.
--]]

local LrExportSession = import "LrExportSession"
local LrFileUtils     = import "LrFileUtils"
local LrPathUtils     = import "LrPathUtils"

local ExportPresets = require "ExportPresets"
local Settings = require "Settings"
local logger   = require "Log"

local RenderPhoto = {}

-- iNaturalist displays at most 2048 px on the long edge. Sending more costs
-- the user's upload bandwidth and iNaturalist's storage to no visible effect.
--
-- This is the *default*, not a cap: a chosen export preset's own size wins
-- outright. Someone who deliberately exports larger has decided to spend their
-- own bandwidth, and iNaturalist resizes anything bigger itself.
RenderPhoto.MAX_PX  = 2048
RenderPhoto.QUALITY = 90

--- The keys no export preset may change, and what they must be.
--
-- Applied last, on top of the preset. The reasons live on the equivalent
-- entries in ExportPresets.OVERRIDDEN, which skips these keys on the way in;
-- this table is the second half of the same guarantee, so that a preset key
-- added to Lightroom tomorrow cannot land in a settings table by surprise.
--
-- LR_export_destinationPathPrefix is not here because its value is the render
-- folder, which is different every time; settingsFor writes it explicitly.
RenderPhoto.OVERRIDES = {
  LR_exportServiceProvider        = "com.adobe.ag.export.file",
  LR_export_destinationType       = "specificFolder",
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
  LR_includeVideoFiles            = false,
  LR_metadata_keywordOptions      = "flat",
}

-- Smaller, for computer vision. The model does not see more in a large image,
-- and this is uploaded and thrown away purely to ask a question -- so it is
-- worth being quick about.
RenderPhoto.SUGGEST_MAX_PX = 1024

-- Lightroom does not promise waitForRender explains itself, and a failure with
-- no reason still has to say something. Without this the user is shown the
-- literal text "nil".
RenderPhoto.FAILED_MESSAGE = "Lightroom could not render this photo."

--- A directory of our own under the system temp folder.
--
-- A fresh one per render rather than a shared one, so two renders running at
-- once cannot collide, and so cleanup can delete the whole directory instead
-- of working out which files inside it were its own.
function RenderPhoto.makeTempFolder()
  local root = LrPathUtils.getStandardFilePath("temp")
  local name = "inat-lightroom-" .. tostring(os.time()) ..
               "-" .. tostring(math.random(100000, 999999))
  local path = LrPathUtils.child(root, name)

  LrFileUtils.createAllDirectories(path)
  return path
end

--- Build the export settings for a render.
--
-- Split out from the render itself because it is the part worth testing: every
-- one of these keys is a string Lightroom silently ignores if it is wrong, and
-- the result of getting one wrong is a file that uploads perfectly and is not
-- what the user asked for.
--
-- Three layers, in this order:
--
--   1. the plugin's own complete table, below;
--   2. the chosen export preset's keys, if there is one;
--   3. the overrides, which no preset may change.
--
-- Layer 1 is complete rather than a handful of interesting keys because
-- fillInDefaultSettings fills anything missing from the user's *last export*,
-- not from documented defaults. Layer 3 repeats what ExportPresets.OVERRIDDEN
-- already skips: either alone would do, and the cost of a preset quietly
-- moving the destination is an upload of the wrong files, or none.
function RenderPhoto.settingsFor(options)
  options = options or {}
  local prefs = options.settings or Settings.all()
  local maxPixels = options.maxPixels or RenderPhoto.MAX_PX
  local preset = options.preset

  local settings = {
    LR_exportServiceProvider   = "com.adobe.ag.export.file",

    -- specificFolder, not tempFolder: see the note at the top of this file.
    LR_export_destinationType       = "specificFolder",
    LR_export_destinationPathPrefix = options.folder,
    LR_export_destinationPathSuffix = "",
    LR_export_useSubfolder          = false,

    -- Nothing may open, reveal or re-import these files. They are an
    -- implementation detail of an upload; reimportExportedPhoto in particular
    -- would add a duplicate of every uploaded photo back into the catalog.
    LR_export_postProcessing        = "doNothing",
    LR_reimportExportedPhoto        = false,
    LR_reimport_stackWithOriginal   = false,

    -- "ask" is Lightroom's own default and would stop the render dead with a
    -- dialog. The directory is new and empty, so the only way to collide is
    -- two selected photos sharing a name -- DSC0001.ARW and DSC0001.JPG both
    -- become DSC0001.jpg. Renaming keeps both; overwriting would silently drop
    -- one of the observation's photos.
    LR_collisionHandling       = "rename",
    LR_renamingTokensOn        = false,
    LR_tokens                  = "{{image_name}}",
    LR_tokenCustomString       = "",
    LR_initialSequenceNumber   = 1,
    LR_extensionCase           = "lowercase",

    LR_format                  = "JPEG",
    LR_jpeg_quality            = RenderPhoto.QUALITY / 100,
    LR_jpeg_useLimitSize       = false,
    LR_jpeg_limitSize          = 100,
    LR_export_colorSpace       = "sRGB",

    -- iNaturalist takes video, but nothing in this plugin renders one, and a
    -- video passed through as if it were an image fails at upload instead,
    -- where the message makes no sense.
    LR_includeVideoFiles       = false,

    LR_size_doConstrain        = true,
    LR_size_userWantsConstrain = true,
    LR_size_maxHeight          = maxPixels,
    LR_size_maxWidth           = maxPixels,
    LR_size_resizeType         = "longEdge",
    LR_size_units              = "pixels",
    LR_size_doNotEnlarge       = true,
    LR_size_resolution         = 72,
    LR_size_resolutionUnits    = "inch",

    -- Sharpened for screen, because that is what these files are for: a
    -- 2048 px downsample of a 24 MP frame is soft without it, and iNaturalist
    -- displays it on a screen at about this size.
    --
    -- The level is measured, not guessed. Export.lrmodule's sharpening popup
    -- stores each title's value immediately after it --
    -- "$$$/AgExport/PopupMenu/SharpeningLow=Low" -> 1,
    -- "$$$/AgExport/PopupMenu/SharpeningStandard=Standard" -> 2,
    -- "$$$/AgExport/PopupMenu/SharpeningHigh=High" -> 3 -- and the media popup
    -- in the same table maps Screen to "screen". So this is Sharpen For
    -- Screen, Standard, which is what Lightroom's own export defaults to.
    --
    -- Off for the computer-vision render: see renderForSuggestions.
    LR_outputSharpeningOn      = options.sharpen ~= false,
    LR_outputSharpeningLevel   = 2,
    LR_outputSharpeningMedia   = "screen",

    -- Written rather than left out even though it is false. An omitted key is
    -- filled from the user's last export, so leaving this out would watermark
    -- uploads for anyone whose last export was watermarked.
    LR_useWatermark            = false,

    LR_removeLocationMetadata  = prefs.render_remove_location or false,
    LR_removeFaceMetadata      = prefs.render_remove_face or false,
    LR_embeddedMetadataOption  = prefs.render_metadata_option or "all",

    -- Keywords go up as a flat list or not at all. iNaturalist has no use for
    -- Lightroom's hierarchy, and this plugin writes its own taxonomy keywords
    -- into that hierarchy -- so exporting it would send the community's
    -- identification back to iNaturalist as if it were the user's own.
    LR_metadata_keywordOptions = "flat",
  }

  if preset and type(preset.value) == "table" then
    -- The preset's own keys win over everything above, including the metadata
    -- options: the point of choosing a preset is to control the file in one
    -- place, and a plugin that honoured the resolution but overrode the
    -- metadata would be the worst of both.
    --
    -- size_resizeType travels with the size values and is never reinterpreted
    -- without them. A preset carries maxWidth and maxHeight whatever its mode,
    -- and in "longEdge" mode Lightroom reads maxHeight -- so a preset holding
    -- longEdge/2048 alongside a stale maxWidth of 1000 renders at 2048, and
    -- only stays that way if the pair arrives together. See
    -- ExportPresets.effectiveSize for the evidence.
    for key, value in pairs(ExportPresets.settingsFrom(preset.value)) do
      settings[key] = value
    end

    -- A DNG or TIFF preset carries no jpeg_quality at all, and LR_format is
    -- forced to JPEG below, so the quality has to come from somewhere.
    if type(settings.LR_jpeg_quality) ~= "number" then
      settings.LR_jpeg_quality = RenderPhoto.QUALITY / 100
    end

    for key, value in pairs(RenderPhoto.OVERRIDES) do
      settings[key] = value
    end

    settings.LR_export_destinationPathPrefix = options.folder
  end

  return settings
end

--- The export preset the user chose, or nil for the plugin's own settings.
--
-- Resolved by GUID rather than by path: a GUID survives the user renaming or
-- moving the file in Lightroom's preset panel, and a path does not.
--
-- Falls back to plugin defaults and says so in the log rather than failing the
-- upload. A preset can disappear -- deleted, or the catalog opened on a
-- machine that does not have it -- and refusing to upload over a render
-- setting would be a worse answer than rendering the way the plugin used to.
function RenderPhoto.chosenPreset(prefs)
  prefs = prefs or Settings.all()

  local id = prefs.render_export_preset
  if id == nil or id == ExportPresets.NONE then return nil end

  local preset = ExportPresets.find(id)
  if not preset then
    logger:warn("Export preset " .. tostring(prefs.render_export_preset_title)
      .. " (" .. tostring(id) .. ") was not found; rendering with the"
      .. " plugin's own settings")
    return nil
  end

  if not preset.usable then
    logger:warn("Export preset " .. tostring(preset.title) .. " "
      .. tostring(preset.reason) .. "; rendering with the plugin's own"
      .. " settings")
    return nil
  end

  -- Logged, not raised. A watermark that no longer resolves is skipped by
  -- Lightroom in silence -- measured at 557475 bytes, identical to no
  -- watermark -- so without this line an upload that quietly lost its
  -- watermark leaves no trace anywhere. The settings dialog says the same
  -- thing where it can still be acted on; this is for afterwards.
  local problem = ExportPresets.watermarkProblem(preset.value,
    ExportPresets.watermarks())
  if problem then
    logger:warn("Export preset " .. tostring(preset.title) .. ": " .. problem)
  end

  return preset
end

--- Render photos to JPEGs in a temporary folder.
--
-- MUST be called from inside a task.
--
-- The caller owns the returned folder and should hand it to
-- RenderPhoto.cleanUp once the upload has finished with the files.
--
-- @param photos   List of LrPhoto
-- @param options  maxPixels, settings, folder, onEvent, isCanceled, preset,
--                 usePreset
-- @return list of { photo = ..., path = ... }, list of error strings, folder,
--         true when the caller asked to stop partway
function RenderPhoto.render(photos, options)
  if not photos or #photos == 0 then
    return {}, {}, nil, false
  end

  options = options or {}
  local folder     = options.folder or RenderPhoto.makeTempFolder()
  local onEvent    = options.onEvent or function() end
  local isCanceled = options.isCanceled or function() return false end

  -- usePreset = false is how the computer-vision path opts out; the reason is
  -- on renderForSuggestions.
  local preset = options.preset
  if preset == nil and options.usePreset ~= false then
    preset = RenderPhoto.chosenPreset(options.settings)
    if preset then
      logger:info("Rendering with export preset " .. tostring(preset.title))
    end
  end

  local session = LrExportSession {
    photosToExport = photos,
    exportSettings = RenderPhoto.settingsFor({
      maxPixels = options.maxPixels,
      settings  = options.settings,
      preset    = preset,
      sharpen   = options.sharpen,
      folder    = folder,
    }),
  }

  local rendered = {}
  local failures = {}
  local canceled = false

  -- Asking for the renditions is what starts the export; there is no separate
  -- "go" call to make here.
  --
  -- This yields an index alongside the rendition, the same shape as an export
  -- provider's exportContext:renditions. Measured in the host, not assumed:
  -- the probe reported "first=number 1 second=table".
  for index, rendition in session:renditions() do
    -- The loop is drained rather than broken out of. Abandoning renditions()
    -- half-way leaves the export session rendering into a folder the caller is
    -- about to delete; skipRender tells Lightroom to stop instead, which is
    -- what makes cancelling a folder-sized selection actually stop the work.
    if canceled or isCanceled() then
      canceled = true
      pcall(function() rendition:skipRender() end)
    else
      onEvent("Rendering photo " .. index .. " of " .. #photos .. "…")

      local ok, pathOrMessage = rendition:waitForRender()
      if ok then
        rendered[#rendered + 1] = { photo = rendition.photo, path = pathOrMessage }
      else
        local reason = pathOrMessage and tostring(pathOrMessage)
                       or RenderPhoto.FAILED_MESSAGE
        failures[#failures + 1] = reason
        logger:warn("Render failed: " .. reason)
      end
    end
  end

  if canceled then
    logger:info("Rendering stopped early at the user's request after "
      .. #rendered .. " of " .. #photos .. " photo(s)")
  end

  return rendered, failures, folder, canceled
end

--- Delete a folder made by render().
--
-- Never raises. By the time this runs the upload has already happened, and a
-- leftover file in a temp directory is not worth failing an upload over or
-- worth telling the user about.
function RenderPhoto.cleanUp(folder)
  if not folder then return false end

  local ok, err = pcall(function()
    LrFileUtils.delete(folder)
  end)

  if not ok then
    logger:warn("Could not remove temporary folder " ..
      tostring(folder) .. ": " .. tostring(err))
  end

  return ok
end

--- Render exactly one photo, small, for a computer-vision question.
--
-- Deliberately ignores the user's export preset and the plugin's own
-- sharpening. This file is uploaded to ask a model what the species is and
-- then deleted: a watermark is wasted work at best and something drawn over
-- the subject at worst, a 4000 px preset makes every suggestion slower for an
-- answer the model does not improve on, and sharpening cannot change what the
-- model sees. The probe measured a 2048 px render at about 520 ms, which is
-- the cost being avoided here.
--
-- @return path, error, folder
function RenderPhoto.renderForSuggestions(photo)
  local rendered, failures, folder = RenderPhoto.render({ photo }, {
    maxPixels  = RenderPhoto.SUGGEST_MAX_PX,
    usePreset  = false,
    sharpen    = false,
  })

  if #rendered == 0 then
    RenderPhoto.cleanUp(folder)
    -- failures can be empty too: if Lightroom yields no renditions at all
    -- there is nothing to have failed, and the caller still needs a reason.
    return nil, failures[1] or RenderPhoto.FAILED_MESSAGE, nil
  end

  return rendered[1].path, nil, folder
end

return RenderPhoto
