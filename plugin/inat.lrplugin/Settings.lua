--[[
  Settings.lua
  ------------
  The plugin's preferences, in one place with one set of defaults.

  These used to be the publish service's exportPresetFields. When the publish
  service was removed there was nowhere left to hang them: a floating panel has
  no settings dialog of its own, and an export preset only exists while an
  export is being configured. So they moved to LrPrefs, which is where the
  credential bookkeeping already lived.

  Reading goes through get() rather than touching prefs directly so that a
  preference nobody has ever set reads as its default instead of nil. Lightroom
  stores prefs per plugin and returns nil for anything unset, and a nil
  geoprivacy reaching the API is a 422 that says nothing useful.
--]]

local LrPrefs = import "LrPrefs"

local Settings = {}

--- Every preference this plugin has, and what it means when unset.
--
-- Split into two groups because they are answerable at different times: the
-- iNaturalist ones are about what an observation says, the render ones are
-- about what the uploaded file contains.
Settings.DEFAULTS = {
  -- What the observation says
  inat_geoprivacy      = "open",
  inat_upload_location = true,
  inat_project_id      = "",
  inat_sync_after_upload = true,

  -- What gets uploaded.
  --
  -- Location is deliberately NOT stripped by default even though this is an
  -- image going to a public website: iNaturalist is a biodiversity record and
  -- a sighting without a place is close to worthless. Obscuring where a rare
  -- thing was seen is what inat_geoprivacy is for, and it does it properly,
  -- per observation, on iNaturalist's side.
  render_remove_location = false,
  render_remove_face     = true,
  render_metadata_option = "all",
  render_use_watermark   = false,
  render_watermark_id    = "",

  -- Updating.
  --
  -- On by default: a plugin that talks to a live API is worth keeping current,
  -- and the check is one request a day. Checking is all it does -- installing
  -- an update stays a button in the Plug-in Manager, because replacing the
  -- code that touches someone's catalog while they are not looking is not a
  -- default anyone chose.
  update_check_automatically = true,

  -- Bookkeeping rather than settings. They live here so that everything stored
  -- for this plugin has one home and one set of defaults, but nothing in the
  -- settings dialog binds them: the check writes them and reads them back.
  --
  -- update_last_checked is a Lightroom time (seconds since 2001), which is what
  -- LrDate.currentTime returns; the automatic check compares it against the
  -- same clock and never against a real-world one.
  update_last_checked = 0,
  update_notified_tag = "",
}

--- The stored value for one preference, or its default.
function Settings.get(key)
  local prefs = LrPrefs.prefsForPlugin()
  local value = prefs[key]
  if value == nil then
    return Settings.DEFAULTS[key]
  end
  return value
end

--- Store one preference.
function Settings.set(key, value)
  local prefs = LrPrefs.prefsForPlugin()
  prefs[key] = value
end

--- Every preference as a flat table, defaults filled in.
-- Callers that need several at once take one of these rather than calling get()
-- repeatedly, so a settings change part-way through an upload cannot make one
-- photo behave differently from the next.
function Settings.all()
  local values = {}
  for key in pairs(Settings.DEFAULTS) do
    values[key] = Settings.get(key)
  end
  return values
end

return Settings
