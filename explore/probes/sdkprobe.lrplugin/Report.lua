--[[
  Report.lua
  ----------
  Collects probe output, shows it, and writes it beside the catalog so a result
  can be pasted into an issue rather than transcribed off a screenshot.

  A modal with a read-only edit_field rather than LrDialogs.message: message
  truncates, cannot be scrolled, and cannot be selected to copy.
--]]

local LrDate      = import "LrDate"
local LrDialogs   = import "LrDialogs"
local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"
local LrView      = import "LrView"

local Report = {}
Report.__index = Report

--- Where the running log goes. Desktop is redirected into OneDrive on some
-- machines; getStandardFilePath follows the redirect, $HOME\Desktop does not.
local function logPath()
  local folder = LrPathUtils.getStandardFilePath("desktop")
  return LrPathUtils.child(folder, "inat-sdk-probe.txt")
end

function Report.new(title)
  local self = setmetatable({ title = title, lines = {} }, Report)

  -- The log is opened now and every line is flushed as it is produced, rather
  -- than written in one go at the end. A probe measures calls that may be slow
  -- enough to look like a hang, and a probe that dies or is given up on part
  -- way through is exactly the run whose output is most worth having: the last
  -- line in the file names the call that did not come back.
  local ok, handle = pcall(function()
    self.path = logPath()
    return io.open(self.path, "a")
  end)
  self.handle = ok and handle or nil

  self:add(string.format("### %s  %s", tostring(title),
    LrDate.timeToUserFormat(LrDate.currentTime(), "%Y-%m-%d %H:%M:%S")))
  return self
end

function Report:add(line)
  line = tostring(line)
  self.lines[#self.lines + 1] = line

  if self.handle then
    -- Flushed per line on purpose: an unflushed buffer is empty at precisely
    -- the moment the file is being read to find out what went wrong.
    pcall(function()
      self.handle:write(line, "\n")
      self.handle:flush()
    end)
  end
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

--- Attach a progress scope, so a slow phase is visible in Lightroom rather than
-- looking like a hang. Optional: the log alone tells the story after the fact,
-- but not while waiting.
function Report:track(scope)
  self.scope = scope
end

--- Announce the phase about to start, in the progress bar and in the log.
function Report:step(caption)
  if self.scope then
    pcall(function() self.scope:setCaption(caption) end)
  end
  self:add("[" .. caption .. "]")
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

--- Close the running log and show what was collected.
function Report:show()
  local body = self:text()

  if self.handle then
    pcall(function()
      self.handle:write("\n")
      self.handle:close()
    end)
    self.handle = nil
  end

  if self.path then
    body = body .. "\n\nWritten to " .. self.path
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
