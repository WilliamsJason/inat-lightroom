--[[
  PluginInit.lua
  --------------
  Entry point called by Lightroom when the plugin loads, and also the handler
  for the "Set Up Credentials" menu item.

  Credentials are stored with LrPasswords so they are encrypted at rest.
--]]

local LrDialogs   = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrPasswords = import "LrPasswords"
local LrView      = import "LrView"
local LrBinding   = import "LrBinding"
local LrLogger    = import "LrLogger"

local logger = LrLogger("iNatLightroom")
logger:enable("print")  -- change to "logfile" in production

local PLUGIN_ID = "com.github.inat-lightroom"

-- Credential keys used with LrPasswords
local KEY_APP_ID     = PLUGIN_ID .. ".app_id"
local KEY_APP_SECRET = PLUGIN_ID .. ".app_secret"
local KEY_USERNAME   = PLUGIN_ID .. ".username"
local KEY_USER_PASS  = PLUGIN_ID .. ".user_pass"

--------------------------------------------------------------------------------
-- Public helpers used by other plugin modules
--------------------------------------------------------------------------------

local PluginInit = {}

--- Read a stored credential; returns nil when not set.
function PluginInit.getCredential(key)
  return LrPasswords.retrieve(PLUGIN_ID, key)
end

--- Persist a credential in the OS keychain via LrPasswords.
function PluginInit.setCredential(key, value)
  LrPasswords.store(PLUGIN_ID, key, value)
end

--- Return a table with all four credentials, or nil if any are missing.
function PluginInit.getStoredCredentials()
  local app_id     = PluginInit.getCredential(KEY_APP_ID)
  local app_secret = PluginInit.getCredential(KEY_APP_SECRET)
  local username   = PluginInit.getCredential(KEY_USERNAME)
  local user_pass  = PluginInit.getCredential(KEY_USER_PASS)

  if not (app_id and app_secret and username and user_pass) then
    return nil
  end

  return {
    app_id     = app_id,
    app_secret = app_secret,
    username   = username,
    user_pass  = user_pass,
  }
end

--------------------------------------------------------------------------------
-- Credential setup dialog
--------------------------------------------------------------------------------

local function showSetupDialog()
  LrFunctionContext.callWithContext("inat_setup", function(context)
    local f      = LrView.osFactory()
    local props  = LrBinding.makePropertyTable(context)

    -- Pre-populate from stored values
    props.app_id     = PluginInit.getCredential(KEY_APP_ID)     or ""
    props.app_secret = PluginInit.getCredential(KEY_APP_SECRET) or ""
    props.username   = PluginInit.getCredential(KEY_USERNAME)   or ""
    props.user_pass  = PluginInit.getCredential(KEY_USER_PASS)  or ""

    local contents = f:column {
      bind_to_object = props,
      spacing = f:label_spacing(),

      f:row {
        f:static_text { title = "iNaturalist OAuth Application", font = "<system/bold>" },
      },
      f:row {
        f:static_text { title = "Create an app at inaturalist.org/oauth/applications/new", font = "<system/small>" },
      },

      f:spacer { height = 8 },

      f:row {
        f:static_text { title = "App ID:",      width = 100, alignment = "right" },
        f:edit_field   { value = LrView.bind("app_id"),     width = 300, immediate = true },
      },
      f:row {
        f:static_text { title = "App Secret:", width = 100, alignment = "right" },
        f:password_field { value = LrView.bind("app_secret"), width = 300, immediate = true },
      },

      f:spacer { height = 8 },

      f:row {
        f:static_text { title = "Your iNaturalist Account", font = "<system/bold>" },
      },
      f:row {
        f:static_text { title = "Username:", width = 100, alignment = "right" },
        f:edit_field   { value = LrView.bind("username"),  width = 300, immediate = true },
      },
      f:row {
        f:static_text { title = "Password:", width = 100, alignment = "right" },
        f:password_field { value = LrView.bind("user_pass"), width = 300, immediate = true },
      },
    }

    local result = LrDialogs.presentModalDialog {
      title    = "iNaturalist – Set Up Credentials",
      contents = contents,
      actionVerb = "Save",
    }

    if result == "ok" then
      PluginInit.setCredential(KEY_APP_ID,     props.app_id)
      PluginInit.setCredential(KEY_APP_SECRET, props.app_secret)
      PluginInit.setCredential(KEY_USERNAME,   props.username)
      PluginInit.setCredential(KEY_USER_PASS,  props.user_pass)
      LrDialogs.message("iNaturalist", "Credentials saved.", "info")
      logger:info("Credentials saved for user: " .. (props.username or ""))
    end
  end)
end

-- The Lightroom menu item calls the file directly; top-level code runs.
showSetupDialog()

return PluginInit
