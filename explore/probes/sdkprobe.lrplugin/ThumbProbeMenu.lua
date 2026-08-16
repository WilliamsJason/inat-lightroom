--[[
  ThumbProbeMenu.lua
  ------------------
  Can the review list show, side by side, the photo iNaturalist has and the
  photo the catalog has?

  Three things have to be true before that design is worth building, and none of
  them can be settled by reading a binary.

  1. f:catalog_photo has to exist, and take a photo. It is documented as taking
     `photo`, but the same documentation says f:edit_text exists on Windows, and
     it does not.

  2. f:picture has to display an arbitrary file. Every example in the SDK passes
     _PLUGIN:resourceId(...) -- a file shipped inside the plugin. A thumbnail
     downloaded at runtime is not that, and if picture only accepts plugin
     resources then the iNaturalist side of the comparison cannot be drawn at
     all.

  3. Both have to accept a *binding*, so the same widgets can be pointed at the
     next twenty-five matches. Lightroom's view tree is fixed once a dialog is
     presented: rows cannot be added or removed. If images can only be set at
     build time then turning the page means dismissing the dialog and showing
     another one, which is a different feature with a different feel.

  The last is the reason this exists. It decides the shape of the whole review
  screen, and getting it wrong means writing the paging twice.
--]]

local LrDialogs   = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp      = import "LrHttp"
local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"
local LrView      = import "LrView"
local LrApplication = import "LrApplication"
local LrProgressScope = import "LrProgressScope"

local Report = require "Report"

local PAGE = 25

--------------------------------------------------------------------------------
-- Fetching some thumbnails to try
--------------------------------------------------------------------------------

