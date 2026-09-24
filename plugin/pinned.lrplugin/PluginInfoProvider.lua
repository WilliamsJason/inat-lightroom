--[[
  PluginInfoProvider.lua
  ----------------------
  The plugin's section in Lightroom's Plug-in Manager.

  This is the one surface Lightroom gives a plugin that is about the plugin
  itself rather than about photos, and it is where people already go to install,
  enable and remove one. So it is where updating lives -- not in the settings
  dialog, which is about what an observation says, and not in the floating
  panel, which is about the photo in front of you.

  The section is deliberately four lines and four buttons. Everything that can
  go wrong here is reported in the status line rather than in a dialog, because
  the Plug-in Manager is already a modal window and a modal on top of it is how
  you end up with a message nobody can dismiss.

  Repair Installation is the fourth, and it is here rather than in the settings
  dialog for a reason that is easy to get backwards: the settings dialog is
  reached through Plug-in Extras, which is a menu of things this plugin's own
  modules do, and those are exactly what stops working when a module is
  missing. The Plug-in Manager section is drawn by Lightroom from a file it
  loads itself, so it survives a folder that has lost other files -- which is
  the only condition under which anyone needs it.
--]]

local LrFunctionContext = import "LrFunctionContext"
local LrHttp            = import "LrHttp"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local Settings      = require "Settings"
local Updater       = require "Updater"
local UpdateCore    = require "UpdateCore"
local UpdateInstall = require "UpdateInstall"
local logger        = require "Log"

-- Required defensively, and it is the one require here that has to be.
--
-- This section is where a user is sent when a file is missing, so it is the
-- one surface that must still open when the folder is damaged. A plain
-- `require` of a module that is itself absent would take the Plug-in Manager
-- section down with it and close the only door to the repair. Nil means "the
-- integrity check is not available", which reads as an installation too
-- damaged to describe -- and the Repair button below does not depend on it.
local ok, PluginFiles = pcall(require, "PluginFiles")
if not ok then PluginFiles = nil end

local PluginInfoProvider = {}

--------------------------------------------------------------------------------
-- The section
--------------------------------------------------------------------------------

--- Which shipped files are absent, as a list. Empty when nothing is, or when
--- the check itself could not be loaded.
local function missingFiles(pluginPath)
  if not PluginFiles then return {} end

  local found, result = pcall(PluginFiles.missing, pluginPath)
  if not found or type(result) ~= "table" then return {} end
  return result
end

