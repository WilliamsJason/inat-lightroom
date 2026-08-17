--[[
  PluginUrls.lua
  --------------
  Building and parsing the "lightroom://com.github.inat-lightroom/<action>"
  URLs that Lightroom routes back into this plugin.

  Wired up by the URLHandler entry in Info.lua. That key is real but barely
  documented; Adobe's own bundled Flickr.lrplugin uses it for its OAuth
  callback.

  This started life as PanelActions.lua, which existed to fake buttons in the
  Metadata panel: a custom field of dataType "url" renders as a clickable row,
  so a field holding one of these URLs was the closest thing to a button that
  panel offered. That worked, but the panel gives a plugin no control over the
  row -- see docs/lightroom-sdk-notes.md -- and the actions have since moved to
  the publish service, which was built for them.

  The URLs themselves stay, for two reasons. They are still reachable from a
  browser or a desktop shortcut, and OAuth needs exactly this mechanism for its
  redirect: iNaturalist will send the authorization code back to
  lightroom://com.github.inat-lightroom/authorization-redirect, which is how a
  public client avoids shipping a secret.
--]]

local PluginUrls = {}

-- Must match LrToolkitIdentifier in Info.lua; Lightroom routes lightroom://
-- URLs to the plugin whose identifier matches the host part.
PluginUrls.SCHEME    = "lightroom://"
PluginUrls.PLUGIN_ID = "com.github.inat-lightroom"

--------------------------------------------------------------------------------
-- URL construction and parsing
--------------------------------------------------------------------------------

--- Build the link for an action, e.g. "lightroom://com.github.inat-lightroom/sync".
function PluginUrls.urlFor(action)
  return PluginUrls.SCHEME .. PluginUrls.PLUGIN_ID .. "/" .. tostring(action)
end

--- Pull the action name out of a URL Lightroom handed us.
-- Returns nil when the URL is not one of ours, so the handler can ignore it
-- rather than guessing.
function PluginUrls.parse(url)
  if type(url) ~= "string" then
    return nil
  end

  -- "-" is a magic character in Lua patterns; the identifier contains one.
  local prefix = PluginUrls.SCHEME .. PluginUrls.PLUGIN_ID .. "/"
  if url:sub(1, #prefix) ~= prefix then
    return nil
  end

  local rest = url:sub(#prefix + 1)
  -- Drop any query string; the OAuth redirect will arrive with one, and
  -- without this "authorization-redirect?code=..." would not match the
  -- handler registered under "authorization-redirect".
  local action = rest:match("^([%w_%-]+)")
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
function PluginUrls.parseObservationId(text)
  if type(text) ~= "string" then
    return nil
  end

  -- The URL form is checked first: a bare "%d+" anywhere would happily match
  -- some other number in the URL.
  return text:match("/observations/(%d+)")
    or text:match("^%s*(%d+)%s*$")
end

return PluginUrls
