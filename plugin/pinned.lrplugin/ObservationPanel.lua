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
local LrColor           = import "LrColor"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp            = import "LrHttp"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local InatAuth   = require "InatAuth"
local NameStyle  = require "NameStyle"
local PanelCore  = require "PanelCore"
local Settings   = require "Settings"
local UploadCore = require "UploadCore"
local logger     = require "Log"

local ObservationPanel = {}

-- Identifies the window to Lightroom so save_frame has something to key its
-- stored position on, and so a second Show does not open a second window.
local WINDOW_ID = "com.github.inat-lightroom.observationPanel"

-- Where the saved frame is keyed, which is deliberately not WINDOW_ID.
--
-- save_frame stores a whole rectangle -- size as well as position -- in
-- Lightroom's preferences, as `["<plugin>_<key>"] = AgRect(l, t, r, b)`. This
-- window is not resizable -- it is presented without `resizable`, and a floating
-- dialog given no frame keys cannot be dragged at all (measured) -- so once a
-- layout has been seen at one width, that width is what reopens forever: making
-- the panel wider changes what Lightroom *would* measure and nothing about what
-- it restores. There is no way to ask it to forget, and a user cannot drag it
-- back.
--
-- Nor would asking for `resizable = true` help. It is honoured, and dragging
-- the window wider only widens the margin: controls keep their declared width.
--
-- So the key carries a number, and **making the panel a different size means
-- bumping it**. The cost is that the window reopens in its default position
-- once, which is cheap next to a panel stuck at a width nobody chose.
--
-- frame3: the Cancel button joined the upload row, which is wider than what
-- frame2 measured.
-- frame4: the suggestion names went from 330pt to 480pt, so every frame saved
-- against frame3 is 150pt too narrow to show what they now draw.
local FRAME_KEY = WINDOW_ID .. ".frame4"

local OBSERVATION_URL = "https://www.inaturalist.org/observations/"

-- What clickable text is drawn in. Lightroom's own dialogs colour their one
-- clickable line rather than underlining it, and there is nothing in LrView
-- that could underline it anyway. Light enough to read against the panel's dark
-- background, which rules out the browser-blue this would be on a page.
local LINK_COLOR = LrColor(0.45, 0.72, 1)

-- Both the window's caption and the handle the z-order fix-up finds it by, so
-- they cannot drift apart.
local WINDOW_TITLE = "Pinned"

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

  return NameStyle.format(taxon, common)
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
    accuracy      = PanelCore.accuracyValue(
                      photo and field(photo, "inat_positional_accuracy")),
    accuracyItems = PanelCore.accuracyItems(
                      photo and field(photo, "inat_positional_accuracy")),

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
      -- rows would still be clickable, and clicking one would put the previous
      -- photo's species onto this one.
      ObservationPanel.clearSuggestions(props)
      props.suggestionStatus  = ""
    end)
  end
end

--- How long to wait between looks at the selected photo, in seconds.
--
-- Short enough that coming back from the Map module feels like the panel
-- noticed, long enough that it is not doing anything while nobody is looking.
ObservationPanel.WATCH_INTERVAL = 2

--- Whether two references describe the same photo.
--
-- Identity first, because that is what the harness and, as far as anything
-- here can tell, the host both do. `localIdentifier` is the fallback in case a
-- second read hands back a different wrapper for the same photo: the whole
-- watcher would go quiet if that were true and nothing would say why.
local function samePhoto(a, b)
  if a == b then return true end
  if not a or not b then return false end

  return a.localIdentifier ~= nil and a.localIdentifier == b.localIdentifier
end

