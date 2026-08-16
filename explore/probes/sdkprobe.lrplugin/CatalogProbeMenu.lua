--[[
  CatalogProbeMenu.lua
  --------------------
  Answers the catalog-side questions Reverse Sync depends on, inside a real
  Lightroom against a real catalog:

    1. Do LrCatalog:findPhotos, :batchGetRawMetadata and
       :batchGetPropertyForPlugin exist and are they reachable from a plugin?
    2. What shape of searchDesc does findPhotos accept for a capture-time
       range -- the flat table, or the smart-collection table-of-criteria with
       a combine key?
    3. How much faster is one batchGetRawMetadata than a getRawMetadata loop?
       This is the whole performance case for indexing the catalog, so a
       number matters more than a belief.

  Lightroom runs a menu item's file top to bottom the moment it is clicked, so
  this starts its own task rather than returning anything.

  findPhotos asserts it is called from within an LrTask -- the string is in
  LibraryToolkit.dll -- which is another reason everything here is inside one.
--]]

local LrApplication     = import "LrApplication"
local LrDate            = import "LrDate"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrProgressScope   = import "LrProgressScope"
local LrTasks           = import "LrTasks"

local Report = require "Report"

--- The type of a method on an SDK object, without assuming indexing is safe.
--
-- Plain pcall is correct here and nowhere else in this file: reading a field
-- cannot yield, and if indexing ever did, LrTasks.pcall could not rescue it --
-- Lua cannot yield across a metamethod at all.
local function methodType(object, name)
  local ok, value = pcall(function() return object[name] end)
  if not ok then return "error: " .. tostring(value) end
  return type(value)
end

--- How many photos a call returned, when it returned anything list-shaped.
local function countOf(value)
  if type(value) ~= "table" then return nil end
  return #value
end

--- Run one findPhotos shape and report what came back.
local function trySearch(report, catalog, label, argument)
  local took, photos, err = Report.timed(function()
    return catalog:findPhotos(argument)
  end)

  if err then
    report:addf("  %-28s FAILED  %s", label, err)
    return nil
  end

  local count = countOf(photos)
  report:addf("  %-28s %8s  %s photo(s)", label, took,
    count and tostring(count) or "non-list result")
  return photos
end

