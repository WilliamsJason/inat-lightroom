--[[
  ReverseSyncDialog.lua
  ---------------------
  Showing the matches, and letting the user throw some of them out.

  Every row arrives ticked. The common case is that the matches are right and
  the user wants all of them, and a list that starts empty makes them tick a
  thousand boxes to say so -- an offer nobody takes, which turns a working
  feature into one people abandon halfway through. Untick is the rarer,
  cheaper direction.

  Why twenty-five rows and a Next button
  --------------------------------------
  A match is a claim that this photo is that observation, and the only way to
  check it is to look at both. So a row shows the catalog photo and the
  iNaturalist photo side by side, which makes it right or wrong at a glance
  rather than a timestamp to be trusted.

  That rules out drawing every row. Hand-built rows do not scale -- measured,
  500 rows took 5.2s to appear and 1000 took 14.9s, getting worse than
  linearly -- and every iNaturalist thumbnail is an HTTP request, so a thousand
  matches would be a thousand downloads before the dialog opened.

  A fixed page of twenty-five rows costs 1.0ms to build and about 2.6s of
  downloads, and both are paid once no matter how many matches there are. The
  page turns by repointing the same twenty-five rows at the next twenty-five
  matches: the SDK fixes the view tree when a dialog is presented, so rows
  cannot be added, but f:catalog_photo and f:picture both accept a binding and
  both redraw when it changes. That was probed before this was written.

  Rows cannot be hidden either. `visible = LrView.bind(...)` on an f:row binds
  and does nothing, so the last page is padded backwards -- it ends on the last
  match and starts a full page before it -- rather than left short with empty
  rows in it. See pageRange.

  Because the widgets are reused, the answer cannot live in them. Selection is
  an array keyed by match index, and the checkboxes are a view onto the page's
  slice of it -- read when leaving a page, written when arriving. Keying by
  index is also what makes the overlap on the last page harmless.
--]]

local LrBinding = import "LrBinding"
local LrColor   = import "LrColor"
local LrDialogs = import "LrDialogs"
local LrTasks   = import "LrTasks"
local LrView    = import "LrView"

local MatchCore  = require "MatchCore"
local ThumbCache = require "ThumbCache"

local logger = require "Log"

local ReverseSyncDialog = {}

--- Rows per page.
ReverseSyncDialog.PAGE_SIZE = 25

--- How big each of the two images is drawn, in points.
--
-- Large enough to tell two frames of the same bird apart, small enough that
-- twenty-five rows scroll rather than needing a dialog taller than a laptop.
ReverseSyncDialog.THUMB = 92

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

--- What the observation is of, common and scientific.
--
-- Both, because neither is sufficient on its own. A common name is what makes
-- a row scannable -- "Dark Fishing Spider" is recognisable at a glance in a way
-- that Dolomedes tenebrosus is not -- but common names are ambiguous, regional,
-- and sometimes shared between unrelated species, so the scientific name is
-- what makes the row unambiguous. Confirming a match is exactly the moment both
-- are wanted.
--
-- The taxon's own common name is preferred over species_guess: the guess is
-- whatever the observer typed at the time, and the taxon is what the community
-- settled on since.
function ReverseSyncDialog.speciesOf(match)
  local observation = match.observation or {}
  local taxon = observation.taxon or {}

  local common     = taxon.preferred_common_name or observation.species_guess
  local scientific = taxon.name

  -- Not both when they are the same word: many taxa have no common name and
  -- report the scientific one in its place, and "Dolomedes (Dolomedes)" reads
  -- as a bug rather than as thoroughness.
  if common and scientific and common ~= scientific then
    return common .. " (" .. scientific .. ")"
  end

  return common or scientific or "Unknown species"
end

--- One row's first line.
function ReverseSyncDialog.describe(match)
  return ReverseSyncDialog.speciesOf(match) .. "  —  "
    .. ReverseSyncDialog.shortPath(match.path)
end

--- One row's second line: only the reasons to doubt it.
--
-- Annotating the confident matches too would leave every row carrying a note,
-- and a list where everything is flagged reads the same as a list where
-- nothing is. An empty string rather than nil, so the row keeps its height and
-- the page does not reflow as it is paged through.
function ReverseSyncDialog.caveats(match)
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

  if #notes == 0 then return "" end
  return table.concat(notes, "; ")
end

