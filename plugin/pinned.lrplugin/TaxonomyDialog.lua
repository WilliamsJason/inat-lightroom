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

  Two windows, or one that keeps up. Opening a second window for a second
  suggestion is the point above, and it is the right answer for anyone
  comparing two lineages -- but it is the wrong answer for anyone who wants one
  window left open beside the panel, because it means pressing the button again
  for every guess and closing what the last press left behind. So which one
  happens is a preference ("Allow multiple Taxonomy windows", Settings ▸
  Observations), and the default is the single window: it is the one that
  cannot end the session with eleven windows open.

  The single window is a different build of the same contents, and it has to
  be. A presented view tree cannot grow or lose rows, so a window that outlives
  the lineage it was opened for cannot be a row per rank -- it is a fixed
  SLOTS-deep ladder of rows whose labels and names are bound, and refreshing it
  is writing to those properties. That costs blank rows below a short lineage,
  which is the price of the window not moving, not flickering and not stealing
  focus every time a suggestion is clicked. The per-taxon windows keep their
  built-to-fit shape, so nobody who wanted that loses it.

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
local Settings  = require "Settings"

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

--- How many rank rows the single window is built with.
--
-- A presented view tree cannot grow, so the window that stays open has to be
-- built once for the deepest lineage it will ever be asked to show, and the
-- rows past the end of a shorter one are left empty. Sixteen covers everything
-- iNaturalist has handed this plugin -- a subspecies of an insect, which is
-- where the sub- and infra- ranks pile up, runs to about fourteen -- without
-- making the window a screen tall for the eight-rung lineages that are
-- ordinary.
--
-- Anything deeper is trimmed from the top rather than the bottom: the finest
-- ranks are what the user asked about and what the heading names, and a
-- lineage missing its kingdom still reads as a lineage, while one missing its
-- species does not.
TaxonomyDialog.SLOTS = 16

--- The single window's title, id and remembered frame.
--
-- The title cannot carry the taxon the way the per-taxon windows' does: it is
-- fixed when the window is built, and this one outlives any one taxon. It is
-- also what the Win32 helpers find the window by, so a changing title would be
-- a window they could no longer close or raise. The taxon is named in a bound
-- heading inside the window instead.
--
-- `save_frame` is safe here and is not on the per-taxon windows, for the same
-- reason: there is only ever one of these, so there is no second window to
-- open exactly on top of the first.
TaxonomyDialog.SINGLE_TITLE = "Pinned - Taxonomy"
TaxonomyDialog.SINGLE_ID    = "com.williamsjason.pinned.taxonomy.single"
TaxonomyDialog.SINGLE_FRAME = "inat_taxonomy_single"

--- The single window while it is on screen, or nil.
--
-- Module state rather than something passed around, because the two callers
-- cannot hand it to each other: the panel's observer fires on a photo's
-- taxonomy changing and knows nothing about windows, and the button that
-- opened the window is in a different task from the one blocked in presenting
-- it. Cleared when the window closes, so that the next press builds a new one
-- rather than writing into a property table nothing is drawing.
TaxonomyDialog.single = nil

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

--------------------------------------------------------------------------------
-- The window that stays open
--------------------------------------------------------------------------------

