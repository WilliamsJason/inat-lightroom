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
    Observations  linking this catalog to iNaturalist, and where the keywords go
    Upload        what gets sent: the observation's own fields, and the file

  Modal on purpose: unlike the observation panel there is nothing here to keep
  watching while you work.

  Every preference is saved the moment it is changed, so the window closes on
  "Done" rather than on "Save". A Save/Cancel pair would promise a pending
  edit that could be thrown away, and there is no such thing here -- Cancel
  would have to undo settings already written. Credentials are the exception,
  because storing a token is a deliberate act with a network check behind it:
  their buttons live on the Account tab, next to the field they act on.
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
local InatOAuth = require "InatOAuth"
local ExportPresets = require "ExportPresets"
local Jobs     = require "Jobs"
local Settings = require "Settings"
local logger   = require "Log"

local TOKEN_URL = "https://www.inaturalist.org/users/api_token"

local SettingsDialog = {}

-- Whether the settings window is on screen. See show().
local isShowing = false

--- Whether the settings window is already open.
--
-- Asked by InatAuth before it sends someone here: the answer to "you have no
-- credentials" is this window, but only when it is not the window they are
-- already looking at.
function SettingsDialog.isShowing()
  return isShowing
end

--------------------------------------------------------------------------------
-- Choices
--------------------------------------------------------------------------------

--- What iNaturalist will do with the observation's coordinates.
SettingsDialog.GEOPRIVACY_ITEMS = {
  { title = "Open - anyone can see where it was",       value = "open" },
  { title = "Obscured - shown as a rough area",         value = "obscured" },
  { title = "Private - location visible only to you",   value = "private" },
}



--- What the popup calls rendering with the plugin's own settings.
SettingsDialog.PRESET_NONE_TITLE =
  "Plugin defaults - 2048 px, JPEG 90, sharpened for screen"

