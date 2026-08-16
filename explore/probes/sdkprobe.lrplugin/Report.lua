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
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
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
function Report.timed(f, ...)
  local startTime = Report.now()
  local results   = { pcall(f, ...) }
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

  local ok = pcall(function()
    local folder = LrPathUtils.getStandardFilePath("desktop")
    path = LrPathUtils.child(folder, "inat-sdk-probe.txt")
    -- Append rather than replace: a probe run is usually one of several, and
    -- losing the previous answer to run the next one is a poor trade.
    local existing = LrFileUtils.exists(path) and LrFileUtils.readFile(path) or ""
    local handle = io.open(path, "w")
    handle:write(existing .. body .. "\n\n")
    handle:close()
  end)

  if ok and path then
    body = body .. "\n\nWritten to " .. path
  end

  local f = LrView.osFactory()
  LrDialogs.presentModalDialog {
    title    = self.title,
    contents = f:column {
      f:edit_text {
        value           = body,
        width           = 720,
        height_in_lines = 30,
        enabled         = true,
      },
    },
    actionVerb   = "Done",
    cancelVerb   = "< exclude >",
  }
end

return Report
