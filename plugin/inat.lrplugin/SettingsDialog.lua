--[[
  SettingsDialog.lua
  ------------------
  Everything about this plugin that is not about one photo.

  This was CredentialsDialog, and credentials are still the first thing in it.
  It grew because the publish service was removed and its settings had nowhere
  to go: geoprivacy, whether to send location, and the render options that used
  to be the Export dialog's Metadata and Watermarking sections.

  Three tabs, because they are answerable at different times and by different
  people:

    Account       once per machine, then forgotten
    Observations  what an observation says
    Image         what the uploaded file contains

  Modal on purpose. Unlike the observation panel there is nothing here to keep
  watching while you work, and a modal is what makes "Save" mean something.
--]]

local LrApplication     = import "LrApplication"
local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp            = import "LrHttp"
local LrProgressScope   = import "LrProgressScope"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local InatAuth = require "InatAuth"
local Jobs     = require "Jobs"
local Settings = require "Settings"
local logger   = require "Log"

local TOKEN_URL = "https://www.inaturalist.org/users/api_token"

local SettingsDialog = {}

--------------------------------------------------------------------------------
-- Choices
--------------------------------------------------------------------------------

--- What iNaturalist will do with the observation's coordinates.
SettingsDialog.GEOPRIVACY_ITEMS = {
  { title = "Open - anyone can see where it was",       value = "open" },
  { title = "Obscured - shown as a rough area",         value = "obscured" },
  { title = "Private - location visible only to you",   value = "private" },
}

--- How much of the photo's own metadata travels with the JPEG.
--
-- These five values are Lightroom's, read out of Export.lrmodule rather than
-- guessed; the Export dialog's Metadata popup offers exactly this list.
SettingsDialog.METADATA_ITEMS = {
  { title = "All metadata",                        value = "all" },
  { title = "All except camera & Camera Raw info", value = "allExceptCameraInfo" },
  { title = "All except Camera Raw info",          value = "allExceptCameraRawInfo" },
  { title = "Copyright & contact info only",       value = "copyrightAndContactOnly" },
  { title = "Copyright only",                      value = "copyrightOnly" },
}

--------------------------------------------------------------------------------
-- Account tab
--------------------------------------------------------------------------------

--- Describe the freshness of the stored token in plain language.
local function tokenStatusText()
  local remaining = InatAuth.tokenSecondsRemaining()
  if not remaining then
    return "No token stored yet."
  end

  if remaining <= 0 then
    return "The stored token has expired. Paste a new one."
  end

  local hours = math.floor(remaining / 3600)
  if hours < 1 then
    return "The stored token expires in less than an hour."
  end
  return "The stored token is valid for about " .. hours .. " more hour(s)."
end

SettingsDialog.tokenStatusText = tokenStatusText