local function run(context)
  local catalog = LrApplication.activeCatalog()
  local report  = Report.new("iNat SDK Probe - Catalog APIs")

  -- Several of the calls below are slow by nature on a large catalog, and this
  -- probe exists precisely because nobody knows how slow. Without a scope the
  -- wait is indistinguishable from a hang -- which is how the first run of this
  -- probe was read, correctly enough, as "no UI appeared".
  local scope = LrProgressScope {
    title            = "iNat SDK probe: catalog APIs",
    functionContext  = context,
  }
  report:track(scope)

  report:add("=== Catalog API probe ===")
  report:addf("catalog path: %s", tostring(catalog:getPath()))
  report:blank()

  -- ---------------------------------------------------------------- exists
  report:step("Method availability")
  report:add("Method availability (LrCatalog):")
  local methods = {
    "findPhotos", "findPhotosWithProperty", "getAllPhotos",
    "batchGetRawMetadata", "batchGetFormattedMetadata",
    "batchGetPropertyForPlugin", "getPhotoByLocalId",
  }
  for _, name in ipairs(methods) do
    report:addf("  %-28s %s", name, methodType(catalog, name))
  end
  report:blank()

  -- ------------------------------------------------------------ everything
  report:step("getAllPhotos")
  report:add("Baseline:")
  local took, allPhotos = Report.timed(function()
    return catalog:getAllPhotos()
  end)
  local total = countOf(allPhotos) or 0
  report:addf("  %-28s %8s  %d photo(s)", "getAllPhotos", took, total)
  report:blank()

  -- ------------------------------------------------------- searchDesc shape
  --
  -- The date operation vocabulary is read out of LibraryToolkit.dll:
  --   == != > < inLast notInLast in today yesterday thisWeek thisMonth ...
  -- so "in" is a real operation. What is not visible in the strings is which
  -- table shape findPhotos wants it wrapped in.
  report:step("findPhotos shapes")
  report:add("findPhotos searchDesc shapes (capture time 2000-01-01 .. 2035-01-01):")

  local rangeFlat = {
    criteria  = "captureTime",
    operation = "in",
    value     = "2000-01-01",
    value2    = "2035-01-01",
  }

  trySearch(report, catalog, "flat criteria table", {
    searchDesc = rangeFlat,
  })

  trySearch(report, catalog, "array + combine", {
    searchDesc = { rangeFlat, combine = "intersect" },
  })

  trySearch(report, catalog, "array + combine + sort", {
    searchDesc = { rangeFlat, combine = "intersect" },
    sort       = "captureTime",
    ascending  = true,
  })

  -- ">=" is deliberately not tested here, and must not be reintroduced.
  --
  -- It is not in the vocabulary next to AgDate in LibraryToolkit.dll -- that
  -- list has ">" and "<" but no ">=" -- and an unsupported operator does not
  -- raise. findPhotos simply never returns. The first run of this probe sat on
  -- that one call for minutes with the progress bar up, which is a far worse
  -- failure than an error, and is the reason Reverse Sync builds its search
  -- descriptors from a fixed table of known-good operators rather than by
  -- assembling operator strings.
  trySearch(report, catalog, "> only", {
    searchDesc = {
      { criteria = "captureTime", operation = ">", value = "2000-01-01" },
      combine = "intersect",
    },
  })

  report:blank()

  -- ------------------------------------------------- narrow window queries
  --
  -- The measurement the whole feature rests on.
  --
  -- Indexing every photo does not survive a catalog of millions, but it does
  -- not have to: observations top out around five digits, so Reverse Sync can
  -- ask one narrow capture-time question per observation instead of holding
  -- the catalog in memory. That trade is only worth making if a narrow window
  -- query is cheap, and if captureTime comparisons honour seconds rather than
  -- silently rounding to whole days.
  --
  -- The result count says which: roughly one match means second-level
  -- precision works, hundreds means the time part is being dropped and only
  -- the date is comparing, zero means the value format was rejected outright.
  report:step("Narrow captureTime windows")
  report:add("Narrow window queries (one per observation is the plan):")

  local WINDOWS = 25
  local stride  = math.max(1, math.floor(total / WINDOWS))
  local windowTotal, windowRuns, windowHits = 0, 0, 0
  local shownExample = false

  --- Count what a ±2 s window around `when` returns, for one value format.
  local function windowCount(when, format, makeValue)
    local _, found, err = Report.timed(function()
      return catalog:findPhotos {
        searchDesc = {
          { criteria = "captureTime", operation = "in",
            value = makeValue(when - 2), value2 = makeValue(when + 2) },
          combine = "intersect",
        },
      }
    end)
    if err then return format .. ": FAILED " .. err end
    return string.format("%s: %d", format, countOf(found) or 0)
  end

  -- Which string format the value wants is not written down anywhere legible,
  -- and getting it wrong is not loud: a rejected format returns nothing rather
  -- than complaining. Three candidates, on one photo, before trusting any of
  -- them 25 times over.
  for i = 1, total do
    local _, when = Report.timed(function()
      return allPhotos[i]:getRawMetadata("dateTimeOriginal")
    end)
    if type(when) == "number" then
      report:add("  value formats (a ±2 s window should hold ~1 photo):")
      report:addf("    %s", windowCount(when, "W3C     ",
        function(t) return LrDate.timeToW3CDate(t) end))
      report:addf("    %s", windowCount(when, "ISO-ish ",
        function(t) return LrDate.timeToUserFormat(t, "%Y-%m-%dT%H:%M:%S") end))
      report:addf("    %s", windowCount(when, "date    ",
        function(t) return LrDate.timeToUserFormat(t, "%Y-%m-%d") end))
      report:blank()
      break
    end
  end

  for i = 1, total, stride do
    if windowRuns >= WINDOWS then break end
    local photo   = allPhotos[i]
    local _, when = Report.timed(function()
      return photo:getRawMetadata("dateTimeOriginal")
    end)

    if type(when) == "number" then
      local from = LrDate.timeToW3CDate(when - 2)
      local to   = LrDate.timeToW3CDate(when + 2)

      local took, found, err = Report.timed(function()
        return catalog:findPhotos {
          searchDesc = {
            { criteria = "captureTime", operation = "in",
              value = from, value2 = to },
            combine = "intersect",
          },
        }
      end)

      if err then
        report:addf("  window query FAILED  %s", err)
        break
      end

      windowRuns  = windowRuns + 1
      windowTotal = windowTotal + (tonumber(took:match("[%d%.]+")) or 0)
      windowHits  = windowHits + (countOf(found) or 0)

      if not shownExample then
        report:addf("  example window  %s .. %s", from, to)
        report:addf("  first query     %8s  %d photo(s)", took,
          countOf(found) or 0)
        shownExample = true
      end
    end
  end

  if windowRuns > 0 then
    report:addf("  %d windows      %.1f ms avg   %.1f photo(s) avg",
      windowRuns, windowTotal / windowRuns, windowHits / windowRuns)
    report:addf("  projected: 10,000 observations = %.1f s of querying",
      (windowTotal / windowRuns) * 10000 / 1000)
  else
    report:add("  (no photo carried a dateTimeOriginal)")
  end

  report:blank()

  -- --------------------------------------------------------- bulk metadata
  --
  -- The comparison that decides whether a whole-catalog index is affordable.
  -- Sampled rather than run over everything, because the loop is the slow half
  -- and running it over 100k photos to prove it is slow is unkind.
  local SAMPLE = 500
  local sample = {}
  for i = 1, math.min(SAMPLE, total) do
    sample[i] = allPhotos[i]
  end

  report:step("batchGetRawMetadata vs loop")
  report:addf("Metadata reads over a %d photo sample:", #sample)

  if #sample > 0 then
    local keys = { "dateTimeOriginal", "gps", "fileName", "isVirtualCopy" }

    local batchTook, batchResult, batchErr = Report.timed(function()
      return catalog:batchGetRawMetadata(sample, keys)
    end)

    if batchErr then
      report:addf("  %-28s FAILED  %s", "batchGetRawMetadata", batchErr)
    else
      report:addf("  %-28s %8s", "batchGetRawMetadata", batchTook)
      -- Shape matters as much as speed: the result is expected to be keyed by
      -- the photo object, not by index.
      local first = sample[1]
      local row   = type(batchResult) == "table" and batchResult[first] or nil
      report:addf("      result type   %s", type(batchResult))
      report:addf("      keyed by photo %s", tostring(row ~= nil))
      if type(row) == "table" then
        report:addf("      dateTimeOriginal %s / gps %s / fileName %s",
          tostring(row.dateTimeOriginal), tostring(row.gps ~= nil),
          tostring(row.fileName))
      end
    end

    local loopTook = select(1, Report.timed(function()
      for _, photo in ipairs(sample) do
        local _ = photo:getRawMetadata("dateTimeOriginal")
        local _ = photo:getRawMetadata("gps")
      end
    end))
    report:addf("  %-28s %8s", "getRawMetadata loop", loopTook)
  else
    report:add("  (catalog is empty; nothing to sample)")
  end

  report:blank()

  -- -------------------------------------------------- plugin property reads
  --
  -- Reverse Sync has to know which photos are already linked before it starts.
  -- findPhotosWithProperty answers that today, one photo at a time after the
  -- fact; batchGetPropertyForPlugin would answer it in one call, if its
  -- signature is what the string table suggests.
  report:step("Plugin property reads")
  report:add("Plugin property reads:")

  local linkedTook, linked, linkedErr = Report.timed(function()
    return catalog:findPhotosWithProperty("com.github.inat-lightroom",
      "inat_observation_id")
  end)
  if linkedErr then
    report:addf("  %-28s FAILED  %s", "findPhotosWithProperty", linkedErr)
  else
    report:addf("  %-28s %8s  %d photo(s)", "findPhotosWithProperty",
      linkedTook, countOf(linked) or 0)
  end

  if #sample > 0 then
    -- Two plausible signatures; report which one answers.
    local _, _, errA = Report.timed(function()
      return catalog:batchGetPropertyForPlugin(sample,
        "com.github.inat-lightroom", "inat_observation_id")
    end)
    report:addf("  %-28s %s", "batch(photos,id,key)",
      errA and ("FAILED  " .. errA) or "ok")

    local _, _, errB = Report.timed(function()
      return catalog:batchGetPropertyForPlugin(sample, _PLUGIN,
        "inat_observation_id")
    end)
    report:addf("  %-28s %s", "batch(photos,_PLUGIN,key)",
      errB and ("FAILED  " .. errB) or "ok")
  end

  report:blank()
  report:add("=== end ===")
  scope:done()
  report:show()
end

LrFunctionContext.postAsyncTaskWithContext("inat_probe_catalog", function(context)
  local ok, err = LrTasks.pcall(run, context)
  if not ok then
    -- The log has already been flushed line by line, so it holds everything up
    -- to the call that failed even though this dialog holds only the error.
    LrDialogs.message("iNat SDK Probe", "Probe failed:\n\n" .. tostring(err) ..
      "\n\nPartial results were written to inat-sdk-probe.txt on the Desktop.",
      "critical")
  end
end)
