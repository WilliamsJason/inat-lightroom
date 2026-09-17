--[[
  Sha256.lua
  ----------
  SHA-256 and base64url, which exist here only to serve PKCE.

  PKCE needs exactly two things the plain Lua standard library cannot do:
  hash the code verifier with SHA-256, and base64url the raw digest. This
  module is the whole of that, and nothing else in the plugin should need it.

  ## Where the hash comes from

  Lightroom does ship SHA-256, but not anywhere the documentation admits.
  `LrDigest` is not in the SDK reference, and it is not in substrate.dll with
  the namespaces that are. It lives in `ftp_client.dll`, listed in that
  toolkit's `AgExports` table beside `LrFtp` -- which is a public, documented
  namespace. Being in `AgExports` is what makes a name reachable by `import`,
  so `LrDigest` is importable for the same reason `LrFtp` is. Underneath it is
  a C module, `WFDigestImpl`, wrapping OpenSSL: the binary carries
  `SHA256_Init`, `SHA256_Update`, `SHA256_Final`, `EVP_sha256` and the matching
  SHA1 and HMAC entry points.

  That is an inference from a binary, not a promise from Adobe, which is why
  nothing below trusts it. `resolve()` tries the plausible shapes and then
  makes the winner hash "abc" and compares against the published SHA-256 test
  vector. A wrong shape, a changed return type, or a missing namespace all end
  up in the same place: `Sha256.available()` returns false with a reason, and
  the caller offers the user the pasted-token path instead of failing halfway
  through a sign-in.

  rcloran's lr-inaturalist-publish bundles a ~500-line pure-Lua SHA-256 rather
  than doing this. That also works, and is the fallback if `LrDigest` ever
  stops being importable -- the known-answer check is what would tell us.

  ## Why hex, not binary

  Lightroom's Lua is 5.1, with no bitwise operators, and `LrStringUtils`
  encodeBase64 is a C function whose behaviour on a string containing NUL
  bytes is untested and awkward to test. Both problems disappear by never
  holding a raw digest: `LrDigest` returns lowercase hex, and
  `base64urlFromHex` goes straight from hex to base64url with arithmetic. A
  32-byte digest is 10 full 3-byte groups plus a 2-byte remainder, so this
  runs a few hundred operations once per sign-in.
--]]

local Sha256 = {}

-- SHA-256 of "abc", from FIPS 180-4. Any implementation that does not produce
-- this is not one we are willing to build a login on.
local KNOWN_INPUT  = "abc"
local KNOWN_DIGEST =
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

--------------------------------------------------------------------------------
-- Resolving an implementation
--------------------------------------------------------------------------------

-- Resolution is cached rather than repeated: it costs an import and a hash,
-- and the answer cannot change within a session.
local resolved      = nil
local resolveFailed = nil

--- Candidate call shapes for LrDigest's SHA-256, most likely first.
--
-- The strings in ftp_client.dll around the digest module are "init", "update"
-- and "digest", which covers both a one-shot `digest(s)` and an incremental
-- handle. Both are tried; whichever produces the right answer wins.
local function candidates(LrDigest)
  local sha = LrDigest and LrDigest.SHA256
  if not sha then return {} end

  return {
    -- One-shot: LrDigest.SHA256.digest("abc")
    function(s)
      if type(sha.digest) ~= "function" then return nil end
      return sha.digest(s)
    end,

    -- Callable table: LrDigest.SHA256("abc")
    function(s)
      local mt = getmetatable(sha)
      if type(sha) ~= "function" and not (mt and mt.__call) then return nil end
      return sha(s)
    end,

    -- Incremental: h = LrDigest.SHA256.init(); h:update(s); h:digest()
    function(s)
      if type(sha.init) ~= "function" then return nil end
      local handle = sha.init()
      if type(handle) ~= "table" and type(handle) ~= "userdata" then
        return nil
      end
      handle:update(s)
      return handle:digest()
    end,
  }
end

