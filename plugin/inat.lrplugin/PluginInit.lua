--[[
  PluginInit.lua
  --------------
  Handler for the "Set Up Credentials" menu item.

  Two ways to authenticate, reflecting where iNaturalist's API access
  currently stands:

    Paste a token       Works today with no application registration. The
                        user signs in at inaturalist.org, opens
                        /users/api_token, and pastes the result. Expires
                        after 24 hours.

    OAuth application   Requires approval from iNaturalist, which has gated
                        application creation since 2022 behind an account age
                        and identification-activity bar. Once configured,
                        tokens refresh silently and the user is never
                        prompted again.

  Secrets go to LrPasswords, which is backed by the OS credential vault.
  Nothing is written to disk by this plugin.
--]]

local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp            = import "LrHttp"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local InatAuth = require "InatAuth"
local logger   = require "Log"

local TOKEN_URL = "https://www.inaturalist.org/users/api_token"
local APP_URL   = "https://www.inaturalist.org/oauth/applications/new"

local PluginInit = {}

--------------------------------------------------------------------------------
-- Credential setup dialog
--------------------------------------------------------------------------------

--- Describe the freshness of the stored token in plain language.
local function tokenStatusText()
  if InatAuth.hasOAuthApp() then
    return "An OAuth application is configured. Tokens refresh automatically."
  end

  local age = InatAuth.tokenAgeSeconds()
  if not age then
    return "No token stored yet."
  end

  local hours = math.floor(age / 3600)
  if hours >= 24 then
    return "Stored token is " .. hours .. " hours old and has expired. Paste a new one."
  end

  return string.format("Stored token is %d hour(s) old. Tokens last 24 hours.", hours)
end

local function showSetupDialog()
  LrFunctionContext.callWithContext("inat_setup", function(context)
    local f     = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)

    props.api_token  = ""
    props.app_id     = ""
    props.app_secret = ""
    props.username   = InatAuth.getStoredUsername() or ""
    props.user_pass  = ""
    props.status     = tokenStatusText()

    local contents = f:column {
      bind_to_object = props,
      spacing = f:label_spacing(),
      width = 520,

      -- ---- Current state ------------------------------------------------
      f:row {
        f:static_text {
          title = LrView.bind("status"),
          width = 500,
          height_in_lines = 2,
        },
      },

      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      -- ---- Option 1: paste a token --------------------------------------
      f:row {
        f:static_text { title = "Option 1: Paste an API token", font = "<system/bold>" },
      },
      f:row {
        f:static_text {
          title = "Sign in to iNaturalist, open the token page, and paste the "
            .. "result below.\nThis works without registering an application, "
            .. "but expires after 24 hours.",
          width = 500,
          height_in_lines = 2,
        },
      },
      f:row {
        f:push_button {
          title = "Open Token Page",
          action = function()
            LrHttp.openUrlInBrowser(TOKEN_URL)
          end,
        },
      },
      f:row {
        f:static_text { title = "Token:", width = 90, alignment = "right" },
        f:password_field { value = LrView.bind("api_token"), width = 380, immediate = true },
      },

      f:spacer { height = 10 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      -- ---- Option 2: OAuth application ----------------------------------
      f:row {
        f:static_text { title = "Option 2: OAuth application", font = "<system/bold>" },
      },
      f:row {
        f:static_text {
          title = "Refreshes tokens automatically, so you are never prompted "
            .. "again.\niNaturalist requires manual approval before you can "
            .. "create an application.",
          width = 500,
          height_in_lines = 2,
        },
      },
      f:row {
        f:push_button {
          title = "Apply for an Application",
          action = function()
            LrHttp.openUrlInBrowser(APP_URL)
          end,
        },
      },
      f:row {
        f:static_text { title = "App ID:", width = 90, alignment = "right" },
        f:edit_field { value = LrView.bind("app_id"), width = 380, immediate = true },
      },
      f:row {
        f:static_text { title = "App Secret:", width = 90, alignment = "right" },
        f:password_field { value = LrView.bind("app_secret"), width = 380, immediate = true },
      },
      f:row {
        f:static_text { title = "Username:", width = 90, alignment = "right" },
        f:edit_field { value = LrView.bind("username"), width = 380, immediate = true },
      },
      f:row {
        f:static_text { title = "Password:", width = 90, alignment = "right" },
        f:password_field { value = LrView.bind("user_pass"), width = 380, immediate = true },
      },
    }

    local result = LrDialogs.presentModalDialog {
      title      = "iNaturalist - Set Up Credentials",
      contents   = contents,
      actionVerb = "Save",
      otherVerb  = "Clear Stored Credentials",
    }

    if result == "other" then
      InatAuth.clear()
      LrDialogs.message("iNaturalist", "Stored credentials cleared.", "info")
      return
    end

    if result ~= "ok" then
      return
    end

    -- Saving touches the network, so it has to run in a task.
    LrTasks.startAsyncTask(function()
      local saved = false

      if props.app_id ~= "" and props.app_secret ~= ""
         and props.username ~= "" and props.user_pass ~= "" then
        InatAuth.storeOAuthApp(props.app_id, props.app_secret,
          props.username, props.user_pass)
        saved = true
      elseif props.api_token ~= "" then
        local ok, err = InatAuth.storeApiToken(props.api_token)
        if not ok then
          LrDialogs.message("iNaturalist", err or "Could not store that token.", "critical")
          return
        end
        saved = true
      end

      if not saved then
        LrDialogs.message("iNaturalist",
          "Nothing to save. Paste a token, or fill in all four application fields.",
          "warning")
        return
      end

      -- Verify immediately. Storing a token that does not work is worse than
      -- storing nothing, because the failure surfaces later during an export.
      local token, tokenErr = InatAuth.getToken(true)
      if not token then
        LrDialogs.message("iNaturalist",
          "Saved, but authentication failed:\n\n" .. tostring(tokenErr), "critical")
        return
      end

      local user, userErr = InatAuth.whoami(token)
      if not user then
        LrDialogs.message("iNaturalist",
          "Saved, but the token was rejected:\n\n" .. tostring(userErr), "critical")
        return
      end

      logger:info("Credentials verified for " .. tostring(user.login))
      LrDialogs.message("iNaturalist",
        "Connected as " .. tostring(user.login)
          .. " (" .. tostring(user.observations_count or 0) .. " observations).",
        "info")
    end)
  end)
end

showSetupDialog()

return PluginInit
