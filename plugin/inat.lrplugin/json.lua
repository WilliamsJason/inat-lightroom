--[[
  json.lua  (bundled)
  -------------------
  Minimal JSON encoder / decoder for the iNaturalist Lightroom plugin.

  Adapted from the public-domain "json.lua" by rxi
  (https://github.com/rxi/json.lua, MIT License).

  Only the subset needed by this plugin is included:
    json.encode(value)  ->  JSON string
    json.decode(str)    ->  Lua value

  Limitations:
  - Numbers are represented as Lua numbers (double).
  - Unicode escape sequences (\uXXXX) in strings are left as-is.
  - Does not validate UTF-8.
--]]

local json = { _version = "0.1.3" }

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local encode

local escape_char_map = {
  ["\\"] = "\\\\", ['"'] = '\\"', ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n",  ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_string(s)
  return s:gsub('[\\"%c]', function(c)
    return escape_char_map[c] or string.format("\\u%04x", c:byte())
  end)
end

local function encode_nil()    return "null" end
local function encode_bool(b)  return b and "true" or "false" end

local function encode_number(n)
  if n ~= n then return "null" end          -- NaN
  if n == math.huge  then return "1e309" end
  if n == -math.huge then return "-1e309" end
  return tostring(n)
end

local function encode_string(s)
  return '"' .. escape_string(s) .. '"'
end

local function encode_table(val, stack)
  local res = {}
  stack = stack or {}
  if stack[val] then error("circular reference") end
  stack[val] = true

  -- Determine array vs object
  local isArray = true
  local n = 0
  for k in pairs(val) do
    n = n + 1
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
      isArray = false
      break
    end
  end
  if isArray and n ~= #val then isArray = false end

  if isArray then
    for i = 1, #val do
      res[i] = encode(val[i], stack)
    end
    stack[val] = nil
    return "[" .. table.concat(res, ",") .. "]"
  else
    for k, v in pairs(val) do
      if type(k) ~= "string" then
        error("json.encode: table key must be a string, got " .. type(k))
      end
      res[#res + 1] = encode_string(k) .. ":" .. encode(v, stack)
    end
    stack[val] = nil
    return "{" .. table.concat(res, ",") .. "}"
  end
end

encode = function(val, stack)
  local t = type(val)
  if t == "nil"      then return encode_nil() end
  if t == "boolean"  then return encode_bool(val) end
  if t == "number"   then return encode_number(val) end
  if t == "string"   then return encode_string(val) end
  if t == "table"    then return encode_table(val, stack) end
  error("json.encode: unsupported type " .. t)
end

function json.encode(val)
  return encode(val)
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local function create_set(...)
  local res = {}
  for _, v in ipairs({...}) do res[v] = true end
  return res
end

local space_chars  = create_set(" ", "\t", "\r", "\n")
local delim_chars  = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")

local function next_char(str, idx, set, negate)
  for i = idx, #str do
    if set[str:sub(i,i)] ~= negate then return i end
  end
  return #str + 1
end

local function decode_error(str, idx, msg)
  local line_count = 1
  for i = 1, idx - 1 do
    if str:sub(i,i) == "\n" then line_count = line_count + 1 end
  end
  error(string.format("json.decode: %s at line %d col %d", msg, line_count, idx))
end

-- Lightroom embeds Lua 5.1, which has no bitwise operators. This has to be
-- done with plain arithmetic; using | and >> here is what stopped the whole
-- plugin from loading.
local function codepoint_to_utf8(cp)
  local floor = math.floor

  if cp <= 0x7F then
    return string.char(cp)
  end
  if cp <= 0x7FF then
    return string.char(
      floor(cp / 64) + 192,
      cp % 64 + 128)
  end
  if cp <= 0xFFFF then
    return string.char(
      floor(cp / 4096) + 224,
      floor(cp % 4096 / 64) + 128,
      cp % 64 + 128)
  end
  if cp <= 0x10FFFF then
    return string.char(
      floor(cp / 262144) + 240,
      floor(cp % 262144 / 4096) + 128,
      floor(cp % 4096 / 64) + 128,
      cp % 64 + 128)
  end

  error(string.format("json.decode: invalid unicode codepoint '%x'", cp))
end

local function parse_unicode_escape(str, i)
  local s = str:sub(i, i+3)
  if #s < 4 then decode_error(str, i, "invalid unicode escape") end
  local cp = tonumber(s, 16)
  if not cp then decode_error(str, i, "invalid unicode escape") end
  i = i + 4

  -- Handle surrogate pairs (\\uD800-\\uDFFF)
  if cp >= 0xD800 and cp <= 0xDBFF then
    if str:sub(i, i+1) ~= "\\u" then decode_error(str, i, "expected surrogate pair") end
    local cp2 = tonumber(str:sub(i+2, i+5), 16)
    if not cp2 then decode_error(str, i, "invalid surrogate pair") end
    cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
    i = i + 6
  end

  return codepoint_to_utf8(cp), i
end

local function parse_string(str, i)
  local res = {}
  local j = i + 1
  while j <= #str do
    local c = str:sub(j, j)
    if c == '"' then
      return table.concat(res), j + 1
    elseif c == "\\" then
      j = j + 1
      local esc = str:sub(j, j)
      if esc == "u" then
        local ch; ch, j = parse_unicode_escape(str, j + 1)
        res[#res+1] = ch
      elseif esc == "b" then res[#res+1] = "\b"; j = j + 1
      elseif esc == "f" then res[#res+1] = "\f"; j = j + 1
      elseif esc == "n" then res[#res+1] = "\n"; j = j + 1
      elseif esc == "r" then res[#res+1] = "\r"; j = j + 1
      elseif esc == "t" then res[#res+1] = "\t"; j = j + 1
      elseif esc == "\\" or esc == "/" or esc == '"' then
        res[#res+1] = esc; j = j + 1
      else
        decode_error(str, j, "invalid escape char " .. esc)
      end
    elseif c:byte() < 32 then
      decode_error(str, j, "control character in string")
    else
      res[#res+1] = c
      j = j + 1
    end
  end
  decode_error(str, j, "unterminated string")
end

local function parse_number(str, i)
  local s = str:sub(i):match("^-?%d+%.?%d*[eE]?[+%-]?%d*")
  if not s then decode_error(str, i, "invalid number") end
  local n = tonumber(s)
  if not n then decode_error(str, i, "invalid number") end
  return n, i + #s
end

local function parse_literal(str, i)
  local word = str:sub(i, i + 4)
  if word:sub(1,4) == "true"  then return true,  i + 4 end
  if word:sub(1,5) == "false" then return false, i + 5 end
  if word:sub(1,4) == "null"  then return nil,   i + 4 end
  decode_error(str, i, "invalid literal")
end

local decode_value  -- forward decl

local function parse_array(str, i)
  local res = {}
  local n   = 1
  i = i + 1  -- skip '['
  while true do
    i = next_char(str, i, space_chars, true)
    if str:sub(i,i) == "]" then return res, i + 1 end
    if n > 1 then
      if str:sub(i,i) ~= "," then decode_error(str, i, "expected ','") end
      i = next_char(str, i + 1, space_chars, true)
    end
    res[n], i = decode_value(str, i)
    n = n + 1
  end
end

local function parse_object(str, i)
  local res = {}
  local pairsSeen = 0
  i = i + 1  -- skip '{'
  while true do
    i = next_char(str, i, space_chars, true)
    if str:sub(i,i) == "}" then return res, i + 1 end

    -- Counted rather than asking whether the table is empty. `null` decodes to
    -- nil, so a pair whose value was null stores nothing, and next(res) still
    -- reports the object as empty -- at which point the comma before the next
    -- key is not consumed and the parser blames the key for not being a
    -- string. Any object whose first field was null failed to decode, and
    -- iNaturalist observations are full of them.
    if pairsSeen > 0 then
      if str:sub(i,i) ~= "," then decode_error(str, i, "expected ','") end
      i = next_char(str, i + 1, space_chars, true)
    end

    if str:sub(i,i) ~= '"' then decode_error(str, i, "expected string key") end
    local key; key, i = parse_string(str, i)
    i = next_char(str, i, space_chars, true)
    if str:sub(i,i) ~= ":" then decode_error(str, i, "expected ':'") end
    i = next_char(str, i + 1, space_chars, true)
    res[key], i = decode_value(str, i)
    pairsSeen = pairsSeen + 1
  end
end

decode_value = function(str, i)
  local c = str:sub(i,i)
  if c == '"'                then return parse_string(str, i)
  elseif c == "{"            then return parse_object(str, i)
  elseif c == "["            then return parse_array(str, i)
  elseif c == "-" or c:match("%d") then return parse_number(str, i)
  else                            return parse_literal(str, i)
  end
end

function json.decode(str)
  if type(str) ~= "string" then error("json.decode: expected string") end
  local i = next_char(str, 1, space_chars, true)
  local val, _ = decode_value(str, i)
  return val
end

return json
