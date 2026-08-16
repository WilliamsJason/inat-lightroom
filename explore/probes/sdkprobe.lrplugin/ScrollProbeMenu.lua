--[[
  ScrollProbeMenu.lua
  -------------------
  How many rows can a scrolled_view hold before the dialog stops being worth
  opening?

  This is the one question behind the Reverse Sync review list that no amount
  of dumping binaries answers. ui.dll's factory exports exactly one list
  control a plugin can use -- simple_list -- and it holds strings, not rows of
  checkboxes. The richer internal table view (columns, row_height, cell types
  image/checkbox/custom, allows_multiple_selection) is in ui.dll but is not in
  the osFactory export list, so it is not reachable. That leaves building N
  ordinary rows inside a scrolled_view, eagerly, with no virtualisation.

  Two costs, measured separately because they have different fixes:

    build    Lua time spent constructing the view tree. Shown as a number.
    open     the wait between asking for the dialog and being able to use it.
             Nothing in the SDK reports this, so it is measured against the
             user: press Escape the instant the window is usable, and the
             elapsed time is the open cost plus human reaction (~0.3 s).

  Also probes catalog_photo, since a thumbnail per row is the difference
  between a list you can check and a list you have to trust.
--]]

local LrApplication     = import "LrApplication"
local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrView            = import "LrView"

local Report = require "Report"

local ROW_COUNTS  = { 50, 100, 250, 500, 1000 }

-- Pushed further than the hand-built rows on purpose. If a native table really
-- does draw only what is on screen, 5000 costs about what 500 does, and that
-- result is the difference between a paged review list and a plain one.
local LIST_COUNTS = { 500, 5000 }

--- Build one review-list row of the shape Reverse Sync would need.
--
-- Deliberately the real thing rather than a placeholder: a checkbox bound to a
-- property, three text columns, and optionally a thumbnail. A probe that
-- measures a simpler row than the feature would ship answers a question nobody
-- asked.
local function buildRow(f, index, photo, withThumbnail)
  local cells = {
    f:checkbox { title = "", value = LrView.bind("sel_" .. index) },
  }

  if withThumbnail and photo then
    cells[#cells + 1] = f:catalog_photo {
      photo  = photo,
      width  = 60,
      height = 40,
    }
  end

  cells[#cells + 1] = f:static_text {
    title = "DSC_" .. string.format("%05d", index) .. ".ARW",
    width = 150,
  }
  cells[#cells + 1] = f:static_text {
    title = "2024-05-10 14:30:0" .. (index % 10),
    width = 130,
  }
  cells[#cells + 1] = f:static_text {
    title = "Quercus robur (English Oak)",
    width = 220,
  }
  cells[#cells + 1] = f:static_text {
    title = (index % 4 == 0) and "ambiguous" or "exact",
    width = 80,
  }

  return f:row(cells)
end

--- Build and show one list of the given size, reporting both costs.
local function measure(report, context, rowCount, withThumbnail, photos)  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  local propTook = select(1, Report.timed(function()
    for i = 1, rowCount do
      props["sel_" .. i] = true
    end
  end))

  local rows
  local buildTook, _, buildErr = Report.timed(function()
    rows = {}
    for i = 1, rowCount do
      rows[i] = buildRow(f, i, photos[i], withThumbnail)
    end
    return true
  end)

  if buildErr then
    report:addf("  %5d rows  BUILD FAILED  %s", rowCount, buildErr)
    return false
  end

  local contents = f:column {
    bind_to_object = props,
    f:static_text {
      title = rowCount .. " rows"
        .. (withThumbnail and " with thumbnails" or "")
        .. " -- press Escape as soon as this is usable.",
      font = "<system/bold>",
    },
    f:scrolled_view {
      width               = 780,
      height              = 420,
      horizontal_scroller = false,
      f:column(rows),
    },
  }

  local openStart = Report.now()
  local shown, showErr = pcall(function()
    return LrDialogs.presentModalDialog {
      title      = "Probe: " .. rowCount .. " rows",
      contents   = contents,
      actionVerb = "Next",
    }
  end)
  local openTook = Report.elapsed(openStart)

  if not shown then
    report:addf("  %5d rows  SHOW FAILED  %s", rowCount, tostring(showErr))
    return false
  end

  report:addf("  %5d rows  props %8s  build %8s  open+dismiss %8s",
    rowCount, propTook, buildTook, openTook)
  return true
