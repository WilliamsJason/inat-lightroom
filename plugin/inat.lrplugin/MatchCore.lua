--[[
  MatchCore.lua
  -------------
  Deciding which catalog photo an observation came from.

  Deliberately free of any `import`. Everything here is arithmetic on times and
  coordinates, and keeping the SDK out means the whole of it runs under plain
  Lua in the test harness -- which matters more here than elsewhere, because
  matching rules are the part of Reverse Sync a user cannot check by eye. A
  wrong keyword is visible; a wrong link is not.

  The clock, and why times are compared as wall clock
  ---------------------------------------------------
  Lightroom's `dateTimeOriginal` is the camera's local reading with no zone
  attached. iNaturalist's `time_observed_at` is the same instant written with
  an offset, "2017-04-29T10:22:27-07:00", and for observations made from these
  photos it was derived from that very EXIF field.

  So the wall clock is the common ground, and converting either side to UTC
  only introduces a zone that neither of them really knows: a photo whose
  camera was never told it had flown gets moved by the conversion, and moved
  out of its own observation's window.

  Times are therefore compared as written, with the offset parsed but not
  applied. The offset is kept anyway, because two observations of the same
  wall-clock time in different zones is exactly the ambiguity worth reporting.
--]]

local MatchCore = {}

--- Tiers, worst to best. Only `time` creates a match; location adjusts it.
MatchCore.CONFIRMED = "confirmed"  -- time matches and location agrees
MatchCore.LIKELY    = "likely"     -- time matches, no location to check
MatchCore.CONFLICT  = "conflict"   -- time matches but location disagrees

--- Metres apart before a location is treated as corroborating.
MatchCore.NEAR_METRES = 250

--- Metres apart before a location is treated as contradicting.
-- Between the two, the location is neither evidence for nor against: a phone
-- observation logged from the car park at the end of a walk is a normal way to
-- be a kilometre from the photo it describes.
MatchCore.FAR_METRES = 5000

--------------------------------------------------------------------------------
-- Civil time
--------------------------------------------------------------------------------

local function isLeap(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Days from 1970-01-01 to y-m-d, proleptic Gregorian.
--
-- Written out rather than handed to os.time, which is limited to the Unix
-- epoch range on some platforms and, more to the point, applies the machine's
-- own timezone -- the one thing this module is careful never to involve.
local function daysFromCivil(year, month, day)
  local y = year
  if month <= 2 then y = y - 1 end

  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp  = (month + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy

  return era * 146097 + doe - 719468
end

--- Seconds since 1970-01-01, treating the parts as wall clock.
function MatchCore.toSeconds(parts)
  if type(parts) ~= "table" then return nil end
  local days = daysFromCivil(parts.year, parts.month, parts.day)
  return days * 86400 + parts.hour * 3600 + parts.min * 60 + parts.sec
end

--- The inverse: seconds back to civil parts.
function MatchCore.fromSeconds(seconds)
  local days = math.floor(seconds / 86400)
  local rem  = seconds - days * 86400

  local z   = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
    - math.floor(doe / 146096)) / 365)
  local y   = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp  = math.floor((5 * doy + 2) / 153)
  local d   = doy - math.floor((153 * mp + 2) / 5) + 1
  local m   = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end

  return {
    year  = y,
    month = m,
    day   = d,
    hour  = math.floor(rem / 3600),
    min   = math.floor((rem % 3600) / 60),
    sec   = rem % 60,
  }
end

--- Format civil parts the way findPhotos wants them.
--
-- This exact layout is not a preference. LrDate.timeToW3CDate produces
-- "2017-04-29T17:22:25.000+00:00" and findPhotos matches nothing at all
-- against it -- no error, an empty result, indistinguishable from a window
-- holding no photo. Seconds resolution with no fraction and no zone works.
function MatchCore.formatSearchValue(parts)
  return string.format("%04d-%02d-%02dT%02d:%02d:%02d",
    parts.year, parts.month, parts.day, parts.hour, parts.min, parts.sec)
