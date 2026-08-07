--[[
  ObservationPanel.lua
  --------------------
  A floating window that follows the filmstrip selection and shows what this
  plugin knows about the selected photo, with the actions that apply to it.

  Why a floating window rather than a docked panel: there is no docked surface
  a plugin can put a button in. The Metadata panel is docked and is genuinely
  ours, but LibraryToolkit.dll validates custom fields down to three data types
  -- verbatim, "should have been 'string', 'enum', or 'url'" -- so it can hold
  our data and never a control. The docking machinery in ui.dll
  (AgViewWinPanelHost::DockOrUndockPanel) has no plugin-facing manifest key.
  See docs/lightroom-sdk-notes.md for the full survey.

  So the division of labour is:

    Metadata panel   the fields, docked, always visible, no actions
    Publish service  publishing, in the left panel, no per-photo detail
    this window      both, at the cost of floating

  The mechanism, read out of the constant table of the window builder in
  ui.dll (the chunk carrying "is_non_modal_sdk_window"):

    presentFloatingDialog(_PLUGIN, {...})   contents, title, onShow, id,
                                            save_frame, blockTask
    selectionChangeObserver                 wired to addSelectionContentObserver
    sourceChangeObserver                    wired to addSourcesChangedObserver
    windowWillClose                         called on close

  save_frame persists position and size across sessions, which is what stops a
  floating window being a nuisance: it reopens where it was left.
--]]

local LrApplication     = import "LrApplication"
local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp            = import "LrHttp"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local logger = require "Log"

local ObservationPanel = {}

-- Identifies the window to Lightroom so save_frame has something to key its
-- stored position on, and so a second Show does not open a second window.
local WINDOW_ID = "com.github.inat-lightroom.observationPanel"

local OBSERVATION_URL = "https://www.inaturalist.org/observations/"

--------------------------------------------------------------------------------
-- Reading the selection
--------------------------------------------------------------------------------

--- Read a photo's plugin metadata field, treating "" as absent.
local function field(photo, id)
  local value = photo:getPropertyForPlugin(_PLUGIN, id)
  if value == "" then return nil end
  return value
end

--- Describe what a photo's relationship with iNaturalist currently is.
-- Split out from the view so it can be tested without a running Lightroom, and
-- so the wording lives in one place rather than being assembled inline.
function ObservationPanel.statusFor(photo)
  if not photo then
    return "No photo selected"
  end

  local obsId = field(photo, "inat_observation_id")
  if not obsId then
    return "Not uploaded yet"
  end

  local taxon  = field(photo, "inat_taxon_name")
  local common = field(photo, "inat_common_name")

  if not taxon then
    -- The normal state of an observation nobody has looked at yet, which is
    -- every one of them for a while after it is made. Saying "unknown" here
    -- would read as something having gone wrong.
    return "Observation " .. obsId .. " - not identified yet"
  end

  if common then
    return common .. " (" .. taxon .. ")"
  end
  return taxon
end

--- Gather everything the window displays for one photo.
-- Returns a flat table of strings, so applying it to the property table is a
-- loop rather than a dozen assignments that can drift out of step.
function ObservationPanel.valuesFor(photo, selectionCount)
  selectionCount = selectionCount or (photo and 1 or 0)

  local values = {
    status        = ObservationPanel.statusFor(photo),
    observationId = photo and field(photo, "inat_observation_id") or "",
    quality       = photo and field(photo, "inat_quality_grade") or "",
    lastSynced    = photo and field(photo, "inat_last_synced") or "",
    speciesGuess  = photo and field(photo, "inat_species_guess") or "",
    url           = photo and field(photo, "inat_observation_url") or "",
    hasPhoto      = photo ~= nil,
    hasObservation = photo ~= nil and field(photo, "inat_observation_id") ~= nil,
  }

  if selectionCount > 1 then
    -- Every field below the heading describes the first photo only. Saying so
    -- is better than letting someone edit a species guess believing it will
    -- land on all of them.
    values.selection = selectionCount .. " photos selected - showing the first"
  elseif selectionCount == 1 then
    values.selection = photo:getFormattedMetadata("fileName") or "1 photo selected"
  else
    values.selection = "Select a photo in the filmstrip"
  end

  return values
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

