--[[
  WindowFix.lua
  -------------
  Makes the floating panel behave like a panel rather than a system-wide
  overlay, by fixing up its window after Lightroom has created it.

  Lightroom creates SDK floating windows WS_EX_TOPMOST and with no owner
  window. Measured against a live Lightroom rather than assumed:

    our panel     class AgWinFrame      ex-style 0x108   owner 0
    Lightroom     class AgWinMainFrame  ex-style 0x100   owner 0

  So the panel sits above every application on the desktop, and having no owner
  it neither minimises nor restores with Lightroom. Above Lightroom is what you
  want from a panel; above the browser you are reading the identification in is
  not.

  There is no Lua control over either. `_topmost` is a real property of the
  underlying window object -- in ui.dll it sits in the same property list as
  borderless, closable, minimizable and canBecomeKeyWindow, all of which the SDK
  window builder does pass -- but the builder's own constant table has no
  `_topmost` and no `level`, so it never reads the key. Passing
  `_topmost = false` through presentFloatingDialog was tried in the host and the
  window still came up 0x108.

  What we actually want is an ordinary owned, non-topmost window: Windows keeps
  an owned window above its owner and nothing else, and minimises it with the
  owner. That is two Win32 calls, which Lua cannot make, so we shell out to
  fix_window_z_order.ps1. Windows only; on macOS this is a no-op, because the
  behaviour there has not been measured and guessing is how the wrong note got
  into the docs in the first place.

  See docs/lightroom-sdk-notes.md for the measurements and the exit codes.
--]]

local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"

local logger = require "Log"

local WindowFix = {}

WindowFix.SCRIPT_NAME = "fix_window_z_order.ps1"

--- Where the helper script lives, given the plugin directory (_PLUGIN.path).
function WindowFix.scriptPath(pluginPath)
  return LrPathUtils.child(pluginPath, WindowFix.SCRIPT_NAME)
end

--- The command line to run.
--
-- Kept separate from apply() so a test can assert on it without a shell.
--
-- Quoting: the executable is deliberately left unquoted. cmd.exe strips the
-- outermost pair of quotes only when the command *begins* with one, so leaving
-- `powershell` bare means the quoted script path survives whether or not
-- anything wraps the string on the way through.
function WindowFix.command(scriptPath, title)
  return table.concat({
    "powershell",
    "-NoProfile",
    "-NonInteractive",
    -- Users install this by pointing the Plug-in Manager at a folder, so the
    -- script is not signed and may well be marked as downloaded.
    "-ExecutionPolicy Bypass",
    "-WindowStyle Hidden",
    '-File "' .. scriptPath .. '"',
    '-Title "' .. title .. '"',
  }, " ")
end

--- True when the fix-up applies to this platform at all.
function WindowFix.applicable()
  return WIN_ENV == true
end

--- Run the fix-up for the window with the given title.
--
-- Must be called from a task: LrTasks.execute blocks. Returns whether the
-- window was fixed, so a caller can decide whether to care; nothing here is
-- worth interrupting the user over, so failure is logged and swallowed.
--
-- The script polls for the window rather than expecting it to exist, which is
-- what lets this be started before the window is up.
function WindowFix.apply(title)
  if not WindowFix.applicable() then return false end

  -- A quote in the title would break out of the argument. Nothing in the
  -- plugin passes one, so this is a guard against a future caller, not a case
  -- to handle.
  if title:find('"', 1, true) then
    logger:warn("WindowFix: refusing to run, title contains a quote")
    return false
  end

  local command = WindowFix.command(WindowFix.scriptPath(_PLUGIN.path), title)
  local ok, result = LrTasks.pcall(function()
    return LrTasks.execute(command)
  end)

  if not ok then
    logger:warn("WindowFix: could not run the helper: " .. tostring(result))
    return false
  end
  if result ~= 0 then
    logger:warn("WindowFix: helper exited " .. tostring(result) ..
      "; the panel stays always-on-top")
    return false
  end

  logger:trace("WindowFix: panel is now owned by the Lightroom window")
  return true
end

return WindowFix
