--[[
  InatMenu.lua
  ------------
  The plugin's single entry in Library > Plug-in Extras.

  There used to be two items, and there is pressure to have none: a menu is a
  poor place for this. But Lightroom gives a plugin no panel of its own, so
  something has to remain reachable when the Metadata panel is not enough --
  in particular, arming photos with the panel action links in the first place,
  which is a chicken-and-egg problem the panel cannot solve for itself.

  One item, one dialog, and everything else moves into the Metadata panel.

  Like every menu-item script this file runs top to bottom on click; nothing
  should require it.
--]]

local LrApplication     = import "LrApplication"
local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrView            = import "LrView"

local CredentialsDialog = require "CredentialsDialog"
local PanelActions      = require "PanelActions"
local SyncCore          = require "SyncCore"
local logger            = require "Log"

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Write the action links onto the selection so the panel rows appear.
-- Metadata fields have no default value, so a field is blank until something
-- writes to it. Syncing and exporting both arm photos on the way past; this is
-- for photos that have never been touched.
local function armSelection()
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos()

  if not photos or #photos == 0 then
    LrDialogs.message("iNaturalist", "No photos selected.", "warning")
    return
  end

  local count = PanelActions.armPhotos(catalog, photos)
  logger:info("Armed " .. count .. " photo(s) with panel actions")

  LrDialogs.message("iNaturalist",
    "Added iNaturalist actions to " .. count .. " photo(s).\n\n"
      .. "Open the Metadata panel and choose the \"iNaturalist\" preset from "
      .. "the dropdown at its top left.",
    "info")
end

--------------------------------------------------------------------------------
-- Hub dialog
--------------------------------------------------------------------------------

LrFunctionContext.postAsyncTaskWithContext("inat_menu", function(context)
  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  props.choice = "sync"

  local contents = f:column {
    bind_to_object = props,
    spacing = f:label_spacing(),
    width = 420,

    f:static_text {
      title = "iNaturalist data lives in the Metadata panel. Choose the "
        .. "\"iNaturalist\" preset from the dropdown at the top of that panel.",
      width = 400,
      height_in_lines = 2,
    },
    f:separator { fill_horizontal = 1 },
    f:spacer { height = 6 },

    f:radio_button {
      title = "Sync selected photos from iNaturalist",
      value = LrView.bind("choice"),
      checked_value = "sync",
    },
    f:radio_button {
      title = "Add iNaturalist actions to selected photos",
      value = LrView.bind("choice"),
      checked_value = "arm",
    },
    f:radio_button {
      title = "Set up credentials…",
      value = LrView.bind("choice"),
      checked_value = "setup",
    },
  }

  local result = LrDialogs.presentModalDialog {
    title      = "iNaturalist",
    contents   = contents,
    actionVerb = "Continue",
  }

  if result ~= "ok" then
    return
  end

  if props.choice == "sync" then
    SyncCore.syncTargetPhotos(context)
  elseif props.choice == "arm" then
    armSelection()
  elseif props.choice == "setup" then
    CredentialsDialog.show()
  end
end)
