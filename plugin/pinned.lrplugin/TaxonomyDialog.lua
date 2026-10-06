--[[
  TaxonomyDialog.lua
  ------------------
  The full taxonomic tree for a chosen suggestion, one rank per row, each with
  its own Copy button.

  This is a dialog rather than a part of the floating panel, and that is the
  whole design decision. The panel's view tree is fixed once presented and a
  bound `visible` does not hide a row (docs/lightroom-sdk-notes.md), so a
  collapsible taxonomy inside the panel is not a thing the SDK can build: the
  rows would stand at full height whether "collapsed" or not, and a kingdom-to-
  subspecies lineage is eight rows of permanent panel. A dialog is built fresh
  every time it opens, so it can be exactly as tall as the lineage it was handed
  and cost the panel nothing.

  Per-row Copy buttons rather than selectable text, for the reason Clipboard.lua
  exists: `selectable = true` really does make a `static_text` copyable, and it
  takes the row's `mouse_down` with it. Here there is no click to lose, so the
  trade would be available -- but a selectable row still leaves the user
  dragging across a label to get a name, and the feature request was for fields
  that are copy/pastable, not fields that can be selected if you aim carefully.

  Nothing here talks to the API. The lineage arrives already fetched, because
  the caller is the only one that knows whether it is allowed to block.
--]]

local LrBinding  = import "LrBinding"
local LrDialogs  = import "LrDialogs"
local LrTasks    = import "LrTasks"
local LrView     = import "LrView"

local Clipboard = require "Clipboard"
local PanelCore = require "PanelCore"

local TaxonomyDialog = {}

--- Width of the rank label column. Wide enough for "Superfamily", which is the
-- longest label a lineage the plugin shows has produced.
local LABEL_WIDTH = 90

--- Width of the name column.
--
-- Generous on purpose, and affordable in a way the panel's 480 is not: this
-- window exists for as long as somebody is reading it, so its width is not
-- permanent furniture. A scientific name plus a list of common names is the
-- long case -- iNaturalist hands whole families things like "Herb-Paris, False
-- Hellebores, Trilliums and allies" -- and `truncation` with a tooltip is the
-- backstop, exactly as in the suggestion list. The Copy button is the real
-- backstop: what the button copies is the untruncated text, so a name too long
-- to read is still a name you can paste.
local NAME_WIDTH = 420

--- Put one piece of text on the clipboard and say so.
--
-- MUST be called from inside a task: the copy shells out.
--
-- Reports into the dialog's own status line rather than a modal, for the reason
-- the panel does: a dialog on top of a dialog to acknowledge a copy is worse
-- than the copy was good.
function TaxonomyDialog.copy(props, text, what)
  if not text or text == "" then
    props.status = "Nothing to copy."
    return false
  end

  if not Clipboard.copy(text) then
    props.status = "Could not copy " .. what .. "."
    return false
  end

  props.status = "Copied " .. what .. "."
  return true
end

--- Build the dialog's contents for a set of taxonomy rows.
--
-- Split out from `show` so the harness can look at the view tree without
-- presenting anything.
function TaxonomyDialog.contents(f, props, rows, actions)
  local column = {
    bind_to_object = props,
    spacing        = f:label_spacing(),
  }

  for index, row in ipairs(rows) do
    column[#column + 1] = f:row {
      spacing = f:label_spacing(),

      f:static_text {
        title     = row.label .. ":",
        width     = LABEL_WIDTH,
        alignment = "right",
      },

      f:static_text {
        title      = row.text,
        tooltip    = row.text,
        width      = NAME_WIDTH,
        truncation = "tail",
      },

      f:push_button {
        title  = "Copy",
        action = function() actions.copyRow(index) end,
      },
    }
  end

  column[#column + 1] = f:separator { fill_horizontal = 1 }

  column[#column + 1] = f:static_text {
    title           = LrView.bind("status"),
    fill_horizontal = 1,
    height_in_lines = 1,
  }

  return f:column(column)
end

--- Show the taxonomy for one taxon.
--
-- @param context  A live LrFunctionContext; the property table is tied to it.
-- @param rows     Taxonomy rows from PanelCore.taxonomyRows.
-- @param heading  What the lineage is of, for the window title.
--
-- MUST be called from inside a task. The dialog's buttons copy, copying shells
-- out, and `LrTasks.execute` blocks -- the same reason the panel's own Copy
-- runs on a task. Buttons inside a presented modal really do get to start
-- tasks; the Reverse Sync review dialog pages itself that way.
--
-- The dialog's action button is Copy All rather than OK, because there is
-- nothing here to accept. Its result is deliberately ignored: a dialog whose
-- every button is a copy has no outcome the caller needs to know about.
function TaxonomyDialog.show(context, rows, heading)
  rows = rows or {}
  if #rows == 0 then return false end

  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)
  props.status = ""

  local actions = {
    copyRow = function(index)
      local row = rows[index]
      if not row then return end

      LrTasks.startAsyncTask(function()
        TaxonomyDialog.copy(props, row.text, row.label:lower())
      end)
    end,
  }

  local contents = TaxonomyDialog.contents(f, props, rows, actions)

  local title = "Pinned - Taxonomy"
  if heading and heading ~= "" then title = title .. ": " .. heading end

  local result = LrDialogs.presentModalDialog {
    title      = title,
    contents   = contents,
    actionVerb = "Copy All",
    cancelVerb = "Close",
  }

  -- Copy All is handled after the dialog closes rather than from inside it,
  -- because the action button dismisses the window whatever its handler does
  -- and a status line nobody can still see is not a report.
  if result == "ok" then
    TaxonomyDialog.copy(props, PanelCore.taxonomyText(rows), "the taxonomy")
    return true
  end

  return false
end

return TaxonomyDialog
