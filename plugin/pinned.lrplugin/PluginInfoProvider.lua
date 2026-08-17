--[[
  PluginInfoProvider.lua
  ----------------------
  The plugin's section in Lightroom's Plug-in Manager.

  This is the one surface Lightroom gives a plugin that is about the plugin
  itself rather than about photos, and it is where people already go to install,
  enable and remove one. So it is where updating lives -- not in the settings
  dialog, which is about what an observation says, and not in the floating
  panel, which is about the photo in front of you.

  The section is deliberately four lines and three buttons. Everything that can
  go wrong here is reported in the status line rather than in a dialog, because
  the Plug-in Manager is already a modal window and a modal on top of it is how
  you end up with a message nobody can dismiss.
--]]

local LrFunctionContext = import "LrFunctionContext"
local LrHttp            = import "LrHttp"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local Settings      = require "Settings"
local Updater       = require "Updater"
local UpdateCore    = require "UpdateCore"
local UpdateInstall = require "UpdateInstall"

local PluginInfoProvider = {}

--------------------------------------------------------------------------------
-- The section
--------------------------------------------------------------------------------

--- Fill in the starting state: what is installed, and anything already staged.
--
-- Kept apart from the view so a test can watch it without a dialog.
function PluginInfoProvider.initialise(props, pluginPath)
  props.installedVersion = Updater.versionString(Updater.currentVersion())
  props.result           = nil
  props.busy             = false

  local pending = UpdateInstall.pending(pluginPath)
  if pending then
    props.staged = true
    props.status = "Version " .. tostring(pending) .. " is staged. Quit and "
      .. "restart Lightroom to finish installing it."
  else
    props.staged = false
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
