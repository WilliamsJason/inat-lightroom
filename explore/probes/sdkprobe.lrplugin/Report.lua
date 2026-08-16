--[[
  Report.lua
  ----------
  Collects probe output, shows it, and writes it beside the catalog so a result
  can be pasted into an issue rather than transcribed off a screenshot.

  A modal with a read-only edit_text rather than LrDialogs.message: message
  truncates, cannot be scrolled, and cannot be selected to copy.
--]]

local LrDate      = import "LrDate"
local LrDialogs   = import "LrDialogs"
local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"
local LrView      = import "LrView"

local Report = {}
Report.__index = Report

function Report.new(title)
  return setmetatable({ title = title, lines = {} }, Report)
end

function Report:add(line)
  self.lines[#self.lines + 1] = tostring(line)
end

function Report:addf(format, ...)
  local ok, line = pcall(string.format, format, ...)
  self:add(ok and line or format)
end

function Report:blank()
  self:add("")
end

function Report:text()
  return table.concat(self.lines, "\n")
end

--- Seconds since some fixed point, as a float. LrDate.currentTime is the only
-- clock available to a plugin with sub-second resolution; os.clock measures CPU
-- time, which is not what any of this is asking about.
function Report.now()
  return LrDate.currentTime()
end

--- Milliseconds between two Report.now() readings, rounded to one decimal.
function Report.elapsed(startTime)
  return string.format("%.1f ms", (Report.now() - startTime) * 1000)
end

--- Run f, returning elapsed-time text plus whatever f returned.
-- Errors are caught: a probe that dies half way is still worth the lines it
-- already produced, and "this call does not exist" is itself a result.
--
-- LrTasks.pcall, not Lua's pcall. **A plain pcall stops the code inside it
-- being able to yield**, and every interesting SDK call here yields. The
-- symptom is not an obvious one: the call comes back with
-- "LrCatalog:findPhotos: must be called from within an LrTask" while running
-- inside a perfectly good task, because what the SDK actually tests is whether
-- yielding is possible right now. getAllPhotos was quieter still -- it returned
-- an empty list rather than complaining, which read as an empty catalog.
function Report.timed(f, ...)
  local startTime = Report.now()
  local results   = { LrTasks.pcall(f, ...) }
  local took      = Report.elapsed(startTime)

  if not results[1] then
    return took, nil, tostring(results[2])
  end
  return took, results[2], nil
end

--- Write the report next to the catalog and show it.
function Report:show()
  local body = self:text()
  local path = nil

  -- io.open in append mode rather than LrFileUtils.readFile and a rewrite:
  -- plain io does not yield, so it works from anywhere, and appending is what
  -- was wanted anyway. A probe run is usually one of several, and losing the
  -- previous answer to run the next one is a poor trade.
  local ok = pcall(function()
    local folder = LrPathUtils.getStandardFilePath("desktop")
    path = LrPathUtils.child(folder, "inat-sdk-probe.txt")
    local handle = io.open(path, "a")
    handle:write(body .. "\n\n")
    handle:close()
  end)

  if ok and path then
    body = body .. "\n\nWritten to " .. path
  end

  -- edit_field, not edit_text. **edit_text is Mac-only**: in ui.dll's factory
  -- list it sits directly behind a MAC_ENV guard, so on Windows f:edit_text is
  -- nil and calling it fails with "attempt to call method 'edit_text' (a nil
  -- value)" -- at the moment the probe tries to show its results, which is the
  -- worst possible time to lose them. The file above is written first for
  -- exactly that reason.
  local f = LrView.osFactory()
  LrDialogs.presentModalDialog {
    title    = self.title,
    contents = f:column {
      f:edit_field {
        value           = body,
        width           = 720,
        height_in_lines = 30,
        enabled         = true,
      },
    },
    actionVerb = "Done",
    cancelVerb = "< exclude >",
  }
end

return Report
