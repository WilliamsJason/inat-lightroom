--[[
  EditCommitProbeMenu.lua
  -----------------------
  When does a non-immediate `f:edit_field` actually write its bound property?

  The observation panel now keeps two names for one taxon: the display form in
  the species guess field, and the bare scientific name beside it for the
  upload. Which one is sent depends on whether the field still holds the text
  the plugin put there -- so it depends on the field having committed whatever
  the user typed by the time a button is pressed.

  The documentation says a field with `immediate = false` writes its binding on
  Enter, Tab or losing focus rather than per keystroke. What it does not say is
  whether clicking a push_button in the same dialog counts as losing focus, and
  that is the case the panel lives on. The plugin had behaved as if it does
  since long before this probe -- a hand-typed guess reaches iNaturalist -- but
  that is inference from a feature working, not a measurement.

  So: type in the fields, then press each button without pressing Enter or Tab
  first, and read back what the properties held at the moment the click was
  handled. The immediate field sits beside it as a control -- it should never
  lag, and if it does the answer is about this probe rather than the binding.

  Run in Lightroom Classic, and the answer is that the field has already
  committed in all three shapes: the observer fires before every handler logs,
  and each read shows text typed just before that click rather than a leftover.
  The static_text mouse_down -- not a focusable control, and so the one that
  might have read stale where a button did not -- committed the field too. Kept
  as the evidence behind the note in docs/lightroom-sdk-notes.md.
--]]

local LrBinding         = import "LrBinding"
local LrColor           = import "LrColor"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks           = import "LrTasks"
local LrView            = import "LrView"

local Report = require "Report"

--- What the properties say right now, as one line.
local function snapshot(props, when)
  return string.format("%-28s deferred=%q  immediate=%q  observed=%d",
    when, tostring(props.deferred), tostring(props.immediate),
    props.observedCount or 0)
end

LrFunctionContext.postAsyncTaskWithContext("inat_probe_edit_commit",
  function(context)
    local report = Report.new("iNat Probe: edit_field commit")
    local f      = LrView.osFactory()
    local props  = LrBinding.makePropertyTable(context)

    props.deferred      = "start"
    props.immediate     = "start"
    props.observedCount = 0
    props.lastObserved  = "start"

    -- An observer as well as a read, because the two answer different
    -- questions: the read says what the property held when the button ran, and
    -- the observer says when it changed. A field that commits on focus loss and
    -- one that commits just after the click are indistinguishable from the read
    -- alone, and they are not the same thing for anything that acts on a click.
    props:addObserver("deferred", function(_, _, value)
      props.observedCount = (props.observedCount or 0) + 1
      props.lastObserved  = tostring(value)
      report:add(snapshot(props, "observer fired"))
    end)

    report:add("Type into both fields, then press the buttons WITHOUT")
    report:add("pressing Enter or Tab first. Each button logs what the")
    report:add("bound properties held when it ran.")
    report:blank()

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),

      f:static_text {
        title = "Type in both, then click a button. Do not press Enter first.",
        font  = "<system/bold>",
      },

      f:row {
        f:static_text { title = "immediate = false:", width = 140 },
        f:edit_field {
          value     = LrView.bind("deferred"),
          immediate = false,
          width     = 300,
        },
      },

      f:row {
        f:static_text { title = "immediate = true:", width = 140 },
        f:edit_field {
          value     = LrView.bind("immediate"),
          immediate = true,
          width     = 300,
        },
      },

      f:row {
        spacing = f:control_spacing(),

        -- The panel's own shape: a push_button in the same dialog, which is
        -- what a user clicks after typing a species guess.
        f:push_button {
          title  = "Read (button)",
          action = function()
            report:add(snapshot(props, "push_button action"))
          end,
        },

        -- The other way the panel is clicked. A static_text with a mouse_down
        -- is not a focusable control, so if focus loss is what commits the
        -- field, this one may read stale where the button does not.
        f:static_text {
          title      = "Read (clickable text)",
          text_color = LrColor(0.45, 0.72, 1),
          mouse_down = function()
            report:add(snapshot(props, "static_text mouse_down"))
          end,
        },

        -- Deliberately on a task, because the panel's own button actions are:
        -- a commit that happens on the next turn of the event loop would show
        -- up here and not above.
        f:push_button {
          title  = "Read (on a task)",
          action = function()
            LrTasks.startAsyncTask(function()
              report:add(snapshot(props, "inside startAsyncTask"))
            end)
          end,
        },
      },
    }

    LrDialogs.presentModalDialog {
      title      = "Probe: edit_field commit",
      contents   = contents,
      actionVerb = "Done",
    }

    report:blank()
    report:add(snapshot(props, "after the dialog closed"))
    report:show()
  end)
