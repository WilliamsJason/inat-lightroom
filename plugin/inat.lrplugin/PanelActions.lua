--[[
  PanelActions.lua
  ----------------
  Clickable actions inside Lightroom's Metadata panel.

  Lightroom Classic has no SDK hook for adding a panel to the Library right
  panel stack -- dumping the shipped binaries confirms the plugin loader
  (substrate.dll) and Library.lrmodule between them recognise only the keys
  listed in Info.lua, and none of them are panel sections. The Metadata panel
  is as close as a plugin gets, and it renders no buttons.

  What it does render is a custom metadata field of dataType "url" as a
  clickable link. Lightroom registers "lightroom://" as a system protocol
  handler and supports a URLHandler entry in Info.lua (Adobe's own bundled
  Flickr.lrplugin uses it), so a field holding

    lightroom://com.github.inat-lightroom/sync

  is a plausible way to get a working button into the panel. That is the whole
  point of this module: build those URLs, parse them back, and write them onto
  photos so the link has something to display.

  Whether Lightroom actually routes a clicked *metadata* URL through the
  plugin's URLHandler is not something the stubs can answer -- it needs one
  pass through the host. If it turns out not to, the fields are inert text and
  nothing else breaks.
--]]

local PanelActions = {}

-- Must match LrToolkitIdentifier in Info.lua; Lightroom routes lightroom://
-- URLs to the plugin whose identifier matches the host part.
PanelActions.SCHEME    = "lightroom://"
PanelActions.PLUGIN_ID = "com.github.inat-lightroom"

--- Field IDs that hold action links, paired with the action they invoke.
--
-- There is deliberately no "open the observation" action: inat_observation_url
-- already holds the real https URL and Lightroom opens that natively, so
-- routing it back through the plugin would only add a failure point.
PanelActions.FIELDS = {
  { field = "inat_action_sync", action = "sync" },
  { field = "inat_action_link", action = "link" },
}

--------------------------------------------------------------------------------
-- URL construction and parsing
--------------------------------------------------------------------------------

--- Build the link for an action, e.g. "lightroom://com.github.inat-lightroom/sync".
function PanelActions.urlFor(action)
  return PanelActions.SCHEME .. PanelActions.PLUGIN_ID .. "/" .. tostring(action)
end

--- Pull the action name out of a URL Lightroom handed us.
-- Returns nil when the URL is not one of ours, so the handler can ignore it
-- rather than guessing.
function PanelActions.parse(url)
  if type(url) ~= "string" then
    return nil
  end

  -- "-" is a magic character in Lua patterns; the identifier contains one.
  local prefix = PanelActions.SCHEME .. PanelActions.PLUGIN_ID .. "/"
  if url:sub(1, #prefix) ~= prefix then
    return nil
  end

  local rest = url:sub(#prefix + 1)
  -- Drop any query string; nothing uses one yet but a stray "?" should not
  -- turn "sync" into an unknown action.
  local action = rest:match("^([%w_]+)")
  if not action or action == "" then
    return nil
  end

  return action
end

--------------------------------------------------------------------------------
-- Reading an observation ID a user typed or pasted
--------------------------------------------------------------------------------

--- Pull an observation ID out of whatever the user pasted.
-- People copy the URL from their browser far more often than they copy the
-- bare number, and it arrives with a trailing slash or a query string as often
-- as not. Returns nil when there is nothing usable, so the caller can say so
-- rather than storing a wrong ID that fails later during a sync.
function PanelActions.parseObservationId(text)
  if type(text) ~= "string" then
    return nil
  end

  -- The URL form is checked first: a bare "%d+" anywhere would happily match
  -- some other number in the URL.
  return text:match("/observations/(%d+)")
    or text:match("^%s*(%d+)%s*$")
end

--------------------------------------------------------------------------------
-- Writing the links onto photos
--------------------------------------------------------------------------------

--- Write every action link onto one photo.
-- Must be called inside catalog:withWriteAccessDo -- setPropertyForPlugin
-- refuses to run outside a transaction.
function PanelActions.armPhoto(photo)
  for _, entry in ipairs(PanelActions.FIELDS) do
    photo:setPropertyForPlugin(_PLUGIN, entry.field,
      PanelActions.urlFor(entry.action))
  end
end

--- Write the action links onto a list of photos, opening the transaction here.
-- @return number of photos armed
function PanelActions.armPhotos(catalog, photos)
  if not photos or #photos == 0 then
    return 0
  end

  catalog:withWriteAccessDo("iNat panel actions", function()
    for _, photo in ipairs(photos) do
      PanelActions.armPhoto(photo)
    end
  end)

  return #photos
end

return PanelActions
