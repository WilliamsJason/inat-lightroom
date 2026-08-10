--[[
  RenderProbe.lua
  ---------------
  TEMPORARY. Delete once RenderPhoto is confirmed working in the host.

  Everything the panel is about to do -- uploading an observation photo, and
  asking the computer vision what a photo is -- needs a JPEG on disk. The
  publish service used to get that for free. Without it, the plugin has to
  drive LrExportSession itself.

  LrExportSession was read out of Export.lrmodule, not recalled, and the
  constructor, the settings keys and the temp-folder destination type all
  check out there. But "the strings are in the binary" is not "it works",
  and every remaining piece of this redesign is stacked on top of it. So it
  gets proven in the running host before anything is built on it.

  What this reports, in the order it can fail:
    * whether LrExportSession can be imported at all
    * whether the constructor accepts the arguments
    * whether iterating renditions starts the export, and what the loop
      actually yields -- rendition alone, or index plus rendition
    * whether a file appears, and how big it is
--]]

local LrApplication     = import "LrApplication"
local LrDialogs         = import "LrDialogs"
local LrFileUtils       = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks           = import "LrTasks"

local RenderPhoto = require "RenderPhoto"
local logger      = require "Log"

local function describe(value)
  local kind = type(value)
  if kind == "table" then
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    return "table{" .. table.concat(keys, ",") .. "}"
  end
  return kind .. " " .. tostring(value)
end

local function probe(report)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos()

  if not photos or #photos == 0 then
    report[#report + 1] = "FAIL  select a photo in the filmstrip first"
    return
  end

  local photo = photos[1]
  report[#report + 1] = "photo: " ..
    tostring(photo:getFormattedMetadata("fileName"))

  local LrExportSession = import "LrExportSession"
  report[#report + 1] = "LrExportSession import: " .. type(LrExportSession)

  local folder = RenderPhoto.makeTempFolder()
  report[#report + 1] = "temp folder: " .. tostring(folder)
  report[#report + 1] = "  created: " ..
    tostring(LrFileUtils.exists(folder))

  local settings = RenderPhoto.settingsFor({ maxPixels = 1024, folder = folder })
  local session = LrExportSession {
    photosToExport = { photo },
    exportSettings = settings,
  }
  report[#report + 1] = "constructor: ok"
  report[#report + 1] = "countRenditions: " ..
    tostring(session:countRenditions())

  -- The one genuinely unknown shape. An export provider's
  -- exportContext:renditions yields index and rendition; whether
  -- LrExportSession:renditions does the same is not established, and getting
  -- it wrong is a nil-index error at upload time.
  local seen = 0
  for first, second in session:renditions() do
    seen = seen + 1
    report[#report + 1] = ("rendition %d: first=%s second=%s")
      :format(seen, describe(first), describe(second))

    local rendition = second or first
    local ok, pathOrMessage = rendition:waitForRender()
    report[#report + 1] = "  waitForRender: ok=" .. tostring(ok) ..
      " value=" .. tostring(pathOrMessage)

    if ok then
      local exists = LrFileUtils.exists(pathOrMessage)
      report[#report + 1] = "  file exists: " .. tostring(exists)
      if exists then
        report[#report + 1] = "  bytes: " ..
          tostring(LrFileUtils.fileAttributes(pathOrMessage).fileSize)
      end
      report[#report + 1] = "  rendition.photo: " ..
        (rendition.photo and "present" or "MISSING")
    end
  end

  if seen == 0 then
    report[#report + 1] = "FAIL  renditions() yielded nothing"
  end

  RenderPhoto.cleanUp(folder)
  report[#report + 1] = "cleaned up: " ..
    tostring(not LrFileUtils.exists(folder))
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext("inatRenderProbe", function(context)
    local report = {}

    context:addFailureHandler(function(_, message)
      report[#report + 1] = "ERROR " .. tostring(message)
      logger:error("Render probe failed: " .. tostring(message))
      LrDialogs.message("iNaturalist render probe",
        table.concat(report, "\n"), "critical")
    end)

    probe(report)

    local text = table.concat(report, "\n")
    logger:info("Render probe:\n" .. text)
    LrDialogs.message("iNaturalist render probe", text, "info")
  end)
end)