--- Look once at the selected photo, and redraw only if it has something new.
--
-- For the case the SDK cannot report: giving a photo a location in the Map
-- module. Nothing tells a plugin that metadata changed -- there are observers
-- for the selection and for the sources and nothing else -- so before this the
-- panel went on saying "None - iNaturalist will mark this casual" until the
-- selection was jogged off the photo and back.
--
-- Only the same photo is touched. A selection that has moved on belongs to the
-- selection observer, which does more than this does: it clears the suggestions
-- too, because they describe the photo they were asked about.
--
-- The suggestions are deliberately left alone here for the same reason -- the
-- photo has not changed, so they still describe it -- and the values the panel
-- owns rather than reads are left alone as well. Overwriting a species guess
-- being typed with what the catalog last stored would be the worst kind of bug:
-- silent, two seconds late, and blamed on the typing.
function ObservationPanel.pollOnce(props)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos() or {}
  local photo   = photos[1]

  if not samePhoto(photo, props.photo) then return false end

  local values = ObservationPanel.valuesFor(photo, #photos)
  if not PanelCore.valuesDiffer(props, values, PanelCore.PANEL_OWNED) then
    return false
  end

  for key, value in pairs(values) do
    if not PanelCore.PANEL_OWNED[key] then props[key] = value end
  end

  return true
end

--- Keep looking for as long as the window is up.
--
-- Errors are caught and logged rather than left to end the task: a watcher that
-- dies on one bad read stops watching for the rest of the session, and the only
-- symptom would be the panel going back to needing a nudge.
--
-- @param props   The window's property table.
-- @param isOpen  Answers whether the window is still up.
function ObservationPanel.watch(props, isOpen)
  while isOpen() do
    LrTasks.sleep(ObservationPanel.WATCH_INTERVAL)

    if not isOpen() then break end

    local ok, err = LrTasks.pcall(ObservationPanel.pollOnce, props)
    if not ok then
      logger:warnf("panel watch failed: %s", tostring(err))
    end
  end
end

--- Forget which name the field was given, without touching the field.
--
-- The two are cleared together and never apart. They exist only to answer "is
-- the text in the box still ours?", and half an answer is worse than none: a
-- scientific name that outlives the row it came from would be sent for a photo
-- whose suggestions were never even asked for.
--
-- The field itself is deliberately left alone. It belongs to the person typing
-- in it (PanelCore.PANEL_OWNED), and emptying it because the suggestion list
-- went away would throw away a guess they are halfway through.
function ObservationPanel.clearChosenName(props)
  props.suggestionOfferedName    = nil
  props.suggestionScientificName = nil
end

--- Forget the lineage held for the chosen suggestion.
--
-- Separate from clearChosenName because the two are cleared at different
-- moments: the names survive for as long as the field they filled, and the
-- lineage belongs to one chosen row and must go the instant a different row is
-- chosen -- otherwise the Taxonomy button opens the previous answer while the
-- list marks the new one.
function ObservationPanel.clearTaxonomy(props)
  props.taxonomy = {}
end

--- Let go of the chosen suggestion, because the field no longer says it.
--
-- Wired to the species guess field as an observer, so typing or pasting over
-- the name unpicks the row that put it there: the mark goes, and so does the
-- taxon id behind it.
--
-- Dropping the taxon id is the whole point. It is what the upload sends as an
-- identification, and it used to survive an edit -- so pasting "Argiini" over
-- a species and pressing Upload posted the species anyway, silently, because
-- free text loses to a taxon id every time. The visible mark going is the
-- honest version of that, and it is also the cue that the plugin noticed.
--
-- `hasSuggestion` is recomputed rather than cleared, because a typed name is
-- still something the buttons can work on -- they look it up (see
-- `PanelCore.taxonForName`) instead of reading an id off a row.
function ObservationPanel.guessEdited(props)
  local typed = props.speciesGuess or ""

  if typed == (props.suggestionOfferedName or "") then return false end

  props.selectedSuggestion = nil
  props.suggestionTaxonId  = nil
  props.suggestionRank     = nil
  props.suggestionScore    = nil

  ObservationPanel.clearChosenName(props)
  ObservationPanel.clearTaxonomy(props)
  ObservationPanel.applySuggestionSlots(props, props.suggestions or {}, nil)
  ObservationPanel.refreshHasSuggestion(props)

  return true
end

--- Whether there is a name for the buttons below the field to act on.
--
-- One rule in one place: a chosen row with a taxon id, or any text in the
-- field. The second half is what lets a typed or pasted name drive Taxonomy…,
-- Update photo tags and the upload -- and it is also why this is recomputed
-- rather than set to false whenever the suggestion list is emptied. A photo
-- that arrives with a species guess already in its metadata has a name worth
-- looking up and no suggestions at all.
function ObservationPanel.refreshHasSuggestion(props)
  props.hasSuggestion = props.suggestionTaxonId ~= nil
    or (props.speciesGuess or "") ~= ""
end

--- Empty the suggestion list and everything derived from it.
--
-- One function because the rows, the chosen row, and what the buttons below do
-- with it are one state: clearing some of them leaves a panel offering to apply
-- a guess that is no longer on screen.
function ObservationPanel.clearSuggestions(props)
  props.suggestions        = {}
  props.selectedSuggestion = nil
  props.suggestionTaxonId  = nil
  props.suggestionRank     = nil
  props.suggestionScore    = nil

  ObservationPanel.clearChosenName(props)
  ObservationPanel.clearTaxonomy(props)
  ObservationPanel.applySuggestionSlots(props, {}, nil)
  ObservationPanel.refreshHasSuggestion(props)
end

--- Copy the suggestion rows onto the fixed set of bound row properties.
--
-- The view reads suggestionTitleN / suggestionLinkN, one pair per row, because
-- a presented view tree cannot grow rows to match a list.
function ObservationPanel.applySuggestionSlots(props, rows, selected)
  local slots = PanelCore.suggestionSlots(rows, selected)

  for index, slot in ipairs(slots) do
    props["suggestionTitle" .. index] = slot.title
    props["suggestionLink" .. index]  = slot.link
  end

  return slots
end

--- The control that shows the suggestions.
--
-- Hand-built rows rather than a list control, because a list row cannot carry a
-- link. Each row is two pieces of clickable text: the name, which picks that
-- suggestion as the guess, and a link out to the taxon's page on iNaturalist
-- for when the name alone does not settle it. That link is why the button that
-- used to do the same job is gone.
--
-- Clickable text is `f:static_text` with a `mouse_down`, which is not in the
-- SDK documentation but is what Lightroom's own alert dialog uses for its
-- "Click here to know more" line -- the string sits in ui.dll beside a
-- text_color, a mouse_down and an LrHttp.openUrlInBrowser call.
--
-- The row count is fixed at PanelCore.SUGGESTION_LIMIT because a presented view
-- tree cannot grow, shrink, or hide a row: a bound `visible` is accepted and
-- changes nothing. Surplus rows carry an empty title and an empty link, which
-- draws as blank space and clicks to nothing.
--
-- Was f:simple_list, which scales far better and was the right control while
-- rows were only selectable. It holds strings, so the moment a row had to hold
-- a second, separately clickable thing it could not. Eight rows is nowhere near
-- where hand-built rows get slow.
-- Both pieces carry an explicit width. A `static_text` takes its size from the
-- title it was *built* with, and these are built empty, so without a width the
-- name collapses to nothing and every row draws as a link floating on the left
-- (seen in the host). `fill_horizontal` alone does not save it: it shares out
-- space a row has spare, and a row of two zero-width controls has none.
--
-- That width is what decides how wide the window wants to be, and it is the
-- only thing that decides how much of a name is readable, because nothing else
-- can recover the rest. Measured, not reasoned (explore/probes/sdkprobe):
-- a window given `resizable = true` really can be dragged wider, and the extra
-- space goes entirely to the margin -- the text keeps its declared width. So a
-- column cannot be made to grow with its window. `height_in_lines = 2` on a
-- bound title does not wrap either; it draws one line, the same height as
-- without it. The width is the whole lever.
--
-- 330 was cutting off most of the list rather than the odd unlucky name.
-- explore/measure_suggestion_widths.py put the 600 most-observed species
-- through this formatter -- 2,400 titles, September 2026 -- and split them:
--
--   scored species rows   max  68 chars   fit at 330
--   coarser rank rows     max 111 chars   about a third fit at 330
--
-- The coarse rows are the long ones because `describeSuggestion` gives them a
-- `- <rank>, containing <name>` tail where a candidate gets `- 87%`, and iNat
-- hands whole families a list of common names to begin with ("Herb-Paris,
-- False Hellebores, Trilliums and allies (Melanthiaceae)"). So the rows being
-- cut were the rows whose tail says why to pick them.
--
-- 480 holds every one of those 2,400 titles if a character is ~4.9pt wide,
-- which is what the probe's width ladder implies but did not prove -- one
-- string at two widths cannot pin down a proportional font. On the pessimistic
-- reading of that ladder it holds about 94%. It is the chosen width rather
-- than the safe one: 560 fits the sample under every reading, and the extra
-- 80pt of permanent panel width was judged not worth it.
--
-- So this fits the names that were measured. It is not a bound -- the sample is
-- the common case out of some half a million taxa -- and `truncation` is what
-- happens when it is wrong. Keeping it matters: the documented behaviour
-- without it is to drop the last *word* silently, measured here as stopping
-- dead mid-phrase with nothing to show the name had been shortened, so the
-- ellipsis is the only thing that tells the reader there is more. Both keys are
-- undocumented and both are read out of ui.dll, where `static_text` is built
-- with `truncation` beside `mouse_down` and `text_color`.
--
-- The `tooltip` below is set in hope rather than in knowledge. `tooltip` is an
-- AgView-level property in ui.dll (`AgView_changed_tooltip`, and
-- `AgViewManifestationWin::SetTooltip` beside `HandleToolTipHitTest`), but
-- nobody has checked that one appears on these rows or that it carries the
-- whole untruncated title, so nothing here relies on it. `resizable` is the
-- warning: present in one key list, absent from another, and only an A/B
-- settled what it did.
--
-- Not `selectable = true`, which would make the name copyable: it is honoured,
-- and it takes the click with it. See docs/lightroom-sdk-notes.md.
local NAME_WIDTH = 480

function ObservationPanel.suggestionsView(f, actions)
  local rows = { spacing = 0 }

  for index = 1, PanelCore.SUGGESTION_LIMIT do
    rows[#rows + 1] = f:row {
      spacing         = f:label_spacing(),
      fill_horizontal = 1,

      f:static_text {
        title           = LrView.bind("suggestionTitle" .. index),
        tooltip         = LrView.bind("suggestionTitle" .. index),
        width           = NAME_WIDTH,
        truncation      = "tail",
        fill_horizontal = 1,
        mouse_down      = function() actions.chooseSuggestion(index) end,
      },

      f:static_text {
        title      = LrView.bind("suggestionLink" .. index),
        width      = 60,
        text_color = LINK_COLOR,
        mouse_down = function() actions.viewSuggestion(index) end,
      },
    }
  end

  -- A frame, because eight rows of plain text against the rest of the panel's
  -- plain text read as more of the same. The list control this replaced drew
  -- its own; without one the suggestions stop looking like a list of things to
  -- click. `show_title = false` is what makes a group_box a bare frame rather
  -- than a titled one -- ui.dll's AgViewWinGroupBox reads it.
  return f:group_box {
    show_title      = false,
    fill_horizontal = 1,
    f:column(rows),
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

    -- The observation ID is the link out to iNaturalist, which is why there is
    -- no View button here any more: the number and the page it names are the
    -- same fact, and a button that says "View on iNaturalist" is a second
    -- control for something the ID already is. Copy stays, because pasting the
    -- number into Link to Observation is the other thing it is wanted for.
    f:row {
      f:static_text { title = "Observation:", width = LABEL, alignment = "right" },
      f:static_text {
        title           = LrView.bind("observationId"),
        width           = 260,
        fill_horizontal = 1,
        text_color      = LINK_COLOR,
        mouse_down      = actions.view,
      },
      f:push_button {
        title   = "Copy",
        enabled = LrView.bind("hasObservation"),
        action  = actions.copyObservationId,
      },
    },

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

    -- Accuracy sits under the coordinates it qualifies. iNaturalist stores it
    -- per observation and Lightroom has nowhere to keep it, so this control is
    -- the only place it can be set -- and leaving it unset is a real answer,
    -- not a missing one, which is why "Not specified" is a listed choice rather
    -- than an empty popup.
    f:row {
      f:static_text { title = "Accuracy:", width = LABEL, alignment = "right" },
      f:popup_menu {
        value           = LrView.bind("accuracy"),
        items           = LrView.bind("accuracyItems"),
        enabled         = LrView.bind("hasPhoto"),
        fill_horizontal = 1,
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
        -- Per-keystroke writes buy nothing here and the field is committed in
        -- time regardless: a probe measured this binding already written before
        -- any click handler in the dialog runs -- a push_button action, a
        -- static_text mouse_down, or work deferred onto a task. That is what
        -- lets PanelCore.guessToSend tell an edited guess from an untouched one
        -- at the moment a button is pressed. See docs/lightroom-sdk-notes.md.
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

    ObservationPanel.suggestionsView(f, actions),

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
    --
    -- The other one is deliberately not that intent: it files the name in the
    -- catalog and tells iNaturalist nothing, which is why it sits apart from
    -- the button that publishes.
    f:row {
      spacing = f:control_spacing(),
      f:push_button {
        title   = LrView.bind("uploadTitle"),
        -- Off while one is already running. The panel's buttons do not block
        -- the window, so without this a second click starts a second upload
        -- against the same selection and makes a duplicate observation.
        enabled = LrView.bind {
          keys      = { "hasPhoto", "uploading" },
          operation = function(_, values)
            return values.hasPhoto and not values.uploading
          end,
        },
        action  = actions.uploadOrUpdate,
        width   = 180,
      },
      -- Always present rather than appearing mid-upload. A button that shows
      -- up only once there is something to cancel is a button nobody knows is
      -- there until they need it, which is the moment they are least able to
      -- go looking.
      f:push_button {
        title   = "Cancel",
        enabled = LrView.bind("uploading"),
        action  = actions.cancelUpload,
      },
      f:push_button {
        title   = "Update photo tags",
        enabled = LrView.bind("hasSuggestion"),
        action  = actions.applyLocally,
      },
      -- The chosen suggestion's whole lineage, kingdom down, one rank per row
      -- with a Copy button each. A dialog rather than anything in the panel,
      -- and this row rather than a row of its own, because both come from the
      -- same limit: a presented view tree cannot hide or resize a row, so a
      -- collapsible taxonomy would stand at full height collapsed, and even an
      -- empty row would cost the panel height permanently for something wanted
      -- occasionally. A dialog is built fresh each time and is exactly as tall
      -- as the lineage it was handed.
      --
      -- It sits beside the other button that works on the chosen name rather
      -- than beside the suggestions, and it is live whenever there is a name
      -- to look up -- a clicked suggestion, or something typed or pasted into
      -- the field, which it resolves against iNaturalist itself.
      f:push_button {
        title   = "Taxonomy…",
        enabled = LrView.bind("hasSuggestion"),
        action  = actions.showTaxonomy,
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
    -- The one place in the panel where a missing token is not reported in
    -- line: the fix is a window, so open it rather than printing a menu path
    -- into a status line two words wide.
    props.suggestionStatus = ""
    InatAuth.reportMissingCredentials(authErr)
    return
  end

  -- Before the rows are described rather than after, because describing them is
  -- what needs to know which way round the two names go. Memoised, and the
  -- account has usually been fetched already for its id, so this is normally
  -- free; when it is not, it is one request on the slowest button in the panel.
  NameStyle.load(api)

  local rows, err = PanelCore.getSuggestions(api, photos[1])
  if not rows then
    props.suggestionStatus = err or "Could not get suggestions."
    return
  end

  props.suggestions        = rows
  ObservationPanel.applySuggestionSlots(props, rows, nil)
  props.selectedSuggestion = nil
  props.suggestionTaxonId  = nil
  props.suggestionRank     = nil
  props.suggestionScore    = nil
  props.hasSuggestion      = false
  ObservationPanel.clearChosenName(props)
  ObservationPanel.clearTaxonomy(props)

  if #rows == 0 then
    props.suggestionStatus = "iNaturalist had no suggestions for this photo."
  else
    props.suggestionStatus =
      "Click a name to use it, or View to open it on iNaturalist."
  end
end

--- Copy a chosen suggestion into the species guess.
--
-- Two names come off the row, because what the field shows and what
-- iNaturalist is told are not the same string and should not be forced to be.
--
-- The field gets "Common name (Scientific name)", the way the row presents it.
-- It is the only selectable control in the panel -- static text cannot be
-- selected, and there is no read-only control that can (see Clipboard.lua) --
-- so it is also the only place a name can be copied from for a caption, and a
-- user who wanted the common name had to retype it.
--
-- The bare name is kept beside it for the upload, because iNaturalist matches
-- species_guess against taxon names to identify an observation that has no
-- taxon, and a parenthetical matches nothing. PanelCore.guessToSend is where
-- that evidence is written down, and it is what decides between the two at send
-- time.
--
-- The taxon id is remembered separately, and it is the more important half --
-- it is what turns the next button press into a real identification rather than
-- free text iNaturalist will ignore.
function ObservationPanel.chooseSuggestion(props, selection)
  local rows  = props.suggestions or {}
  local index = PanelCore.selectedIndex(selection)
  local row   = index and rows[index]

  if not row then
    props.selectedSuggestion = nil
    props.suggestionTaxonId = nil
    props.suggestionRank    = nil
    props.suggestionScore   = nil
    ObservationPanel.clearChosenName(props)
    ObservationPanel.clearTaxonomy(props)
    ObservationPanel.applySuggestionSlots(props, rows, nil)
    ObservationPanel.refreshHasSuggestion(props)
    return nil
  end

  -- All three written together, and only here. The pair below is only
  -- trustworthy as a pair: a scientific name left over from a row the field no
  -- longer shows is a wrong identification waiting to be sent.
  --
  -- The offered name is written *before* the field, not after, and that order
  -- is load-bearing: an observer on `speciesGuess` drops the chosen row the
  -- moment the text stops matching what was offered, and it fires inside the
  -- assignment. Writing the field first would have it compare against the
  -- previous row's name, decide the user had typed something, and unpick the
  -- choice being made.
  props.suggestionOfferedName    = PanelCore.suggestionName(row)
  props.speciesGuess             = props.suggestionOfferedName
  props.suggestionScientificName = row.name or row.common_name or ""

  props.selectedSuggestion = index
  props.suggestionTaxonId = row.taxon_id
  ObservationPanel.refreshHasSuggestion(props)

  -- Kept so the upload can argue about a weak species-level claim. Read off the
  -- row at the moment it is chosen rather than looked up later, because the list
  -- is replaced wholesale by the next Get Suggestions and the index would then
  -- point at something else.
  props.suggestionRank    = row.rank
  props.suggestionScore   = row.combined_score

  -- The mark on the row is the only thing saying which one is chosen: these
  -- rows are drawn by us and have no selection highlight of their own.
  ObservationPanel.applySuggestionSlots(props, rows, index)

  -- The lineage held belongs to whichever row was chosen last, so the old one
  -- goes now rather than when the new one arrives. Between the two there is
  -- nothing to open, which is honest; leaving the previous lineage in place
  -- while the new row is marked would offer a window describing another taxon.
  ObservationPanel.clearTaxonomy(props)

  return row
end

--- Load the chosen suggestion's full lineage, ready for the Taxonomy button.
--
-- MUST be called from inside a task: it may fetch.
--
-- Usually free, which is what makes it worth doing on every click rather than
-- behind a button. Get Suggestions has already fetched the top candidate's
-- lineage to build the coarser rows at the head of the list, and
-- `InatAPI:getTaxon` memoises, so the common case is a cache read. A row
-- further down costs one request, once.
--
-- The guard is the point of the rest of it. Clicking down a list faster than
-- the network answers leaves several of these in flight at once, and without a
-- check at the end the slowest reply wins -- the panel would settle on the
-- lineage of a row the user has already moved off. So the chosen taxon is read
-- again after the fetch and the answer is dropped unless it is still the one
-- being asked about.
--
-- Failure is silent except in the status line. A row with no lineage is a row
-- whose Taxonomy button stays off, which is the honest state.
function ObservationPanel.loadTaxonomy(props)
  local rows  = props.suggestions or {}
  local index = PanelCore.selectedIndex(props.selectedSuggestion)
  local row   = index and rows[index]

  if not row or not row.taxon_id then
    ObservationPanel.clearTaxonomy(props)
    return nil
  end

  local wanted = row.taxon_id

  local api = UploadCore.requireAPI()
  if not api then
    -- Nothing said. Choosing a row is not asking to sign in, and the panel's
    -- own Get Suggestions has already reported this properly for anyone who
    -- did ask -- there is no way to have a suggestion list to click without
    -- having been through it.
    return nil
  end

  NameStyle.load(api)

  local taxonomy, err = PanelCore.taxonomyFor(api, row)

  if props.suggestionTaxonId ~= wanted then return nil end

  if not taxonomy then
    ObservationPanel.clearTaxonomy(props)
    props.suggestionStatus = err or "Could not load the taxonomy."
    return nil
  end

  props.taxonomy = taxonomy

  return taxonomy
end

--- The taxon every button below should act on.
--
-- MUST be called from inside a task: it may fetch.
--
-- One answer to one question -- "what did the user say this is?" -- rather than
-- each button reaching for `suggestionTaxonId` and getting nil the moment the
-- field was edited. A chosen row answers it for free; anything typed or pasted
-- costs a lookup, and is worth one, because an identification needs a taxon id
-- and free text is ignored by iNaturalist on any observation that already has a
-- taxon.
--
-- The resolved id is written back, so looking it up, reading its taxonomy and
-- then uploading is one request rather than three.
--
-- @return taxon id or nil, and a message when there was a name that resolved to
--         nothing. No name at all is not an error: uploading without a guess is
--         allowed, and always has been.
function ObservationPanel.taxonIdToUse(props, api)
  if props.suggestionTaxonId then return props.suggestionTaxonId, nil end

  local typed = props.speciesGuess or ""
  if typed == "" then return nil, nil end

  local taxon, err = PanelCore.taxonForName(api, typed)
  if not taxon or not taxon.id then return nil, err end

  props.suggestionTaxonId = taxon.id
  props.suggestionRank    = taxon.rank
  props.taxonomy          = PanelCore.taxonomyRows(taxon)

  return taxon.id, nil
end

--- Open the taxonomy window for whatever the panel is currently claiming.
--
-- MUST be called from inside a task with a live context: the window's buttons
-- copy, copying shells out, and presenting it blocks this task until it closes.
--
-- Two sources, in order of what they cost. A chosen row has had its lineage
-- fetched already, on the click; a typed or pasted name has not, and is looked
-- up here. The second case is the one that makes this worth having: reading a
-- tribe out of one window, pasting it into the field and pressing the button
-- again is how you walk up a lineage until you reach a rank you actually
-- believe.
function ObservationPanel.showTaxonomy(context, props)
  local taxonomy = props.taxonomy or {}

  if #taxonomy == 0 then
    local typed = props.speciesGuess or ""
    if typed == "" then
      props.suggestionStatus = "Choose a suggestion or type a name first."
      return false
    end

    local api = UploadCore.requireAPI()
    if not api then
      InatAuth.reportMissingCredentials()
      return false
    end

    props.suggestionStatus = "Looking up " .. typed .. "…"

    NameStyle.load(api)

    local found, err = PanelCore.taxonomyForName(api, typed)
    if not found then
      props.suggestionStatus = err or "Could not load the taxonomy."
      return false
    end

    -- Kept, so a second press of the button opens it again without a request,
    -- and so an upload that follows already knows what it is identifying.
    props.taxonomy = found
    props.suggestionStatus = ""
    taxonomy = found
  end

  -- The finest rung names the window, because that is the taxon the user asked
  -- about; the rest of it is what that is a member of. It is also what keys the
  -- window, so asking twice about one species raises the window already open.
  local leaf = taxonomy[#taxonomy]

  return require("TaxonomyDialog").show(context, taxonomy, leaf and leaf.name)
end

--- Open a suggestion's taxon page on iNaturalist.
--
-- The row's own link, and the reason there is no longer a button doing this for
-- whichever row happens to be chosen. Clicking it does not choose the row: what
-- the two clicks mean is different -- one says "this is what it is", the other
-- says "I do not know yet, show me" -- and merging them would make looking
-- something up commit to it.
function ObservationPanel.viewSuggestion(props, index)
  local rows = props.suggestions or {}
  local row  = rows[PanelCore.selectedIndex(index)]
  local url  = row and PanelCore.taxonUrl(row.taxon_id)

  if not url then return nil end

  LrHttp.openUrlInBrowser(url)
  return url
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
    LrDialogs.message("Pinned",
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
    LrDialogs.message("Pinned", "Select at least one photo first.", "warning")
    return
  end

  local api, authErr = UploadCore.requireAPI()
  if not api then
    InatAuth.reportMissingCredentials(authErr)
    return
  end

  local settings = Settings.all()
  local guess    = props.speciesGuess or ""
  local accuracy = props.accuracy

  -- Resolved rather than read off the chosen row, because there may not be a
  -- chosen row: a name typed or pasted over the field is an identification the
  -- user means just as much, and without an id behind it iNaturalist would
  -- ignore it on anything already identified.
  --
  -- A name that resolves to nothing does not stop the upload; free text in
  -- species_guess has always been allowed and is the right answer for anything
  -- iNaturalist has no taxon for. It does get asked about, below, because the
  -- difference is otherwise invisible: the upload succeeds either way.
  local taxonId, lookupErr = ObservationPanel.taxonIdToUse(props, api)

  -- Both of these come before the confidence and location gates below, and
  -- before anything is rendered. They ask whether this is the right operation
  -- on the right photos at all; the two below ask about the content of an
  -- operation already agreed to. Taking somebody's answer on the species and
  -- only then telling them their selection was wrong wastes the answer they
  -- just gave, and a refusal that arrives after twenty raw files have been
  -- rendered wastes the whole wait as well.
  --
  -- Both decide for themselves whether they apply to this job, reading the
  -- same signal the branch below reads -- whether photos[1] already carries an
  -- inat_observation_id -- so neither needs that branch to have happened yet,
  -- and neither can speak about uploading during an update.
  local overLimit = PanelCore.tooManyPhotos(photos)
  if overLimit then
    LrDialogs.message("Pinned Upload", overLimit, "critical")
    props.suggestionStatus = ""
    return
  end

  -- A separate dialog rather than one merged with the gates below, deliberately.
  -- They are three different questions, and a single OK answering all of them
  -- is an OK that means nothing. Asked first, cancelling here costs one dialog
  -- rather than three.
  local merging = PanelCore.multiPhotoWarning(photos)
  if merging then
    local answer = LrDialogs.confirm(
      "Upload " .. #photos .. " photos as one observation?", merging,
      "Upload", "Cancel")
    if answer ~= "ok" then
      props.suggestionStatus = ""
      return
    end
  end

  -- What the field says and what iNaturalist is told part company here, and
  -- only here. The field is the display form; this is the name a taxon lookup
  -- can match.
  --
  -- Computed after the gates above rather than before them, so a selection
  -- that is refused never pays for it.
  local wireGuess = PanelCore.guessToSend(
    guess, props.suggestionOfferedName, props.suggestionScientificName)

  -- Asked before the branch, because both jobs end with iNaturalist holding a
  -- species-level claim. The location warning below is upload-only for a real
  -- reason -- an update cannot add coordinates -- but a weak identification is
  -- just as wrong on an observation that already exists.
  --
  -- Named with the displayed form rather than the wire one: this is a sentence
  -- somebody has to decide on, and the name they are looking at on screen is
  -- the one it should be about.
  local doubt = PanelCore.confidenceWarning({
    rank           = props.suggestionRank,
    combined_score = props.suggestionScore,
    name           = guess,
  })
  if doubt then
    local answer = LrDialogs.confirm("Identify as a species?", doubt,
      "Identify Anyway", "Cancel")
    if answer ~= "ok" then
      props.suggestionStatus = ""
      return
    end
  end

  -- Which of the two jobs this is depends on the photo, not on the button: the
  -- caption is only a description of what is about to happen.
  local existing = UploadCore.pluginField(photos[1], "inat_observation_id")

  -- Last of the gates, because it is the one most likely to be answered "no"
  -- after a second look at the spelling, and an answer of no here should not
  -- have cost the three dialogs above.
  --
  -- Asked at all because `taxonIdToUse` has just done the only lookup that can
  -- tell the difference, and without this the upload reports success whether
  -- it carried an identification or a string nothing will ever match.
  if not taxonId then
    local freeText = PanelCore.freeTextWarning(guess, lookupErr, existing ~= nil)
    if freeText then
      local answer = LrDialogs.confirm(
        existing and "Send a name iNaturalist will ignore?"
                  or "Upload without an identification?",
        freeText,
        existing and "Send Anyway" or "Upload Anyway", "Cancel")
      if answer ~= "ok" then
        props.suggestionStatus = ""
        return
      end
    end
  end

  if existing then
    props.suggestionStatus = "Updating the identification…"

    -- Before the identification, because this is the step that can be skipped
    -- without the user noticing. The identification announces itself in the
    -- status line; a silently dropped accuracy would not.
    local accOk, accErr = PanelCore.updateAccuracy(catalog, api, photos, accuracy)
    if not accOk then
      LrDialogs.message("Pinned",
        accErr or "Could not update the location accuracy.", "critical")
      props.suggestionStatus = ""
      return
    end

    local ok, err = PanelCore.updateSpeciesGuess(catalog, api, photos, wireGuess, taxonId)
    if not ok then
      LrDialogs.message("Pinned", err or "Could not update the observation.", "critical")
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

  -- Written to the photos first, because the upload builds its observation from
  -- what the photo says rather than from what the panel is showing. A choice
  -- made in the popup and not written down here would simply not be sent.
  PanelCore.recordAccuracy(catalog, photos, accuracy)

  -- The flag is cleared here rather than by the Cancel button, so a cancel left
  -- over from a previous run cannot stop the next one before it starts.
  props.uploadCanceled = false
  props.uploading      = true

  local observationId, _, errors, canceled = PanelCore.upload(catalog, api, settings, photos, {
    sleep      = LrTasks.sleep,
    onEvent    = function(message) props.suggestionStatus = message end,
    isCanceled = function() return props.uploadCanceled == true end,
  })

  props.uploading = false

  if canceled then
    -- No modal. The user asked for this, so telling them it happened in a box
    -- they have to dismiss is making them acknowledge their own decision. The
    -- exception is a cancel that could not finish tidying up, which is news.
    if #errors > 0 then
      LrDialogs.message("Pinned Upload", table.concat(errors, "\n"), "warning")
    end
    props.suggestionStatus = "Upload cancelled."
    return
  end

  if not observationId then
    LrDialogs.message("Pinned Upload",
      errors[1] or "The upload failed.", "critical")
    props.suggestionStatus = ""
    return
  end

  -- A taxon chosen before the upload could not be sent with it: an
  -- identification needs an observation to attach to, and there was not one
  -- until a moment ago. So it is posted now, as a second step.
  if taxonId then
    local ok, err = PanelCore.updateSpeciesGuess(catalog, api, photos, wireGuess, taxonId)
    if not ok then
      errors[#errors + 1] = err
    end
  end

  if #errors > 0 then
    LrDialogs.message("Pinned Upload",
      "Uploaded as observation " .. tostring(observationId)
      .. ", but some things did not work:\n\n" .. table.concat(errors, "\n"),
      "warning")
  end

  props.suggestionStatus = "Uploaded as observation " .. tostring(observationId) .. "."
end

--- Ask the upload in progress to stop.
--
-- Sets a flag rather than doing anything itself. The upload runs on its own
-- task and is the only thing that knows what it has created so far, so it is
-- the only thing that can undo it; this just tells it to, at the next point
-- where stopping is safe.
--
-- Not on a task, deliberately. Setting one property must not queue behind the
-- upload's own task, or pressing Cancel would take effect only once the thing
-- being cancelled had finished.
function ObservationPanel.cancelUpload(props)
  if not props.uploading then return false end

  props.uploadCanceled   = true
  props.suggestionStatus = "Cancelling…"
  return true
end

--- File the chosen suggestion's taxonomy in the catalog, and tell nobody.
--
-- MUST be called from inside a task.
--
-- No location warning and no confidence warning here, deliberately. Both exist
-- because a bad record on iNaturalist is a public artefact other people build
-- on; a keyword in your own catalog is neither public nor permanent, and you can
-- see it and change it. Warning about it anyway would train people to click past
-- the warnings that matter.
function ObservationPanel.applyLocally(props)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos() or {}

  if #photos == 0 then
    LrDialogs.message("Pinned", "Select at least one photo first.", "warning")
    return
  end

  local api, authErr = UploadCore.requireAPI()
  if not api then
    InatAuth.reportMissingCredentials(authErr)
    return
  end

  props.suggestionStatus = "Applying keywords…"

  -- Same resolution the upload does, for the same reason: the keywords should
  -- describe what the field says, not what was clicked before it was edited.
  -- Unlike the upload this cannot go on without an id -- the whole keyword
  -- hierarchy is read off the taxon -- so an unresolved name stops here.
  local taxonId, lookupErr = ObservationPanel.taxonIdToUse(props, api)
  if lookupErr then
    LrDialogs.message("Pinned", lookupErr, "warning")
    props.suggestionStatus = ""
    return
  end

  local ok, err = PanelCore.applyGuessLocally(catalog, api, photos, taxonId)
  if not ok then
    LrDialogs.message("Pinned", err or "Could not apply that taxon.",
      "critical")
    props.suggestionStatus = ""
    return
  end

  props.suggestionStatus = "Keywords applied to " .. #photos .. " photo(s)."
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

--- Put the shown observation ID on the clipboard.
--
-- MUST be called from inside a task.
--
-- Reports through the panel's own status line rather than a dialog. A modal to
-- dismiss after every copy would defeat the point, which is to make attaching
-- further photos to the same observation a couple of clicks.
function ObservationPanel.copyObservationId(props)
  local id = props.observationId

  if not id or id == "" then
    props.suggestionStatus = "No observation to copy."
    return false
  end

  local Clipboard = require "Clipboard"

  if not Clipboard.copy(id) then
    props.suggestionStatus = "Could not copy observation " .. id .. "."
    return false
  end

  props.suggestionStatus = "Copied observation " .. id .. " to the clipboard."
  return true
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

      -- Every bound property the view reads has to exist before the window is
      -- built, including one title and one link caption per suggestion row.
      props.suggestionStatus = ""
      props.uploading        = false
      props.uploadCanceled   = false
      ObservationPanel.clearSuggestions(props)

      -- The field is the panel's other input, and until now it was an input
      -- nothing watched: a name typed over a chosen suggestion left the mark on
      -- the row and the taxon id behind it, and the taxon id is what got sent.
      -- This is what makes editing the field mean what it looks like it means.
      --
      -- Registered after the first clearSuggestions so that setting the bound
      -- keys up does not count as an edit, and before refresh() so that the
      -- first photo's stored guess does.
      props:addObserver("speciesGuess", function()
        ObservationPanel.guessEdited(props)
      end)

      -- On its own task because it is a network call and the panel should be on
      -- screen before it finishes. Until it does, names are drawn iNaturalist's
      -- default way round; the account's answer arrives a moment later and the
      -- panel redraws itself when the selection next changes.
      LrTasks.startAsyncTask(function()
        NameStyle.load(UploadCore.requireAPI())
        refresh()
      end)

      refresh()

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

        -- Not on a task. It only sets a flag, and starting a task to do that
        -- would put it behind the upload it is meant to interrupt.
        cancelUpload = function()
          ObservationPanel.cancelUpload(props)
        end,

        applyLocally = function()
          LrTasks.startAsyncTask(function()
            ObservationPanel.applyLocally(props)
            refresh()
          end)
        end,

        -- Not on a task: neither picking a row nor opening a browser blocks,
        -- and there is nothing to refresh from the catalog afterwards. The
        -- lineage that follows it does need one, and it is started separately
        -- so that the row is marked and the guess filled immediately rather
        -- than at network speed.
        chooseSuggestion = function(index)
          ObservationPanel.chooseSuggestion(props, index)
          LrTasks.startAsyncTask(function()
            ObservationPanel.loadTaxonomy(props)
          end)
        end,

        viewSuggestion = function(index)
          ObservationPanel.viewSuggestion(props, index)
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

        -- On a task because the copy shells out, and LrTasks.execute blocks.
        copyObservationId = function()
          LrTasks.startAsyncTask(function()
            ObservationPanel.copyObservationId(props)
          end)
        end,

        -- Its own context, not the panel's. The dialog's property table is tied
        -- to whatever context it is given, and the panel's lives as long as the
        -- window -- so handing this one the panel's would leave a property
        -- table per dialog opened, never collected, for as long as the panel is
        -- up.
        showTaxonomy = function()
          LrFunctionContext.postAsyncTaskWithContext("inat_taxonomy",
            function(taxonomyContext)
              ObservationPanel.showTaxonomy(taxonomyContext, props)
            end)
        end,

        -- The observation ID's own click, not a button's. Guarded because the
        -- ID can be empty, and openUrlInBrowser would then open /observations/
        -- and a 404.
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

      -- Nothing tells a plugin that a photo's metadata changed, so the panel
      -- looks for itself while it is up. Started here rather than inside the
      -- window because the call below blocks this task until the window closes;
      -- `open` is what stops the watcher afterwards.
      local open = true

      LrTasks.startAsyncTask(function()
        ObservationPanel.watch(props, function() return open end)
      end)

      LrDialogs.presentFloatingDialog(_PLUGIN, {
        title    = WINDOW_TITLE,
        contents = ObservationPanel.contents(f, props, actions),

        -- Keyed so this is the same window every time rather than a new one.
        -- The saved frame is keyed separately, so that a layout change can
        -- start it over without the window itself becoming a different one.
        id         = WINDOW_ID,
        save_frame = FRAME_KEY,

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

        -- Stops the watcher at the earliest moment there is, rather than
        -- whenever this task is next scheduled.
        windowWillClose = function() open = false end,
      })

      -- blockTask means this line is reached when the window has closed, which
      -- is what stops the watcher. Also set from windowWillClose, because a
      -- watcher left running against a dead property table is exactly the kind
      -- of thing that would only show up as a mystery in the log much later.
      open = false
    end)
end

return ObservationPanel