end

--- The same list as a simple_list, which is a native table_view underneath.
--
-- Worth measuring against the hand-built rows because it is a different kind of
-- thing: ui.dll builds simple_list from a table_view inside a scroll_view, and a
-- native table draws only the rows on screen. If it holds 5000 items without
-- complaint then the review list does not need paging at all -- the cost is
-- that an item is a string, so the selection has to carry the meaning that a
-- per-row checkbox would have carried.
--
-- allows_multiple_selection turns the selection itself into the answer:
-- everything selected is everything that gets linked, which is also how
-- "selected by default" is expressed (pre-fill value with every index).
local function measureSimpleList(report, context, rowCount)
  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  local items, selected
  local buildTook, _, buildErr = Report.timed(function()
    items    = {}
    selected = {}
    for i = 1, rowCount do
      items[i] = {
        title = string.format("DSC_%05d.ARW    2024-05-10 14:30:0%d    "
          .. "Quercus robur (English Oak)    %s",
          i, i % 10, (i % 4 == 0) and "ambiguous" or "exact"),
        value = i,
      }
      selected[i] = i
    end
    props.selection = selected
    return true
  end)

  if buildErr then
    report:addf("  %5d items BUILD FAILED  %s", rowCount, buildErr)
    return false
  end

  local contents = f:column {
    bind_to_object = props,
    f:static_text {
      title = rowCount .. " items in a simple_list -- press Escape as soon as "
        .. "this is usable.",
      font = "<system/bold>",
    },
    f:simple_list {
      items                     = items,
      value                     = LrView.bind("selection"),
      allows_multiple_selection = true,
      width                     = 780,
      height                    = 420,
    },
  }

  local openStart = Report.now()
  local shown, showErr = pcall(function()
    return LrDialogs.presentModalDialog {
      title      = "Probe: simple_list, " .. rowCount .. " items",
      contents   = contents,
      actionVerb = "Next",
    }
  end)
  local openTook = Report.elapsed(openStart)

  if not shown then
    report:addf("  %5d items SHOW FAILED  %s", rowCount, tostring(showErr))
    return false
  end

  -- What the selection looks like coming back matters as much as the timing:
  -- simple_list's value is a table even for one row (see
  -- docs/lightroom-sdk-notes.md), and a pre-filled multiple selection is not
  -- something this plugin has done before.
  local returned = props.selection
  local count    = (type(returned) == "table") and #returned or -1
  report:addf("  %5d items build %8s  open+dismiss %8s  selection back: %s (%d)",
    rowCount, buildTook, openTook, type(returned), count)
  return true
end

local function run(context)
  local report = Report.new("iNat SDK Probe - Scrolled View")
  -- A handful of real photos, so catalog_photo is exercised with something it
  -- can actually draw.
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getAllPhotos() or {}

  report:add("=== Scrolled view probe ===")
  report:addf("catalog holds %d photo(s)", #photos)
  report:add("")
  report:add("open+dismiss includes human reaction time (~0.3 s); it is there")
  report:add("to separate 'instant' from 'unusable', not to be precise.")
  report:blank()

  local wantThumbnails = LrDialogs.confirm(
    "Include a catalog_photo thumbnail in every row?",
    "Run it once without and once with: the difference is the cost of "
      .. "thumbnails, which is the part most likely to make a long list "
      .. "unusable.",
    "With thumbnails", "Text only") == "ok"

  report:addf("thumbnails: %s", tostring(wantThumbnails))
  report:blank()
  report:add("Timings:")

  for _, rowCount in ipairs(ROW_COUNTS) do
    local ok = measure(report, context, rowCount, wantThumbnails, photos)
    if not ok then break end

    -- Anything past a thousand rows is academic if a thousand already hurts,
    -- and asking somebody to dismiss five more dialogs to prove it is rude.
  end

  report:blank()
  report:add("simple_list (native table_view, one string per row):")

  for _, rowCount in ipairs(LIST_COUNTS) do
    if not measureSimpleList(report, context, rowCount) then break end
  end

  report:blank()
  report:add("=== end ===")
  report:show()
end

LrFunctionContext.postAsyncTaskWithContext("inat_probe_scroll", function(context)
  local ok, err = pcall(run, context)
  if not ok then
    LrDialogs.message("iNat SDK Probe", "Probe failed:\n\n" .. tostring(err),
      "critical")
  end
end)