--- Fill in the starting state: what is installed, and anything already staged.
--
-- Kept apart from the view so a test can watch it without a dialog.
--
-- The integrity check runs before the staged-update check and wins the status
-- line, because a damaged installation is the more urgent of the two and the
-- less self-explanatory. "Quit and restart to finish installing" is advice
-- someone can act on without understanding it; "Could not load toolkit script"
-- is not, and this is the only place that names the cause.
function PluginInfoProvider.initialise(props, pluginPath)
  props.installedVersion = Updater.versionString(Updater.currentVersion())
  props.result           = nil
  props.busy             = false

  local absent = missingFiles(pluginPath)
  props.damaged = #absent > 0

  if props.damaged then
    logger:warn("PluginInfoProvider: missing from the plugin folder: " ..
      table.concat(absent, ", "))
  end

  local pending = UpdateInstall.pending(pluginPath)
  props.staged = pending ~= nil

  -- An update applied while Lightroom was starting. Nothing is missing and a
  -- repair would re-download a folder that is already correct, so this is said
  -- before the ordinary "not checked yet" and after real damage.
  local stale = PluginFiles and PluginFiles.appliedAtStartup
    and PluginFiles.appliedAtStartup() or nil

  if props.damaged and not pending then
    props.status = "This installation is damaged: " .. #absent ..
      (#absent == 1 and " file is" or " files are") .. " missing (" ..
      table.concat(absent, ", ") .. "). Press Repair Installation to download "
      .. "this release again and put them back."
  elseif props.damaged then
    props.status = "This installation is damaged, and version " ..
      tostring(pending) .. " is staged to replace it. Quit and restart "
      .. "Lightroom to finish installing it."
  elseif pending then
    props.status = "Version " .. tostring(pending) .. " is staged. Quit and "
      .. "restart Lightroom to finish installing it."
  elseif stale then
    props.status = "Version " .. tostring(stale) .. " was installed while "
      .. "Lightroom was starting, so parts of it will not load until you quit "
      .. "Lightroom and start it again. Nothing is damaged."
  else
    props.status = "Not checked yet."
  end

  return props
end

--- Run the check and put the answer in the property table.
-- Must be called from a task.
function PluginInfoProvider.runCheck(props)
  props.busy   = true
  props.status = "Checking…"

  local result, err = UpdateCore.check()

  props.result = result
  props.status = UpdateCore.statusText(result, err)
  props.busy   = false

  return result
end

--- Stage whatever the last check found.
-- Must be called from a task.
function PluginInfoProvider.runInstall(props)
  local result = props.result
  if not result or not result.canInstall then
    props.status = "There is nothing to install. Check for updates first."
    return false
  end

  props.busy   = true
  props.status = "Downloading…"

  local ok, err = UpdateCore.install(result)

  props.busy = false

  if not ok then
    props.status = "Could not install the update: " .. tostring(err)
    return false
  end

  props.staged = true
  props.status = UpdateCore.stagedText(result)
  return true
end

--- Reinstall the current release over a damaged installation.
-- Must be called from a task.
--
-- Unlike runInstall this does not require a prior check: someone arriving here
-- has a plugin that is failing, and making them press Check for Updates first
-- -- to be told they are up to date, which is true and unhelpful -- is a step
-- between them and the fix for no benefit. UpdateCore.repair does its own
-- check.
function PluginInfoProvider.runRepair(props)
  props.busy   = true
  props.status = "Downloading…"

  local result, err = UpdateCore.repair()

  props.busy = false

  if not result then
    props.status = "Could not repair this installation: " .. tostring(err)
    return false
  end

  props.result = result
  props.staged = true
  props.status = UpdateCore.repairedText(result)
  return true
end

function PluginInfoProvider.sectionsForTopOfDialog(f, props)
  PluginInfoProvider.initialise(props, _PLUGIN.path)

  return {
    {
      title = "Updates",

      -- Everything lives inside one column so that `bind_to_object` can be
      -- stated once, and so that it is stated at all.
      --
      -- Without it, a binding in a Plug-in Manager section does not fall back
      -- to the property table this function is handed -- it falls back to the
      -- plugin's preferences. That failure is close to invisible: a bound key
      -- that happens to name a preference quietly reads and writes the wrong
      -- table, and one that does not simply renders empty. Both happened here.
      -- "Installed version:" was blank on the first run in Lightroom while the
      -- checkbox below looked perfectly correct, because
      -- `update_check_automatically` is a real preference and `installedVersion`
      -- is not.
      f:column {
        bind_to_object = props,
        spacing        = f:control_spacing(),

        f:row {
          f:static_text { title = "Installed version:", width = 110 },
          f:static_text { title = LrView.bind("installedVersion") },
        },

        f:row {
          f:static_text {
            title           = LrView.bind("status"),
            width           = 460,
            height_in_lines = 3,
          },
        },

        f:row {
          spacing = f:control_spacing(),

          f:push_button {
            title   = "Check for Updates",
            enabled = LrView.bind {
              key       = "busy",
              transform = function(busy) return not busy end,
            },
            action = function()
              LrTasks.startAsyncTask(function()
                PluginInfoProvider.runCheck(props)
              end)
            end,
          },

          f:push_button {
            title = "Download and Install",
            -- Only ever live when a check has found something installable, so
            -- the button cannot be the thing that discovers there is no release
            -- attached.
            enabled = LrView.bind {
              keys = { "result", "busy", "staged" },
              operation = function(_binder, values)
                local result = values.result
                return result ~= nil and result.canInstall == true
                  and not values.busy and not values.staged
              end,
            },
            action = function()
              LrTasks.startAsyncTask(function()
                PluginInfoProvider.runInstall(props)
              end)
            end,
          },

          f:push_button {
            title = "Repair Installation",
            -- Live whether or not the integrity check found anything. It is
            -- the fallback for "the plugin is behaving strangely", and the
            -- check only knows about files that are absent -- a folder can be
            -- wrong in ways a list of names cannot see. Disabled only while
            -- something else is already writing to the folder.
            enabled = LrView.bind {
              keys = { "busy", "staged" },
              operation = function(_binder, values)
                return not values.busy and not values.staged
              end,
            },
            action = function()
              LrTasks.startAsyncTask(function()
                PluginInfoProvider.runRepair(props)
              end)
            end,
          },

          f:push_button {
            title  = "Release Notes",
            action = function()
              local result = props.result
              local url = result and result.latest and result.latest.pageUrl
                or Updater.RELEASES_PAGE_URL
              LrHttp.openUrlInBrowser(url)
            end,
          },
        },

        f:row {
          f:checkbox {
            title = "Check for updates automatically",
            value = LrView.bind("update_check_automatically"),
          },
        },

        f:row {
          f:static_text {
            title = "Updates are downloaded from this plugin's GitHub releases "
              .. "and checked against the checksum published with them.\n"
              .. "An update finishes installing when you quit Lightroom.",
            width           = 460,
            height_in_lines = 2,
          },
        },
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Preferences
--------------------------------------------------------------------------------

--- Bind the automatic-check preference, and save it when the dialog closes.
--
-- The Plug-in Manager does not have an OK button of its own for a plugin's
-- section, so the value is written when the section goes away rather than when
-- something is clicked.
function PluginInfoProvider.startDialog(props)
  props.update_check_automatically = Settings.get("update_check_automatically")
end

function PluginInfoProvider.endDialog(props)
  if props.update_check_automatically ~= nil then
    Settings.set("update_check_automatically", props.update_check_automatically)
  end
end

return PluginInfoProvider
