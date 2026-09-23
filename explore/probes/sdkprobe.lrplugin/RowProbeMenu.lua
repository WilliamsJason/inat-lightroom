--[[
  RowProbeMenu.lua
  ----------------
  Why does the Observation panel's suggestion list lose the end of a name, and
  which of the possible fixes does the host actually support?

  The panel builds ten rows of `f:static_text` with **empty** titles and points
  each one at a binding, because the window outlives any photo selection and a
  presented view tree cannot grow rows. That combination -- sized before it has
  any text, filled afterwards -- is where the surprises live. `ui.dll` says only
  that the keys exist: `AgViewWinStaticText` reads `selectable`,
  `height_in_lines` and `resize_to_fit_text_height`, and `scroll_view` reads
  `vertical_scroller` and `horizontal_scroller`. Which of them *do* anything
  here is what this measures.

  Everything about the probe windows mirrors the panel on purpose, because a
  probe that measures an easier case than the feature answers a question nobody
  asked: floating windows rather than modals, titles bound to a property table,
  built empty and filled only once the window is already on screen, and the
  string shapes `PanelCore.describeSuggestion` actually produces -- including
  the `- <note>` tail ("family, containing <name>") that is the longest thing
  the panel can build.

  **Four short windows, shown one after another, rather than one tall one.**
  The first cut put every variant in a single window, which came out taller
  than the screen: the last block was below the bottom edge, the title bar was
  out of reach, and the questionnaire behind it could not be got to at all. A
  probe nobody can finish measures nothing. Hence:

    * each window holds a few blocks and stays short;
    * the button that advances is at the **top** of the window, so it is
      reachable even if the bottom is not, and it closes the window through
      LrDialogs.closeFloatingDialogsForPlugin rather than relying on a title
      bar the user may not be able to click;
    * the questionnaire is inside a scrolled_view, so it cannot outgrow the
      screen either, however many questions it grows.

  Whether a floating window can be moved or resized **is itself one of the
  measurements**, and it is measured by comparison rather than by opinion.
  `presentFloatingDialog`'s own key list in ui.dll reads

      onShow save_frame blockTask background_color closable maximizable
      minimizable borderless skin margin position canBecomeKeyWindow
      is_non_modal_sdk_window acceptsFirstResponder title auto_layout ...

  -- `resizable` is **not** in it, though `AgViewWin32Window` one chunk away
  does read `resizable` with `horizontally` and `vertically` beside it. So the
  window keys may simply be dropped on the way through. Three of the four
  windows below are therefore built differently on purpose: one asks for
  everything, one asks for nothing, one asks for `resizable = "horizontally"`.
  Whatever the answers are, the difference between them is the finding.

  That matters beyond this probe. If a floating dialog cannot be resized at
  all, then the panel can never be made wider either, and "let the name column
  grow with the window" is dead as a fix rather than merely unproven.

  Nothing in the SDK reports layout back -- there is no way to ask a view how
  wide it ended up or how many lines it drew -- so the last word is the user's,
  in the questionnaire at the end. Same trick as the scrolled-view probe's
  "press Escape when it is usable": when the host will not say, measure against
  the person watching. The one thing that is *not* left to impression is
  whether a click still lands: every name carries the same `mouse_down`, and
  the counts per variant are reported as numbers.
--]]

local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local Report = require "Report"

--- The width the panel gives a suggestion name today.
local NAME_WIDTH = 330

--- The link column beside each name, also as the panel has it.
local LINK_WIDTH = 60

--- What the panel shows: PanelCore.SUGGESTION_LIMIT rows.
local PANEL_ROWS = 10

--- Suggestion titles in the shapes `PanelCore.describeSuggestion` builds.
--
-- It appends `- <score>%` to a scored row and `- <note>` to a coarse one, and
-- the notes are much the longer of the two. So the longest strings the panel
-- can produce belong to the rows whose tail carries the reason to pick them,
-- which is what makes losing the tail expensive rather than untidy.
--
-- The first version of this string ended "and 8 others", which the formatter
-- cannot emit: `coarserRows` builds the note as `<rank>, ` plus one of
-- `agreed by top suggestions`, `containing <name>`, or `from the top
-- suggestion`. An invented sample measures an invented problem, and this one
-- was 30 characters short of what the panel really draws -- a width that
-- passed against it would have shipped too narrow. Taken now from
-- explore/measure_suggestion_widths.py, which runs real taxa through the real
-- formatter; this is the longest of 2,400.
--
-- The chosen-row mark is included because it is part of what has to fit.
local LONGEST = "\226\151\143 Herb-Paris, False Hellebores, Trilliums and "
  .. "allies (Melanthiaceae) - family, containing Trillium grandiflorum"

