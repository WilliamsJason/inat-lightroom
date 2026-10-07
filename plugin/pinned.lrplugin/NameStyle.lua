--[[
  NameStyle.lua
  -------------
  Which way round a taxon's two names go.

  Every taxon has up to two names -- a scientific one and a common one -- and
  there is no neutral way to show both. iNaturalist settles it per account, in
  Settings > Content & Display:

    * "Display name" -> prefers_common_names (default true)
    * "Scientific name first" -> prefers_scientific_name_first (default false)

  Before this, the plugin had an opinion of its own in two places and they
  disagreed: the suggestion list and the species guess field said
  "Swift Forktail (Ischnura erratica)", and the taxonomy window said
  "Ischnura erratica (Swift Forktail)". Nobody chose that; the two were written
  months apart. Reading the account settles it once, and settles it the way the
  user already answered it on the website.

  The preference is read from GET /v1/users/me, which is the only place it is
  exposed -- the public user record does not carry preferences. InatAPI
  memoises that call, so following the account costs one request per session at
  most, and nothing at all once anything else has asked who we are.

  The formatting itself is pure and takes a style, so the harness can test all
  four combinations without a network. The loaded style is held here rather
  than threaded through every caller because it is a property of the account,
  not of a taxon: a function that formats a name should not need an API client
  to do it.
--]]

local logger = require "Log"

local NameStyle = {}

--- What iNaturalist does for an account that has never touched the settings.
--
-- Taken from iNaturalistAPI's own PREFS table (lib/models/user.js), which
-- carries the defaults because the preference row only exists once it differs
-- from the default -- an account that never changed it has nothing stored, and
-- an API answer missing the field means "default", not "false".
NameStyle.DEFAULT = {
  commonNames    = true,
  scientificFirst = false,
}

--- The style an account's user record describes.
--
-- @param user  A user record from GET /v1/users/me, or nil.
--
-- Absent fields fall back to the defaults above rather than to false. An
-- unauthenticated client, a request that failed, and an account that has never
-- changed the setting all arrive here as nil, and all three mean "whatever
-- iNaturalist would do".
function NameStyle.of(user)
  if type(user) ~= "table" then
    return { commonNames    = NameStyle.DEFAULT.commonNames,
             scientificFirst = NameStyle.DEFAULT.scientificFirst }
  end

  local common = user.prefers_common_names
  local first  = user.prefers_scientific_name_first

  -- Spelled out rather than `x == nil and DEFAULT or x`: that idiom cannot
  -- carry a false, and both of these defaults and values are booleans. The
  -- scientific-name-first default is false, so the short form would answer nil
  -- for every account that never changed it.
  if common == nil then common = NameStyle.DEFAULT.commonNames end
  if first  == nil then first  = NameStyle.DEFAULT.scientificFirst end

  return { commonNames = common, scientificFirst = first }
end

--- The style in force, which is the default until the account has been read.
--
-- Never nil, so no caller has to decide what to do without one. The panel opens
-- and draws before the account comes back, and drawing the default order for a
-- moment is better than drawing nothing.
function NameStyle.current()
  return NameStyle._style or NameStyle.of(nil)
end

--- Read the account's preference and hold on to it.
--
-- MUST be called from inside a task: it may fetch.
--
-- Failure is not an error worth showing anyone. A name in the wrong order is a
-- cosmetic disappointment, and refusing to show a suggestion list because the
-- preferences could not be read would be a much larger one. It is logged and
-- the default stands.
--
-- @return the style now in force.
function NameStyle.load(api)
  if NameStyle._style then return NameStyle._style end
  if not api or type(api.currentUser) ~= "function" then
    return NameStyle.current()
  end

  local user, err = api:currentUser()
  if not user then
    logger:info("Could not read name preferences, using defaults: " ..
      tostring(err or "unknown"))
    return NameStyle.current()
  end

  NameStyle._style = NameStyle.of(user)

  return NameStyle._style
end

--- Forget the loaded style, so the next load reads the account again.
--
-- For sign-out and for tests. Two accounts in one Lightroom session is rare but
-- it is not nobody, and a held preference belonging to the previous login is
-- the kind of bug that looks like a rendering glitch.
function NameStyle.forget()
  NameStyle._style = nil
end

--- One taxon's two names as one string.
--
-- @param scientific  The scientific name.
-- @param common      The common name, or nil.
-- @param style       A style, or nil for whatever is in force.
--
-- With common names switched off the common name is dropped rather than moved,
-- which is what iNaturalist itself does: somebody who turned them off wants the
-- binomial, and parenthesising the thing they switched off would be an odd way
-- of honouring the setting.
--
-- With them on, both are always shown. A name on its own -- either one -- is
-- ambiguous often enough that the panel would stop being checkable, and the
-- whole point of the field is that it can be copied into a caption.
--
-- Except when they are the same word. Plenty of taxa have no common name and
-- report the scientific one in its place, and "Dolomedes (Dolomedes)" reads as
-- a bug rather than as thoroughness.
function NameStyle.format(scientific, common, style)
  style = style or NameStyle.current()

  local sci = type(scientific) == "string" and scientific ~= "" and scientific
  local com = type(common) == "string" and common ~= "" and common

  if not style.commonNames then
    -- Nothing but a common name still beats "Unnamed taxon". The setting is
    -- about preference, and there is no preference to express here.
    return sci or com or ""
  end

  if sci and com and sci ~= com then
    if style.scientificFirst then
      return sci .. " (" .. com .. ")"
    end
    return com .. " (" .. sci .. ")"
  end

  return sci or com or ""
end

return NameStyle
