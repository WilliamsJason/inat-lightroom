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
  All and Close are buttons in the contents. Close cannot be
  `closeFloatingDialogsForPlugin` -- that is the only programmatic close the SDK
  has and it is plugin-wide, so it would take the observation panel with it,
  which is not a Close button, it is a trapdoor. What it does instead is send
  the window the same WM_CLOSE its own close box sends, through the Win32 helper
  the panel already needs for its z-order. That is Windows-only, so on anything
  else the button is absent rather than dead and the close box is the way out.

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

--- How far each rank steps right from the one above it.
--
-- The point of the window is that a lineage is a descent, and a flush-left list
-- of eight ranks does not say so -- it reads as eight unrelated facts. One step
-- per level makes the nesting visible at a glance.
--
-- The labels were right-aligned before, which produced a staircase by accident:
-- "Kingdom" and "Subclass" are different lengths, so the column of names was
-- straight and the column of labels was ragged, and the raggedness carried no
-- meaning. It read as centring. Now the labels are left-aligned, so every step
-- in the staircase is a real step down the tree.
--
-- A spacer rather than spaces in the label text, for two reasons: the label
-- column is a fixed width, so padding "Subspecies" with eight spaces would
-- simply truncate it; and nothing indented this way can leak into the
-- clipboard, which is what the Copy buttons promise.
local INDENT_WIDTH = 10

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

--- Roughly what the Close button takes from the status line beside it.
--
-- The status line is given an explicit width because `static_text` with a bound
-- title measures itself against whatever it happens to hold at build time --
-- "" -- and would otherwise be a few pixels wide forever. Adding a button to
-- the row without taking the room back would push the window wider than the
-- lineage needs.
local CLOSE_WIDTH = 70

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
    -- The deeper the rank, the further right, and the name column gives back
    -- exactly what the indent takes -- so the Copy buttons stay in one straight
    -- column no matter how deep the lineage runs. A staircase of buttons would
    -- be the same accident the right-aligned labels were.
    local indent = (index - 1) * INDENT_WIDTH

    column[#column + 1] = f:row {
      spacing = f:label_spacing(),

      f:spacer { width = indent },

      f:static_text {
        title      = row.label .. ":",
        width      = LABEL_WIDTH,
        alignment  = "left",
        truncation = "tail",
      },

      f:static_text {
        title      = row.text,
        tooltip    = row.text,
        width      = NAME_WIDTH - indent,
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
  --
  -- Close is beside it because a window of this shape reads as a dialog and a
  -- dialog is expected to have one. The close box in the title bar still works
  -- and does the same thing -- literally, it is the same WM_CLOSE -- but the
  -- button is where people look. It is absent rather than dead where the
  -- helper behind it cannot run, which today means anywhere but Windows.
  column[#column + 1] = f:row {
    spacing = f:label_spacing(),

    f:push_button {
      title  = "Copy All",
      action = actions.copyAll,
    },

    actions.close and f:push_button {
      title  = "Close",
      action = actions.close,
    } or f:spacer { width = 0 },

    f:static_text {
      title           = LrView.bind("status"),
      width           = LABEL_WIDTH + NAME_WIDTH -
                          (actions.close and CLOSE_WIDTH or 0),
      truncation      = "tail",
      height_in_lines = 1,
    },
  }

  -- The window hugs its contents, so without this the button row sits on the
  -- frame. Everything else has a row below it to breathe against; this one has
  -- the bottom of the window.
  column[#column + 1] = f:spacer { height = 6 }

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

  local WindowFix = require "WindowFix"

  local title = "Pinned - Taxonomy"
  if heading and heading ~= "" then title = title .. ": " .. heading end

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

  -- Only offered where it can work. The helper is Win32; the title-bar close
  -- box does the same job everywhere, and a button that silently does nothing
  -- would be worse than no button.
  if WindowFix.applicable() then
    actions.close = function()
      LrTasks.startAsyncTask(function()
        if not WindowFix.close(title) then
          props.status = "Could not close the window. Use the close box."
        end
      end)
    end
  end

  local contents = TaxonomyDialog.contents(f, props, rows, actions)
  -- Same fix-up the panel needs, for the same reason: Lightroom makes every
  -- window it creates this way topmost and ownerless, so without this a
  -- taxonomy window floats over every other application and does not minimise
  -- with Lightroom. Started before the window exists because the helper polls
  -- for the title, and because the call below does not return until the window
  -- has closed.
  LrTasks.startAsyncTask(function()
    WindowFix.apply(title)
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
