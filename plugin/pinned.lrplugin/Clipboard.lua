--[[
  Clipboard.lua
  -------------
  Putting a short piece of text on the system clipboard.

  The SDK has no clipboard API at all -- there is no LrClipboard, and no view
  control that is both read-only and selectable, so text the plugin shows can
  normally only be retyped. That matters for the observation ID: linking a
  second photo to an observation means getting that number from the panel into
  a dialog, and retyping a nine-digit number is exactly where a typo turns into
  a photo attached to a stranger's observation.

  So this shells out, the same way WindowFix does. One command, no temporary
  files, and the text is passed as an argument rather than piped because
  LrTasks.execute hands the whole line to the shell either way.
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

--- The command line that would copy this text, or nil if we cannot.
--
-- Newlines are refused rather than handled: everything the plugin copies is a
-- single short token, and a line break would either break the command line or
-- silently land a second line on the clipboard.
function Clipboard.command(text)
  if type(text) ~= "string" or text == "" then return nil end
  if text:find("[\r\n]") then return nil end

  if WIN_ENV == true then
    return table.concat({
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy Bypass",
      "-WindowStyle Hidden",
      '-Command "Set-Clipboard -Value ' .. powershellQuote(text) .. '"',
    }, " ")
  end

  -- printf rather than echo: echo is a shell builtin whose treatment of
  -- backslashes and leading dashes varies, and pbcopy should receive the text
  -- with no trailing newline.
  return "printf %s " .. shellQuote(text) .. " | pbcopy"
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
