--[[
  ReverseSyncDialog.lua
  ---------------------
  Showing the matches, and letting the user throw some of them out.

  Every row arrives ticked. The common case is that the matches are right and
  the user wants all of them, and a list that starts empty makes them tick a
  thousand boxes to say so -- an offer nobody takes, which turns a working
  feature into one people abandon halfway through. Untick is the rarer,
  cheaper direction.

  Why a simple_list rather than a column of checkboxes
  ----------------------------------------------------
  Rows of f:checkbox inside a scrolled_view is the obvious build and it does
  not survive the sizes this produces. Measured, minus about 2.2s of human
  reaction time: 500 hand-built rows took 5.2s to appear, and 1000 took 14.9s
  -- getting worse than linearly, so 5000 was not worth waiting for.
  f:simple_list wraps a native table_view and did 5000 rows in 7.1s.

  The cost is that a simple_list row is a string and a selection, not a
  widget, so "selected" has to mean "will be linked". That reads backwards
  from a checkbox until you use it, and it is the only shape that scales.
--]]

local LrDialogs = import "LrDialogs"
local LrView    = import "LrView"

local MatchCore = require "MatchCore"

local ReverseSyncDialog = {}

--- The last two path segments, which is what identifies a photo to its owner.
--
-- Full paths are long enough to push everything interesting off the right of
-- the row, and a bare filename is ambiguous the moment somebody has DSC_0042
-- in more than one shoot -- which, over a career, is everybody.
function ReverseSyncDialog.shortPath(path)
  if not path or path == "" then return "(unknown file)" end
  local folder, name = path:match("([^/\\]+)[/\\]([^/\\]+)$")
  if folder and name then return folder .. "/" .. name end
  return path
end

--- One row's text.
function ReverseSyncDialog.describe(match)
  local observation = match.observation or {}
  local name = observation.species_guess
    or (observation.taxon and (observation.taxon.preferred_common_name
                               or observation.taxon.name))
    or "Unknown species"

  local row = string.format("%s  —  %s",
    ReverseSyncDialog.shortPath(match.path), name)

  -- Only the doubts are spelled out. Annotating the confident matches too
  -- would leave every row carrying a note, and a list where everything is
  -- flagged reads the same as a list where nothing is.
  local notes = {}
  if match.tier == MatchCore.CONFLICT and match.distance then
    notes[#notes + 1] = string.format("iNat says %.0f km away",
      match.distance / 1000)
  end
  if match.ambiguous then
    notes[#notes + 1] = string.format("%d other photo(s) fit equally well",
      match.alternatives or 0)
  end
  if match.secondsApart and match.secondsApart > 0 then
    notes[#notes + 1] = string.format("%ds apart", match.secondsApart)
  end

  if #notes > 0 then row = row .. "   [" .. table.concat(notes, "; ") .. "]" end
  return row
end

--- Build the list items and the initial selection.
-- @return items, selection -- both arrays, selection holding every index
function ReverseSyncDialog.build(matches)
  local items, selection = {}, {}

  for index, match in ipairs(matches) do
    items[index] = { title = ReverseSyncDialog.describe(match), value = index }
    selection[index] = index
  end

  return items, selection
end

--- The summary line above the list.
function ReverseSyncDialog.summarise(summary)
  local parts = { string.format("%d of %d observations matched a photo",
    summary.matched or 0, summary.observations or 0) }

  if (summary.unmatched or 0) > 0 then
    parts[#parts + 1] = string.format("%d found no photo", summary.unmatched)
  end
  if (summary.undatable or 0) > 0 then
    -- Worth naming rather than folding into "unmatched": nothing is wrong with
    -- the catalog, the observation just does not carry a time, and matching it
    -- on date alone would be picking a photo out of that whole day.
    parts[#parts + 1] = string.format("%d had no time of day", summary.undatable)
  end
  if (summary.ambiguous or 0) > 0 then
    parts[#parts + 1] = string.format("%d were ambiguous", summary.ambiguous)
  end
  if (summary.conflicts or 0) > 0 then
    parts[#parts + 1] = string.format("%d disagree on location", summary.conflicts)
  end

  return table.concat(parts, ", ") .. "."
end

--- Apply the dialog's selection back onto the matches.
--
-- The list hands back the values of the selected rows, so anything absent was
-- deliberately unticked.
function ReverseSyncDialog.applySelection(matches, selected)
  local chosen = {}
  for _, value in ipairs(selected or {}) do chosen[value] = true end

  local count = 0
  for index, match in ipairs(matches) do
    match.selected = chosen[index] or false
    if match.selected then count = count + 1 end
  end

  return count
end

--- Show the review list.
-- @return the matches with `selected` set, or nil if the user cancelled
function ReverseSyncDialog.show(context, matches, summary)
  if #matches == 0 then
    LrDialogs.message("iNaturalist Reverse Sync",
      ReverseSyncDialog.summarise(summary), "info")
    return nil
  end

  local LrBinding = import "LrBinding"
  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  local items, selection = ReverseSyncDialog.build(matches)
  props.selection = selection

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),

    f:static_text { title = ReverseSyncDialog.summarise(summary), width = 620 },
    f:static_text {
      title = "Every match is selected. Deselect any you do not want linked; "
        .. "ctrl-click or shift-click to change the selection.",
      width           = 620,
      height_in_lines = 2,
    },

    f:simple_list {
      items                    = items,
      value                    = LrView.bind("selection"),
      allows_multiple_selection = true,
      width                    = 620,
      height                   = 380,
    },
  }

  local result = LrDialogs.presentModalDialog {
    title      = "iNaturalist Reverse Sync",
    contents   = contents,
    actionVerb = "Link Selected",
  }

  if result ~= "ok" then return nil end

  ReverseSyncDialog.applySelection(matches, props.selection)
  return matches
end

return ReverseSyncDialog