end

--------------------------------------------------------------------------------
-- Parsing iNaturalist times
--------------------------------------------------------------------------------

local function validParts(parts)
  if parts.month < 1 or parts.month > 12 then return false end
  if parts.hour > 23 or parts.min > 59 or parts.sec > 60 then return false end

  local limit = MONTH_DAYS[parts.month]
  if parts.month == 2 and isLeap(parts.year) then limit = 29 end
  return parts.day >= 1 and parts.day <= limit
end

--- Parse an ISO-8601 timestamp into wall-clock parts plus its offset.
--
-- Accepts what the API actually emits: "2017-04-29T10:22:27-07:00",
-- "...Z", "...+0530", a space instead of the T, and fractional seconds.
-- Returns nil for anything else rather than guessing, because a
-- misparsed time produces a confident match to the wrong photo.
--
-- @return { year, month, day, hour, min, sec, offset } where offset is
--         minutes east of UTC, or nil when the string carried no zone
function MatchCore.parseTimestamp(text)
  if type(text) ~= "string" then return nil end

  local year, month, day, hour, min, sec, rest = string.match(text,
    "^%s*(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
  if not year then return nil end

  local parts = {
    year  = tonumber(year),
    month = tonumber(month),
    day   = tonumber(day),
    hour  = tonumber(hour),
    min   = tonumber(min),
    sec   = tonumber(sec),
  }
  if not validParts(parts) then return nil end

  rest = rest or ""
  rest = string.gsub(rest, "^%.%d+", "")           -- drop fractional seconds
  rest = string.gsub(rest, "%s", "")

  if rest == "" then
    return parts                                    -- no zone: wall clock only
  elseif rest == "Z" or rest == "z" then
    parts.offset = 0
  else
    local sign, oh, om = string.match(rest, "^([%+%-])(%d%d):?(%d%d)$")
    if not sign then return parts end               -- unreadable zone, keep time
    local minutes = tonumber(oh) * 60 + tonumber(om)
    parts.offset = sign == "-" and -minutes or minutes
  end

  return parts
end

--- The wall-clock time an observation was made, or nil if it has none.
--
-- `time_observed_at` is the field with a time in it. `observed_on` is a date
-- only, and an observation carrying just that cannot be matched to a photo by
-- a two second window -- it would match the whole day, which is not a match so
-- much as a coincidence waiting to be confirmed. Those are skipped rather than
-- guessed at.
function MatchCore.observedAt(observation)
  if type(observation) ~= "table" then return nil end

  local parts = MatchCore.parseTimestamp(observation.time_observed_at)
  if parts then return parts end

  -- observed_on_string is what the user typed or the phone reported, and is
  -- sometimes a full timestamp when time_observed_at is missing.
  return MatchCore.parseTimestamp(observation.observed_on_string)
end

--- Whether an observation's time is only known to the minute.
--
-- iNaturalist's web uploader reads the photo's EXIF time and formats it
-- through moment.js as "YYYY/MM/DD h:mm A" -- a format string with no seconds
-- token -- and the server parses that back with Chronic, which fills the
-- seconds in as zero. A frame shot at 20:03:41 is therefore recorded as
-- 20:03:00, and a two second window around it finds nothing at all. This is
-- not an edge case: on a real 770-observation account, 495 of them arrived
-- this way, against the ~13 that chance would put on an exact minute.
--
-- The loss is a truncation and not a rounding -- every second from :00 to :59
-- formats to the same string -- so the true time is at or after the recorded
-- one and never before it. That asymmetry is the whole point: widening
-- backwards as well would double the candidates for no reason.
--
-- Observations from the mobile app and from direct API calls send a full
-- ISO-8601 string and keep their seconds, so this must not fire for them. A
-- source that recorded seconds says so by writing them down, even when they
-- happen to be zero.
function MatchCore.isMinutePrecision(observation)
  local parts = MatchCore.observedAt(observation)
  if not parts or parts.sec ~= 0 then return false end

  local text = observation.observed_on_string
  if type(text) == "string" and text:match("%d:%d%d:%d%d") then
    return false
  end

  return true
end

--- The span of wall-clock seconds an observation could have been made in.
--
-- A point for a source that recorded seconds, and the whole minute for one
-- that did not. Everything that reasons about time works from this rather
-- than from a single instant, so that widening the search and judging how
-- close a photo is stay two views of one decision instead of drifting apart.
--
-- @return fromSeconds, toSeconds -- both nil when the observation has no time
function MatchCore.observedSpan(observation)
  local parts = MatchCore.observedAt(observation)
  if not parts then return nil, nil end

  local centre = MatchCore.toSeconds(parts)
  if MatchCore.isMinutePrecision(observation) then
    return centre, centre + 59
  end
  return centre, centre
end

--- The capture-time window to search for one observation.
-- @return fromValue, toValue -- strings for findPhotos, or nil when undatable
function MatchCore.windowFor(observation, toleranceSeconds)
  local from, to = MatchCore.observedSpan(observation)
  if not from then return nil, nil end

  local slack = toleranceSeconds or 2

  return MatchCore.formatSearchValue(MatchCore.fromSeconds(from - slack)),
         MatchCore.formatSearchValue(MatchCore.fromSeconds(to + slack))
end

--------------------------------------------------------------------------------
-- Location
--------------------------------------------------------------------------------

--- The true coordinates of an observation, or nil when they are not knowable.
--
-- An obscured observation reports a deliberately wrong public location, up to
-- about 30 km from the truth, and it reports it in the same field and the same
-- format as an honest one. Treating that as corroboration would turn every
-- obscured observation into a location conflict and demote perfectly good
-- matches. Only `private_location` is believed, and its absence means no
-- opinion rather than a bad one.
--
-- Kept in step with SyncCore.coordinatesFrom deliberately: two answers to
-- "where was this" is one more than the plugin can afford.
function MatchCore.coordinatesFrom(observation)
  if type(observation) ~= "table" then return nil, nil end

  local point = observation.private_location
  if not point or point == "" then
    if observation.obscured then return nil, nil end
    point = observation.location
  end
  if type(point) ~= "string" or point == "" then return nil, nil end

  local latitude, longitude = string.match(point,
    "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
  return tonumber(latitude), tonumber(longitude)
end

--- Great-circle distance in metres.
function MatchCore.distanceMetres(lat1, lon1, lat2, lon2)
  if not (lat1 and lon1 and lat2 and lon2) then return nil end

  local R = 6371000
  local toRad = math.pi / 180

  local dLat = (lat2 - lat1) * toRad
  local dLon = (lon2 - lon1) * toRad
  local a = math.sin(dLat / 2) ^ 2
    + math.cos(lat1 * toRad) * math.cos(lat2 * toRad) * math.sin(dLon / 2) ^ 2

  return 2 * R * math.atan2(math.sqrt(a), math.sqrt(1 - a))
end

--------------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------------

--- Rate one candidate photo against one observation.
--
-- Time has already done its work by the time this is called -- the candidate
-- came out of a window query -- so this only decides how much to trust the
-- match, and never rejects one outright on location. A conflict is reported
-- rather than discarded because "iNat thinks this was 40 km away" is a thing
-- the user can adjudicate and this module cannot.
--
-- @param photoInfo { seconds = wall-clock seconds, latitude = , longitude = }
-- @return tier, distanceMetres, secondsApart
function MatchCore.rate(observation, photoInfo)
  local from, to = MatchCore.observedSpan(observation)
  local apart = nil
  if from and photoInfo.seconds then
    -- Distance to the span, not to its start. A minute-precision observation
    -- is equally consistent with every frame inside its minute, so calling a
    -- photo at :41 "41 seconds out" would both rank it last and tell the user
    -- it barely matched, when it is in fact a perfect fit for what iNaturalist
    -- actually recorded.
    if photoInfo.seconds < from then
      apart = from - photoInfo.seconds
    elseif photoInfo.seconds > to then
      apart = photoInfo.seconds - to
    else
      apart = 0
    end
  end

  local obsLat, obsLon = MatchCore.coordinatesFrom(observation)
  local distance = MatchCore.distanceMetres(obsLat, obsLon,
    photoInfo.latitude, photoInfo.longitude)

  if not distance then
    return MatchCore.LIKELY, nil, apart
  elseif distance <= MatchCore.NEAR_METRES then
    return MatchCore.CONFIRMED, distance, apart
  elseif distance >= MatchCore.FAR_METRES then
    return MatchCore.CONFLICT, distance, apart
  end
  return MatchCore.LIKELY, distance, apart
end

--- Every candidate for one observation, best first.
--
-- An observation is allowed more than one photo -- that is how iNaturalist
-- works, and a burst of a settled insect is the ordinary case -- so the review
-- list wants all of them as separate rows rather than one row and a note
-- saying two others existed. The user can then untick the frames they do not
-- want, which is also the only way to recover when the closest-in-time frame
-- is not the one the observation was made from.
--
-- Ordering is the same judgement chooseMatch makes: closest in time wins, and
-- location breaks a tie that time cannot. table.sort is not stable, so the
-- original position is the final tiebreak -- otherwise two frames on the same
-- second could swap places between runs and the row order would wander.
--
-- @return array of { photo, path, tier, distance, secondsApart }
function MatchCore.rankMatches(observation, candidates)
  if type(candidates) ~= "table" or #candidates == 0 then return {} end

  local rated = {}
  for index, candidate in ipairs(candidates) do
    local tier, distance, apart = MatchCore.rate(observation, candidate)
    rated[#rated + 1] = {
      photo        = candidate.photo,
      path         = candidate.path,
      tier         = tier,
      distance     = distance,
      secondsApart = apart,
      _score       = apart or math.huge,
      _index       = index,
    }
  end

  table.sort(rated, function(left, right)
    if left._score ~= right._score then return left._score < right._score end

    local leftConfirmed  = left.tier == MatchCore.CONFIRMED
    local rightConfirmed = right.tier == MatchCore.CONFIRMED
    if leftConfirmed ~= rightConfirmed then return leftConfirmed end

    return left._index < right._index
  end)

  for _, entry in ipairs(rated) do
    entry._score = nil
    entry._index = nil
  end

  return rated
end

--- Pick the best candidate for one observation.
--
-- Ties are the interesting case. A burst of frames two seconds apart is one
-- observation and several equally good photos, and picking the first quietly
-- would link an arbitrary one of them. Instead the closest in time wins, and
-- `ambiguous` is set whenever anything else was within a second of it.
--
-- Kept alongside rankMatches because "which single photo is this observation
-- of" is still a real question -- it is what a caller that is not offering a
-- choice needs, and what decides which row is ticked first.
--
-- @param candidates array of { photo = , seconds = , latitude = , longitude = ,
--                              path = }
-- @return { photo, path, tier, distance, secondsApart, ambiguous, alternatives }
function MatchCore.chooseMatch(observation, candidates)
  local ranked = MatchCore.rankMatches(observation, candidates)
  if #ranked == 0 then return nil end

  local best = ranked[1]
  local bestApart = best.secondsApart or math.huge

  -- Counted by position rather than by comparing photos. Identity looks like
  -- the obvious key and is not: virtual copies, and any caller that reuses one
  -- table for several rows, make two distinct candidates compare equal, and
  -- the failure is silent -- a burst reports itself as unambiguous and the
  -- user is never asked which frame they meant.
  local alternatives = 0
  for position = 2, #ranked do
    local apart = ranked[position].secondsApart
    if apart and bestApart and math.abs(apart - bestApart) <= 1 then
      alternatives = alternatives + 1
    end
  end

  best.ambiguous    = alternatives > 0
  best.alternatives = alternatives
  return best
end

return MatchCore
