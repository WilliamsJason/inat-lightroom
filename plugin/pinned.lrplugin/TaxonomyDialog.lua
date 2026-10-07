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

  Floating rather than modal, and that was a bug report rather than a
  preference. Modal windows stack: open a second one and only the top is
  selectable, so the first is stuck on screen underneath, unreadable and
  unmovable, until the top one is dismissed. There is no way to close a modal
  from code either, so "one at a time" could not even be enforced. Floating
  windows are independent -- each can be raised, dragged and closed on its own
  -- which turns the stack from a defect into the feature it looked like: two
  lineages side by side is how anyone decides between two suggestions.

  The cost is that a floating window has no action buttons of its own, so Copy
  All is a button in the contents, and closing is the window's own close box.
  `closeFloatingDialogsForPlugin` is the only programmatic close and it is
  plugin-wide -- it would take the observation panel with it, which is not a
  Close button, it is a trapdoor.

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

  -- Copy All is a button in the contents because a floating window has no
  -- action bar to put it in. It reports in the status line below, and unlike
  -- the modal version it can: the window is still there to read it.
  column[#column + 1] = f:row {
    spacing = f:label_spacing(),

    f:push_button {
      title  = "Copy All",
      action = actions.copyAll,
    },

    f:static_text {
      title           = LrView.bind("status"),
      width           = LABEL_WIDTH + NAME_WIDTH,
      truncation      = "tail",
      height_in_lines = 1,
    },
  }

  return f:column(column)
end

--- The window id for one taxon's lineage.
--
-- Keyed on the taxon so asking twice about the same species raises the window
-- that is already open rather than laying an identical one on top of it, while
-- two different species get two windows -- which is the entire point of making
-- these floating.
function TaxonomyDialog.windowId(rows)
  local leaf = rows and rows[#rows]
  local key  = leaf and (leaf.id or leaf.name) or "none"

  return "com.williamsjason.pinned.taxonomy." .. tostring(key)
end

--- Show the taxonomy for one taxon.
--
-- @param context  A live LrFunctionContext; the property table is tied to it.
-- @param rows     Taxonomy rows from PanelCore.taxonomyRows.
-- @param heading  What the lineage is of, for the window title.
--
-- MUST be called from inside a task, and the task MUST be one the caller can
-- spare: `blockTask` holds it until the window closes. That is not optional --
-- the property table every binding here reads lives in `context`, and without
-- blockTask the task ends, the context dies, and the window is left bound to a
-- dead object (docs/lightroom-sdk-notes.md).
--
-- No `save_frame`. Every one of these would share one remembered rectangle, so
-- a second window would open exactly on top of the first and the stacking this
-- was written to fix would be back -- with the added insult of being the
-- position the user had chosen. Letting Lightroom place them is the lesser
-- evil while there is no way to offset a window from code.
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

    copyAll = function()
      LrTasks.startAsyncTask(function()
        TaxonomyDialog.copy(props, PanelCore.taxonomyText(rows), "the taxonomy")
      end)
    end,
  }

  local contents = TaxonomyDialog.contents(f, props, rows, actions)

  local title = "Pinned - Taxonomy"
  if heading and heading ~= "" then title = title .. ": " .. heading end

  -- Same fix-up the panel needs, for the same reason: Lightroom makes every
  -- window it creates this way topmost and ownerless, so without this a
  -- taxonomy window floats over every other application and does not minimise
  -- with Lightroom. Started before the window exists because the helper polls
  -- for the title, and because the call below does not return until the window
  -- has closed.
  LrTasks.startAsyncTask(function()
    require("WindowFix").apply(title)
  end)

  LrDialogs.presentFloatingDialog(_PLUGIN, {
    title     = title,
    contents  = contents,
    id        = TaxonomyDialog.windowId(rows),
    closable  = true,
    blockTask = true,
  })

  return true
end

return TaxonomyDialog