local TITLES = {
  LONGEST,
  "  Ground Beetles (Carabidae) - family, agreed by top suggestions",
  "  Narrow-collared Snail-eating Beetle (Scaphinotus angusticollis) - 28%",
  "  Galerita bicolor - 9%",
}

--- Two rows is enough to read a width against, and every row costs height the
-- first cut did not have to spare. The full-length question is asked properly
-- by the ten-row windows instead of badly by every block at once.
local SAMPLE = { TITLES[1], TITLES[3] }

--- Just the worst case, for the blocks that only ask "does this width hold it".
local WORST = { LONGEST }

local LINK = "View \226\134\145"

--- The widths the fallback fix would have to choose between.
--
-- "Widen NAME_WIDTH" is the fix of last resort, and the only thing anybody
-- needs to know about it is the number. A ladder of one-row blocks costs almost
-- no height and turns that from an argument into a reading.
local LADDER = { 440, 560, 680 }

--- One variant's rows, built empty and bound, exactly as the panel builds its.
--
-- @param f        the view factory
-- @param key      variant letter, which also namespaces its bound properties
-- @param actions  what a name click does, so a variant can prove it is still
--                 clickable rather than only readable
-- @param name     extra keys for the name control -- the thing being varied
-- @param count    how many rows
local function variantRows(f, key, actions, name, count)
  local rows = { spacing = 0 }

  for index = 1, count do
    local nameView = {
      title      = LrView.bind(key .. index),
      tooltip    = LrView.bind(key .. index),
      mouse_down = function() actions.clicked(key) end,
    }
    for k, v in pairs(name) do nameView[k] = v end

    rows[#rows + 1] = f:row {
      spacing         = f:label_spacing(),
      fill_horizontal = 1,

      f:static_text(nameView),

      f:static_text {
        title = LrView.bind(key .. "link" .. index),
        width = LINK_WIDTH,
      },
    }
  end

  return f:column(rows)
end

