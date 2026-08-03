--[[
  PluginInit.lua
  --------------
  Legacy entry point for the "Set Up Credentials" menu item.

  The dialog itself now lives in CredentialsDialog.lua so that the consolidated
  menu and the Metadata panel actions can open it without this file's
  load-time side effect. Kept as a thin launcher because a menu item may still
  point at it, and because opening the dialog on load is exactly what a
  menu-item script is supposed to do.
--]]

local CredentialsDialog = require "CredentialsDialog"

CredentialsDialog.show()

return CredentialsDialog