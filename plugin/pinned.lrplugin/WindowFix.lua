--[[
  WindowFix.lua
  -------------
  Win32 fix-ups for the floating windows Lightroom builds for us: making the
  panel behave like a panel rather than a system-wide overlay, and closing one
  window by name.

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

  Closing is here for the same reason: the SDK's only programmatic close is
  plugin-wide, so the taxonomy window's Close button would take the panel with
  it. A window's close box sends WM_CLOSE and nothing stops us sending the same
  message. Same platform caveat, same no-op on macOS.
--]]

local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"

local logger = require "Log"

local WindowFix = {}

WindowFix.SCRIPT_NAME = "fix_window_z_order.ps1"

--- The helper that closes one window by title.
--
-- Separate script, same approach, because the SDK has no per-window close:
-- `closeFloatingDialogsForPlugin` is the only programmatic one and it is
-- plugin-wide, so a Close button built on it would take the observation panel
-- down with whatever window the user actually meant.
WindowFix.CLOSE_SCRIPT_NAME = "close_window.ps1"

--- Where a helper script lives, given the plugin directory (_PLUGIN.path).
function WindowFix.scriptPath(pluginPath, name)
  return LrPathUtils.child(pluginPath, name or WindowFix.SCRIPT_NAME)
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

--- Ask the window with the given title to close itself.
--
-- Must be called from a task: LrTasks.execute blocks.
--
-- Returns whether the request got out. Failure is logged and swallowed, as
-- above: the window's own close box is still there, so the worst case is a
-- button that does nothing rather than a window that cannot be dismissed.
--
-- Windows only, for the same reason apply() is -- the behaviour on macOS has
-- not been measured. Callers should ask `applicable()` before drawing a button
-- for this, so nobody is offered one that cannot work.
function WindowFix.close(title)
  if not WindowFix.applicable() then return false end

  if title:find('"', 1, true) then
    logger:warn("WindowFix: refusing to close, title contains a quote")
    return false
  end

  local script = WindowFix.scriptPath(_PLUGIN.path, WindowFix.CLOSE_SCRIPT_NAME)
  local ok, result = LrTasks.pcall(function()
    return LrTasks.execute(WindowFix.command(script, title))
  end)

  if not ok then
    logger:warn("WindowFix: could not run the close helper: " .. tostring(result))
    return false
  end
  if result ~= 0 then
    logger:warn("WindowFix: close helper exited " .. tostring(result) ..
      "; no window titled '" .. title .. "' was found")
    return false
  end

  return true
end

return WindowFix
