--[[
  MissingScriptProbeMenu.lua
  --------------------------
  What does Lightroom actually say when a toolkit script is not there?

  The whole ExportPresets investigation turned on one line of wording in a
  screenshot:

    An internal error has occurred.
    Could not load toolkit script: ExportPresets

  That was read as "the file is absent", then re-read as "the file is present
  but unbindable", then read back again as "absent" -- three readings of a
  string nobody had ever produced deliberately. This produces it deliberately,
  on a machine we control, with the file known to be absent for certain.

  WHAT IS BEING SEPARATED
  -----------------------
    absent        a module with no file at all. The reporter's case, by
                  hypothesis.

    unparseable   a file that is present and is not valid Lua. Known to word
                  differently -- "error loading toolkit script `json' (...)"
                  with a line number -- but that was recorded off someone
                  else's screenshot too, so it gets reproduced here as well.

    empty         a file that is present, parses, and returns nothing. A
                  plausible outcome of a copy that created the destination and
                  wrote no bytes, which is one of the ways a bad copy could
                  look, and worth being able to tell apart from absent.

    control       a module that is present and fine. If this fails, nothing
                  else on the page means anything.

    case          the control's name in the wrong case. Windows will not care
                  and macOS may not either, but if it ever does care that is a
                  whole class of "file is right there" failures, so it is one
                  cheap line to ask.

  WHY CATCHING IT IS NOT THE WHOLE ANSWER
  ---------------------------------------
  This catches the errors so it can print all five side by side. But the
  reporter did not see a caught error, he saw Lightroom's own dialog, and the
  two are not guaranteed to be worded the same -- "An internal error has
  occurred." is Lightroom's framing around the message, not part of it.

  So there is a second menu item, "iNat Probe: Missing Script (uncaught)",
  which requires an absent module and does nothing about it. That one is
  meant to produce the real dialog, to be compared against the screenshot
  pixel for pixel. Run this one first; it is the one that writes a file.
--]]

local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"

local Report = require "Report"

--- A module name that cannot possibly resolve, and is obviously deliberate
-- if it ever turns up in a log.
local ABSENT = "NoSuchScript_DeliberatelyAbsent"

--- Write a file into the plugin folder, returning whether it landed.
local function writeModule(name, body)
  local path = LrPathUtils.child(_PLUGIN.path, name .. ".lua")

  local ok, handle = pcall(io.open, path, "w")
  if not ok or not handle then return nil, path end

  handle:write(body)
  handle:close()

  return LrFileUtils.exists(path), path
end

--- require, reporting the exact error text rather than raising.
--
-- The error string is the entire point of this probe, so it is printed raw
-- and unwrapped. Anything that reformats it -- trimming, truncating, stripping
-- a prefix -- destroys the one thing being measured.
local function ask(report, label, moduleName)
  local took, value, err = Report.timed(require, moduleName)

  if err then
    report:addf("  %-12s %-34s FAILED  [%s]", label, moduleName, took)
    report:addf("      %s", err)
    return false, err
  end

  report:addf("  %-12s %-34s loaded  [%s]  returned %s",
    label, moduleName, took, type(value))
  return true, nil
end

local function run(report)
  report:add("What does Lightroom say when a toolkit script is missing?")
  report:add("Producing the wording deliberately, with the file known to be")
  report:add("absent, so the reporter's screenshot can be read against a")
  report:add("known case instead of being interpreted.")
  report:blank()

  report:step("setting up")

  -- A file that is present and is not Lua. The unfinished string is enough
  -- to fail the parse on the first line, so the line number in the error is
  -- predictable and can be checked rather than just noted.
  local badOk, badPath = writeModule("ProbeUnparseable",
    'this is not lua at all, and the string never closes -> "\n')
  report:addf("  unparseable file   %s", tostring(badOk))
  report:addf("    %s", tostring(badPath))

  -- Present, parses, returns nothing. require's own contract is interesting
  -- here: a module that returns nil is not obviously an error to Lua.
  local emptyOk, emptyPath = writeModule("ProbeEmpty", "-- nothing at all\n")
  report:addf("  empty file         %s", tostring(emptyOk))
  report:addf("    %s", tostring(emptyPath))

  -- Confirm the absent one really is absent. A leftover from an earlier run
  -- would quietly turn this probe into the opposite experiment.
  local absentPath = LrPathUtils.child(_PLUGIN.path, ABSENT .. ".lua")
  report:addf("  absent really is   %s", tostring(LrFileUtils.exists(absentPath)))
  report:addf("    %s", tostring(absentPath))
  report:blank()

  report:step("require")
  ask(report, "control", "Report")
  local _, absentErr = ask(report, "absent", ABSENT)
  ask(report, "unparseable", "ProbeUnparseable")
  ask(report, "empty", "ProbeEmpty")
  ask(report, "wrong case", "report")
  report:blank()

  report:step("dofile, for comparison")
  -- require and dofile fail through different paths, and only require is
  -- routed through Lightroom's toolkit-script machinery. If the wording
  -- differs, the "toolkit script" phrasing is Lightroom's and not Lua's,
  -- which is worth knowing when reading any of these messages.
  local took, _, err = Report.timed(dofile, absentPath)
  if err then
    report:addf("  dofile absent   FAILED  [%s]", took)
    report:addf("      %s", err)
  else
    report:addf("  dofile absent   returned, unexpectedly  [%s]", took)
  end
  report:blank()

  report:step("reading")
  if absentErr and absentErr:find("Could not load toolkit script", 1, true) then
    report:add("  Reproduced. A module with no file on disk produces exactly")
    report:add("  the reporter's wording, on this machine, on this OS. The")
    report:add("  message means what it says and the 0.3.3 re-reading of it")
    report:add("  was wrong.")
  elseif absentErr then
    report:add("  An absent module does NOT produce the reporter's wording")
    report:add("  here. Either the message is platform-specific or it means")
    report:add("  something other than absent. Compare the text above against")
    report:add("  the screenshot before concluding anything further.")
  else
    report:add("  The absent module LOADED, which should be impossible and")
    report:add("  means a stale file is sitting in the plugin folder. Clear")
    report:add("  it out and run again; nothing above is trustworthy.")
  end
  report:blank()
  report:add("  Now run 'iNat Probe: Missing Script (uncaught)' to see how")
  report:add("  Lightroom frames the same failure in its own dialog, which is")
  report:add("  what the reporter actually sent.")
end

LrTasks.startAsyncTask(function()
  local report = Report.new("iNat Probe: Missing Script")
  local ok, err = LrTasks.pcall(run, report)
  if not ok then
    report:blank()
    report:addf("probe aborted: %s", tostring(err))
  end
  report:show()
end)