--- A labelled block: what is being varied, then the rows varying it.
local function block(f, spec, actions)
  local rows = variantRows(f, spec.key, actions, spec.name, #spec.titles)

  return f:group_box {
    show_title      = false,
    fill_horizontal = 1,

    f:static_text {
      title = spec.key .. ".  " .. spec.caption,
      font  = "<system/bold>",
    },
    spec.scrolled and f:scrolled_view {
      -- Deliberately smaller than its contents in both directions, so whichever
      -- scrollers the host is willing to draw have a reason to appear.
      width               = 260,
      height              = 70,
      horizontal_scroller = true,
      vertical_scroller   = true,
      rows,
    } or rows,
  }
end

--------------------------------------------------------------------------------
-- The variants, grouped into the window each is shown in
--------------------------------------------------------------------------------

--- Window 1: how wide does a name have to be?
--
-- The window that asks to be dragged wider, so it holds the blocks whose answer
-- depends on the window's width and nothing else.
local WIDTHS = {
  {
    key     = "A",
    caption = "width=" .. NAME_WIDTH .. ", truncation=tail  (the panel today)",
    titles  = SAMPLE,
    name    = {
      width           = NAME_WIDTH,
      truncation      = "tail",
      fill_horizontal = 1,
    },
  },
}

for index, width in ipairs(LADDER) do
  WIDTHS[#WIDTHS + 1] = {
    key     = "W" .. index,
    caption = "width=" .. width .. ", truncation=tail",
    titles  = WORST,
    name    = { width = width, truncation = "tail" },
  }
end

--- Window 2: can a name be made to show its whole self where it is?
local SHAPES = {
  {
    key     = "B",
    caption = "width=" .. NAME_WIDTH .. ", height_in_lines=2, no truncation",
    titles  = SAMPLE,
    name    = {
      width           = NAME_WIDTH,
      height_in_lines = 2,
      fill_horizontal = 1,
    },
  },
  {
    key     = "C",
    caption = "width=" .. NAME_WIDTH .. ", height_in_lines=2, truncation=tail",
    titles  = SAMPLE,
    name    = {
      width           = NAME_WIDTH,
      height_in_lines = 2,
      truncation      = "tail",
      fill_horizontal = 1,
    },
  },
  {
    key     = "D",
    caption = "no width, fill_horizontal only",
    titles  = SAMPLE,
    name    = { fill_horizontal = 1, truncation = "tail" },
  },
  {
    key     = "G",
    caption = "selectable=true -- try selecting the text, then click a name",
    titles  = SAMPLE,
    name    = {
      width           = NAME_WIDTH,
      truncation      = "tail",
      selectable      = true,
      fill_horizontal = 1,
    },
  },
  {
    key      = "F",
    caption  = "inside a scrolled_view (260x70, both scrollers asked for)",
    titles   = SAMPLE,
    scrolled = true,
    name     = { width = NAME_WIDTH, truncation = "tail" },
  },
}

--- Windows 3 and 4: does the list fit at all?
--
-- Four rows fit anything, so nothing above can answer this, and it is the
-- question the user's own words asked for. Once as the panel draws them today,
-- once wrapped -- because if wrapping is the fix then it doubles the height of
-- the tallest thing in the window and may create the overflow it was meant to
-- avoid. Each gets a window to itself so that neither is squeezed by the other.
local TALL = {}
for index = 1, PANEL_ROWS do
  TALL[index] = TITLES[((index - 1) % #TITLES) + 1]
end

local FULL_LIST = {
  key     = "H",
  caption = "the panel's row, all " .. PANEL_ROWS .. " of them",
  titles  = TALL,
  name    = {
    width           = NAME_WIDTH,
    truncation      = "tail",
    fill_horizontal = 1,
  },
}

local FULL_LIST_WRAPPED = {
  key     = "I",
  caption = "the same " .. PANEL_ROWS .. " rows at height_in_lines=2",
  titles  = TALL,
  name    = {
    width           = NAME_WIDTH,
    height_in_lines = 2,
    fill_horizontal = 1,
  },
}

--- Every block, in one list, for filling and for reporting click counts.
local ALL = {}
for _, spec in ipairs(WIDTHS) do ALL[#ALL + 1] = spec end
for _, spec in ipairs(SHAPES) do ALL[#ALL + 1] = spec end
ALL[#ALL + 1] = FULL_LIST
ALL[#ALL + 1] = FULL_LIST_WRAPPED

--- Fill or empty every bound title.
--
-- Filling happens only once a window is up, which is the whole point: the
-- panel's rows are measured while empty and receive their text afterwards, and
-- a probe that built its rows with the text already in them would be measuring
-- a case the panel never reaches.
local function setTitles(props, filled)
  for _, spec in ipairs(ALL) do
    for index, title in ipairs(spec.titles) do
      props[spec.key .. index]           = filled and title or ""
      props[spec.key .. "link" .. index] = filled and LINK or ""
    end
  end
end

--------------------------------------------------------------------------------
-- Showing one window
--------------------------------------------------------------------------------

--- Show one window's blocks and wait for it to be dismissed.
--
-- @param specs   the blocks to draw
-- @param step    "2 of 4", for somebody who has no idea how much is left
-- @param lines   what to do while it is up
-- @param window  extra keys handed to presentFloatingDialog -- the thing being
--                varied *about the window itself*
local function showWindow(props, actions, specs, step, lines, window)
  local f = LrView.osFactory()

  local contents = {
    bind_to_object = props,
    spacing        = f:control_spacing(),
    margin         = 12,

    -- At the top, and not only in the title bar. A window that turns out to be
    -- taller than the screen still has its first row on screen, and closing it
    -- from here does not depend on being able to reach a title bar or a corner.
    f:row {
      spacing = f:control_spacing(),
      f:push_button {
        title  = "Done with this window \226\134\146",
        action = function()
          LrDialogs.closeFloatingDialogsForPlugin(_PLUGIN)
        end,
      },
      f:static_text { title = step, font = "<system/bold>" },
      f:static_text { title = LrView.bind("clicked"), fill_horizontal = 1 },
    },
  }

  for _, line in ipairs(lines) do
    contents[#contents + 1] = f:static_text { title = line, fill_horizontal = 1 }
  end

  for _, spec in ipairs(specs) do
    contents[#contents + 1] = block(f, spec, actions)
  end

  contents[#contents + 1] = f:row {
    spacing = f:control_spacing(),
    f:push_button { title = "Fill",  action = function() setTitles(props, true) end },
    f:push_button { title = "Clear", action = function() setTitles(props, false) end },
  }

  local args = {
    title     = "iNat probe: " .. step,
    contents  = f:column(contents),
    blockTask = true,
  }
  for key, value in pairs(window or {}) do args[key] = value end

  -- Filled from a task rather than before showing, because what has to be true
  -- is that the rows were measured before the text existed, and a sleep is the
  -- only thing here that can promise the window was already drawn.
  setTitles(props, false)
  LrTasks.startAsyncTask(function()
    LrTasks.sleep(1.2)
    setTitles(props, true)
  end)

  LrDialogs.presentFloatingDialog(_PLUGIN, args)
end

--------------------------------------------------------------------------------
-- The questionnaire
--------------------------------------------------------------------------------

local YES_NO = {
  { title = "not sure", value = "?"   },
  { title = "yes",      value = "yes" },
  { title = "no",       value = "no"  },
}

local WIDTH_ANSWERS = {
  { title = "not sure",            value = "?"    },
  { title = "330 (it already fits)", value = "330" },
  { title = "440",                 value = "440"  },
  { title = "560",                 value = "560"  },
  { title = "680",                 value = "680"  },
  { title = "none of them",        value = "none" },
}

--- The answers the report is made of.
--
-- One question per thing that could be true, rather than a free text box: a
-- probe whose result is a sentence is a probe whose result gets argued about.
local QUESTIONS = {
  -- The window itself. Three windows were built differently on purpose, so
  -- these three answers together say whether the keys do anything at all.
  { key = "win1_move",   text = "Window 1 (asked for every window key): could you MOVE it?" },
  { key = "win1_resize", text = "Window 1: could you RESIZE it by dragging an edge?" },
  { key = "win1_max",    text = "Window 1: was there a Maximize button, and did it work?" },
  { key = "win2_resize", text = "Window 2 (asked for no window keys): could you resize it?" },
  { key = "win4_resize", text = "Window 4 (resizable='horizontally'): could you resize it?" },
  { key = "A_grew",      text = "If any window got wider: did block A's names get wider too?" },

  -- Width.
  { key = "A_full",   text = "A: is the whole of the long name readable at 330?" },
  { key = "ladder",   items = WIDTH_ANSWERS,
    text = "W1-W3: the narrowest width that showed the WHOLE long name?" },

  -- Shape.
  { key = "B_wrap",   text = "B: did the long name wrap onto a second line?" },
  { key = "B_end",    text = "B: without truncation, did it stop mid-phrase with no '...'?" },
  { key = "C_wrap",   text = "C: did the long name wrap, rather than ellipsise?" },
  { key = "D_drawn",  text = "D: did the names draw at all (any width)?" },
  { key = "G_select", text = "G: could you SELECT the text with the mouse?" },
  { key = "G_click",  text = "G: did clicking a name still count a click? (checked below)" },
  { key = "G_look",   text = "G: did the selectable rows draw a box/border around them?" },
  { key = "F_horiz",  text = "F: was there a horizontal scroll bar?" },
  { key = "F_vert",   text = "F: was there a vertical scroll bar?" },

  -- Height.
  { key = "H_fit",    text = "H: were all 10 plain rows drawn, none cut off?" },
  { key = "I_fit",    text = "I: were all 10 wrapped rows drawn, none cut off?" },

  -- The real panel, which is the only window with the saved frame the user
  -- lives with. If ten rows do not fit there, the request for a scroll bar was
  -- literally right and wrapping is the wrong first fix.
  { key = "P_fit",    text = "REAL PANEL: are all 10 suggestions visible at its normal size?" },
  { key = "P_tail",   text = "REAL PANEL: is the lost text the tail at the right edge?" },
  { key = "P_resize", text = "REAL PANEL: can you resize or move that window?" },
}

--- Ask the questions and hand back the answers.
--
-- A modal after the windows have closed rather than controls inside them,
-- because the windows are the thing being looked at and a questionnaire inside
-- one would be resized along with the evidence.
--
-- Inside a scrolled_view, because this list only ever grows and the last thing
-- this probe should do is put its own Record button off the bottom of the
-- screen -- which is exactly how the first version of it failed.
local function ask(context, clicks)
  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  local rows = { spacing = f:control_spacing() }

  for _, question in ipairs(QUESTIONS) do
    props[question.key] = "?"
    rows[#rows + 1] = f:row {
      f:static_text { title = question.text, width = 430 },
      f:popup_menu {
        value = LrView.bind(question.key),
        items = question.items or YES_NO,
        width = 150,
      },
    }
  end

  LrDialogs.presentModalDialog {
    title    = "Probe: what did the rows do?",
    contents = f:column {
      bind_to_object = props,
      spacing        = f:control_spacing(),

      f:static_text {
        title = "Answer what you saw. 'not sure' is a real answer and is "
          .. "recorded as one.",
        font  = "<system/bold>",
      },
      f:static_text {
        title = "Clicks counted while the windows were open: " .. clicks
          .. "  (the per-variant breakdown goes in the report)",
      },
      f:scrolled_view {
        width             = 620,
        height            = 420,
        vertical_scroller = true,
        f:column(rows),
      },
    },
    actionVerb = "Record",
  }

  local answers = {}
  for _, question in ipairs(QUESTIONS) do
    answers[#answers + 1] = { text = question.text, value = props[question.key] }
  end
  return answers
end

--------------------------------------------------------------------------------

local function run(context)
  local report = Report.new("iNat SDK Probe - Suggestion Rows")
  local props  = LrBinding.makePropertyTable(context)

  -- Per-variant click counts, so "selectable ate the click" is a measurement
  -- rather than an impression. Kept outside the property table because the
  -- questionnaire is a different table in a different window.
  local clicks  = {}
  local actions = {
    clicked = function(key)
      clicks[key] = (clicks[key] or 0) + 1
      props.clicked = "last click: block " .. key
    end,
  }
  props.clicked = "no clicks yet"

  report:add("=== Suggestion row layout probe ===")
  report:addf("panel width %d, link width %d, full list %d rows",
    NAME_WIDTH, LINK_WIDTH, PANEL_ROWS)
  report:addf("longest title: %d chars", #LONGEST)
  report:add(LONGEST)
  report:blank()

  -- Window 1 asks for everything presentFloatingDialog is known to read about
  -- a frame, plus the `resizable` that AgViewWin32Window reads and that
  -- presentFloatingDialog's key list does not mention. If this one cannot be
  -- resized, no floating window can.
  showWindow(props, actions, WIDTHS, "1 of 4 - widths", {
    "Try to MOVE this window, then to RESIZE it wider, then Maximize it.",
    "Watch whether block A's names get wider when the window does.",
    "W1-W3 below are the same long name at 440, 560 and 680.",
  }, {
    resizable   = true,
    maximizable = true,
    minimizable = true,
    closable    = true,
  })

  -- The control: no frame keys at all, exactly as the real panel asks for it.
  showWindow(props, actions, SHAPES, "2 of 4 - shapes", {
    "Try to resize this one too -- it asks for no window keys, so the",
    "difference between it and window 1 is what those keys are worth.",
    "In block G: try selecting the text, then click a name.",
  }, nil)

  showWindow(props, actions, { FULL_LIST }, "3 of 4 - ten plain rows", {
    "All " .. PANEL_ROWS .. " rows as the panel draws them today.",
    "Is the tenth row on screen, or cut off below the edge?",
  }, nil)

  showWindow(props, actions, { FULL_LIST_WRAPPED }, "4 of 4 - ten wrapped rows", {
    "The same ten at height_in_lines=2 -- the height wrapping would cost.",
    "Try to resize this one as well: it asks for resizable='horizontally'.",
  }, { resizable = "horizontally" })

  local total = 0
  for _, count in pairs(clicks) do total = total + count end

  report:add("Answers:")
  for _, answer in ipairs(ask(context, total)) do
    report:addf("  %-62s %s", answer.text, answer.value)
  end

  report:blank()
  report:add("Clicks per block (G against the rest is the selectable test):")
  for _, spec in ipairs(ALL) do
    report:addf("  %-3s %d", spec.key, clicks[spec.key] or 0)
  end

  report:blank()
  report:add("=== end ===")
  report:show()
end

LrFunctionContext.postAsyncTaskWithContext("inat_probe_rows", function(context)
  local ok, err = LrTasks.pcall(run, context)
  if not ok then
    LrDialogs.message("iNat SDK Probe", "Probe failed:\n\n" .. tostring(err),
      "critical")
  end
end)
