--[[
  LateLoadProbeMenu.lua
  ---------------------
  Can a file that appeared during LrInitPlugin be required in that session?

  ProbeInit.lua wrote one on the way in. This asks for it four ways, and the
  pattern across the four is the answer rather than any one result:

    control       a module that shipped in the folder and was therefore
                  present when Lightroom bound the list. If this fails,
                  require is broken in this context and nothing else here
                  means anything.

    today's       the file written during this launch's LrInitPlugin. This is
                  the one the whole 0.3.3 diagnosis rests on.

    yesterday's   a file written during an *earlier* launch's init, and so
                  present on disk before this launch began. If today's fails
                  and this succeeds, the difference is purely when the file
                  arrived -- which is the claim, isolated.

    dofile        the same file, read straight off disk rather than through
                  require. Separates "Lightroom will not load this module"
                  from "the file is unreadable", which the internal error
                  wording does not distinguish.

  WHAT TO DO WITH THE RESULT
  --------------------------
  If today's fails and yesterday's succeeds, 0.3.3 is right and the only
  remaining question is whether a Reload Plug-in is enough to rescue the
  session -- which is worth knowing because it is far cheaper to ask a user
  for than a full restart, and it has already been shown to pick up a file
  added while Lightroom was running.

  So: run this once, then Reload Plug-in, then run it again WITHOUT quitting.
  The second run's "yesterday's" is the first run's "today's".

  If today's succeeds, the diagnosis is wrong, and what actually broke that
  user is something else still unexplained.
--]]

local LrFileUtils = import "LrFileUtils"
local LrPrefs     = import "LrPrefs"
local LrTasks     = import "LrTasks"

local Report = require "Report"

local prefs = LrPrefs.prefsForPlugin(nil)

--- require, reporting rather than raising, and naming which failure it was.
local function tryRequire(report, label, moduleName)
  if not moduleName then
    report:addf("  %-14s (nothing recorded to try)", label)
    return
  end

  local took, value, err = Report.timed(require, moduleName)

  if err then
    -- The wording is the diagnosis. "Could not load toolkit script" is the
    -- error a user sees and the one this whole investigation started from;
    -- anything else here is a different fault wearing the same clothes.
    local wording = err:match("[Cc]ould not load toolkit script")
      and "  <-- THE REPORTED ERROR" or ""
    report:addf("  %-14s %-34s FAILED  [%s]%s", label, moduleName, took, wording)
    report:addf("      %s", err:gsub("%s+", " "))
    return false
  end

  report:addf("  %-14s %-34s loaded  [%s] %s", label, moduleName, took,
    type(value) == "table" and ("stamp=" .. tostring(value.stamp)) or
      type(value))
  return true
end

LrTasks.startAsyncTask(function()
  local report = Report.new("iNat Probe: Late File Load")

  report:add("Does a file written during LrInitPlugin load in that session?")
  report:add("This plugin has no LrShutdownPlugin, so it is the reporter's")
  report:add("situation by construction: nothing is ever applied at unload.")
  report:blank()

  report:step("what init did")
  report:addf("  written at        %s", tostring(prefs.lateWritten))
  report:addf("  module name       %s", tostring(prefs.lateName))
  report:addf("  path              %s", tostring(prefs.latePath))
  report:addf("  on disk after     %s", tostring(prefs.lateOnDisk))
  if prefs.lateError then
    report:addf("  write error       %s", tostring(prefs.lateError))
  end
  report:addf("  left by earlier   %s (%s found)",
    tostring(prefs.latePrevious), tostring(prefs.latePreviousCount))
  report:blank()

  -- Asked again now rather than trusting what init recorded. If this
  -- disagrees with "on disk after", the file went away in between and the
  -- experiment is void.
  report:step("is it still there")
  local exists = prefs.latePath and LrFileUtils.exists(prefs.latePath)
  report:addf("  LrFileUtils.exists -> %s", tostring(exists))
  report:blank()

  report:step("require")
  tryRequire(report, "control", "Report")
  local late = tryRequire(report, "today's", prefs.lateName)
  local copied = tryRequire(report, "today's (copy)", prefs.lateCopyName)
  local old  = tryRequire(report, "yesterday's", prefs.latePrevious)
  report:blank()

  report:step("LrFileUtils.copy to a destination that did not exist")
  report:add("  This is the real mechanism. v0.3.0's realFs.copy assumed")
  report:add("  every file in an update already exists at the destination,")
  report:add("  and returned LrFileUtils.copy's value straight to a caller")
  report:add("  that only treated `false` as failure.")
  report:addf("  raised            %s", tostring(prefs.lateCopyRaised))
  report:addf("  returned          %s", tostring(prefs.lateCopyReturn))
  report:addf("  on disk after     %s", tostring(prefs.lateCopyOnDisk))
  if prefs.lateCopyReturn == "nil" and prefs.lateCopyOnDisk == true then
    report:add("  <-- returns nil on SUCCESS, so `== false` was never the")
    report:add("      right test and a real failure would look identical")
  end
  report:blank()

  report:step("dofile, bypassing require")
  if prefs.latePath then
    local took, value, err = Report.timed(dofile, prefs.latePath)
    report:addf("  dofile %s  [%s]",
      err and ("failed: " .. err:gsub("%s+", " ")) or
        ("returned " .. type(value)), took)
  end
  report:blank()

  report:step("reading")
  report:addf("  control %s / today's %s / today's copy %s / yesterday's %s",
    tostring(true), tostring(late), tostring(copied), tostring(old))
  if late == false and old == true then
    report:add("  Today's file failed and an older one loaded. The only")
    report:add("  difference between them is whether the file existed when")
    report:add("  Lightroom bound the script list, so the 0.3.3 diagnosis")
    report:add("  holds and it is specifically a binding-time problem.")
  elseif late == true and old == true then
    report:add("  Both loaded, and today's could not have been present when")
    report:add("  the list was bound. A file added during LrInitPlugin IS")
    report:add("  requireable, so the 0.3.3 mechanism is wrong: the reporter's")
    report:add("  module did not fail to LOAD, it failed to ARRIVE.")
    report:add("  That points back at the silent copy, which is what 0.3.1")
    report:add("  fixed and which that user never received.")
  elseif late == true then
    report:add("  Today's file loaded, but there was no older file to compare")
    report:add("  against, so this is suggestive rather than conclusive.")
    report:add("  Reload Plug-in and run again -- the second run has both.")
  else
    report:add("  Inconclusive. Read the lines above rather than this one.")
  end

  report:show()
end)
