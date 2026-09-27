--[[
  MissingScriptRawMenu.lua
  ------------------------
  The same failure as MissingScriptProbeMenu, with nothing catching it.

  This exists because the evidence in the original report is a *screenshot of
  Lightroom's dialog*, and a caught error string is not that. Lightroom wraps
  what it catches in its own framing -- "An internal error has occurred." and
  whatever else it decides to add -- and the only way to see the wrapper is to
  let the failure reach it.

  So this script does the one thing every other file in this plugin is careful
  not to do: it fails, on purpose, at the top level of a menu script, exactly
  as a real missing module would.

  WHAT TO DO
  ----------
  Click it, screenshot the dialog, and put that next to the reporter's
  screenshot. Same wording means the message means "absent" and the whole
  stale-session reading was a misreading. Different wording means the two
  failures are genuinely different and the investigation is not finished.

  There is nothing to clean up afterwards. Nothing is written, no preference
  is touched, and the error does not leave Lightroom in any particular state
  -- a menu script that raises is a supported outcome, just an ugly one.
--]]

-- Deliberately not in a pcall, not in a task, and not guarded in any way.
-- Every one of those would catch it, which is the opposite of the point.
--
-- The name is the same one MissingScriptProbeMenu checks for absence, so if
-- that probe reported "absent really is false" this will not behave as
-- intended and the folder needs clearing first.
require "NoSuchScript_DeliberatelyAbsent"
