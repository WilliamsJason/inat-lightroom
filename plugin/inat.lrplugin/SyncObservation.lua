--[[
  SyncObservation.lua
  -------------------
  Menu entry point for "Sync Selected Photos".

  Nothing but a launcher. Lightroom executes a menu-item script top to bottom
  when the item is clicked, which means this file cannot be required from
  anywhere else without running a sync as a side effect. All of the actual work
  lives in SyncCore.lua so that the Metadata panel action links can reach it
  too.

  postAsyncTaskWithContext is what pairs the task and the context correctly --
  callWithContext would return the moment the task was queued, leaving the
  progress scope holding a context that had already ended.
--]]

local LrFunctionContext = import "LrFunctionContext"

local SyncCore = require "SyncCore"

LrFunctionContext.postAsyncTaskWithContext("inat_sync", function(context)
  SyncCore.syncTargetPhotos(context)
end)
