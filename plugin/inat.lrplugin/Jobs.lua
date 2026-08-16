--[[
  Jobs.lua
  --------
  One long-running iNaturalist operation at a time.

  The operations this guards all walk the catalog and write to it: a sync, a
  reverse sync, a link. Two of them at once is not merely slow. They contend
  for write transactions, they report into two progress bars that each claim to
  be the one that matters, and a reverse sync deciding which photo is free to
  link while a sync is busy relinking photos is reading a catalog that is
  changing underneath it.

  The lock is module state rather than dialog state on purpose. A sync started
  from the menu is still running after the settings dialog is closed and
  reopened, and a guard that lived in the dialog would forget about it.
--]]

local LrDialogs = import "LrDialogs"
local LrTasks   = import "LrTasks"

local Jobs = {}

--- The label of whatever is running, or nil.
local current = nil

--- Listeners to notify when that changes, so a dialog can grey a button out.
--
-- Held weakly by key so that a dialog which has since been dismissed does not
-- keep its property table alive, or get written to long after it stopped being
-- visible.
local watchers = setmetatable({}, { __mode = "k" })

function Jobs.current()
  return current
end

function Jobs.isRunning()
  return current ~= nil
end

--- Be told when a job starts or finishes.
-- @param key    Any table; the registration lasts as long as the caller holds it.
-- @param notify Called with the running job's label, or nil when idle.
function Jobs.watch(key, notify)
  watchers[key] = notify
  -- Guarded like the later ones: a listener that cannot cope with the current
  -- state should not stop the caller registering, nor take down whatever it was
  -- in the middle of doing when it registered.
  pcall(notify, current)
end

local function announce()
  for _, notify in pairs(watchers) do
    -- One broken listener must not stop the others being told, and must not
    -- take down the job that was only trying to say it had finished.
    pcall(notify, current)
  end
end

--- Tell the user why nothing happened.
function Jobs.reportBusy(blocking)
  LrDialogs.message("iNaturalist",
    "Something else is still running: " .. tostring(blocking) .. ".\n\n"
      .. "Wait for it to finish, or cancel it from the progress bar in the "
      .. "top left.",
    "info")
end

--- Run body with the lock held, if nothing else holds it.
--
-- @param label  What to call this in the "already running" message.
-- @param body   The work. May yield; it is expected to.
-- @return true when it ran, or false plus the label of what blocked it.
function Jobs.run(label, body)
  if current then return false, current end

  current = label
  announce()

  -- LrTasks.pcall, not plain pcall: the body yields -- every one of these makes
  -- HTTP calls -- and plain pcall turns yielding off, which surfaces as the
  -- body claiming it is not running inside a task.
  --
  -- Wrapped at all because the release has to happen even when the body fails.
  -- A job that errors without releasing leaves the plugin refusing to do
  -- anything until Lightroom restarts, and the user has no way to tell that is
  -- what happened.
  local ok, err = LrTasks.pcall(body)

  current = nil
  announce()

  if not ok then error(err, 0) end
  return true
end

--- Run body if the lock is free, and say so if it is not.
function Jobs.runOrReport(label, body)
  local ran, blocking = Jobs.run(label, body)
  if not ran then Jobs.reportBusy(blocking) end
  return ran
end

return Jobs