local function accountTab(f, props)
  local LABEL = 90

  return f:tab_view_item {
    title      = "Account",
    identifier = "account",

    f:column {
      spacing = f:label_spacing(),
      margin  = 10,

      f:static_text {
        title           = LrView.bind("status"),
        width           = 500,
        height_in_lines = 2,
      },

      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      f:static_text { title = "Option 1: Paste an API token", font = "<system/bold>" },
      f:static_text {
        title = "Sign in to iNaturalist, open the token page, and paste the "
          .. "result below.\nThis works without registering an application, "
          .. "but expires after 24 hours.",
        width           = 500,
        height_in_lines = 2,
      },
      f:push_button {
        title  = "Open Token Page",
        action = function() LrHttp.openUrlInBrowser(TOKEN_URL) end,
      },
      f:row {
        f:static_text { title = "Token:", width = LABEL, alignment = "right" },
        f:password_field { value = LrView.bind("api_token"), width = 380, immediate = true },
      },

      f:spacer { height = 10 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      -- No fields here on purpose. This offered an OAuth application using the
      -- password grant: app id, app secret, iNaturalist username and password.
      -- It worked, which is what made it worth removing rather than leaving --
      -- iNaturalist recommends against the password grant, and against it
      -- particularly in distributed applications, because it means typing an
      -- account password into someone else's software. Sign-in in the browser
      -- is the replacement, and a field that cannot be filled in wrongly is
      -- better than one that can.
      f:static_text { title = "Option 2: Sign in with iNaturalist", font = "<system/bold>" },
      f:static_text {
        title = "Coming soon. This will hand you to iNaturalist to sign in, "
          .. "then keep\nitself topped up so you are never asked again. Your "
          .. "password stays with\niNaturalist -- the plugin never sees it.",
        width           = 500,
        height_in_lines = 3,
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Observations tab
--------------------------------------------------------------------------------

local function observationsTab(f, props, actions)
  local LABEL = 110

  return f:tab_view_item {
    title      = "Observations",
    identifier = "observations",

    f:column {
      spacing = f:label_spacing(),
      margin  = 10,

      f:static_text { title = "What new observations say", font = "<system/bold>" },

      f:row {
        f:static_text { title = "Location:", width = LABEL, alignment = "right" },
        f:popup_menu {
          value = LrView.bind("inat_geoprivacy"),
          items = SettingsDialog.GEOPRIVACY_ITEMS,
          width = 320,
        },
      },

      f:row {
        f:static_text { title = "", width = LABEL },
        f:checkbox {
          title = "Send the photo's GPS coordinates",
          value = LrView.bind("inat_upload_location"),
        },
      },
      f:static_text {
        title = "An observation with no location is close to useless as a record.\n"
          .. "Use Obscured rather than turning this off: iNaturalist then hides\n"
          .. "the exact spot but still counts the sighting.",
        width           = 500,
        height_in_lines = 3,
      },

      f:spacer { height = 8 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      f:row {
        f:static_text { title = "Project ID:", width = LABEL, alignment = "right" },
        f:edit_field {
          value              = LrView.bind("inat_project_id"),
          width              = 120,
          immediate          = true,
          placeholder_string = "optional",
        },
      },

      f:row {
        f:static_text { title = "", width = LABEL },
        f:checkbox {
          title = "Sync taxa back from iNaturalist after uploading",
          value = LrView.bind("inat_sync_after_upload"),
        },
      },

      f:spacer { height = 10 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      f:static_text { title = "Everything already linked", font = "<system/bold>" },
      f:static_text {
        title = "Fetches the current identification for every photo in this\n"
          .. "catalog that has an observation ID, and updates its keywords.",
        width           = 500,
        height_in_lines = 2,
      },
      f:push_button {
        title   = "Sync All Linked Photos",
        action  = actions.syncAll,
        enabled = LrView.bind("idle"),
      },

      f:spacer { height = 10 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      f:static_text { title = "Observations not linked", font = "<system/bold>" },
      f:static_text {
        title = "Looks through your iNaturalist observations for ones where the\n"
          .. "matching photo in your catalog does not have the linked\n"
          .. "iNaturalist metadata. You choose what gets linked before\n"
          .. "anything is written.",
        width           = 500,
        height_in_lines = 4,
      },
      f:push_button {
        title   = "Find Unlinked Observations…",
        action  = actions.reverseSync,
        enabled = LrView.bind("idle"),
      },
      f:static_text {
        title   = LrView.bind("busyLabel"),
        width   = 500,
        visible = LrView.bind { key = "idle", transform = function(idle)
          return not idle
        end },
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Image tab
--------------------------------------------------------------------------------

local function imageTab(f, props)
  local LABEL = 110

  return f:tab_view_item {
    title      = "Image",
    identifier = "image",

    f:column {
      spacing = f:label_spacing(),
      margin  = 10,

      f:static_text {
        title = "Uploads are always JPEG, sRGB, 2048 px on the long edge --\n"
          .. "which is the largest size iNaturalist displays.",
        width           = 500,
        height_in_lines = 2,
      },

      f:spacer { height = 8 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      f:row {
        f:static_text { title = "Metadata:", width = LABEL, alignment = "right" },
        f:popup_menu {
          value = LrView.bind("render_metadata_option"),
          items = SettingsDialog.METADATA_ITEMS,
          width = 320,
        },
      },

      f:row {
        f:static_text { title = "", width = LABEL },
        f:checkbox {
          title = "Remove location info from the uploaded file",
          value = LrView.bind("render_remove_location"),
        },
      },
      f:static_text {
        title = "This strips GPS from the JPEG only. The observation's own\n"
          .. "location is set on the Observations tab and is unaffected.",
        width           = 500,
        height_in_lines = 2,
      },

      f:row {
        f:static_text { title = "", width = LABEL },
        f:checkbox {
          title = "Remove person info",
          value = LrView.bind("render_remove_face"),
        },
      },

      f:spacer { height = 8 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      f:row {
        f:static_text { title = "", width = LABEL },
        f:checkbox {
          title = "Add a simple copyright watermark",
          value = LrView.bind("render_use_watermark"),
        },
      },
      f:static_text {
        title = "Lightroom's named watermark presets cannot be listed by a\n"
          .. "plugin, so this is the built-in copyright watermark only.",
        width           = 500,
        height_in_lines = 2,
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------

--- Copy the editable preferences off the property table into storage.
-- Kept apart from the dialog so it can be tested without one.
function SettingsDialog.savePreferences(props)
  for key in pairs(Settings.DEFAULTS) do
    local value = props[key]
    if value ~= nil then
      Settings.set(key, value)
    end
  end
end

--- Store the pasted token, if one was given.
-- @return "token", or nil plus a message when nothing usable was given
function SettingsDialog.saveCredentials(props)
  if props.api_token ~= "" then
    local ok, err = InatAuth.storeApiToken(props.api_token)
    if not ok then
      return nil, err or "Could not store that token."
    end
    return "token", nil
  end

  return nil, nil
end

--------------------------------------------------------------------------------
-- Sync All
--------------------------------------------------------------------------------

--- Every photo in the catalog that has ever been linked to an observation.
--
-- findPhotosWithProperty is the right primitive and the only one that does not
-- mean walking the whole catalog: it asks the catalog's own index for photos
-- carrying a value for one plugin field.
--
-- It returns photos that have a value at all, and "" counts -- an unlinked
-- photo keeps an empty string rather than losing the field -- so the result is
-- filtered rather than trusted.
function SettingsDialog.linkedPhotos(catalog)
  local candidates = catalog:findPhotosWithProperty(
    _PLUGIN.id, "inat_observation_id") or {}

  local linked = {}
  for _, photo in ipairs(candidates) do
    local id = photo:getPropertyForPlugin(_PLUGIN, "inat_observation_id")
    if id and id ~= "" then
      linked[#linked + 1] = photo
    end
  end

  return linked
end

--- Sync every linked photo in the catalog.
function SettingsDialog.syncAll(context)
  local catalog = LrApplication.activeCatalog()
  local photos  = SettingsDialog.linkedPhotos(catalog)

  if #photos == 0 then
    LrDialogs.message("iNaturalist Sync",
      "No photos in this catalog are linked to an observation yet.", "info")
    return 0
  end

  logger:info("Sync All: " .. #photos .. " linked photo(s)")
  require("SyncCore").syncPhotos(context, photos,
    { label = "Syncing all linked photos" })
  return #photos
end

--- Find observations whose photo is in the catalog but not linked to them.
--
-- Two phases with different shapes: fetching is bounded by iNaturalist's page
-- size and the network, matching by the number of observations. Both report
-- through one progress scope so the user sees continuous movement rather than
-- a bar that fills, resets, and fills again.
function SettingsDialog.reverseSync(context)
  return Jobs.runOrReport("Finding unlinked observations", function()
    SettingsDialog.reverseSyncNow(context)
  end)
end

--- The reverse sync itself, without the lock.
function SettingsDialog.reverseSyncNow(context)
  local UploadCore  = require "UploadCore"
  local ReverseSync = require "ReverseSync"

  local api, err = UploadCore.requireAPI()
  if not api then
    InatAuth.reportMissingCredentials(err)
    return
  end

  local progress = LrProgressScope {
    title           = "iNaturalist Reverse Sync",
    caption         = "Fetching your observations…",
    functionContext = context,
  }
  progress:setCancelable(true)

  local matches, summary = ReverseSync.prepare(api, {
    shouldStop = function() return progress:isCanceled() end,

    onFetch = function(fetched, total)
      -- The total is unknown until the first page comes back, and a bar that
      -- sits at zero looks identical to one that has hung.
      progress:setCaption(string.format("Fetched %d of %d observations…",
        fetched, total or fetched))
      if total and total > 0 then
        progress:setPortionComplete(fetched, total * 2)
      end
    end,

    onProgress = function(done, total)
      progress:setCaption(string.format("Checking observation %d of %d…",
        done, total))
      progress:setPortionComplete(total + done, total * 2)
    end,
  })

  progress:done()

  if not matches then
    LrDialogs.message("iNaturalist Reverse Sync",
      "Could not fetch your observations: " .. tostring(summary), "warning")
    return
  end
  if summary.stopped and #matches == 0 then return end

  local reviewed = require("ReverseSyncDialog").show(context, matches, summary)
  if not reviewed then return end

  -- A second scope: the review dialog sits between the two phases for as long
  -- as the user takes over it, and a progress bar left up behind a modal looks
  -- like work still happening.
  local linking = LrProgressScope {
    title           = "iNaturalist Reverse Sync",
    caption         = "Linking…",
    functionContext = context,
  }

  local linked, failures = ReverseSync.apply(LrApplication.activeCatalog(),
    reviewed, {
      -- Passing the API is what turns a link into a sync: keywords, quality
      -- grade and location get written in the same transaction, so a photo is
      -- never left linked to an observation it knows nothing else about.
      api = api,
      onProgress = function(done, total)
        linking:setCaption(string.format("Linked %d of %d…", done, total))
        linking:setPortionComplete(done, total)
      end,
    })

  linking:done()

  local message = string.format(
    "Linked %d photo(s) to observations, with their keywords and location.",
    linked)
  if #failures > 0 then
    message = message .. string.format("\n%d could not be linked.", #failures)
  end
  LrDialogs.message("iNaturalist Reverse Sync", message, "info")
end

--------------------------------------------------------------------------------
-- Showing it
--------------------------------------------------------------------------------

--- Open the settings dialog. Modal, so it blocks until dismissed.
--- Build the tab views.
--
-- Exposed so their identifiers can be checked without opening a modal dialog.
-- ui.dll raises "Multiple tab_view_item views with the same identifier" and
-- "tab_view_item needs to have a string or number identifier" -- both are
-- runtime errors that surface only when the dialog is opened, at which point
-- the settings window simply does not appear.
function SettingsDialog.tabs(f, props, actions)
  return {
    accountTab(f, props),
    observationsTab(f, props, actions),
    imageTab(f, props),
  }
end

function SettingsDialog.show()
  LrFunctionContext.callWithContext("inat_settings", function(context)
    local f     = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)

    props.api_token  = ""
    props.status     = tokenStatusText()

    for key, value in pairs(Settings.all()) do
      props[key] = value
    end

    -- Follows the lock rather than the buttons, so the dialog is right about
    -- what is running even when it was not the one that started it: opened
    -- during a sync launched from the menu, the buttons come up already greyed.
    --
    -- The property table dies with this dialog while the job carries on, so
    -- the update is guarded. It is a plain field write, which cannot yield, so
    -- an ordinary pcall is the right one here.
    Jobs.watch(props, function(running)
      pcall(function()
        props.idle      = (running == nil)
        props.busyLabel = running and (tostring(running) .. "…") or ""
      end)
    end)

    local actions = {
      syncAll = function()
        -- Its own task and its own context: the sync outlives this dialog, and
        -- its progress scope must not be tied to a context that ends when the
        -- dialog is dismissed.
        LrFunctionContext.postAsyncTaskWithContext("inat_sync_all",
          function(syncContext)
            SettingsDialog.syncAll(syncContext)
          end)
      end,

      reverseSync = function()
        -- Same reasoning as syncAll: this outlives the settings dialog, and
        -- its progress scope must not be tied to a context that ends when the
        -- dialog is dismissed. It also opens a dialog of its own, which cannot
        -- be done from inside this one's action.
        LrFunctionContext.postAsyncTaskWithContext("inat_reverse_sync",
          function(syncContext)
            SettingsDialog.reverseSync(syncContext)
          end)
      end,
    }

    local contents = f:column {
      bind_to_object = props,
      width = 540,

      f:tab_view {
        unpack(SettingsDialog.tabs(f, props, actions)),
      },
    }

    local result = LrDialogs.presentModalDialog {
      title      = "Pinned Settings",
      contents   = contents,
      actionVerb = "Save",
      otherVerb  = "Clear Stored Credentials",
    }

    if result == "other" then
      InatAuth.clear()
      LrDialogs.message("Pinned", "Stored credentials cleared.", "info")
      return
    end

    if result ~= "ok" then
      return
    end

    -- Preferences are saved whether or not credentials were touched. Someone
    -- opening this to change geoprivacy has no reason to retype a token, and
    -- making them would be a good way to end up with neither saved.
    SettingsDialog.savePreferences(props)

    -- Verifying credentials touches the network, so it has to run in a task.
    LrTasks.startAsyncTask(function()
      local stored, storeErr = SettingsDialog.saveCredentials(props)

      if storeErr then
        LrDialogs.message("Pinned", storeErr, "critical")
        return
      end

      if not stored then
        -- Not a failure. The settings above were saved; there was simply
        -- nothing in the credential fields, which is the normal case for
        -- anyone who set them up last week.
        return
      end

      -- Verify immediately. Storing a token that does not work is worse than
      -- storing nothing, because the failure surfaces later during an upload.
      local token, tokenErr = InatAuth.getToken(true)
      if not token then
        LrDialogs.message("Pinned",
          "Saved, but authentication failed:\n\n" .. tostring(tokenErr), "critical")
        return
      end

      local user, userErr = InatAuth.whoami(token)
      if not user then
        LrDialogs.message("Pinned",
          "Saved, but the token was rejected:\n\n" .. tostring(userErr), "critical")
        return
      end

      logger:info("Credentials verified for " .. tostring(user.login))
      LrDialogs.message("Pinned",
        "Connected as " .. tostring(user.login)
          .. " (" .. tostring(user.observations_count or 0) .. " observations).",
        "info")
    end)
  end)
end

return SettingsDialog
