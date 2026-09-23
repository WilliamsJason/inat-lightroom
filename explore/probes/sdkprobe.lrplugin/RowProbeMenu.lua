--[[
  RowProbeMenu.lua
  ----------------
  Why does the Observation panel's suggestion list lose the end of a name, and
  which of the three possible fixes does the host actually support?

  The panel builds ten rows of `f:static_text` with **empty** titles and points
  each one at a binding, because the window outlives any photo selection and a
  presented view tree cannot grow rows. That combination -- sized before it has
  any text, filled afterwards -- is where the surprises live. A `static_text`
  built empty collapses to zero width, which is why every row carries an
  explicit `width` today; whether that width is a floor the window can stretch
  or a size that ignores `fill_horizontal`, and whether a title arriving by
  binding will wrap onto a second line, are both layout questions the binary
  cannot answer. `ui.dll` says only that the keys exist:
  `AgViewWinStaticText` reads `selectable`, `height_in_lines` and
  `resize_to_fit_text_height`, and `scroll_view` reads `vertical_scroller` and
  `horizontal_scroller`. Which of them *do* anything here is what this measures.

  Everything about the probe window mirrors the panel on purpose, because a
  probe that measures an easier case than the feature answers a question nobody
  asked:

    * a floating window (presentFloatingDialog), not a modal -- the panel is
      floating, and floating windows are resizable frames whose contents may or
      may not follow;
    * titles bound to a property table, built empty, filled only once the
      window is already on screen;
    * the real strings: the shapes `PanelCore.describeSuggestion` produces,
      including the `- <note>` tail ("genus, containing … and 8 others") that
      is the longest string the panel can build.

  No `save_frame`: the panel keeps one so it reopens where it was left, but a
  probe wants its natural size every run. A saved frame from the first run
  would silently be the answer to every run after it.

  Nothing in the SDK reports layout back -- there is no way to ask a view how
  wide it ended up or how many lines it drew -- so the last word is the user's.
  The window is followed by a questionnaire, one question per variant, and the
  answers go into the same Desktop log as every other probe. Same trick as the
  scrolled-view probe's "press Escape when it is usable": when the host will
  not say, measure against the person watching.
--]]

local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local Report = require "Report"

--- The width every variant starts from: what ObservationPanel.lua uses today.
local NAME_WIDTH = 330

--- The link column beside each name, also as the panel has it.
local LINK_WIDTH = 60

--- Suggestion titles in the shapes `PanelCore.describeSuggestion` builds.
--
-- It appends `- <score>%` to a scored row and `- <note>` to a coarse one, and
-- the notes are much the longer of the two: a genus row carries "containing
-- <species> and N others". So the longest strings the panel can produce belong
-- to the rows whose tail carries the reason to pick them, which is what makes
-- losing the tail expensive rather than untidy.
--
-- The chosen-row mark is included because it is part of what has to fit.
local TITLES = {
  "\226\151\143 Bombardier Beetles (Brachinus) - genus, containing Brachinus "
    .. "crepitans and 8 others",
  "  Ground Beetles (Carabidae) - family, agreed by top suggestions",
  "  Narrow-collared Snail-eating Beetle (Scaphinotus angusticollis) - 28%",
  "  Galerita bicolor - 9%",
}

--- What the panel actually shows: PanelCore.SUGGESTION_LIMIT rows.
--
-- The variants above use four rows because four is enough to read a width
-- against. Whether ten of them fit the window is a different question with a
-- different answer, and it is the question behind "add a scroll bar", so it
-- gets its own variants rather than an assumption.
local PANEL_ROWS = 10

local LINK = "View \226\134\145"