--- Copy the current selection's values onto the bound property table.
local function refresh(props)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos() or {}
  local photo   = photos[1]

  props.photo = photo

  for key, value in pairs(ObservationPanel.valuesFor(photo, #photos)) do
    props[key] = value
  end
end

--- Build the window contents.
-- Everything visible is bound rather than baked in, because the window outlives
-- any one selection: the observer refreshes the property table and the view
-- follows. Rebuilding the window instead would work, but reopening a floating
-- window steals focus on Windows, and doing that on every arrow-key press in
-- the filmstrip would make the plugin unusable.
function ObservationPanel.contents(f, props, actions)
  local LABEL = 96

  local function labelled(title, key)
    return f:row {
      f:static_text { title = title, width = LABEL, alignment = "right" },
      f:static_text {
        title         = LrView.bind(key),
        width         = 260,
        fill_horizontal = 1,
      },
    }
  end

  return f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),
    margin  = 12,

    f:static_text {
      title      = LrView.bind("selection"),
      font       = "<system/bold>",
      fill_horizontal = 1,
    },

    f:static_text {
      title           = LrView.bind("status"),
      fill_horizontal = 1,
      height_in_lines = 1,
    },

    f:separator { fill_horizontal = 1 },

    labelled("Observation:", "observationId"),
    labelled("Quality:", "quality"),
    labelled("Last synced:", "lastSynced"),

    f:separator { fill_horizontal = 1 },

    -- The one editable thing here. It is what a later publish uploads, so it
    -- belongs next to the buttons that publish rather than only in the
    -- Metadata panel.
    f:row {
      f:static_text { title = "Species guess:", width = LABEL, alignment = "right" },
      f:edit_field {
        value           = LrView.bind("speciesGuess"),
        fill_horizontal = 1,
        immediate       = false,
        enabled         = LrView.bind("hasPhoto"),
        placeholder_string = "What is it?",
      },
      f:push_button {
        title   = "Save",
        enabled = LrView.bind("hasPhoto"),
        action  = actions.saveSpeciesGuess,
      },
    },

    f:separator { fill_horizontal = 1 },

    f:row {
      spacing = f:control_spacing(),
      f:push_button {
        title   = "Sync",
        enabled = LrView.bind("hasPhoto"),
        action  = actions.sync,
      },
      f:push_button {
        title  = "Link to Observation…",
        enabled = LrView.bind("hasPhoto"),
        action = actions.link,
      },
      f:push_button {
        title   = "View on iNaturalist",
        enabled = LrView.bind("hasObservation"),
        action  = actions.view,
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Write the edited species guess onto every selected photo.
-- Unlike the display, this deliberately applies to the whole selection: typing
-- one name and having it land on the six frames of the same animal is the
-- common case, and the heading says how many are selected.
function ObservationPanel.saveSpeciesGuess(props)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos() or {}

  if #photos == 0 then
    return 0
  end

  local guess = props.speciesGuess or ""

  catalog:withWriteAccessDo("iNat species guess", function()
    for _, photo in ipairs(photos) do
      photo:setPropertyForPlugin(_PLUGIN, "inat_species_guess", guess)
    end
  end)

  logger:info("Species guess set on " .. #photos .. " photo(s): " .. guess)
  return #photos
end

--------------------------------------------------------------------------------
-- Showing it
--------------------------------------------------------------------------------

--- Open the panel, or bring it to the front if it is already open.
function ObservationPanel.show()
  LrFunctionContext.postAsyncTaskWithContext("inat_observation_panel",
    function(context)
      local f     = LrView.osFactory()
      local props = LrBinding.makePropertyTable(context)

      refresh(props)

      local actions = {
        saveSpeciesGuess = function()
          LrTasks.startAsyncTask(function()
            ObservationPanel.saveSpeciesGuess(props)
          end)
        end,

        sync = function()
          -- Its own task with its own context: the sync outlives the click,
          -- and its progress scope must not be tied to a context that ends
          -- when this window closes.
          LrFunctionContext.postAsyncTaskWithContext("inat_panel_sync",
            function(syncContext)
              local SyncCore = require "SyncCore"
              SyncCore.syncTargetPhotos(syncContext)
              refresh(props)
            end)
        end,

        link = function()
          LrFunctionContext.postAsyncTaskWithContext("inat_panel_link",
            function(linkContext)
              require("LinkObservation").run(linkContext)
              refresh(props)
            end)
        end,

        view = function()
          local id = props.observationId
          if id and id ~= "" then
            LrHttp.openUrlInBrowser(OBSERVATION_URL .. id)
          end
        end,
      }

      LrDialogs.presentFloatingDialog(_PLUGIN, {
        title    = "iNaturalist",
        contents = ObservationPanel.contents(f, props, actions),

        -- Keyed so save_frame has something to store a position against, and
        -- so this is the same window every time rather than a new one.
        id         = WINDOW_ID,
        save_frame = WINDOW_ID,

        -- The point of the whole thing: follow the filmstrip.
        selectionChangeObserver = function()
          refresh(props)
        end,

        -- Changing folder or collection changes the selection too, and
        -- without this the window would keep describing a photo that is no
        -- longer on screen.
        sourceChangeObserver = function()
          refresh(props)
        end,

        -- Holds this task open for as long as the window is up, which is what
        -- keeps the function context -- and therefore the property table the
        -- window is bound to -- alive. Without it the context ends the moment
        -- show() returns and the bindings are pointing at a dead object.
        blockTask = true,
      })
    end)
end

return ObservationPanel
