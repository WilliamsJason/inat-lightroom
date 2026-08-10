--[[
  RenderPhoto.lua
  ---------------
  Turning catalog photos into JPEGs, without an export service provider.

  The publish service used to get this for free: Lightroom rendered the photos
  and handed the plugin file paths. With the service gone, the panel has to
  render them itself, and both things it wants to do need a file --
  iNaturalist's computer vision scores an uploaded image, and an observation
  photo is an actual JPEG.

  LrExportSession is what makes that possible. Verified in Export.lrmodule
  rather than recalled:

    LrExportSession { photosToExport = ..., exportSettings = ... }
      :countRenditions()   :renditions()
      :doExportOnNewTask() :doExportOnCurrentTask()

  and the settings side:

    LR_export_destinationType = "tempFolder"     a real value, with its own
                                                 "Export N files" progress
                                                 scope for plugin temp dirs
    LR_exportServiceProvider  = "com.adobe.ag.export.file"
                                                 the plain file provider, which
                                                 declares
                                                 canExportToTemporaryLocation

  Two things about it will bite:

    * "AgExportSession:addRenditionsForPhotos: must not call on main UI task"
      -- verbatim from the binary. This must run on a task.
    * renditions() is not a passive accessor. Its constant table runs
      progressScope / stopIfCanceled / renderProgressPortion straight into
      startRendering, so asking for the renditions is what begins the export.
      Calling doExportOnCurrentTask as well would be asking for the same work
      twice.

  The temp folder is Lightroom's and it clears it when it feels like it, which
  is fine: the file only has to outlive the upload.
--]]

local LrExportSession = import "LrExportSession"

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

--- Build the export settings for a render.
--
-- Split out from the render itself because it is the part worth testing: every
-- one of these keys is a string Lightroom silently ignores if it is wrong, and
-- the result of getting one wrong is a file that uploads perfectly and is not
-- what the user asked for.
function RenderPhoto.settingsFor(options)
  options = options or {}
  local prefs = options.settings or Settings.all()

  local settings = {
    LR_exportServiceProvider   = "com.adobe.ag.export.file",
    LR_export_destinationType  = "tempFolder",

    LR_format                  = "JPEG",
    LR_jpeg_quality            = RenderPhoto.QUALITY / 100,
    LR_export_colorSpace       = "sRGB",
    LR_exportColorSpace        = "sRGB",

    LR_size_doConstrain        = true,
    LR_size_maxHeight          = options.maxPixels or RenderPhoto.MAX_PX,
    LR_size_maxWidth           = options.maxPixels or RenderPhoto.MAX_PX,
    LR_size_resizeType         = "longEdge",
    LR_size_units              = "pixels",
    LR_size_doNotEnlarge       = true,

    LR_outputSharpeningOn      = false,
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

--- Render photos to JPEGs in Lightroom's temporary folder.
--
-- MUST be called from inside a task.
--
-- @param photos   List of LrPhoto
-- @param options  maxPixels, settings
-- @return list of { photo = ..., path = ... }, list of error strings
function RenderPhoto.render(photos, options)
  if not photos or #photos == 0 then
    return {}, {}
  end

  local session = LrExportSession {
    photosToExport = photos,
    exportSettings = RenderPhoto.settingsFor(options),
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

  return rendered, failures
end

--- Render exactly one photo, small, for a computer-vision question.
-- @return path, error
function RenderPhoto.renderForSuggestions(photo)
  local rendered, failures = RenderPhoto.render({ photo }, {
    maxPixels = RenderPhoto.SUGGEST_MAX_PX,
  })

  if #rendered == 0 then
    -- failures can be empty too: if Lightroom yields no renditions at all
    -- there is nothing to have failed, and the caller still needs a reason.
    return nil, failures[1] or RenderPhoto.FAILED_MESSAGE
  end

  return rendered[1].path, nil
end

return RenderPhoto