--- Public observations with photos. No token: what is being measured is whether
-- a downloaded JPEG can be drawn, and any JPEG answers that.
local function fetchPhotoUrls(report, count)
  local url = "https://api.inaturalist.org/v2/observations"
    .. "?per_page=" .. tostring(count)
    .. "&photos=true&order_by=id&order=desc"
    .. "&fields=id,photos.url"

  local took, body, err = Report.timed(function()
    local text = LrHttp.get(url, { { field = "Accept", value = "application/json" } })
    return text
  end)
  report:addf("  fetch observation list: %s", took)
  if err or not body then
    report:addf("  FAILED: %s", tostring(err))
    return {}
  end

  -- Picked out with a pattern rather than decoded. The probe deliberately does
  -- not require the plugin's json.lua: it is a separate plugin, and what is
  -- being tested here is the SDK, not our parser.
  local urls = {}
  for photoUrl in string.gmatch(body, '"url"%s*:%s*"([^"]+)"') do
    urls[#urls + 1] = photoUrl
  end
  report:addf("  found %d photo url(s)", #urls)
  return urls
end

--- Download one thumbnail to a temp file. Returns the path, or nil plus why.
local function download(url, index)
  local body, headers = LrHttp.get(url)
  if not body or #body == 0 then
    return nil, "empty body (status " .. tostring(headers and headers.status) .. ")"
  end

  local folder = LrPathUtils.getStandardFilePath("temp")
  local path   = LrPathUtils.child(folder, string.format("inat-probe-%02d.jpg", index))

  local handle, openErr = io.open(path, "wb")
  if not handle then return nil, tostring(openErr) end
  handle:write(body)
  handle:close()

  return path, nil, #body
end

--------------------------------------------------------------------------------
-- The probe
--------------------------------------------------------------------------------

local function run(context)
  local report = Report.new("iNat Probe: Thumbnails")
  local f = LrView.osFactory()

  local scope = LrProgressScope {
    title = "iNat thumbnail probe",
    functionContext = context,
  }
  report:track(scope)

  ------------------------------------------------------------------ the factory

  report:step("Which widgets exist")
  for _, name in ipairs({ "catalog_photo", "picture", "checkbox",
                          "scrolled_view", "simple_list" }) do
    report:addf("  f.%-14s %s", name,
      type(f[name]) == "function" and "present" or "MISSING")
  end
  report:blank()

  ------------------------------------------------------------------- some photos

  report:step("Catalog photos to draw")
  local catalog = LrApplication.activeCatalog()
  local photos = catalog:getTargetPhotos() or {}
  if #photos < 2 then
    photos = catalog:getAllPhotos() or {}
  end
  report:addf("  %d photo(s) available", #photos)
  if #photos == 0 then
    report:add("  nothing to draw; open a catalog with photos in it")
    report:show()
    return
  end
  report:blank()

  --------------------------------------------------------------- downloading

  report:step("Downloading " .. PAGE .. " thumbnails")
  local urls = fetchPhotoUrls(report, PAGE)

  local paths = {}
  local startedAll = Report.now()
  for index = 1, math.min(PAGE, #urls) do
    scope:setCaption(string.format("Downloading %d of %d", index, PAGE))
    local took, result, err = Report.timed(download, urls[index], index)
    if index <= 3 or err then
      report:addf("  [%02d] %s %s", index, took, err and ("FAILED: " .. err) or "ok")
    end
    if not err then paths[#paths + 1] = result end
  end
  report:addf("  %d of %d downloaded in %s -- so a page of %d costs about that",
    #paths, math.min(PAGE, #urls), Report.elapsed(startedAll), PAGE)
  report:blank()

  if #paths == 0 then
    report:add("  no thumbnails; the picture tests below cannot mean anything")
  end

  ------------------------------------------------------------------- building

  report:step("Building the widgets")

  local built = {}

  local took, _, err = Report.timed(function()
    built.staticCatalogPhoto = f:catalog_photo {
      photo = photos[1], width = 120, height = 120,
    }
  end)
  report:addf("  f:catalog_photo { photo = <LrPhoto> }        %s %s",
    took, err and ("FAILED: " .. err) or "built")

  took, _, err = Report.timed(function()
    built.staticPicture = f:picture {
      value = paths[1], width = 120, height = 120,
    }
  end)
  report:addf("  f:picture { value = <downloaded path> }      %s %s",
    took, err and ("FAILED: " .. err) or "built")

  -- The one that decides the design.
  local LrBinding = import "LrBinding"
  local bound = LrBinding.makePropertyTable(context)
  bound.photo = photos[1]
  bound.path  = paths[1]
  bound.label = "page 1"

  took, _, err = Report.timed(function()
    built.boundCatalogPhoto = f:catalog_photo {
      photo = LrView.bind("photo"), width = 120, height = 120,
      bind_to_object = bound,
    }
  end)
  report:addf("  f:catalog_photo { photo = bind(...) }        %s %s",
    took, err and ("FAILED: " .. err) or "built")

  took, _, err = Report.timed(function()
    built.boundPicture = f:picture {
      value = LrView.bind("path"), width = 120, height = 120,
      bind_to_object = bound,
    }
  end)
  report:addf("  f:picture { value = bind(...) }              %s %s",
    took, err and ("FAILED: " .. err) or "built")
  report:blank()

  ------------------------------------------------------------ a page of rows

  report:step("Building a page of " .. PAGE .. " rows")

  local rowProps = LrBinding.makePropertyTable(context)
  local rows = {}
  local rowsTook, _, rowsErr = Report.timed(function()
    for index = 1, PAGE do
      rowProps["selected" .. index] = true
      rowProps["photo" .. index]    = photos[((index - 1) % #photos) + 1]
      rowProps["path" .. index]     = paths[((index - 1) % math.max(#paths, 1)) + 1]

      rows[#rows + 1] = f:row {
        spacing = 8,
        f:checkbox {
          title = "",
          value = LrView.bind("selected" .. index),
          bind_to_object = rowProps,
        },
        f:catalog_photo {
          photo = LrView.bind("photo" .. index),
          width = 90, height = 90,
          bind_to_object = rowProps,
        },
        f:picture {
          value = LrView.bind("path" .. index),
          width = 90, height = 90,
          bind_to_object = rowProps,
        },
        f:static_text { title = "row " .. index, width = 200 },
      }
    end
  end)
  report:addf("  %d rows: %s %s", PAGE, rowsTook,
    rowsErr and ("FAILED: " .. rowsErr) or "built")
  report:blank()

  ----------------------------------------------------------------- showing it

  report:step("Showing them")
  report:add("  Look at the window that opens, then answer the questions in it.")

  local answers = { swapped = "not asked" }

  local ok, answer = LrTasks.pcall(function()
    local page = 1
    return LrDialogs.presentModalDialog {
      title = "iNat Probe: Thumbnails",
      contents = f:column {
        spacing = 10,
        f:static_text {
          title = "1. Do you see a catalog photo and a downloaded photo below?",
        },
        f:row {
          spacing = 12,
          f:column { f:static_text { title = "catalog_photo" },
                     built.boundCatalogPhoto },
          f:column { f:static_text { title = "picture" },
                     built.boundPicture },
        },
        f:static_text {
          title = "2. Press Swap. Do BOTH images change to a different photo?",
        },
        f:row {
          f:push_button {
            title = "Swap",
            action = function()
              page = page + 1
              local nextPhoto = photos[((page - 1) % #photos) + 1]
              local nextPath  = paths[((page - 1) % math.max(#paths, 1)) + 1]
              bound.photo = nextPhoto
              bound.path  = nextPath
              bound.label = "page " .. page
            end,
          },
          f:static_text {
            title = LrView.bind("label"),
            bind_to_object = bound,
            width = 120,
          },
        },
        f:static_text { title = "3. Below: a page of " .. PAGE .. " rows." },
        f:scrolled_view {
          width = 560, height = 320,
          f:column(rows),
        },
      },
      actionVerb = "Both images changed",
      cancelVerb = "They did not",
    }
  end)

  if not ok then
    report:addf("  presentModalDialog FAILED: %s", tostring(answer))
  else
    answers.swapped = (answer == "ok") and "yes -- images rebind"
      or "no -- images cannot be rebound"
    report:addf("  rebinding both images: %s", answers.swapped)
  end
  report:blank()

  report:step("What this means")
  report:add("  images rebind  -> one dialog, 25 fixed rows, Next repoints them")
  report:add("  they do not    -> a fresh dialog per page")

  report:show()
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext("inat_thumb_probe", run)
end)
