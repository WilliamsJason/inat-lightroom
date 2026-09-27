--[[
  UnreadableProbeMenu.lua
  -----------------------
  A file that is present and still will not load.

  WHY THIS EXISTS
  ---------------
  Four messages have now been produced deliberately on Windows, and none of
  them is the one in the reporter's screenshot:

    require, absent      error loading toolkit script `X'
                         (Could not load script X.lua: doesn't seem to be in
                         the toolkit.)
    require, bad parse   error loading toolkit script `X'
                         ([string "X.lua"]:1: ...)
    declared, absent     No script by the name X.lua
    reporter             Could not load toolkit script: PluginFiles

  The two require branches in substrate.dll sit next to each other and split
  on toolkit membership rather than on the disk:

    "Could not load script %s: doesn't seem to be in the toolkit."
    "Could not load toolkit script: %s"

  The first is "I do not have that". The second is "I have that and could not
  load it", and it takes no reason argument, which is why it reads so bare.

  So the reporter's file is very probably THERE. That is worth stating plainly
  because it contradicts the last two diagnoses, including the one committed
  earlier today: a missing file produces a different message, and
  PluginFiles.brokenInstallText would have reported nothing missing -- which
  is exactly what he experienced.

  WHAT IS BEING TRIED
  -------------------
  Ways for a file to exist and still be unloadable, cheapest first:

    empty       zero bytes. A copy that created the destination and wrote
                nothing is a plausible outcome of a half-done copy.
    directory   a *folder* named X.lua. Present to anything that only asks
                "does this path exist", unreadable to anything that opens it.
                This is what a bad copy or a bad unzip can leave behind.
    denied      present, non-empty, valid Lua, and not readable by this user.
                The macOS-flavoured one: a copy that does not carry
                permissions across leaves precisely this.

  LrFileUtils.exists returns a truthy value for all three, which is the point.
  Every "is the install intact" check in the plugin asks exactly that question
  and would pass all three.

  CLEANING UP
  -----------
  The denied case changes an ACL, so it is restored in the same run whether
  or not the require succeeded, and the result of the restore is printed. A
  probe that leaves an unreadable file in a plugin folder has created the bug
  it was investigating.
--]]

local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"

local Report = require "Report"

local function pathFor(name)
  return LrPathUtils.child(_PLUGIN.path, name .. ".lua")
end

--- Remove whatever is at a path, file or folder, so a re-run starts clean.
local function clear(path)
  if LrFileUtils.exists(path) then
    pcall(LrFileUtils.delete, path)
  end
end

--- require, reporting the error verbatim. The wording is the measurement.
local function ask(report, label, moduleName)
  local took, value, err = Report.timed(require, moduleName)

  if err then
    report:addf("  %-10s FAILED  [%s]", label, took)
    report:addf("      %s", err)
    return err
  end

  report:addf("  %-10s loaded  [%s]  returned %s", label, took, type(value))
  return nil
end

--- What every "is the install intact" check in the real plugin would say.
local function existsSays(report, path)
  report:addf("      LrFileUtils.exists -> %s", tostring(LrFileUtils.exists(path)))
end

local function run(report)
  report:add("A file can be present and still refuse to load. None of the")
  report:add("four messages produced so far match the reporter's, and the")
  report:add("two require branches split on toolkit membership rather than")
  report:add("on the disk -- so his file is probably there and unreadable.")
  report:blank()

  local found = {}

  -- ---------------------------------------------------------------- empty
  report:step("empty file, zero bytes")
  local emptyPath = pathFor("ProbeZeroBytes")
  clear(emptyPath)
  local handle = io.open(emptyPath, "wb")
  if handle then handle:close() end
  report:addf("      wrote %s", tostring(emptyPath))
  existsSays(report, emptyPath)
  found.empty = ask(report, "empty", "ProbeZeroBytes")
  report:blank()

  -- ------------------------------------------------------------ directory
  report:step("a folder named like a script")
  local dirPath = pathFor("ProbeIsAFolder")
  clear(dirPath)
  pcall(LrFileUtils.createAllDirectories, dirPath)
  report:addf("      created %s", tostring(dirPath))
  existsSays(report, dirPath)
  found.directory = ask(report, "directory", "ProbeIsAFolder")
  report:blank()

  -- --------------------------------------------------------------- denied
  report:step("present, valid Lua, not readable")
  local deniedPath = pathFor("ProbeDenied")
  clear(deniedPath)
  local dh = io.open(deniedPath, "wb")
  if dh then
    dh:write("return { probe = 'denied' }\n")
    dh:close()
  end

  -- No os.getenv: Lightroom's Lua has the os table stripped down and getenv
  -- is nil, which aborted the first run of this probe at exactly this line.
  -- LrTasks.execute goes through cmd.exe, so the expansion happens there
  -- instead and never needs to be visible to Lua.
  local who = "%USERNAME%"

  -- icacls rather than anything in the SDK: LrFileUtils has no notion of
  -- permissions at all, which is itself part of the finding.
  local denyCmd = string.format('icacls "%s" /deny "%s":(R)', deniedPath, who)
  local denyRc = LrTasks.execute(denyCmd)
  report:addf("      deny for %s -> rc=%s", who, tostring(denyRc))
  existsSays(report, deniedPath)

  -- Prove the denial actually took, so a require that succeeds cannot be
  -- mistaken for "permissions do not matter" when it really means "the ACL
  -- did not apply".
  local readable = io.open(deniedPath, "r")
  report:addf("      io.open for read -> %s",
    readable and "still readable, DENY DID NOT TAKE" or "refused, as intended")
  if readable then readable:close() end

  found.denied = ask(report, "denied", "ProbeDenied")

  local restoreRc = LrTasks.execute(
    string.format('icacls "%s" /remove:d "%s"', deniedPath, who))
  report:addf("      restore -> rc=%s", tostring(restoreRc))
  local afterRestore = io.open(deniedPath, "r")
  report:addf("      readable again -> %s", tostring(afterRestore ~= nil))
  if afterRestore then afterRestore:close() end
  report:blank()

  -- -------------------------------------------------------------- reading
  report:step("reading")
  local target = "Could not load toolkit script"
  local hit = nil
  for label, err in pairs(found) do
    if err and err:find(target, 1, true) then hit = label end
  end

  if hit then
    report:addf("  MATCH: the '%s' case produces the reporter's wording.", hit)
    report:add("  His file is present and unloadable, not missing. Every")
    report:add("  check in the plugin that asks LrFileUtils.exists would")
    report:add("  call that folder healthy, which is why Repair looked")
    report:add("  unnecessary and a restart looked like the answer.")
  else
    report:add("  None of these produced it either. The message is reachable")
    report:add("  -- it is in substrate.dll next to loadScript -- but not by")
    report:add("  any route tried so far. Do not guess again in the plugin;")
    report:add("  find the route first, or ask the reporter for the folder")
    report:add("  listing with sizes and permissions.")
  end
end

LrTasks.startAsyncTask(function()
  local report = Report.new("iNat Probe: Present But Unloadable")
  local ok, err = LrTasks.pcall(run, report)
  if not ok then
    report:blank()
    report:addf("probe aborted: %s", tostring(err))
  end
  report:show()
end)
