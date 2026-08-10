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
local LrApplicationView = import "LrApplicationView"
local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp            = import "LrHttp"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local PanelCore  = require "PanelCore"
local Settings   = require "Settings"
local UploadCore = require "UploadCore"
local logger     = require "Log"

local ObservationPanel = {}

-- Identifies the window to Lightroom so save_frame has something to key its
-- stored position on, and so a second Show does not open a second window.
local WINDOW_ID = "com.github.inat-lightroom.observationPanel"

local OBSERVATION_URL = "https://www.inaturalist.org/observations/"

-- Both the window's caption and the handle the z-order fix-up finds it by, so
-- they cannot drift apart.
local WINDOW_TITLE = "iNaturalist"

-- The two captions the one action button alternates between.
ObservationPanel.UPLOAD_TITLE = "Upload to iNaturalist"
ObservationPanel.UPDATE_TITLE = "Update species guess"

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

  local linked = photo ~= nil and field(photo, "inat_observation_id") ~= nil

  local values = {
    status        = ObservationPanel.statusFor(photo),
    observationId = photo and field(photo, "inat_observation_id") or "",
    quality       = photo and field(photo, "inat_quality_grade") or "",
    lastSynced    = photo and field(photo, "inat_last_synced") or "",
    speciesGuess  = photo and field(photo, "inat_species_guess") or "",
    url           = photo and field(photo, "inat_observation_url") or "",
    hasPhoto      = photo ~= nil,
    hasObservation = linked,

    location      = PanelCore.describeLocation(photo),
    hasLocation   = photo ~= nil
                    and select(1, UploadCore.locationOf(photo)) ~= nil,

    -- The action button's caption. Uploading and correcting an identification
    -- are the same intent at different points in a photo's life, so they share
    -- a button and it says which one it is about to do.
    uploadTitle   = linked and ObservationPanel.UPDATE_TITLE
                           or ObservationPanel.UPLOAD_TITLE,
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
--
-- The catalog reads happen on a task because they have to. Lightroom calls the
-- window's observers outside any task, and reading plugin metadata yields --
-- doing it inline fails with "We can only wait from within a task" (and, when
-- the observer is reached through a metamethod, "Yielding is not allowed within
-- a C or metamethod call"). Both were swallowed silently, which is why the
-- panel appeared to ignore the filmstrip: the observers were firing perfectly
-- and every refresh was dying halfway through.
--
-- Each call gets a generation number and only the newest one is allowed to
-- write. Arrow-keying down the filmstrip fires the observer faster than the
-- reads complete, and Lightroom emits transient selections on the way (a folder
-- change reports the whole folder selected before settling on one photo), so
-- without this the panel can land on a stale value and stay there.
local function makeRefresh(props)
  local generation = 0

  return function()
    generation = generation + 1
    local mine = generation

    LrTasks.startAsyncTask(function()
      local catalog = LrApplication.activeCatalog()
      local photos  = catalog:getTargetPhotos() or {}
      local photo   = photos[1]
      local values  = ObservationPanel.valuesFor(photo, #photos)

      -- Read before the check, applied after: a newer refresh started while
      -- this one was reading, so what it read is already out of date.
      if mine ~= generation then return end

      props.photo = photo
      for key, value in pairs(values) do
        props[key] = value
      end

      -- Suggestions belong to the photo they were asked about. Leaving them on
      -- screen after the selection moves is worse than showing nothing: the
      -- list would still be clickable, and clicking it would put the previous
      -- photo's species onto this one.
      props.suggestions       = {}
      props.suggestionItems   = {}
      props.selectedSuggestion = nil
      props.suggestionTaxonId = nil
      props.suggestionStatus  = ""
    end)
  end
end

--- The control that shows the suggestions.
--
-- Isolated because f:simple_list is undocumented. It is real -- ui.dll's
-- view-constructor list has it beside popup_menu, and its implementation there
-- wraps a table_view in a scroll_view -- and it renders correctly in the host,
-- but if it ever turns out not to, swapping the constructor here for
-- f:popup_menu is the whole fix: the items are the SDK's usual
-- { title = ..., value = ... } shape either way.
--
-- Its `value` is bound to the table_view's selected_indexes, so what comes back
-- is a list rather than a row number. PanelCore.selectedIndex deals with that.
function ObservationPanel.suggestionsView(f)
  return f:simple_list {
    items           = LrView.bind("suggestionItems"),
    value           = LrView.bind("selectedSuggestion"),
    fill_horizontal = 1,
    height          = 110,
    enabled         = LrView.bind("hasPhoto"),
  }
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

    -- Location gets a row of its own rather than sitting with the others,
    -- because it is the one field here the user can still do something about,
    -- and the one whose absence quietly costs them the observation.
    f:row {
      f:static_text { title = "Location:", width = LABEL, alignment = "right" },
      f:static_text {
        title           = LrView.bind("location"),
        fill_horizontal = 1,
      },
      f:push_button {
        title   = "Set on Map",
        enabled = LrView.bind("hasPhoto"),
        action  = actions.openMap,
      },
    },

    f:separator { fill_horizontal = 1 },

    -- The identification half of the window. There is no Save button any more:
    -- a guess saved to the catalog and never sent anywhere was the thing that
    -- looked like it worked and did not. Everything here ends at one of the two
    -- buttons below, which both talk to iNaturalist.
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
        title   = "Get Suggestions",
        enabled = LrView.bind("hasPhoto"),
        action  = actions.getSuggestions,
      },
    },

    ObservationPanel.suggestionsView(f),

    f:static_text {
      title           = LrView.bind("suggestionStatus"),
      fill_horizontal = 1,
      height_in_lines = 1,
    },

    -- One button, two jobs, because they are the same intent at different
    -- points in a photo's life: tell iNaturalist what this is. Which one it is
    -- depends only on whether the photo is linked yet, so making the user
    -- choose between two buttons would be asking them a question the plugin
    -- already knows the answer to.
    f:row {
      f:push_button {
        title   = LrView.bind("uploadTitle"),
        enabled = LrView.bind("hasPhoto"),
        action  = actions.uploadOrUpdate,
        width   = 180,
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
      f:push_button {
        title   = "Unlink",
        enabled = LrView.bind("hasObservation"),
        action  = actions.unlink,
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Ask iNaturalist what the selected photo might be, and fill the list.
--
-- MUST be called from inside a task.
--
-- Everything it reports goes to props.suggestionStatus rather than a modal.
-- Suggestions are a thing you ask for repeatedly while making up your mind, and
-- a dialog to dismiss after every one would make that unbearable.
function ObservationPanel.loadSuggestions(props)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos() or {}

  if #photos == 0 then
    props.suggestionStatus = "Select a photo first."
    return
  end

  props.suggestionStatus = "Asking iNaturalist…"

  local api, authErr = UploadCore.requireAPI()
  if not api then
    props.suggestionStatus = authErr
    return
  end

  local rows, err = PanelCore.getSuggestions(api, photos[1])
  if not rows then
    props.suggestionStatus = err or "Could not get suggestions."
    return
  end

  props.suggestions        = rows
  props.suggestionItems    = PanelCore.suggestionItems(rows)
  props.selectedSuggestion = nil
  props.suggestionTaxonId  = nil

  if #rows == 0 then
    props.suggestionStatus = "iNaturalist had no suggestions for this photo."
  else
    props.suggestionStatus = "Pick one to use it as the species guess."
  end
end

--- Copy a chosen suggestion into the species guess.
--
-- The scientific name goes into the field, not the common name: it is
-- unambiguous, and it is what gets uploaded when there is no taxon to point at.
-- The taxon id is remembered separately, and it is the more important half --
-- it is what turns the next button press into a real identification rather than
-- free text iNaturalist will ignore.
function ObservationPanel.chooseSuggestion(props, selection)
  local rows  = props.suggestions or {}
  local index = PanelCore.selectedIndex(selection)
  local row   = index and rows[index]

  if not row then
    props.suggestionTaxonId = nil
    return nil
  end

  props.speciesGuess      = row.name or row.common_name or ""
  props.suggestionTaxonId = row.taxon_id

  return row
end

--- Hand the user over to Lightroom's Map module to set a location.
--
-- Deliberately not a GPS control of our own. A plugin cannot draw a map --
-- LrView has no canvas and no mouse coordinates -- so the best we could build
-- is two number fields, against a module that already has place search,
-- draggable pins, reverse geocoding, tracklogs and saved locations, and that
-- writes the GPS itself. Sending people there is not a compromise; it is the
-- better tool.
--
-- "map" is the module's public name, checked in Lightroom.exe's module table
-- where it maps to com.adobe.ag.location, rather than guessed from the UI.
--
-- Wrapped because this is the first time the plugin has called
-- LrApplicationView at all, and a button that silently does nothing is the
-- worst outcome -- especially this button, whose whole job is to be the way out
-- of a problem the panel just pointed at.
function ObservationPanel.openMap()
  local ok, err = pcall(function()
    LrApplicationView.switchToModule("map")
  end)

  if not ok then
    logger:warn("could not switch to the Map module: " .. tostring(err))
    LrDialogs.message("iNaturalist",
      "Could not open the Map module. You can reach it from the module picker "
      .. "at the top right of the Lightroom window.", "info")
  end
end

--- Upload the selection, or correct the identification of what is already up.
--
-- MUST be called from inside a task.
function ObservationPanel.uploadOrUpdate(props)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos() or {}

  if #photos == 0 then
    LrDialogs.message("iNaturalist", "Select at least one photo first.", "warning")
    return
  end

  local api, authErr = UploadCore.requireAPI()
  if not api then
    LrDialogs.message("iNaturalist", authErr, "critical")
    return
  end

  local settings = Settings.all()
  local guess    = props.speciesGuess or ""
  local taxonId  = props.suggestionTaxonId

  -- Which of the two jobs this is depends on the photo, not on the button: the
  -- caption is only a description of what is about to happen.
  if UploadCore.pluginField(photos[1], "inat_observation_id") then
    props.suggestionStatus = "Updating the identification…"

    local ok, err = PanelCore.updateSpeciesGuess(catalog, api, photos, guess, taxonId)
    if not ok then
      LrDialogs.message("iNaturalist", err or "Could not update the observation.", "critical")
      props.suggestionStatus = ""
      return
    end

    props.suggestionStatus = taxonId and "Identification posted."
                                     or "Species guess sent."
    return
  end

  -- Asked only on the way to a new observation. An update cannot add
  -- coordinates, so raising it there would be a warning with nothing behind it.
  local warning = PanelCore.locationWarning(settings, photos)
  if warning then
    local answer = LrDialogs.confirm("Upload without a location?", warning,
      "Upload Anyway", "Cancel")
    if answer ~= "ok" then
      props.suggestionStatus = ""
      return
    end
  end

  props.suggestionStatus = "Uploading…"

  local observationId, _, errors = PanelCore.upload(catalog, api, settings, photos, {
    sleep   = LrTasks.sleep,
    onEvent = function(message) props.suggestionStatus = message end,
  })

  if not observationId then
    LrDialogs.message("iNaturalist Upload",
      errors[1] or "The upload failed.", "critical")
    props.suggestionStatus = ""
    return
  end

  -- A taxon chosen before the upload could not be sent with it: an
  -- identification needs an observation to attach to, and there was not one
  -- until a moment ago. So it is posted now, as a second step.
  if taxonId then
    local ok, err = PanelCore.updateSpeciesGuess(catalog, api, photos, guess, taxonId)
    if not ok then
      errors[#errors + 1] = err
    end
  end

  if #errors > 0 then
    LrDialogs.message("iNaturalist Upload",
      "Uploaded as observation " .. tostring(observationId)
      .. ", but some things did not work:\n\n" .. table.concat(errors, "\n"),
      "warning")
  end

  props.suggestionStatus = "Uploaded as observation " .. tostring(observationId) .. "."
end

--- Forget the link between the selected photos and their observation.
--
-- MUST be called from inside a task.
--
-- Confirmed first, because the button is next to three that are harmless and
-- this one is not obviously reversible: relinking means finding the observation
-- ID again by hand. The dialog says what it will and will not touch, since the
-- word "unlink" does not make clear that nothing on iNaturalist is deleted.
function ObservationPanel.unlink(props)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos() or {}

  if #photos == 0 then return 0 end

  local answer = LrDialogs.confirm(
    "Unlink from iNaturalist?",
    "This forgets the observation link on " .. #photos .. " photo(s).\n\n"
    .. "Nothing on iNaturalist is changed or deleted, and the taxonomy "
    .. "keywords already applied are kept.",
    "Unlink", "Cancel")

  if answer ~= "ok" then return 0 end

  return PanelCore.unlink(catalog, photos)
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
      local refresh = makeRefresh(props)

      props.suggestions      = {}
      props.suggestionItems  = {}
      props.suggestionStatus = ""

      refresh()

      -- Picking a row in the list is the selection changing, not a click on
      -- anything, so there is no action callback to hang this off. The property
      -- observer is how a list control tells us anything at all.
      props:addObserver("selectedSuggestion", function()
        ObservationPanel.chooseSuggestion(props, props.selectedSuggestion)
      end)

      local actions = {
        getSuggestions = function()
          LrTasks.startAsyncTask(function()
            ObservationPanel.loadSuggestions(props)
          end)
        end,

        uploadOrUpdate = function()
          LrTasks.startAsyncTask(function()
            ObservationPanel.uploadOrUpdate(props)
            refresh()
          end)
        end,

        unlink = function()
          LrTasks.startAsyncTask(function()
            ObservationPanel.unlink(props)
            refresh()
          end)
        end,

        -- Not on a task. Switching modules is a UI call, and the module change
        -- is what makes the filmstrip selection observable again afterwards --
        -- the panel refreshes itself from that, so there is nothing to wait for
        -- here.
        openMap = function()
          ObservationPanel.openMap()
        end,

        sync = function()
          -- Its own task with its own context: the sync outlives the click,
          -- and its progress scope must not be tied to a context that ends
          -- when this window closes.
          LrFunctionContext.postAsyncTaskWithContext("inat_panel_sync",
            function(syncContext)
              local SyncCore = require "SyncCore"
              SyncCore.syncTargetPhotos(syncContext)
              refresh()
            end)
        end,

        link = function()
          LrFunctionContext.postAsyncTaskWithContext("inat_panel_link",
            function(linkContext)
              require("LinkObservation").run(linkContext)
              refresh()
            end)
        end,

        view = function()
          local id = props.observationId
          if id and id ~= "" then
            LrHttp.openUrlInBrowser(OBSERVATION_URL .. id)
          end
        end,
      }

      -- Lightroom makes this window WS_EX_TOPMOST and ownerless, so it would
      -- float over every application and not minimise with Lightroom. Nothing
      -- in the SDK controls that, so a helper fixes the window up from
      -- outside. Started before the window exists on purpose: the call below
      -- blocks this task until the window closes, and the helper polls for the
      -- window rather than expecting to find it immediately.
      LrTasks.startAsyncTask(function()
        require("WindowFix").apply(WINDOW_TITLE)
      end)

      LrDialogs.presentFloatingDialog(_PLUGIN, {
        title    = WINDOW_TITLE,
        contents = ObservationPanel.contents(f, props, actions),

        -- Keyed so save_frame has something to store a position against, and
        -- so this is the same window every time rather than a new one.
        id         = WINDOW_ID,
        save_frame = WINDOW_ID,

        -- The point of the whole thing: follow the filmstrip.
        --
        -- These fire outside any task, so refresh() does its catalog reads on
        -- one rather than inline. Any error raised here is swallowed by
        -- Lightroom, so getting that wrong is invisible.
        selectionChangeObserver = refresh,

        -- Changing folder or collection changes the selection too, and
        -- without this the window would keep describing a photo that is no
        -- longer on screen.
        sourceChangeObserver = refresh,

        -- Holds this task open for as long as the window is up, which is what
        -- keeps the function context -- and therefore the property table the
        -- window is bound to -- alive. Without it the context ends the moment
        -- show() returns and the bindings are pointing at a dead object.
        blockTask = true,
      })
    end)
end

return ObservationPanel