--- The rows the single window can actually show, deepest kept.
--
-- A lineage longer than the ladder is trimmed from the kingdom end, because
-- the rungs nearest the leaf are the ones the user asked about. Trimming from
-- the other end would drop the species and leave the window describing
-- something nobody chose.
function TaxonomyDialog.visibleRows(rows)
  rows = rows or {}

  local extra = #rows - TaxonomyDialog.SLOTS
  if extra <= 0 then return rows end

  local kept = {}
  for index = extra + 1, #rows do
    kept[#kept + 1] = rows[index]
  end

  return kept
end

--- Point the single window at a lineage.
--
-- Every slot is written on every refresh, including the empty ones, because a
-- shorter lineage replacing a longer one has to clear the rows it does not
-- reach -- otherwise the tail of the previous taxon stays on screen below the
-- new one and reads as part of it.
--
-- `rows` is kept on the property table rather than closed over, so the Copy
-- buttons built once at the top of this file act on whatever the window is
-- showing now rather than on what it was opened with.
--
-- @return the rows actually shown.
function TaxonomyDialog.fill(props, rows, heading)
  local shown = TaxonomyDialog.visibleRows(rows)
  local leaf  = shown[#shown]

  props.rows = shown

  if heading == nil or heading == "" then
    heading = leaf and leaf.name or ""
  end
  props.heading = heading

  for slot = 1, TaxonomyDialog.SLOTS do
    local row = shown[slot]

    props["rowUsed"  .. slot] = row ~= nil
    props["rowLabel" .. slot] = row and (row.label .. ":") or ""
    props["rowText"  .. slot] = row and row.text or ""
    props["rowCopy"  .. slot] = row and "Copy" or ""
  end

  return shown
end

--- The single window's contents: a fixed ladder of bound rows.
--
-- The same shape as `contents` above, built from properties instead of from a
-- lineage. The indent is still per position rather than bound, because
-- position is the one thing about a slot that cannot change: slot 3 is always
-- the third rung shown, whatever it holds.
--
-- An unused slot is emptied three ways on purpose. Its label, name and button
-- titles go to "" so nothing of the last taxon is left behind; `enabled` goes
-- false so a stray click on an empty row copies nothing; and `visible` is
-- bound as well because it costs nothing and might work -- it was measured not
-- *collapsing* a row (docs/lightroom-sdk-notes.md), and whether it hides the
-- control was never established. If it does, an empty row is genuinely empty;
-- if it does not, it is a blank disabled button, which is what it would have
-- been anyway.
function TaxonomyDialog.slotContents(f, props, actions)
  local column = {
    bind_to_object = props,
    spacing        = f:label_spacing(),
  }

  -- What the per-taxon windows put in the title bar. This one's title bar is
  -- fixed -- it is how the Win32 helpers find the window -- so the taxon is
  -- named here instead, where it can change with the lineage below it.
  column[#column + 1] = f:static_text {
    title      = LrView.bind("heading"),
    font       = "<system/bold>",
    width      = LABEL_WIDTH + NAME_WIDTH,
    truncation = "tail",
  }

  column[#column + 1] = f:separator { fill_horizontal = 1 }

  for slot = 1, TaxonomyDialog.SLOTS do
    local indent = (slot - 1) * INDENT_WIDTH
    local used   = "rowUsed" .. slot
    local text   = "rowText" .. slot

    column[#column + 1] = f:row {
      spacing = f:label_spacing(),

      f:spacer { width = indent },

      f:static_text {
        title      = LrView.bind("rowLabel" .. slot),
        width      = LABEL_WIDTH,
        alignment  = "left",
        truncation = "tail",
      },

      f:static_text {
        title      = LrView.bind(text),
        tooltip    = LrView.bind(text),
        width      = NAME_WIDTH - indent,
        truncation = "tail",
      },

      f:push_button {
        title   = LrView.bind("rowCopy" .. slot),
        enabled = LrView.bind(used),
        visible = LrView.bind(used),
        action  = function() actions.copyRow(slot) end,
      },
    }
  end

  column[#column + 1] = f:separator { fill_horizontal = 1 }

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

  column[#column + 1] = f:spacer { height = 6 }

  return f:column(column)
end

--- Build the single window and register it, without presenting it.
--
-- Split from `showSingle` for the same reason `contents` is split from `show`:
-- presenting blocks the task until the window closes, so a test that called
-- the whole thing could never look at what it built. It is also what makes the
-- module state observable -- `showSingle` clears it on the line after the
-- window closes, which in a harness that does not block is the line after it
-- opens.
--
-- @param context  A live LrFunctionContext; it MUST outlive the window.
-- @return the window state: { props, contents, actions }.
function TaxonomyDialog.singleWindow(context, rows, heading)
  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  props.status = ""
  TaxonomyDialog.fill(props, rows, heading)

  local WindowFix = require "WindowFix"

  local actions = {
    copyRow = function(slot)
      local row = (props.rows or {})[slot]
      if not row then return end

      LrTasks.startAsyncTask(function()
        TaxonomyDialog.copy(props, row.text, row.label:lower())
      end)
    end,

    copyAll = function()
      LrTasks.startAsyncTask(function()
        TaxonomyDialog.copy(props, PanelCore.taxonomyText(props.rows),
          "the taxonomy")
      end)
    end,
  }

  if WindowFix.applicable() then
    actions.close = function()
      LrTasks.startAsyncTask(function()
        if not WindowFix.close(TaxonomyDialog.SINGLE_TITLE) then
          props.status = "Could not close the window. Use the close box."
        end
      end)
    end
  end

  local state = {
    props   = props,
    actions = actions,
  }
  state.contents = TaxonomyDialog.slotContents(f, props, actions)

  TaxonomyDialog.single = state

  return state
end

--- Show the one taxonomy window, or point the open one at this lineage.
--
-- A second press is not a second window: the one already up is refilled and
-- raised. Raising is a Win32 call like the rest of the window handling here,
-- so where it cannot run the window is still correct, just not brought to the
-- front -- which is a worse answer than Windows gets and a much better one
-- than a window that silently ignores the button.
--
-- MUST be called from inside a task with a context that can be held: the call
-- below does not return until the window closes.
function TaxonomyDialog.showSingle(context, rows, heading)
  rows = rows or {}
  if #rows == 0 then return false end

  local WindowFix = require "WindowFix"
  local live      = TaxonomyDialog.single

  if live then
    TaxonomyDialog.fill(live.props, rows, heading)

    LrTasks.startAsyncTask(function()
      WindowFix.raise(TaxonomyDialog.SINGLE_TITLE)
    end)

    return true
  end

  local state = TaxonomyDialog.singleWindow(context, rows, heading)

  LrTasks.startAsyncTask(function()
    WindowFix.apply(TaxonomyDialog.SINGLE_TITLE)
  end)

  LrDialogs.presentFloatingDialog(_PLUGIN, {
    title      = TaxonomyDialog.SINGLE_TITLE,
    contents   = state.contents,
    id         = TaxonomyDialog.SINGLE_ID,
    save_frame = TaxonomyDialog.SINGLE_FRAME,
    closable   = true,
    blockTask  = true,

    -- The earliest moment there is. Also cleared below, because a window state
    -- left behind is a refresh writing into a property table nothing draws,
    -- and the next press would raise a window that is not there.
    windowWillClose = function()
      if TaxonomyDialog.single == state then TaxonomyDialog.single = nil end
    end,
  })

  if TaxonomyDialog.single == state then TaxonomyDialog.single = nil end

  return true
end

--- Point the open single window at a new lineage, if there is one.
--
-- The panel calls this whenever the taxonomy it holds changes, which is how a
-- window left open follows the species guess without the button being pressed
-- again. Three things it deliberately does not do:
--
--   * nothing, when no single window is open. There is no window to fill and
--     opening one uninvited would make choosing a suggestion pop up a window.
--   * nothing, for an empty lineage. The panel clears its taxonomy between one
--     suggestion and the next, and while a typed name is unresolved; blanking
--     the window at each of those moments would make it flicker through empty
--     and leave it empty whenever the guess is not a name iNaturalist knows.
--     The last good lineage stays until there is a better one.
--   * it does not raise the window. A refresh is something the user did not
--     ask for; stealing focus from the panel they are clicking in would be.
function TaxonomyDialog.refresh(rows, heading)
  local live = TaxonomyDialog.single
  if not live then return false end

  rows = rows or {}
  if #rows == 0 then return false end

  TaxonomyDialog.fill(live.props, rows, heading)

  return true
end

--- Show a lineage, in whichever kind of window the user has asked for.
--
-- The only entry point callers should use. Which one it is is a preference
-- rather than a guess, because both answers are right for somebody: one window
-- left open beside the panel, or a window per taxon for comparing two.
function TaxonomyDialog.present(context, rows, heading)
  if Settings.get("taxonomy_multiple_windows") then
    return TaxonomyDialog.show(context, rows, heading)
  end

  return TaxonomyDialog.showSingle(context, rows, heading)
end

return TaxonomyDialog
