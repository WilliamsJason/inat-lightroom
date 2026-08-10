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
--]]

local LrExportSession = import "LrExportSession"
local LrFileUtils     = import "LrFileUtils"
local LrPathUtils     = import "LrPathUtils"

local Settings = require "Settings"
local logger   = require "Log"

local RenderPhoto = {}

-- iNaturalist displays at most 2048 px on the long edge. Sending more costs
-- the user's upload bandwidth and iNaturalist's storage to no visible effect.
RenderPhoto.MAX_PX  = 2048
RenderPhoto.QUALITY = 90

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
function RenderPhoto.settingsFor(options)
  options = options or {}
  local prefs = options.settings or Settings.all()
  local maxPixels = options.maxPixels or RenderPhoto.MAX_PX

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

    LR_outputSharpeningOn      = false,
    LR_outputSharpeningLevel   = 2,
    LR_outputSharpeningMedia   = "screen",

    LR_useWatermark            = prefs.render_use_watermark or false,
    LR_removeLocationMetadata  = prefs.render_remove_location or false,
    LR_removeFaceMetadata      = prefs.render_remove_face or false,
    LR_embeddedMetadataOption  = prefs.render_metadata_option or "all",

    -- Keywords go up as a flat list or not at all. iNaturalist has no use for
    -- Lightroom's hierarchy, and this plugin writes its own taxonomy keywords
    -- into that hierarchy -- so exporting it would send the community's
    -- identification back to iNaturalist as if it were the user's own.
    LR_metadata_keywordOptions = "flat",
  }

  if settings.LR_useWatermark then
    -- No plugin can list the user's named watermark presets: watermarkPresets
    -- appears in no binary in the product. The built-in copyright watermark is
    -- what there is.
    settings.LR_watermarking_id = "<simpleCopyrightWatermark>"
  end

  return settings
end

--- Render photos to JPEGs in a temporary folder.
--
-- MUST be called from inside a task.
--
-- The caller owns the returned folder and should hand it to
-- RenderPhoto.cleanUp once the upload has finished with the files.
--
-- @param photos   List of LrPhoto
-- @param options  maxPixels, settings, folder
-- @return list of { photo = ..., path = ... }, list of error strings, folder
function RenderPhoto.render(photos, options)
  if not photos or #photos == 0 then
    return {}, {}, nil
  end

  options = options or {}
  local folder = options.folder or RenderPhoto.makeTempFolder()

  local session = LrExportSession {
    photosToExport = photos,
    exportSettings = RenderPhoto.settingsFor({
      maxPixels = options.maxPixels,
      settings  = options.settings,
      folder    = folder,
    }),
  }

  local rendered = {}
  local failures = {}

  -- Asking for the renditions is what starts the export; there is no separate
  -- "go" call to make here.
  --
  -- The loop takes two variables because it is not established whether this
  -- yields the rendition alone or an index alongside it, the way an export
  -- provider's exportContext:renditions does. Taking whichever arrived is
  -- cheap; guessing wrong is a nil index error at upload time.
  for first, second in session:renditions() do
    local rendition = second or first

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

  return rendered, failures, folder
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
-- @return path, error, folder
function RenderPhoto.renderForSuggestions(photo)
  local rendered, failures, folder = RenderPhoto.render({ photo }, {
    maxPixels = RenderPhoto.SUGGEST_MAX_PX,
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
