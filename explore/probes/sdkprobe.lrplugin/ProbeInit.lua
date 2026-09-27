--[[
  ProbeInit.lua
  -------------
  LrInitPlugin for the probe: writes a brand-new .lua file into the plugin's
  own folder while Lightroom is loading the plugin.

  WHAT THIS IS FOR
  ----------------
  The claim behind 0.3.3 is that Lightroom fixes the set of toolkit scripts a
  plugin has when it loads the plugin -- before LrInitPlugin runs -- so a file
  that appears during init cannot be required for the rest of that session.

  That was inferred from a user's log, never reproduced. Two releases were
  shipped on the strength of it, and a Reload Plug-in has since been shown to
  pick up a file added while Lightroom was running, which narrows the claim to
  a question of *when* the file appears. So it needs testing directly.

  This reproduces the exact condition with no updater, no download and no
  staging folder involved: a file that did not exist when Lightroom bound the
  script list, and does exist by the time anything tries to require it.

  The probe plugin has no LrShutdownPlugin, which is the point. That is the
  reporter's situation by construction -- for him the hook never runs, so
  every update lands at init -- and it is why this can be tested on Windows
  without pretending to be a Mac.

  WHY A UNIQUE NAME EACH LAUNCH
  -----------------------------
  A fixed name would be left behind by the previous run, so it *would* be on
  disk at the next launch, Lightroom would bind it, and the require would
  succeed for a reason that has nothing to do with the question. Stamping the
  name guarantees that the file being asked for cannot have been present when
  the list was bound. Old ones are swept up below so the folder does not fill.

  Everything is written to preferences rather than logged, because the plugin
  this belongs to has no logger and the menu item needs to read it back.
--]]

local LrDate      = import "LrDate"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrPrefs     = import "LrPrefs"

local prefs = LrPrefs.prefsForPlugin(nil)

--- A name that cannot collide with a previous run's.
--
-- Was string.format("%d", LrDate.currentTime() * 1000), which is where the
-- first version of this probe went wrong and produced a result that read as
-- a clean refutation of the 0.3.3 diagnosis:
--
--   currentTime() is ~8.1e8 seconds, so *1000 is ~8.1e11
--   "%d" in Lua 5.1 casts to a 32-bit int -> -2147483648, every single launch
--
-- So every run wrote the SAME filename. Run one created it legitimately; run
-- two found last run's copy already on disk at bind time and "proved" that a
-- late file loads, when all it had proved was that an early file loads.
--
-- A counter cannot overflow and cannot repeat, and it is stored where the
-- experiment can see it. %.0f would also have worked and is what the format
-- string should have been.
local function nextName()
  local n = (tonumber(prefs.lateCounter) or 0) + 1
  prefs.lateCounter = n
  return string.format("LateArrival_%03d", n)
end

--- Files earlier runs left behind, newest last.
--
-- The pattern deliberately allows a leading minus: the broken run wrote
-- LateArrival_-2147483648.lua, "%d+" did not match it, so the sweep reported
-- nothing to compare against and the experiment silently lost its control.
local function previous()
  local found = {}

  for file in LrFileUtils.files(_PLUGIN.path) do
    local leaf = LrPathUtils.leafName(file)
    if leaf:match("^LateArrival_[%-%d]+%.lua$") then
      found[#found + 1] = leaf:gsub("%.lua$", "")
    end
  end

  table.sort(found)
  return found
end

--- Keep exactly one earlier file, delete the rest.
--
-- The survivor is the control: it was on disk before this launch, so
-- Lightroom saw it when it bound the script list. Keeping more than one just
-- fills the folder, and keeping none removes the only thing that makes
-- today's result interpretable.
local function trim(found)
  for index = 1, #found - 1 do
    pcall(LrFileUtils.delete,
      LrPathUtils.child(_PLUGIN.path, found[index] .. ".lua"))
  end

  return found[#found]
end

local found = previous()
prefs.latePrevious      = trim(found)
prefs.latePreviousCount = #found

local name = nextName()
local path = LrPathUtils.child(_PLUGIN.path, name .. ".lua")

-- Written two ways on purpose. io.open is what the first version used and it
-- is not how an update arrives: the updater calls LrFileUtils.copy, which is
-- the call whose failure mode started all of this. If the two disagree, the
-- mechanism matters and that is the finding.
local source = LrPathUtils.child(_PLUGIN.path, "Report.lua")
local viaCopy = LrPathUtils.child(_PLUGIN.path, name .. "_copied.lua")

local ok, err = pcall(function()
  local handle = assert(io.open(path, "w"))
  handle:write(
    "-- Written during LrInitPlugin by ProbeInit.lua. Not shipped.\n",
    "return { stamp = \"", name, "\", how = \"io.open\" }\n")
  handle:close()
end)

-- The real mechanism: LrFileUtils.copy to a destination that does not exist.
-- v0.3.0's realFs.copy assumed "every file in an update already exists at the
-- destination", which is false for exactly the files that broke.
local copyOk, copyResult = pcall(LrFileUtils.copy, source, viaCopy)

prefs.lateName        = ok and name or nil
prefs.latePath        = path
prefs.lateError       = (not ok) and tostring(err) or nil
prefs.lateOnDisk      = ok and (LrFileUtils.exists(path) == "file") or false

prefs.lateCopyName    = name .. "_copied"
prefs.lateCopyPath    = viaCopy
prefs.lateCopyRaised  = not copyOk
prefs.lateCopyReturn  = tostring(copyResult)
prefs.lateCopyOnDisk  = (LrFileUtils.exists(viaCopy) == "file")

prefs.lateWritten = LrDate.timeToUserFormat(LrDate.currentTime(),
  "%Y-%m-%d %H:%M:%S")