--- Spell a string out one byte at a time, if any of them are not plain ASCII.
--
-- A row turned up in the field showing its species and then nothing at all
-- where the filename should be -- not "(unknown file)", which is what a missing
-- path draws, but an empty space. That means the string reached f:static_text
-- and the string is not what it appears to be.
--
-- The likely cause is a byte the control will not draw: Lua has no idea what
-- encoding a string is in, `#path` counts bytes rather than characters, and a
-- path that is not valid UTF-8 -- or holds something exotic but legal, like an
-- emoji or a combining accent -- can end the drawn text early. None of that is
-- visible by printing the path, because printing it is how it went wrong.
--
-- @return the escaped form, or nil when every byte is ordinary
function ReverseSyncDialog.oddBytes(text)
  if type(text) ~= "string" then return nil end

  local out, odd = {}, false

  for index = 1, #text do
    local byte = text:byte(index)
    if byte >= 32 and byte <= 126 then
      out[#out + 1] = string.char(byte)
    else
      out[#out + 1] = string.format("\\x%02X", byte)
      odd = true
    end
  end

  if not odd then return nil end
  return table.concat(out)
end

--- Warn about any path whose bytes a control may refuse to draw.
--
-- The path is what gets escaped, not the whole row: the separator between
-- species and filename is an em dash, so every title contains non-ASCII bytes
-- and reporting on titles would report on all of them.
--
-- This was written to explain a row that drew its species and then nothing
-- where the filename should have been, and it did that by coming back empty.
-- Every path was plain ASCII, which ruled out the bytes and left the layout --
-- where the answer was that f:static_text drops a word too long to fit rather
-- than clipping it. Kept anyway: a path that cannot be drawn is still possible,
-- and this is the only way it would ever be visible.
function ReverseSyncDialog.logRows(matches)
  local odd = 0

  for index, match in ipairs(matches) do
    local escaped = ReverseSyncDialog.oddBytes(match.path)

    if escaped then
      odd = odd + 1
      logger:warnf("review row %d path has bytes f:static_text may not draw:"
        .. " %s (%d bytes, species %s)",
        index, escaped, #match.path, ReverseSyncDialog.speciesOf(match))
    end
  end

  return odd
end

--- How many pages a set of matches needs.
function ReverseSyncDialog.pageCount(total, pageSize)
  pageSize = pageSize or ReverseSyncDialog.PAGE_SIZE
  if total <= 0 or pageSize <= 0 then return 1 end
  return math.ceil(total / math.min(pageSize, total))
end

--- The first and last match index shown on a page.
--
-- The last page is padded backwards rather than left short: it ends on the last
-- match and begins a full page before it, so every page has exactly as many
-- matches as there are rows, and the final few rows overlap the previous page.
--
-- The obvious alternative is to hide the surplus rows, and it does not work.
-- `visible = LrView.bind(...)` on an f:row is accepted, binds, and changes
-- nothing: page 7 of 7 drew all twenty-five rows, nine of them an empty
-- checkbox beside a placeholder tile, which reads as nine matches the feature
-- has failed to describe. Rows cannot be added or removed after the dialog is
-- presented, so the only thing left to control is which matches they point at.
--
-- Overlap is safe because selection is keyed by match index: a match shown on
-- two pages is one checkbox state seen twice, not two.
function ReverseSyncDialog.pageRange(page, total, pageSize)
  pageSize = math.min(pageSize or ReverseSyncDialog.PAGE_SIZE, total)
  if pageSize <= 0 then return 1, 0 end

  local last  = math.min(page * pageSize, total)
  local first = math.max(1, last - pageSize + 1)
  return first, last
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

--- How many are ticked.
function ReverseSyncDialog.countSelected(selected, total)
  local count = 0
  for index = 1, total do
    if selected[index] then count = count + 1 end
  end
  return count
end

--- "Page 3 of 12 — 148 of 372 selected".
function ReverseSyncDialog.statusLine(page, pages, chosen, total)
  return string.format("Page %d of %d   —   %d of %d selected",
    page, pages, chosen, total)
end

------------------------------------------------------------------ the pager

--- Which page is showing, and what is ticked.
--
-- Split out from `show` so the paging arithmetic and the selection bookkeeping
-- can be tested without a view factory, which the harness cannot draw.
local Pager = {}
Pager.__index = Pager

function Pager.new(matches, props, options)
  options = options or {}

  local selected = {}
  for index = 1, #matches do selected[index] = true end

  local pageSize = math.min(options.pageSize or ReverseSyncDialog.PAGE_SIZE,
    math.max(#matches, 1))

  return setmetatable({
    matches     = matches,
    props       = props,
    selected    = selected,
    page        = 1,
    pageSize    = pageSize,
    pages       = ReverseSyncDialog.pageCount(#matches, pageSize),
    cache       = options.cache,
    placeholder = options.placeholder,
    -- Bumped on every page change. A download that finishes after the user has
    -- moved on compares this and drops its result, so a slow thumbnail from
    -- page 2 cannot appear in a row now showing page 3.
    epoch       = 0,
  }, Pager)
end

--- Copy the page's checkboxes back into the selection array.
--
-- Called before the page changes and before the dialog is accepted, because
-- those properties are the only place the current page's answer lives.
function Pager:harvest()
  local first, last = ReverseSyncDialog.pageRange(
    self.page, #self.matches, self.pageSize)

  for index = first, last do
    local row = index - first + 1
    self.selected[index] = self.props["selected" .. row] and true or false
  end
end

--- Point the rows at the current page.
function Pager:render()
  local props = self.props
  local first, last = ReverseSyncDialog.pageRange(
    self.page, #self.matches, self.pageSize)

  self.epoch = self.epoch + 1

  for row = 1, self.pageSize do
    local index = first + row - 1
    local match = index <= last and self.matches[index] or nil

    if match then
      props["selected" .. row] = self.selected[index] and true or false
      props["species" .. row]  = ReverseSyncDialog.speciesOf(match)
      props["file" .. row]     = ReverseSyncDialog.shortPath(match.path)
      props["caveat" .. row]   = ReverseSyncDialog.caveats(match)
      props["photo" .. row]    = match.photo
      props["image" .. row]    = self.placeholder
    else
      -- Padding the last page backwards means this should be unreachable. It
      -- stays because the alternative to clearing a row is leaving the previous
      -- page's photos under a checkbox that links something else.
      props["selected" .. row] = false
      props["species" .. row]  = ""
      props["file" .. row]     = ""
      props["caveat" .. row]   = ""
      props["photo" .. row]    = nil
      props["image" .. row]    = self.placeholder
    end
  end

  self:refreshStatus()
end

--- Recount and redraw the line under the list.
function Pager:refreshStatus()
  self.props.status = ReverseSyncDialog.statusLine(self.page, self.pages,
    ReverseSyncDialog.countSelected(self.selected, #self.matches),
    #self.matches)
  self.props.canGoBack    = self.page > 1
  self.props.canGoForward = self.page < self.pages
end

--- Fetch this page's iNaturalist thumbnails, filling rows in as they land.
--
-- MUST be called from inside a task.
function Pager:loadImages()
  if not self.cache then return end

  local mine = self.epoch
  local first, last = ReverseSyncDialog.pageRange(
    self.page, #self.matches, self.pageSize)

  local urls = {}
  for index = first, last do
    local url = ThumbCache.observationUrl(self.matches[index].observation)
    if url then urls[index - first + 1] = url end
  end

  self.cache:fetchAll(urls,
    function(row, path)
      if self.epoch ~= mine then return end
      self.props["image" .. row] = path
    end,
    function() return self.epoch ~= mine end)
end

--- Move by one page, keeping the current page's answers.
function Pager:turn(delta)
  local wanted = self.page + delta
  if wanted < 1 or wanted > self.pages then return false end

  self:harvest()
  self.page = wanted
  self:render()
  return true
end

--- Tick or untick everything, across every page rather than just this one.
--
-- Whole-run rather than page-only because the button is next to a status line
-- that counts the whole run: "Select None" leaving 340 of 372 ticked would be
-- a lie told by the control right beside the number.
function Pager:setAll(value)
  self:harvest()
  for index = 1, #self.matches do self.selected[index] = value end

  -- Re-rendering would bump the epoch and throw away this page's thumbnails,
  -- which are already correct -- only the ticks changed.
  local first, last = ReverseSyncDialog.pageRange(
    self.page, #self.matches, self.pageSize)
  for index = first, last do
    self.props["selected" .. (index - first + 1)] = value
  end

  self:refreshStatus()
end

--- Write the answer back onto the matches.
function Pager:commit()
  self:harvest()

  local count = 0
  for index, match in ipairs(self.matches) do
    match.selected = self.selected[index] and true or false
    if match.selected then count = count + 1 end
  end

  return count
end

ReverseSyncDialog.Pager = Pager

--------------------------------------------------------------------------- UI

--- Build one reusable row.
local function buildRow(f, props, row)
  local thumb = ReverseSyncDialog.THUMB

  return f:row {
    spacing        = 8,
    bind_to_object = props,

    f:checkbox {
      title = "",
      value = LrView.bind("selected" .. row),
    },
    f:catalog_photo {
      photo  = LrView.bind("photo" .. row),
      width  = thumb,
      height = thumb,
    },
    f:picture {
      value  = LrView.bind("image" .. row),
      width  = thumb,
      height = thumb,
    },
    f:column {
      spacing = 2,
      -- Three separate controls rather than one line, because f:static_text
      -- silently drops a word that does not fit rather than clipping it. With
      -- the species and the filename sharing a fixed width, a long species name
      -- pushed the filename out entirely -- the row showed
      -- "Narrow-collared Snail-eating Beetle (Scaphinotus angusticollis)  —  "
      -- and then nothing, which looks like a match with no photo behind it.
      -- Adding scientific names made it worse on every row at once.
      --
      -- On its own line each piece only has to fit itself, and the one that
      -- overflows is the one that is too long.
      f:static_text {
        title = LrView.bind("species" .. row),
        width = 500,
      },
      f:static_text {
        title = LrView.bind("file" .. row),
        width = 500,
      },
      f:static_text {
        title      = LrView.bind("caveat" .. row),
        width      = 500,
        text_color = LrColor(0.78, 0.45, 0.1),
      },
    },
  }
end

--- Show the review list.
-- @return the matches with `selected` set, or nil if the user cancelled
function ReverseSyncDialog.show(context, matches, summary)
  if #matches == 0 then
    LrDialogs.message("iNaturalist Reverse Sync",
      ReverseSyncDialog.summarise(summary), "info")
    return nil
  end

  local f     = LrView.osFactory()
  local props = LrBinding.makePropertyTable(context)

  local placeholder = _PLUGIN.path .. "/no-photo.png"
  local cache = ThumbCache.new { placeholder = placeholder }

  local pager = Pager.new(matches, props,
    { cache = cache, placeholder = placeholder })

  ReverseSyncDialog.logRows(matches)

  -- Every bound property is given a value before any widget asks for it: a
  -- binding to a key the table has never held reads as nil, and f:picture with
  -- no file is exactly the case the placeholder exists to avoid.
  local children = { spacing = 6 }
  for row = 1, pager.pageSize do
    props["selected" .. row] = false
    props["species" .. row]  = ""
    props["file" .. row]     = ""
    props["caveat" .. row]   = ""
    props["photo" .. row]    = nil
    props["image" .. row]    = placeholder
    children[#children + 1] = buildRow(f, props, row)
  end

  pager:render()

  -- Paging runs in a task because turning the page downloads the next
  -- twenty-five thumbnails, and a button handler that yields without one is
  -- the "cannot yield" error.
  local function turnPage(delta)
    LrTasks.startAsyncTask(function()
      if pager:turn(delta) then pager:loadImages() end
    end)
  end

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),

    f:static_text { title = ReverseSyncDialog.summarise(summary), width = 780 },
    f:static_text {
      title = "Each row shows your photo beside the iNaturalist photo. "
        .. "Everything is ticked; untick anything you do not want linked.",
      width           = 780,
      height_in_lines = 2,
    },

    f:scrolled_view {
      width  = 800,
      height = 460,
      f:column(children),
    },

    f:row {
      spacing = 8,
      f:push_button {
        title   = "Back",
        enabled = LrView.bind("canGoBack"),
        action  = function() turnPage(-1) end,
      },
      f:push_button {
        title   = "Next",
        enabled = LrView.bind("canGoForward"),
        action  = function() turnPage(1) end,
      },
      f:static_text {
        title = LrView.bind("status"),
        width = 320,
      },
      f:push_button {
        title  = "Select All",
        action = function() pager:setAll(true) end,
      },
      f:push_button {
        title  = "Select None",
        action = function() pager:setAll(false) end,
      },
    },
  }

  -- The first page's thumbnails are fetched after the dialog is on screen
  -- rather than before it: 2.6 seconds of nothing, with the scan's progress
  -- bar already gone, reads as a hang.
  LrTasks.startAsyncTask(function() pager:loadImages() end)

  local result = LrDialogs.presentModalDialog {
    title      = "iNaturalist Reverse Sync",
    contents   = contents,
    actionVerb = "Link Selected",
  }

  cache:discard()

  if result ~= "ok" then return nil end

  pager:commit()
  return matches
end

return ReverseSyncDialog
