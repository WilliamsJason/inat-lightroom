--[[
  Log.lua
  -------
  Shared logger for the plugin.

  LrLogger instances only write anywhere once something calls enable() on them.
  Each module creating its own logger meant only whichever module happened to
  call enable() produced output -- and during an export, nothing did. Requiring
  this module instead guarantees logging is on no matter which entry point
  Lightroom loaded first.

  Output lands in:
    Windows  %USERPROFILE%\Documents\LrClassicLogs\iNatLightroom.log
    macOS    ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/iNatLightroom.log
--]]

local LrLogger = import "LrLogger"

local logger = LrLogger("iNatLightroom")
logger:enable("logfile")

return logger