--- One variant's rows, built empty and bound, exactly as the panel builds its.
--
-- @param f        the view factory
-- @param key      variant letter, which also namespaces its bound properties
-- @param actions  what a name click does, so a variant can prove it is still
--                 clickable rather than only readable
-- @param name     extra keys for the name control -- the thing being varied
-- @param count    how many rows, defaulting to one per sample title
local function variantRows(f, key, actions, name, count)
  local rows = { spacing = 0 }

  for index = 1, (count or #TITLES) do
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
local function variant(f, key, caption, actions, name, count)
  return f:group_box {
    show_title = false,
    fill_horizontal = 1,

    f:static_text {
      title = key .. ".  " .. caption,
      font  = "<system/bold>",
    },
    variantRows(f, key, actions, name, count),
  }
end

--- Every variant, in the order the report asks about them.
--
-- A is the panel as it ships, so every other row here is read against it
-- rather than against a memory of it.
local VARIANTS = {
  {
    key     = "A",
    caption = "width=" .. NAME_WIDTH .. ", truncation=tail  (the panel today)",
    name    = {
      width           = NAME_WIDTH,
      truncation      = "tail",
      fill_horizontal = 1,
    },
  },
  {
    key     = "B",
    caption = "width=" .. NAME_WIDTH .. ", height_in_lines=2, no truncation",
    name    = {
      width           = NAME_WIDTH,
      height_in_lines = 2,
      fill_horizontal = 1,
    },
  },
  {
    key     = "C",
    caption = "width=" .. NAME_WIDTH .. ", height_in_lines=2, truncation=tail",
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
    name    = { fill_horizontal = 1, truncation = "tail" },
  },
  {
    key     = "E",
    caption = "width=" .. NAME_WIDTH
      .. " with height_in_lines=2 -- drag the window wider and watch this one",
    name    = {
      width           = NAME_WIDTH,
      height_in_lines = 2,
      fill_horizontal = 1,
    },
  },
  {
    key     = "G",
    caption = "selectable=true -- try selecting the text, then clicking a name",
    name    = {
      width           = NAME_WIDTH,
      truncation      = "tail",
      selectable      = true,
      fill_horizontal = 1,
    },
  },
  -- The two below are the vertical question, which is the one the user's words
  -- asked for ("add a scroll bar") and the one the rest of this probe cannot
  -- answer: four rows fit anything. Ten is what the panel shows, so ten is
  -- what has to be looked at -- once as the panel draws them today, and once
  -- wrapped, because if wrapping is the fix then it doubles the height of the
  -- tallest thing in the window and may create the overflow it was meant to
  -- avoid.
  {
    key     = "H",
    caption = "the panel's row, all " .. PANEL_ROWS .. " of them -- does the "
      .. "list fit?",
    count   = PANEL_ROWS,
    name    = {
      width           = NAME_WIDTH,
      truncation      = "tail",
      fill_horizontal = 1,
    },
  },
  {
    key     = "I",
    caption = "the same " .. PANEL_ROWS .. " rows wrapped to two lines -- does "
      .. "that still fit?",
    count   = PANEL_ROWS,
    name    = {
      width           = NAME_WIDTH,
      height_in_lines = 2,
      fill_horizontal = 1,
    },
  },
}

--- The scrolled variant, built apart because it wraps its rows rather than
-- changing them: a viewport deliberately narrower and shorter than its
-- contents, with both scrollers asked for, so whichever ones the host is
-- willing to draw have a reason to appear.
local function scrolledVariant(f, actions)
  return f:group_box {
    show_title      = false,
    fill_horizontal = 1,

    f:static_text {
      title = "F.  the same rows inside a scrolled_view (260x70, both "
        .. "scrollers asked for)",
      font  = "<system/bold>",
    },
    f:scrolled_view {
      width               = 260,
      height              = 70,
      horizontal_scroller = true,
      vertical_scroller   = true,
      variantRows(f, "F", actions, {
        width      = NAME_WIDTH,
        truncation = "tail",
      }),
    },
  }
end

--- Fill or empty every bound title.
--
-- Filling happens only once the window is up, which is the whole point: the
-- panel's rows are measured while empty and receive their text afterwards, and
-- a probe that built its rows with the text already in them would be measuring
-- a case the panel never reaches.
local function setTitles(props, filled)
  for _, spec in ipairs(VARIANTS) do
    for index = 1, (spec.count or #TITLES) do
      -- Cycled rather than repeated, so a ten-row variant is a mixture of
      -- lengths like a real answer from iNaturalist rather than ten copies of
      -- the worst case.
      local title = TITLES[((index - 1) % #TITLES) + 1]
      props[spec.key .. index]           = filled and title or ""
      props[spec.key .. "link" .. index] = filled and LINK or ""
    end
  end

  for index, title in ipairs(TITLES) do
    props["F" .. index]         = filled and title or ""
    props["Flink" .. index]     = filled and LINK or ""
  end
end

--- The answers the report is made of.
--
-- Deliberately one question per thing that could be true, rather than a free
-- text box: a probe whose result is a sentence is a probe whose result gets
-- argued about.
local QUESTIONS = {
  { key = "A_full",  text = "A: is the whole of row 1 readable?" },
  { key = "B_wrap",  text = "B: did row 1 wrap onto a second line?" },
  { key = "B_full",  text = "B: is the whole of row 1 readable?" },
  { key = "C_wrap",  text = "C: did row 1 wrap, rather than ellipsise?" },
  { key = "D_drawn", text = "D: did the names draw at all (any width)?" },
  { key = "E_grew",  text = "E: dragging the window wider widened the names?" },
  { key = "A_grew",  text = "A: dragging the window wider widened these too?" },
  { key = "F_horiz", text = "F: was there a horizontal scroll bar?" },
  { key = "F_vert",  text = "F: was there a vertical scroll bar?" },
  { key = "F_grew",  text = "F: did the scrolled box resize with the window?" },
  { key = "G_select",text = "G: could you select the text with the mouse?" },
  { key = "G_click", text = "G: did clicking a name still count a click?" },
  { key = "H_fit",   text = "H: were all 10 rows drawn, none cut off?" },
  { key = "I_fit",   text = "I: were all 10 wrapped rows drawn, none cut off?" },
  -- The probe's own window is not the panel's window, and only the panel's
  -- window has the saved frame the user actually lives with. So the vertical
  -- question is asked about the real thing as well: if the answer here is no,
  -- the request for a scroll bar was literally right and wrapping is the wrong
  -- first fix, because it makes the list taller still.
  { key = "P_fit",   text = "In the real panel, at the size it opens at: are "
      .. "all 10 suggestions visible?" },
  { key = "P_tail",  text = "In the real panel: is the lost text the tail at "
      .. "the right edge?" },
}

local ANSWERS = {
  { title = "not sure", value = "?"   },
  { title = "yes",      value = "yes" },
  { title = "no",       value = "no"  },
}

--- Ask the questions and hand back the answers.
--
-- A modal after the floating window has closed rather than controls inside it,
-- because the window is the thing being resized and a questionnaire inside it
-- would be resized along with the evidence.
local function ask(context, clicks)
  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  local rows = { spacing = f:control_spacing(), bind_to_object = props }

  rows[#rows + 1] = f:static_text {
    title = "Answer what you saw. 'not sure' is a real answer and is recorded "
      .. "as one.",
    font  = "<system/bold>",
  }

  for _, question in ipairs(QUESTIONS) do
    props[question.key] = "?"
    rows[#rows + 1] = f:row {
      f:static_text { title = question.text, width = 430 },
      f:popup_menu {
        value = LrView.bind(question.key),
        items = ANSWERS,
        width = 100,
      },
    }
  end

  rows[#rows + 1] = f:static_text {
    title = "Clicks counted while the window was open: " .. clicks,
  }

  LrDialogs.presentModalDialog {
    title      = "Probe: what did the rows do?",
    contents   = f:column(rows),
    actionVerb = "Record",
  }

  local answers = {}
  for _, question in ipairs(QUESTIONS) do
    answers[#answers + 1] = { text = question.text, value = props[question.key] }
  end
  return answers
end

local function run(context)
  local report = Report.new("iNat SDK Probe - Suggestion Rows")
  local f      = LrView.osFactory()
  local props  = LrBinding.makePropertyTable(context)

  -- Per-variant click counts, so "selectable ate the click" is a measurement
  -- rather than an impression. Kept outside the property table because the
  -- questionnaire is a different table in a different window.
  local clicks = {}
  local actions = {
    clicked = function(key)
      clicks[key] = (clicks[key] or 0) + 1
      props.clicked = "last click: variant " .. key
    end,
  }

  setTitles(props, false)
  props.clicked = "no clicks yet"

  local blocks = {
    bind_to_object = props,
    spacing        = f:control_spacing(),
    margin         = 12,

    f:static_text {
      title = "Every name below is built empty and filled by a binding a "
        .. "moment from now, like the panel's rows.",
      font  = "<system/bold>",
    },
    f:static_text {
      title = "Then: drag this window much wider, and watch which variants "
        .. "follow. Close it to answer the questions.",
    },
    f:static_text {
      title = "Two of the questions are about the real Observation panel, so "
        .. "have it open with a photo's suggestions loaded.",
    },
  }

  for _, spec in ipairs(VARIANTS) do
    blocks[#blocks + 1] =
      variant(f, spec.key, spec.caption, actions, spec.name, spec.count)
  end
  blocks[#blocks + 1] = scrolledVariant(f, actions)

  blocks[#blocks + 1] = f:row {
    spacing = f:control_spacing(),
    f:push_button {
      title  = "Fill",
      action = function() setTitles(props, true) end,
    },
    f:push_button {
      title  = "Clear",
      action = function() setTitles(props, false) end,
    },
    f:static_text { title = LrView.bind("clicked"), fill_horizontal = 1 },
  }

  -- Filled from a task rather than from onShow, because what has to be true is
  -- that the rows were measured before the text existed, and a sleep is the
  -- only thing here that can promise the window was already drawn. Fill and
  -- Clear above are for repeating it by hand once it is up.
  LrTasks.startAsyncTask(function()
    LrTasks.sleep(1.5)
    setTitles(props, true)
  end)

  report:add("=== Suggestion row layout probe ===")
  report:addf("name width %d, link width %d, %d rows per variant (%d for the "
    .. "full-list variants)", NAME_WIDTH, LINK_WIDTH, #TITLES, PANEL_ROWS)
  report:blank()
  report:add("Titles rendered:")
  for _, title in ipairs(TITLES) do
    report:addf("  (%3d chars) %s", #title, title)
  end
  report:blank()

  LrDialogs.presentFloatingDialog(_PLUGIN, {
    title     = "iNat probe: suggestion rows",
    contents  = f:column(blocks),
    id        = "inat_probe_rows",
    blockTask = true,
  })

  local total = 0
  for _, count in pairs(clicks) do total = total + count end

  report:add("Answers:")
  for _, answer in ipairs(ask(context, total)) do
    report:addf("  %-52s %s", answer.text, answer.value)
  end

  report:blank()
  report:add("Clicks per variant:")
  for _, spec in ipairs(VARIANTS) do
    report:addf("  %s  %d", spec.key, clicks[spec.key] or 0)
  end
  report:addf("  F  %d", clicks.F or 0)

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