--- Normalise whatever a candidate returned to lowercase hex, or nil.
--
-- A digest that came back as raw bytes rather than hex is converted rather
-- than rejected: the check that matters is the value, not the encoding.
local function toHex(value)
  if type(value) ~= "string" then return nil end

  if #value == 64 and value:match("^%x+$") then
    return value:lower()
  end

  if #value == 32 then
    local out = {}
    for i = 1, 32 do
      out[i] = string.format("%02x", value:byte(i))
    end
    return table.concat(out)
  end

  return nil
end

--- Find a working SHA-256, or record why there is not one.
-- @return function(string) -> lowercase hex, or nil plus a reason
local function resolve()
  if resolved then return resolved, nil end
  if resolveFailed then return nil, resolveFailed end

  local ok, LrDigest = pcall(import, "LrDigest")
  if not ok or type(LrDigest) ~= "table" then
    resolveFailed = "This version of Lightroom does not provide LrDigest, "
      .. "so the plugin cannot compute the SHA-256 that browser sign-in needs."
    return nil, resolveFailed
  end

  for _, candidate in ipairs(candidates(LrDigest)) do
    local called, raw = pcall(candidate, KNOWN_INPUT)
    if called then
      local hex = toHex(raw)
      if hex == KNOWN_DIGEST then
        resolved = function(s)
          local hashed, result = pcall(candidate, s)
          if not hashed then return nil end
          return toHex(result)
        end
        return resolved, nil
      end
    end
  end

  resolveFailed = "Lightroom's LrDigest did not produce a correct SHA-256, "
    .. "so the plugin cannot use browser sign-in."
  return nil, resolveFailed
end

--- Whether SHA-256 is usable in this Lightroom.
-- @return true, or false plus a reason fit to show a user
function Sha256.available()
  local hash, reason = resolve()
  if hash then return true, nil end
  return false, reason
end

--- SHA-256 of a string, as lowercase hex.
-- @return hex string, or nil plus a reason
function Sha256.hex(input)
  local hash, reason = resolve()
  if not hash then return nil, reason end

  local digest = hash(input)
  if not digest then
    return nil, "SHA-256 failed on this input."
  end
  return digest, nil
end

--------------------------------------------------------------------------------
-- base64url
--------------------------------------------------------------------------------

local ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

--- base64url of the bytes a hex string describes, unpadded.
--
-- Unpadded because RFC 7636 says so: the code challenge carries no "="
-- characters, which would need percent-encoding in a query string anyway.
--
-- Arithmetic rather than bitwise operators, because Lightroom's Lua is 5.1
-- and has none. Three bytes become a 24-bit number and then four 6-bit
-- indices; a trailing group of two bytes yields three characters, one byte
-- yields two, and neither is padded.
function Sha256.base64urlFromHex(hex)
  if type(hex) ~= "string" or hex == "" or not hex:match("^%x+$")
      or #hex % 2 ~= 0 then
    return nil
  end

  local bytes = {}
  for pair in hex:gmatch("%x%x") do
    bytes[#bytes + 1] = tonumber(pair, 16)
  end

  local out   = {}
  local total = #bytes
  local i     = 1

  local function char(sixBits)
    return ALPHABET:sub(sixBits + 1, sixBits + 1)
  end

  while i + 2 <= total do
    local n = bytes[i] * 65536 + bytes[i + 1] * 256 + bytes[i + 2]
    out[#out + 1] = char(math.floor(n / 262144) % 64)
      .. char(math.floor(n / 4096) % 64)
      .. char(math.floor(n / 64) % 64)
      .. char(n % 64)
    i = i + 3
  end

  local left = total - i + 1
  if left == 2 then
    local n = bytes[i] * 65536 + bytes[i + 1] * 256
    out[#out + 1] = char(math.floor(n / 262144) % 64)
      .. char(math.floor(n / 4096) % 64)
      .. char(math.floor(n / 64) % 64)
  elseif left == 1 then
    local n = bytes[i] * 65536
    out[#out + 1] = char(math.floor(n / 262144) % 64)
      .. char(math.floor(n / 4096) % 64)
  end

  return table.concat(out)
end

return Sha256
