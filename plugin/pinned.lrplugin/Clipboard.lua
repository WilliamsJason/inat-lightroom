--[[
  Clipboard.lua
  -------------
  Putting a short piece of text on the system clipboard.

  The SDK has no clipboard API at all -- there is no LrClipboard, and no view
  control that is both read-only and clickable and selectable. `static_text`
  does take `selectable = true`, and the text really can be selected and
  copied -- but a selectable row stops reporting `mouse_down`, measured in
  explore/probes/sdkprobe, so making a row copyable would cost the click that
  uses it. Text the plugin shows can therefore only be retyped. That matters
  for the observation ID: linking a
  second photo to an observation means getting that number from the panel into
  a dialog, and retyping a nine-digit number is exactly where a typo turns into
  a photo attached to a stranger's observation.

  So this shells out, the same way WindowFix does. One command, no temporary
  files, and the text is passed as an argument rather than piped because
  LrTasks.execute hands the whole line to the shell either way.

  Newlines used to be refused outright, back when the only thing copied was a
  nine-digit observation ID and a line break could only be a mistake. A
  taxonomy is the counter-example: eight ranks are worth having as eight lines,
  and flattening them into one would hand the user something they have to take
  apart again. So a line break is now a thing to carry rather than a thing to
  reject -- but it is carried as *lines*, never as a newline inside the command
  line, because a raw newline in a command is where quoting stops being a
  formatting question and starts being a second command.
--]]

local LrTasks = import "LrTasks"

local logger = require "Log"

local Clipboard = {}

--- Quote a string for the Windows PowerShell single-quoted form.
-- Only the quote itself is special there, and it is escaped by doubling.
local function powershellQuote(text)
  return "'" .. text:gsub("'", "''") .. "'"
end

--- Quote a string for a POSIX shell's single-quoted form.
-- A single quote cannot appear inside single quotes at all, so it has to be
-- closed, escaped and reopened.
local function shellQuote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

--- The lines this text should land on the clipboard as.
--
-- Both line endings are accepted because both turn up: text built here uses
-- "\n", and anything that has been round a Windows control may not. One
-- trailing newline is dropped, so that a block built by appending "\n" to each
-- line does not copy as a blank last line.
--
-- @return a list of lines, or nil when there is nothing to copy
local function linesOf(text)
  if type(text) ~= "string" then return nil end

  local normalised = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n$", "")
  if normalised == "" then return nil end

  local lines = {}
  for line in (normalised .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  return lines
end

--- The command line that would copy this text, or nil if we cannot.
--
-- A single line keeps the form it has always had. Several lines become several
-- arguments, which is the only way to get a line break onto the clipboard
-- without putting one into the command: PowerShell's Set-Clipboard joins an
-- array with the platform's own line ending, and printf repeats its format once
-- per argument.
function Clipboard.command(text)
  local lines = linesOf(text)
  if not lines then return nil end

  if WIN_ENV == true then
    local quoted = {}
    for index, line in ipairs(lines) do quoted[index] = powershellQuote(line) end

    local value = quoted[1]
    if #quoted > 1 then
      value = "@(" .. table.concat(quoted, ",") .. ")"
    end

    return table.concat({
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy Bypass",
      "-WindowStyle Hidden",
      '-Command "Set-Clipboard -Value ' .. value .. '"',
    }, " ")
  end

  -- printf rather than echo: echo is a shell builtin whose treatment of
  -- backslashes and leading dashes varies, and pbcopy should receive the text
  -- with no trailing newline.
  if #lines == 1 then
    return "printf %s " .. shellQuote(lines[1]) .. " | pbcopy"
  end

  -- Several lines do take a trailing newline, because the format is applied to
  -- every argument including the last and printf has no way to skip it. A block
  -- of text ending in a line break is what a text field would have produced
  -- anyway; a single token ending in one is not, which is why the case above
  -- stays as it was.
  local quoted = {}
  for index, line in ipairs(lines) do quoted[index] = shellQuote(line) end

  return "printf '%s\\n' " .. table.concat(quoted, " ") .. " | pbcopy"
end

--- Copy text to the clipboard. MUST be called from inside a task.
-- Returns true when the helper reported success. Failure is logged and
-- reported back rather than raised: nothing here is worth an error dialog the
-- caller cannot phrase better itself.
function Clipboard.copy(text)
  local command = Clipboard.command(text)
  if not command then
    logger:warn("Clipboard: nothing copyable in " .. tostring(text))
    return false
  end

  local ok, result = LrTasks.pcall(function()
    return LrTasks.execute(command)
  end)

  if not ok then
    logger:warn("Clipboard: could not run the helper: " .. tostring(result))
    return false
  end
  if result ~= 0 then
    logger:warn("Clipboard: helper exited " .. tostring(result))
    return false
  end

  return true
end

return Clipboard
