--[[
  UpdateCore.lua
  --------------
  The update flow, with no dialog in it.

  Updater knows how to ask GitHub what exists. UpdateInstall knows how to get a
  release onto disk safely. This is the part that decides when to ask, what to
  do with the answer, and what to say -- which is the part both the Plug-in
  Manager section and the unattended startup check need, and neither should own.

  Two rules shape all of it:

    Checking is automatic; installing is not. A plugin that replaces itself
    without being asked is a plugin that changes what your catalog does while
    you are not looking. The check is cheap and quiet; the install is a button.

    Not knowing is not the same as being up to date. Every network failure here
    resolves to "could not check", never to silence that a user would read as
    "nothing new".
--]]

local LrDate  = import "LrDate"
local LrHttp  = import "LrHttp"
local LrTasks = import "LrTasks"

local Settings      = require "Settings"
local Updater       = require "Updater"
local UpdateInstall = require "UpdateInstall"
local logger        = require "Log"

local UpdateCore = {}

--- How long a check is good for.
--
-- A day. Releases of a plugin like this arrive weeks apart, and the cost of
-- being a day late is nothing next to the cost of hitting GitHub on every
-- launch from every machine behind one address.
UpdateCore.CHECK_INTERVAL_SECONDS = 24 * 60 * 60

--- How long to wait after launch before checking.
--
-- Lightroom is busy opening the catalog, and this is the least urgent thing
-- happening on the machine.
UpdateCore.STARTUP_DELAY_SECONDS = 30

--------------------------------------------------------------------------------
-- When to check
--------------------------------------------------------------------------------

--- Whether an automatic check is due.
--
-- Pure, and takes the clock as an argument, so the interval can be tested
-- without waiting a day.
--
-- A last-checked time in the future means the clock moved, or the preference
-- was written by a machine in another timezone through a synced preferences
-- file. Treating it as due is the safe reading: the worst case is one extra
-- request, against a check that would otherwise never run again.
function UpdateCore.isCheckDue(now, lastChecked, enabled)
  if enabled == false then return false end
  if type(lastChecked) ~= "number" or lastChecked <= 0 then return true end
  if lastChecked > now then return true end
  return (now - lastChecked) >= UpdateCore.CHECK_INTERVAL_SECONDS
end

function UpdateCore.checkIsDue()
  return UpdateCore.isCheckDue(
    LrDate.currentTime(),
    Settings.get("update_last_checked"),
    Settings.get("update_check_automatically"))
end

--------------------------------------------------------------------------------
-- Checking
--------------------------------------------------------------------------------

--- Ask GitHub, and remember when we asked.
--
-- Must be called from a task.
--
-- The timestamp is written whether or not the answer was useful. Recording only
-- successes turns an offline week into a request on every single launch, which
-- is the behaviour rate limits exist to punish.
function UpdateCore.check()
  local result, err = Updater.check()

  Settings.set("update_last_checked", LrDate.currentTime())

  if not result then
    logger:warn("Updater: could not check for updates: " .. tostring(err))
    return nil, err
  end

  return result
end

--- Plain language for whatever the check found.
--
-- Pure, so the wording can be tested. The Plug-in Manager shows this in a
-- static text, and it is the only place most people will ever read the
-- version they are running.
function UpdateCore.statusText(result, err)
  if err then
    return "Could not check for updates: " .. tostring(err)
  end

  if not result then
    return "Not checked yet."
  end

  local installed = Updater.versionString(result.current)

  if not result.isNewer then
    return "Version " .. installed .. " is the latest release."
  end

  local available = Updater.versionString(result.latest.version)

  if not result.canInstall then
    -- A release with no archive attached is a release published by hand rather
    -- than by the workflow. Offering an Install button that cannot work would
    -- be worse than saying so.
    return "Version " .. available .. " is available, but that release has no "
      .. "downloadable plugin attached. Install it from the releases page."
  end

  return "Version " .. available .. " is available. You have " .. installed .. "."
end

--------------------------------------------------------------------------------
-- Installing
--------------------------------------------------------------------------------

--- Download, verify and stage a release.
--
-- Must be called from a task.
--
-- @return true, or nil plus a message fit to show a user
function UpdateCore.install(result)
  if not result or not result.canInstall then
    return nil, "there is nothing to install"
  end

  local hash, hashErr = Updater.expectedHash(result.latest)
  if not hash then
    -- Refusing here is the point. Installing something whose checksum could not
    -- be read is exactly the case the checksum exists for.
    return nil, "could not read the release checksum: " .. tostring(hashErr)
  end

  local ok, err = UpdateInstall.stage(result.latest, hash)
  if not ok then return nil, err end

  return true
end

--- What to tell someone once an update is staged.
function UpdateCore.stagedText(result)
  local version = result and result.latest
    and Updater.versionString(result.latest.version) or "The update"

  return "Version " .. version .. " is ready. It will finish installing when "
    .. "you quit Lightroom, and will be in use next time you start it."
end

--------------------------------------------------------------------------------
-- The unattended check
--------------------------------------------------------------------------------

--- Whether to interrupt someone about this release.
--
-- Once per version, not once per launch. Being told about the same release
-- every morning is how a notification becomes something people learn to click
-- through without reading.
function UpdateCore.shouldNotify(result, alreadyNotifiedTag)
  if not result or not result.isNewer then return false end
  local tag = result.latest and result.latest.tag
  if not tag then return false end
  return tag ~= alreadyNotifiedTag
end

--- The startup check: quiet, throttled, and never blocking.
--
-- Runs in its own task because it sleeps and then touches the network, and
-- LrInitPlugin must return promptly -- Lightroom is loading plugins.
function UpdateCore.checkOnStartup()
  if not UpdateCore.checkIsDue() then return end

  LrTasks.startAsyncTask(function()
    LrTasks.sleep(UpdateCore.STARTUP_DELAY_SECONDS)

    local result = UpdateCore.check()
    if not UpdateCore.shouldNotify(result, Settings.get("update_notified_tag")) then
      return
    end

    Settings.set("update_notified_tag", result.latest.tag)

    -- A dialog, once, for a version. The alternative is a status line in the
    -- Plug-in Manager that nobody opens, which is the same as not telling
    -- anyone. There is a preference to turn the whole check off.
    local LrDialogs = import "LrDialogs"
    local answer = LrDialogs.confirm(
      "iNaturalist",
      UpdateCore.statusText(result),
      "Show Me",
      "Later")

    if answer == "ok" then
      LrHttp.openUrlInBrowser(result.latest.pageUrl)
    end
  end)
end

return UpdateCore