--- The export-preset popup's items: plugin defaults, then the usable presets.
--
-- Unusable presets are deliberately NOT items. A popup entry that can be
-- chosen and then quietly ignored is worse than no entry at all, and Lightroom
-- has no per-item disabled state. They are named underneath instead, by
-- presetNotes, so the answer to "where is the preset I just made" is on screen
-- rather than absent.
function SettingsDialog.presetItems(presets)
  local items = {
    { title = SettingsDialog.PRESET_NONE_TITLE, value = "" },
  }

  for _, preset in ipairs(presets or {}) do
    if preset.usable then
      items[#items + 1] = { title = preset.title, value = preset.id }
    end
  end

  return items
end

--- Why presets the user can see in Lightroom are missing from the popup.
--
-- Returns "" when nothing was rejected, so the text can be bound with no
-- special case -- and so the rule is never explained to someone it excluded
-- nobody from.
--
-- States the rule and deliberately does NOT name the presets it excluded.
-- Naming them was tried and removed: the rejected list has no bounded length,
-- since someone with a shelf of optical-media and email presets makes it
-- arbitrarily long, and the sentence was already too long for the tab. Capping
-- the names and counting the rest worked but bought a mechanism for a line
-- nobody needs the detail of -- the presets are absent from the popup right
-- above, which is the part the user acts on.
function SettingsDialog.presetNotes(presets)
  for _, preset in ipairs(presets or {}) do
    if not preset.usable then
      return "Note: Only Hard Drive presets are listed as other presets"
        .. " cannot render a file for upload."
    end
  end

  return ""
end

--- What the chosen preset will do to the file.
--
-- The watermark warning is deliberately NOT in here; it has its own control.
-- Measured: an f:static_text whose contents do not fit its width drops the
-- word that overflows and draws nothing in its place, with no ellipsis and no
-- sign that anything is missing. Putting a warning at the end of a sentence
-- of unknown length is how it disappears on the one machine where it matters.
--
-- Deliberately silent about a size value the preset stores and ignores -- a
-- longEdge preset carrying a stale maxWidth. Lightroom's own Export dialog
-- shows a single Long Edge box, so that number is not visible anywhere the
-- user could have seen it and not something they can act on. Explaining a
-- discrepancy only the plugin can see is noise. The rule itself still matters
-- and still has its evidence: see ExportPresets.effectiveSize.
--
-- @param preset     an entry from ExportPresets.list(), or nil
-- @param available  id -> title from ExportPresets.watermarks()
function SettingsDialog.presetSummary(preset, available)
  if not preset then
    return "Uploads are JPEG, sRGB, 2048 px on the long edge, sharpened for"
      .. " screen, and not watermarked."
  end

  local size = ExportPresets.effectiveSize(preset.value)
  local text = "This preset exports at " .. tostring(size.text)

  -- The default line above ends on the watermark, so this one does too --
  -- the watermark is most of why anyone chose a preset. Absent when it
  -- cannot be stated truthfully; see ExportPresets.watermarkText.
  local watermark = ExportPresets.watermarkText(preset.value, available)
  if watermark then
    text = text .. ", " .. watermark
  end

  return text .. "."
end

--- Why the chosen preset's watermark will not draw, or "".
--
-- Answered here, at the moment of choosing, because this is the only place
-- the user can act on it: the fix is to re-point the preset in Lightroom. A
-- render-time warning also goes to the log (see RenderPhoto.chosenPreset) for
-- working out afterwards why an upload came out unwatermarked, but an upload
-- status line scrolls past and cannot be fixed from there.
--
-- @param preset     an entry from ExportPresets.list(), or nil
-- @param available  id -> title from ExportPresets.watermarks()
function SettingsDialog.presetWarning(preset, available)
  if not preset then return "" end

  local problem = ExportPresets.watermarkProblem(preset.value, available)
  if not problem then return "" end

  return "Warning: " .. problem .. "."
end

--------------------------------------------------------------------------------
-- Account tab
--------------------------------------------------------------------------------

--- Describe the freshness of the stored token in plain language.
local function tokenStatusText()
  -- Signed in through the browser, the JWT's age is bookkeeping rather than
  -- news: it is refreshed silently whenever it runs out, so telling someone
  -- it expires in six hours invites them to do something about it when there
  -- is nothing to do.
  if InatAuth.isSignedIn() then
    return "Signed in to iNaturalist. Pinned keeps itself signed in."
  end

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

local function accountTab(f, props, actions)
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
        height_in_lines = 3,
      },

      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      -- Browser sign-in leads, because it is the one that ends the daily
      -- ritual. The pasted token stays below it rather than being removed:
      -- it needs no registered application, so it is what still works if
      -- LrDigest turns out to be missing, if the application is ever
      -- suspended, or if someone simply does not want to authorize anything.
      f:static_text {
        title = "Option 1: Sign in with iNaturalist",
        font  = "<system/bold>",
      },
      f:static_text {
        title = "Opens iNaturalist in your browser to sign in once, then keeps\n"
          .. "itself topped up so you are never asked again. Your password\n"
          .. "stays with iNaturalist -- the plugin never sees it.",
        width           = 500,
        height_in_lines = 3,
      },
      f:row {
        f:static_text { title = "", width = LABEL },
        f:push_button {
          title   = "Sign In with iNaturalist",
          action  = actions.signIn,
          enabled = LrView.bind {
            key       = "signedIn",
            transform = function(value) return not value end,
          },
        },
        f:push_button {
          title   = "Sign Out",
          action  = actions.signOut,
          enabled = LrView.bind("signedIn"),
        },
      },
      f:static_text {
        title = "Signing out forgets the token here. To withdraw access\n"
          .. "altogether, remove it under Account Settings > Applications\n"
          .. "on iNaturalist.",
        width           = 500,
        height_in_lines = 3,
      },

      f:spacer { height = 10 },
      f:separator { fill_horizontal = 1 },
      f:spacer { height = 6 },

      f:static_text { title = "Option 2: Paste an API token", font = "<system/bold>" },
      f:static_text {
        title = "Sign in to iNaturalist, open the token page, and paste the "
          .. "result below.\nThis works without authorizing an application, "
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
        f:password_field {
          value     = LrView.bind("api_token"),
          width     = 380,
          immediate = true,
          -- Disabled rather than hidden while signed in, so the section does
          -- not appear and disappear as the window is used. A pasted token
          -- would be ignored anyway: getToken prefers the OAuth credential.
          enabled   = LrView.bind {
            key       = "signedIn",
            transform = function(value) return not value end,
          },
        },
      },

      -- On this tab rather than in the window's button bar, because they are
      -- the only two things in the dialog that do not take effect the moment
      -- they are changed: a token has to be stored and checked against
      -- iNaturalist, and clearing one is deliberate enough to ask for its own
      -- button. Everything else here saves itself, so the window needs no Save.
      f:row {
        f:static_text { title = "", width = LABEL },
        f:push_button {
          title   = "Save Token",
          action  = actions.saveToken,
          enabled = LrView.bind {
            key       = "signedIn",
            transform = function(value) return not value end,
          },
        },
        f:push_button {
          title  = "Clear Stored Credentials",
          action = actions.clearCredentials,
        },
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Keyword root
--------------------------------------------------------------------------------

--- The picker's first item: picking nothing, rather than picking a keyword.
-- Its value is the empty string, which the observer treats as "no choice made"
-- so that selecting it does not silently empty the field.
SettingsDialog.KEYWORD_ROOT_PICK_PROMPT = "Choose an existing keyword…"

--- The separator between levels of the keyword root path.
-- Lightroom writes a keyword hierarchy this way in its own interface, so a
-- user reading "Nature > iNaturalist" already knows what it means.
SettingsDialog.KEYWORD_ROOT_SEPARATOR = " > "

--- How many keywords the picker is willing to list.
--
-- A backstop rather than the thing that keeps the list short -- the depth
-- below does that. It still matters for a catalog with hundreds of top-level
-- keywords, where a popup that long is unusable and slow to build. Past the
-- cap the edit field is still there and still takes any path.
SettingsDialog.KEYWORD_ROOT_PICK_LIMIT = 500

--- How deep into the keyword tree the picker looks.
--
-- Listing the whole tree made the popup useless: this plugin writes a keyword
-- per taxon under the root, so the picker filled with its own output -- five
-- hundred rows of "iNaturalist > Animalia > Arthropoda > …" covering the
-- screen, none of which anyone would file a taxonomy under.
--
-- Two levels is where the useful answers are. A root is somewhere near the top
-- of a catalog -- "Nature", or "Nature > iNaturalist" -- and anything deeper is
-- quicker to type than to find in a list. The field beside the popup still
-- takes a path of any depth.
SettingsDialog.KEYWORD_ROOT_PICK_DEPTH = 2

--- The catalog's top two levels of keywords, as picker items of full paths.
--
-- Depth-first so children follow their parent, which keeps a tree readable in
-- a flat list. Exposed for testing: walking a catalog needs no dialog.
--
-- Must be called from a task. A keyword is a handle into the catalog rather
-- than a value copied out of it, so getName and getChildren need read access
-- just as getKeywords does -- and the read block needs a task around it.
function SettingsDialog.keywordRootItems(catalog)
  local items = {
    { title = SettingsDialog.KEYWORD_ROOT_PICK_PROMPT, value = "" },
  }

  local function walk(keywords, prefix, depth)
    if depth > SettingsDialog.KEYWORD_ROOT_PICK_DEPTH then return end

    -- Sorting a copy: getChildren hands back the catalog's own ordering, and
    -- the list is read alphabetically whatever order it arrives in.
    --
    -- Every name is read *before* the sort, never from inside the comparator.
    -- table.sort is a C function, getName yields, and Lua 5.1 cannot yield
    -- across a C call: comparing keywords directly raised "Yielding is not
    -- allowed within a C or metamethod call" for every catalog, which the
    -- guard in show() turned into a picker offering nothing but its prompt.
    local sorted = {}
    for _, kw in ipairs(keywords or {}) do
      sorted[#sorted + 1] = { keyword = kw, name = kw:getName() }
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)

    for _, entry in ipairs(sorted) do
      if #items > SettingsDialog.KEYWORD_ROOT_PICK_LIMIT then return end

      local path = prefix == ""
        and entry.name
        or (prefix .. SettingsDialog.KEYWORD_ROOT_SEPARATOR .. entry.name)

      items[#items + 1] = { title = path, value = path }
      -- Asking for children one level past the last one listed would read the
      -- whole taxonomy tree to throw it away, which is the expensive half of
      -- the walk on the catalogs that need this most.
      if depth < SettingsDialog.KEYWORD_ROOT_PICK_DEPTH then
        walk(entry.keyword:getChildren(), path, depth + 1)
      end
    end
  end

  -- One read block around the whole walk rather than one per keyword: it is a
  -- lock, and taking it thousands of times for a tree that is not changing
  -- costs more than holding it once.
  catalog:withReadAccessDo(function()
    walk(catalog:getKeywords(), "", 1)
  end)

  return items
end

--- Make the picker write into the edit field.
--
-- Two controls for one setting: the field takes any path, including one whose
-- keywords do not exist yet, and the popup fills it in from the catalog for
-- the common case of nesting under something already there.
--
-- Apart from the dialog because a modal cannot be opened from a test, and the
-- rule about the prompt row is exactly the kind of thing that breaks quietly.
function SettingsDialog.watchKeywordRootPicker(props)
  props:addObserver("sync_keyword_root_pick", function()
    -- Read back off the table rather than trusting the arguments the observer
    -- was handed: ObservationPanel does the same, for the same reason.
    local picked = props.sync_keyword_root_pick
    -- The prompt row is a choice of nothing. Treating it as a value would
    -- empty the field the moment the popup was reset.
    if picked == nil or picked == "" then return end

    props.sync_keyword_root = picked
    -- Back to the prompt, so picking the same keyword twice still registers as
    -- a change -- Lightroom does not re-notify for a write of the value that
    -- is already there.
    props.sync_keyword_root_pick = ""
  end)
end

--- Keep the preset description in step with the popup, and the stored title
--- in step with the stored id.
--
-- The title is saved alongside the GUID so that a preset which has since been
-- deleted can still be named -- an id on its own tells the user nothing about
-- which preset went missing.
--
-- The list is passed in rather than re-read on every change: reading it walks
-- two folders and parses every file, and nothing on disk can change while a
-- modal dialog is up.
function SettingsDialog.watchExportPresetPicker(props, presets, watermarks)
  local byId = {}
  for _, preset in ipairs(presets or {}) do byId[preset.id] = preset end

  local function refresh()
    local preset = byId[props.render_export_preset]
    props.render_export_preset_title = preset and preset.title or ""
    props.exportPresetSummary = SettingsDialog.presetSummary(preset, watermarks)
    props.exportPresetWarning = SettingsDialog.presetWarning(preset, watermarks)
  end

  refresh()
  props:addObserver("render_export_preset", refresh)
end

local function keywordRootSection(f, props)
  local LABEL = 110

  return f:column {
    spacing = f:label_spacing(),
    fill_horizontal = 1,

    f:static_text { title = "Where the taxonomy keywords go", font = "<system/bold>" },

    f:row {
      f:static_text { title = "Keyword root:", width = LABEL, alignment = "right" },
      f:edit_field {
        value              = LrView.bind("sync_keyword_root"),
        width              = 180,
        immediate          = true,
        placeholder_string = "top level",
      },
      f:popup_menu {
        value = LrView.bind("sync_keyword_root_pick"),
        items = LrView.bind("keywordRootItems"),
        width = 190,
      },
    },

    f:static_text {
      title = "Synced keywords are filed under this, as\n"
        .. "Root > Animalia > Insecta > …  Use > to nest it inside a keyword\n"
        .. "you already have, or clear it to file the kingdoms at the top\n"
        .. "level. Keywords already written stay where they are.",
      width           = 500,
      height_in_lines = 4,
    },
  }
end

--------------------------------------------------------------------------------
-- Observations tab
--------------------------------------------------------------------------------

--- Linking this catalog to iNaturalist, and where the taxonomy lands.
--
-- What an observation *says* is not here: geoprivacy, the project, and whether
-- coordinates travel are all decided at upload time, and they read better
-- beside the file settings they are applied with than beside the catalog-wide
-- jobs below.
local function observationsTab(f, props, actions)
  return f:tab_view_item {
    title      = "Observations",
    identifier = "observations",

    f:column {
      spacing = f:label_spacing(),
      margin  = 10,

      keywordRootSection(f, props),

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
-- Upload tab
--------------------------------------------------------------------------------

--- Everything an upload decides: what the observation says, and what the file
-- carries. One tab because they are answered together, at the same moment, by
-- someone about to send a photo.
local function uploadTab(f, props)
  local LABEL = 110

  return f:tab_view_item {
    title      = "Upload",
    identifier = "upload",

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

      -- No "send the coordinates" checkbox any more: the popup above is the
      -- whole privacy answer. The checkbox's own help text already told
      -- people to use Obscured instead of turning it off -- iNaturalist hides
      -- the spot and still counts the sighting -- so the setting existed to
      -- be talked out of. An observation with no location cannot reach
      -- research grade, which is a poor thing to have behind a tickbox.
      f:static_text {
        title = "Coordinates are sent whenever the photo has them. Obscured\n"
          .. "hides the exact spot but still counts the sighting.",
        width           = 500,
        height_in_lines = 2,
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

      f:static_text { title = "The file that gets sent", font = "<system/bold>" },

      f:row {
        f:static_text { title = "Render with:", width = LABEL, alignment = "right" },
        f:popup_menu {
          value = LrView.bind("render_export_preset"),
          items = LrView.bind("exportPresetItems"),
          width = 320,
        },
      },
      f:static_text {
        title           = LrView.bind("exportPresetSummary"),
        width           = 500,
        height_in_lines = 3,
      },
      -- The Metadata popup and the two Remove checkboxes that used to sit
      -- below are gone; an export preset says all of this better, in the
      -- place the user already edits it. So this line has to carry what they
      -- were for, phrased as what you get rather than what the plugin does.
      f:static_text {
        title = "Make an export preset in Lightroom to add a watermark,\n"
          .. "change the resolution, or choose what metadata travels with\n"
          .. "the file. It shows up here.",
        width           = 500,
        height_in_lines = 3,
      },
      -- Its own control, not the end of the sentence above: a static_text
      -- that overflows its width drops the word that does not fit and says
      -- nothing about having done so, so the warning would be the part that
      -- vanished.
      f:static_text {
        title           = LrView.bind("exportPresetWarning"),
        width           = 500,
        height_in_lines = 2,
      },
      -- Always drawn, empty when there is nothing to say, rather than bound
      -- to `visible`: a bound `visible` was measured NOT hiding a row in the
      -- reverse-sync list -- it binds, the property changes, and the view
      -- keeps drawing -- and a blank two lines is a better outcome than a
      -- leftover warning about a preset the user has already fixed.
      f:static_text {
        title           = LrView.bind("exportPresetNotes"),
        width           = 500,
        height_in_lines = 2,
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------

--- Copy one edited preference off the property table into storage.
-- Tidying belongs here rather than at the call sites so that a value written
-- as it is typed and a value written on close go through the same rules.
function SettingsDialog.applyPreference(props, key)
  local value = props[key]
  if value == nil then return end

  if key == "sync_keyword_root" then
    value = SettingsDialog.normalizeKeywordRoot(value)
  end

  Settings.set(key, value)
end

--- Copy the editable preferences off the property table into storage.
-- Kept apart from the dialog so it can be tested without one.
function SettingsDialog.savePreferences(props)
  for key in pairs(Settings.DEFAULTS) do
    SettingsDialog.applyPreference(props, key)
  end
end

--- Store each preference as it is changed, rather than on the way out.
--
-- What makes the dialog honest: with no Save button there is nothing to
-- promise, and with nothing pending there is nothing a Cancel could undo.
-- A ticked checkbox is already the setting.
--
-- Every key in DEFAULTS gets an observer, including the few nothing on screen
-- binds -- the bookkeeping ones. Writing back a value no control can change
-- costs nothing, and a setting that gains a control later cannot be forgotten
-- here.
function SettingsDialog.watchPreferences(props)
  for key in pairs(Settings.DEFAULTS) do
    props:addObserver(key, function()
      SettingsDialog.applyPreference(props, key)
    end)
  end
end

--- Tidy a typed keyword root into the path the sync will actually build.
--
-- Round-tripped through InatAPI so the stored string and the keywords written
-- from it cannot disagree: stray spaces, a trailing ">", an empty level typed
-- between two separators all vanish here rather than becoming a keyword named
-- " " that nobody can find. An empty result is left empty, which means the top
-- level of the catalog.
function SettingsDialog.normalizeKeywordRoot(value)
  local levels = require("InatAPI").keywordRootPath(tostring(value or ""))
  return table.concat(levels, SettingsDialog.KEYWORD_ROOT_SEPARATOR)
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

--- Store the pasted token, check it, and say what happened.
--
-- Must run in a task: verifying touches the network.
--
-- The field is emptied once the token is stored, whether or not the check that
-- follows succeeds -- what is on screen then matches what is on disk, and the
-- status line above it is the one thing worth reading.
--
-- @return true when a token was stored, false when there was nothing to store
--         or storing failed
function SettingsDialog.commitToken(props)
  local stored, storeErr = SettingsDialog.saveCredentials(props)

  if storeErr then
    LrDialogs.message("Pinned", storeErr, "critical")
    return false
  end

  if not stored then
    LrDialogs.message("Pinned",
      "Paste a token into the field above first.", "info")
    return false
  end

  props.api_token = ""
  props.status    = tokenStatusText()

  -- Verify immediately. Storing a token that does not work is worse than
  -- storing nothing, because the failure surfaces later during an upload.
  local token, tokenErr = InatAuth.getToken(true)
  if not token then
    LrDialogs.message("Pinned",
      "Saved, but authentication failed:\n\n" .. tostring(tokenErr), "critical")
    return true
  end

  local user, userErr = InatAuth.whoami(token)
  if not user then
    LrDialogs.message("Pinned",
      "Saved, but the token was rejected:\n\n" .. tostring(userErr), "critical")
    return true
  end

  logger:info("Credentials verified for " .. tostring(user.login))
  LrDialogs.message("Pinned",
    "Connected as " .. tostring(user.login)
      .. " (" .. tostring(user.observations_count or 0) .. " observations).",
    "info")
  return true
end

--- Forget the stored token, and say so on the tab that did it.
function SettingsDialog.clearCredentials(props)
  InatAuth.clear()
  props.api_token = ""
  props.signedIn  = false
  props.status    = tokenStatusText()
  LrDialogs.message("Pinned", "Stored credentials cleared.", "info")
end

--------------------------------------------------------------------------------
-- Browser sign-in
--------------------------------------------------------------------------------

--- Hand the user to iNaturalist to sign in.
--
-- Returns as soon as the browser is open. The rest happens when iNaturalist
-- redirects back into the plugin, which may be seconds or minutes later and
-- may well be after this window has been closed -- so the dialog is refreshed
-- through a callback rather than by waiting for anything.
function SettingsDialog.signIn(props)
  local ok, err = InatOAuth.startSignIn()

  if not ok then
    LrDialogs.message("Pinned",
      "Could not start signing in.\n\n" .. tostring(err)
        .. "\n\nYou can still paste an API token below.", "critical")
    return false
  end

  props.status = "Waiting for iNaturalist in your browser…"

  -- Refresh this window if it is still open when the redirect lands. The
  -- property table outlives the function context, so touching it later is
  -- safe; the dialog simply may not be on screen to show it.
  InatOAuth.onComplete = function(succeeded)
    if succeeded then
      props.signedIn = true
      props.api_token = ""
    end
    props.status = tokenStatusText()
  end

  LrDialogs.message("Pinned",
    "iNaturalist has been opened in your browser.\n\n"
      .. "Sign in and press Authorize, and Lightroom will pick it up from "
      .. "there. You can close this window.", "info")
  return true
end

--- Forget a browser sign-in.
--
-- Local only, and says so: iNaturalist keeps its own list of authorized
-- applications, and nothing the plugin does from here removes it from that
-- list. Claiming otherwise would be the kind of reassurance that matters and
-- is wrong.
function SettingsDialog.signOut(props)
  InatAuth.clear()
  props.api_token = ""
  props.signedIn  = false
  props.status    = tokenStatusText()
  LrDialogs.message("Pinned",
    "Signed out on this computer.\n\n"
      .. "iNaturalist still lists Pinned under Account Settings > "
      .. "Applications until you remove it there.", "info")
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
    LrDialogs.message("Pinned Sync",
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
    title           = "Pinned Reverse Sync",
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
    LrDialogs.message("Pinned Reverse Sync",
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
    title           = "Pinned Reverse Sync",
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
    -- One reason, verbatim. A count on its own tells the user that something
    -- went wrong and gives them nowhere to go with it; the message at least
    -- names the observation and what the catalog objected to. The rest are in
    -- the log, which is where a list of them belongs.
    local first = failures[1]
    if first and first.message then
      message = message .. string.format("\n\nFirst failure (observation %s):\n%s",
        tostring(first.observation), tostring(first.message))
    end
  end
  LrDialogs.message("Pinned Reverse Sync", message, "info")
end

--------------------------------------------------------------------------------
-- Showing it
--------------------------------------------------------------------------------

--- Build the tab views.
--
-- Exposed so their identifiers can be checked without opening a modal dialog.
-- ui.dll raises "Multiple tab_view_item views with the same identifier" and
-- "tab_view_item needs to have a string or number identifier" -- both are
-- runtime errors that surface only when the dialog is opened, at which point
-- the settings window simply does not appear.
function SettingsDialog.tabs(f, props, actions)
  return {
    accountTab(f, props, actions),
    observationsTab(f, props, actions),
    uploadTab(f, props),
  }
end

--- Open the settings dialog.
--
-- Returns as soon as the task is queued; the dialog itself is modal, so it
-- blocks that task until dismissed.
--
-- @param options  optional table:
--                   tab     identifier of the tab to open on ("account",
--                           "observations", "upload"). Defaults to the first.
--                   notice  a sentence to show above the token status, used
--                           when something else sent the user here -- an
--                           upload or a sync that had no credentials to run
--                           with. Without it the window looks like it opened
--                           by itself.
function SettingsDialog.show(options)
  options = options or {}

  -- Set here rather than inside the task, so that two failed operations in
  -- quick succession cannot both queue a window before either has opened one.
  isShowing = true

  -- A task, not a plain context. The keyword-root picker walks the catalog to
  -- build its list, and catalog:getKeywords refuses outside a task -- Lightroom
  -- reports it as "An internal error has occurred: We can only wait from within
  -- a task", names nothing, and the settings window simply never opens. A menu
  -- item's script does not run in a task, so this has to make one.
  --
  -- The context belongs to the task rather than to a caller that has already
  -- returned, which is the same reason syncAll and reverseSync below post their
  -- own. A modal dialog is fine inside a task; reverseSync already opens one.
  LrFunctionContext.postAsyncTaskWithContext("inat_settings", function(context)
    -- Logged because this task is the only place a failure can be seen from.
    -- Nothing it raises reaches the user, so "did the dialog even try to open"
    -- is otherwise unanswerable.
    logger:trace("Settings: opening")

    -- Kept set for the whole task rather than just around the modal call, so
    -- that anything sent here while it is up -- a sync started from this very
    -- window finding no credentials, say -- reports instead of stacking a
    -- second copy of the window on top of the first. Cleared by the context
    -- so that an error raised below cannot leave it stuck on.
    context:addCleanupHandler(function() isShowing = false end)

    local f     = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)

    props.api_token  = ""
    props.signedIn   = InatAuth.isSignedIn()
    props.status     = options.notice
      and (options.notice .. " " .. tokenStatusText())
      or tokenStatusText()

    -- The picker is a way of typing into the field, not a second setting: it
    -- has no entry in Settings.DEFAULTS, so savePreferences ignores it.
    props.sync_keyword_root_pick = ""

    -- Guarded, because the picker is a convenience and the dialog is not.
    -- Reading the catalog is the only thing here that can fail, and an error
    -- raised inside this task is not shown to anyone -- the first version of
    -- this bug reached users as a menu item that did nothing when clicked.
    -- Losing the popup costs a convenience; losing the dialog costs every
    -- setting in the plugin, including the credentials.
    --
    -- LrTasks.pcall rather than Lua's: the catalog read yields.
    local ok, itemsOrErr =
      LrTasks.pcall(SettingsDialog.keywordRootItems, LrApplication.activeCatalog())
    if ok then
      props.keywordRootItems = itemsOrErr
    else
      logger:warn("Settings: could not list keywords for the picker: "
        .. tostring(itemsOrErr))
      props.keywordRootItems = {
        { title = SettingsDialog.KEYWORD_ROOT_PICK_PROMPT, value = "" },
      }
    end

    for key, value in pairs(Settings.all()) do
      props[key] = value
    end

    -- Guarded for the same reason as the keyword picker: reading two folders
    -- off disk and parsing every file in them is the other thing here that
    -- can fail, and an error raised inside this task is never shown. An
    -- unreadable preset folder must cost the popup, not the dialog.
    local presetsOk, presetsOrErr = pcall(ExportPresets.list)
    local presets = presetsOk and presetsOrErr or {}
    if not presetsOk then
      logger:warn("Settings: could not list export presets: "
        .. tostring(presetsOrErr))
    end

    local watermarksOk, watermarksOrErr = pcall(ExportPresets.watermarks)
    local watermarks = watermarksOk and watermarksOrErr or nil
    if not watermarksOk then
      logger:warn("Settings: could not list watermark presets: "
        .. tostring(watermarksOrErr))
    end

    props.exportPresetItems = SettingsDialog.presetItems(presets)
    props.exportPresetNotes = SettingsDialog.presetNotes(presets)

    -- A preset chosen before it was deleted would otherwise leave the popup
    -- showing a blank row, since nothing in items matches it. Reset to the
    -- plugin defaults, which is what the render path does anyway.
    local stillThere = false
    for _, item in ipairs(props.exportPresetItems) do
      if item.value == props.render_export_preset then stillThere = true end
    end
    if not stillThere then
      logger:warn("Settings: export preset "
        .. tostring(props.render_export_preset_title)
        .. " is no longer available; falling back to the plugin defaults")
      props.render_export_preset = ExportPresets.NONE
      -- Written through directly because the observers that save edits are
      -- not attached yet -- they go on below, after the stored values are in,
      -- so that filling the table is not mistaken for an edit.
      Settings.set("render_export_preset", ExportPresets.NONE)
      Settings.set("render_export_preset_title", "")
    end

    SettingsDialog.watchKeywordRootPicker(props)
    SettingsDialog.watchExportPresetPicker(props, presets, watermarks)

    -- After the values are in, so that filling the table from storage is not
    -- itself mistaken for an edit.
    SettingsDialog.watchPreferences(props)

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

      -- A task because storing the token is followed by a request to
      -- iNaturalist, and a button's action does not run in one.
      saveToken = function()
        LrTasks.startAsyncTask(function()
          SettingsDialog.commitToken(props)
        end)
      end,

      clearCredentials = function()
        SettingsDialog.clearCredentials(props)
      end,

      -- Not a task. Generating the challenge is arithmetic and
      -- openUrlInBrowser does not yield, so there is nothing here to wait for
      -- -- the network part happens later, in the redirect handler's own task.
      signIn = function()
        SettingsDialog.signIn(props)
      end,

      signOut = function()
        SettingsDialog.signOut(props)
      end,
    }

    local contents = f:column {
      bind_to_object = props,
      width = 540,

      f:tab_view {
        -- Set rather than bound: which tab is open is not a setting, and
        -- nothing changes it after the window is up. An identifier the tabs
        -- do not use would simply leave the first one selected.
        value = options.tab,
        unpack(SettingsDialog.tabs(f, props, actions)),
      },
    }

    -- One button, and it only closes the window. Every setting here was
    -- written the moment it was changed, and the credentials have their own
    -- buttons on the Account tab, so there is nothing left for a Save to do --
    -- and nothing a Cancel could take back. "< exclude >" is what
    -- presentModalDialog takes to leave the cancel button off entirely.
    LrDialogs.presentModalDialog {
      title      = "Pinned Settings",
      contents   = contents,
      actionVerb = "Done",
      cancelVerb = "< exclude >",
    }

    -- A backstop, not the saving mechanism. An edit_field that was still being
    -- typed into when the window closed has already reached the property table
    -- -- every field here is immediate -- but writing the lot once more costs
    -- one pass over a handful of keys and cannot leave a stale preference.
    SettingsDialog.savePreferences(props)
  end)
end

return SettingsDialog
