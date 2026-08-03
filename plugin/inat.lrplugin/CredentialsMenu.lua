--[[
  CredentialsMenu.lua
  -------------------
  The plugin's only entry in Library > Plug-in Extras: "Set Up Credentials".

  Everything else that used to be here now lives in the Metadata panel, which
  is a better home for it -- the panel is in front of you while you work, and a
  menu is not. Credentials are the exception: you need them before the panel
  can do anything, and the panel is a poor place to type a token into.

  Once OAuth replaces the pasted token this item becomes "Authorize with
  iNaturalist", used once per machine and then forgotten.

  Like every menu-item script, Lightroom runs this file top to bottom when the
  item is clicked. Nothing may require it -- the dialog itself is in
  CredentialsDialog.lua for exactly that reason.
--]]

local CredentialsDialog = require "CredentialsDialog"

CredentialsDialog.show()
