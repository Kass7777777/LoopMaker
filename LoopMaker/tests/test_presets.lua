local helper = require("tests.test_helper")
local presets = require("lib.presets")
local settings = require("lib.settings")

local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local SECTION = "Sol_LoopMaker"
local INDEX_KEY = "preset_names"

local function assert_contains(text, fragment, message)
  assert_true(type(text) == "string" and text:find(fragment, 1, true) ~= nil,
    message or ("expected " .. tostring(text) .. " to contain " .. fragment))
end

local function assert_array(expected, actual)
  assert_equal(#expected, #actual, "array length differs")
  for index, value in ipairs(expected) do
    assert_equal(value, actual[index], "array differs at index " .. index)
  end
end

local function make_api(options)
  options = options or {}
  local store = options.store or {}
  local calls = {}
  local api = {}

  function api.GetExtState(section, key)
    calls[#calls + 1] = { method = "get", section = section, key = key }
    if options.throw_get then
      error("get exploded")
    end
    if options.false_get then
      return false
    end
    return store[section .. "\0" .. key] or ""
  end

  function api.SetExtState(section, key, value, persist)
    calls[#calls + 1] = {
      method = "set", section = section, key = key, value = value, persist = persist,
    }
    if persist and (value:find("\r", 1, true) or value:find("\n", 1, true)) then
      error("persistent ExtState values must be single-line")
    end
    if options.throw_set_key == key then
      error("set exploded")
    end
    if options.false_set_key == key then
      return false
    end
    store[section .. "\0" .. key] = value
  end

  function api.DeleteExtState(section, key, persist)
    calls[#calls + 1] = {
      method = "delete", section = section, key = key, persist = persist,
    }
    if options.throw_delete then
      error("delete exploded")
    end
    if options.false_delete then
      return false
    end
    store[section .. "\0" .. key] = nil
  end

  return api, store, calls
end

local function stored(store, key)
  return store[SECTION .. "\0" .. key]
end

test("settings encoding is stable and includes only default fields", function()
  local first = presets.encode_settings({
    suffix = "tail",
    loops = 3,
    glue = false,
    unknown = "ignored",
  })
  local second = presets.encode_settings({
    glue = false,
    unknown = 123,
    loops = 3,
    suffix = "tail",
  })

  assert_equal(first, second)
  assert_equal(nil, first:find("unknown", 1, true))

  assert_equal(nil, first:find("\r", 1, true))
  assert_equal(nil, first:find("\n", 1, true))

  local previous
  for token in first:gmatch("[^;]+") do
    local key = token:match("^([^=]+)=")
    assert_true(key ~= nil, "encoded setting token has no key")
    if previous then
      assert_true(previous < key, "setting keys are not sorted")
    end
    previous = key
  end
end)

test("settings round trip numbers booleans and every required control byte", function()
  local input = settings.defaults()
  input.loops = 7
  input.glue = false
  input.prefix = "\0\r\n\t\\=中文"

  local encoded = presets.encode_settings(input)
  local decoded = presets.decode_settings(encoded)

  assert_contains(encoded, "prefix=string:%00%0D%0A%09%5C%3D%E4%B8%AD%E6%96%87")
  assert_equal(nil, encoded:find("\0", 1, true))
  assert_equal(nil, encoded:find("\r", 1, true))
  assert_equal(nil, encoded:find("\t", 1, true))
  assert_equal(7, decoded.loops)
  assert_equal(false, decoded.glue)
  assert_equal(input.prefix, decoded.prefix)
end)

test("settings decoder rejects damaged percent strings without truncating later fields", function()
  local defaults = settings.defaults()
  local decoded, warnings = presets.decode_settings(table.concat({
    "prefix=string:%61%62%0",
    "suffix=string:%61%66%74%65%72",
  }, ";"))

  assert_equal(defaults.prefix, decoded.prefix)
  assert_equal("after", decoded.suffix)
  assert_true(#warnings >= 1)
  assert_contains(warnings[1], "prefix")
end)

test("settings decoder falls back for NaN and infinity text", function()
  local defaults = settings.defaults()
  local decoded = presets.decode_settings(table.concat({
    "loops=number:nan",
    "cf_ratio=number:inf",
    "pitch=number:-inf",
  }, ";"))

  assert_equal(defaults.loops, decoded.loops)
  assert_equal(defaults.cf_ratio, decoded.cf_ratio)
  assert_equal(defaults.pitch, decoded.pitch)
end)

test("settings decoder never executes malicious text", function()
  _G.__preset_attack_executed = false
  local decoded = presets.decode_settings(table.concat({
    "prefix=string:%73%61%66%65",
    "loops=number:(function() _G.__preset_attack_executed=true return 9 end)()",
    "suffix=string:%6C%6F%61%64%73%74%72%69%6E%67%28%27%65%72%72%6F%72%27%29",
  }, ";"))

  assert_equal(false, _G.__preset_attack_executed)
  assert_equal(settings.defaults().loops, decoded.loops)
  assert_equal("safe", decoded.prefix)
  assert_equal("loadstring('error')", decoded.suffix)
  _G.__preset_attack_executed = nil
end)

test("settings decoder ignores unknown and damaged lines then sanitizes", function()
  local defaults = settings.defaults()
  local decoded = presets.decode_settings(table.concat({
    "loops=string:99",
    "glue=boolean:not-a-bool",
    "prefix=string:bad\\qescape",
    "unknown=number:42",
    "not a setting line",
    "cf_ratio=number:8",
    "pitch=number:-200",
  }, ";"))

  assert_equal(defaults.loops, decoded.loops)
  assert_equal(defaults.glue, decoded.glue)
  assert_equal(defaults.prefix, decoded.prefix)
  assert_equal(nil, decoded.unknown)
  assert_equal(0.5, decoded.cf_ratio)
  assert_equal(-96, decoded.pitch)
end)

test("name encoding removes empty invalid duplicate names and sorts", function()
  local long_name = string.rep("a", 65)
  local encoded = presets.encode_names({
    "中文预设", "Alpha", "中文预设", "", "bad\tname", long_name, 42,
  })
  local decoded = presets.decode_names(encoded)

  assert_array({ "Alpha", "中文预设" }, decoded)
end)

test("name length limit counts Unicode codepoints instead of UTF-8 bytes", function()
  local exactly_64 = string.rep("界", 64)
  local too_long = string.rep("界", 65)

  assert_array({ exactly_64 }, presets.decode_names(presets.encode_names({ too_long, exactly_64 })))
  assert_true(type(presets.preset_key(exactly_64)) == "string")
  local key, reason = presets.preset_key(too_long)
  assert_equal(nil, key)
  assert_true(type(reason) == "string")
end)

test("names reject invalid UTF-8 non-scalars DEL and C1 controls", function()
  local invalid_utf8 = string.char(0xC3, 0x28)
  local surrogate = string.char(0xED, 0xA0, 0x80)
  local del = "bad" .. string.char(0x7F) .. "name"
  local c1 = "bad" .. string.char(0xC2, 0x80) .. "name"

  for _, name in ipairs({ invalid_utf8, surrogate, del, c1 }) do
    local key, reason = presets.preset_key(name)
    assert_equal(nil, key)
    assert_true(type(reason) == "string")
  end
  assert_array({}, presets.decode_names(
    presets.encode_names({ invalid_utf8, surrogate, del, c1 })))
end)

test("names reject only ASCII-whitespace-only values and allow Unicode whitespace", function()
  for _, name in ipairs({ "", " ", " \t\r\n " }) do
    local key, reason = presets.preset_key(name)
    assert_equal(nil, key)
    assert_true(type(reason) == "string")
  end

  local full_width_space = "　"
  assert_true(type(presets.preset_key(full_width_space)) == "string")
  assert_array({ full_width_space },
    presets.decode_names(presets.encode_names({ full_width_space })))
end)

test("name encoding is single-line and safely round trips common symbols", function()
  local names = { "A:B% C", "中文-预设_1", "path\\name=ok" }
  local encoded = presets.encode_names(names)
  local decoded = presets.decode_names(encoded)

  assert_equal(nil, encoded:find("\r", 1, true))
  assert_equal(nil, encoded:find("\n", 1, true))
  assert_contains(encoded, "%41%3A%42%25%20%43")
  assert_contains(encoded, ";")
  table.sort(names)
  assert_array(names, decoded)
end)

test("name decoder warns about malformed escaped and control-character entries", function()
  local decoded, warnings = presets.decode_names(table.concat({
    "%47%6F%6F%64%20%4E%61%6D%65",
    "%ZZ",
    "%C3%28",
    "%62%61%64%0A%6E%61%6D%65",
    "%62%61%64%7F%6E%61%6D%65",
    "%62%61%64%C2%80%6E%61%6D%65",
    string.rep("%61", 65),
    "%47%6F%6F%64%20%4E%61%6D%65",
  }, ";"))

  assert_array({ "Good Name" }, decoded)
  assert_true(#warnings >= 6)
end)

test("preset key percent-encodes collision characters and UTF-8 bytes", function()
  assert_equal("preset:A%3AB%25C", presets.preset_key("A:B%C"))
  assert_equal("preset:%E4%B8%AD%E6%96%87", presets.preset_key("中文"))
  local key, reason = presets.preset_key("bad\nname")
  assert_equal(nil, key)
  assert_true(type(reason) == "string")
end)

test("list reads the fixed section and sorted index", function()
  local api, store, calls = make_api()
  store[SECTION .. "\0" .. INDEX_KEY] = presets.encode_names({ "Zulu", "Alpha", "中文" })

  local names, reason = presets.list(api)

  assert_equal(nil, reason)
  assert_array({ "Alpha", "Zulu", "中文" }, names)
  assert_equal("get", calls[1].method)
  assert_equal(SECTION, calls[1].section)
  assert_equal(INDEX_KEY, calls[1].key)
end)

test("list and load expose warnings for damaged persisted data", function()
  local api, store = make_api()
  store[SECTION .. "\0" .. INDEX_KEY] = presets.encode_names({ "Good" }) .. ";%ZZ"
  store[SECTION .. "\0" .. presets.preset_key("Good")] =
    "loops=number:2;prefix=string:%0"

  local names, list_reason, list_warnings = presets.list(api)
  assert_equal(nil, list_reason)
  assert_array({ "Good" }, names)
  assert_true(#list_warnings >= 1)

  local loaded, load_reason, load_warnings = presets.load(api, "Good")
  assert_equal(nil, load_reason)
  assert_equal(2, loaded.loops)
  assert_equal(settings.defaults().prefix, loaded.prefix)
  assert_true(#load_warnings >= 1)
end)

test("list returns an empty array and reason when API is missing throws or returns false", function()
  local missing, missing_reason = presets.list({})
  assert_array({}, missing)
  assert_true(type(missing_reason) == "string")

  local throwing = make_api({ throw_get = true })
  local thrown, thrown_reason = presets.list(throwing)
  assert_array({}, thrown)
  assert_contains(thrown_reason, "GetExtState")

  local false_api = make_api({ false_get = true })
  local false_names, false_reason = presets.list(false_api)
  assert_array({}, false_names)
  assert_contains(false_reason, "GetExtState")
end)

test("save load and delete round trip through ExtState", function()
  local api, store = make_api()
  local saved, save_reason = presets.save(api, "中文预设", {
    loops = 4.6,
    prefix = "loop=前缀\\",
    extra = "ignored",
  })
  assert_equal(true, saved)
  assert_equal(nil, save_reason)

  local names = presets.list(api)
  assert_array({ "中文预设" }, names)

  local loaded, load_reason = presets.load(api, "中文预设")
  assert_equal(nil, load_reason)
  assert_equal(5, loaded.loops)
  assert_equal("loop=前缀\\", loaded.prefix)
  assert_equal(nil, loaded.extra)

  local deleted, delete_reason = presets.delete(api, "中文预设")
  assert_equal(true, deleted)
  assert_equal(nil, delete_reason)
  assert_equal(nil, stored(store, presets.preset_key("中文预设")))
  assert_array({}, presets.list(api))
end)

test("save preserves de-duplicates and sorts a single-line multi-name index", function()
  local api, store = make_api()
  store[SECTION .. "\0" .. INDEX_KEY] = presets.encode_names({ "Zulu", "Alpha", "Zulu" })

  assert_equal(true, presets.save(api, "Middle", { loops = 2 }))
  assert_equal(true, presets.save(api, "Alpha", { loops = 3 }))

  local index_value = stored(store, INDEX_KEY)
  assert_equal(nil, index_value:find("\r", 1, true))
  assert_equal(nil, index_value:find("\n", 1, true))
  assert_array({ "Alpha", "Middle", "Zulu" }, presets.decode_names(index_value))
end)

test("void SetExtState and DeleteExtState nil returns are successful", function()
  local api = make_api()
  local saved, save_reason = presets.save(api, "VoidAPI", { loops = 2 })
  assert_equal(true, saved)
  assert_equal(nil, save_reason)

  local deleted, delete_reason = presets.delete(api, "VoidAPI")
  assert_equal(true, deleted)
  assert_equal(nil, delete_reason)
end)

test("save and delete continue past a damaged index and return warnings", function()
  local api, store = make_api()
  store[SECTION .. "\0" .. INDEX_KEY] = presets.encode_names({ "Alpha" }) .. ";%ZZ"

  local saved, save_reason, save_warnings = presets.save(api, "Beta", {})
  assert_equal(true, saved)
  assert_equal(nil, save_reason)
  assert_true(#save_warnings >= 1)
  assert_array({ "Alpha", "Beta" }, presets.decode_names(stored(store, INDEX_KEY)))

  store[SECTION .. "\0" .. INDEX_KEY] = presets.encode_names({ "Beta" }) .. ";%ZZ"
  local deleted, delete_reason, delete_warnings = presets.delete(api, "Beta")
  assert_equal(true, deleted)
  assert_equal(nil, delete_reason)
  assert_true(#delete_warnings >= 1)
end)

test("save and delete pass default and explicit persist flags to every write", function()
  local api, _, calls = make_api()
  assert_equal(true, presets.save(api, "DefaultPersist", {}))
  assert_equal(true, presets.save(api, "SessionOnly", {}, false))
  assert_equal(true, presets.delete(api, "SessionOnly", false))

  local writes = {}
  for _, call in ipairs(calls) do
    if call.method == "set" or call.method == "delete" then
      writes[#writes + 1] = call
    end
  end

  local expected = {
    { "set", presets.preset_key("DefaultPersist"), true },
    { "set", INDEX_KEY, true },
    { "set", presets.preset_key("SessionOnly"), false },
    { "set", INDEX_KEY, false },
    { "delete", presets.preset_key("SessionOnly"), false },
    { "set", INDEX_KEY, false },
  }
  assert_equal(#expected, #writes)
  for index, value in ipairs(expected) do
    assert_equal(value[1], writes[index].method, "wrong method at write " .. index)
    assert_equal(value[2], writes[index].key, "wrong key at write " .. index)
    assert_equal(value[3], writes[index].persist, "wrong persist flag at write " .. index)
  end
end)

test("load rejects invalid names and reports missing presets", function()
  local api = make_api()
  local empty, empty_reason = presets.load(api, "")
  assert_equal(nil, empty)
  assert_true(type(empty_reason) == "string")

  local invalid, invalid_reason = presets.load(api, "bad\nname")
  assert_equal(nil, invalid)
  assert_true(type(invalid_reason) == "string")

  local missing, missing_reason = presets.load(api, "Missing")
  assert_equal(nil, missing)
  assert_contains(missing_reason, "not found")
end)

test("load reports missing throwing and false APIs", function()
  local missing, missing_reason = presets.load({}, "Name")
  assert_equal(nil, missing)
  assert_contains(missing_reason, "GetExtState")

  local throwing = make_api({ throw_get = true })
  local thrown, thrown_reason = presets.load(throwing, "Name")
  assert_equal(nil, thrown)
  assert_contains(thrown_reason, "GetExtState")

  local false_api = make_api({ false_get = true })
  local false_value, false_reason = presets.load(false_api, "Name")
  assert_equal(nil, false_value)
  assert_contains(false_reason, "GetExtState")
end)

test("save rejects invalid names before writing", function()
  local api, _, calls = make_api()
  local invalid, invalid_reason = presets.save(api, string.rep("界", 65), {})
  assert_equal(nil, invalid)
  assert_true(type(invalid_reason) == "string")
  assert_equal(0, #calls)
end)

test("save safely reports each missing required API", function()
  for _, method in ipairs({ "GetExtState", "SetExtState" }) do
    local api = make_api()
    api[method] = nil
    local result, reason = presets.save(api, "Name", {})
    assert_equal(nil, result)
    assert_contains(reason, method)
  end
end)

test("save reports false and thrown preset writes", function()
  local key = presets.preset_key("Name")
  local false_api = make_api({ false_set_key = key })
  local false_result, false_reason = presets.save(false_api, "Name", {})
  assert_equal(nil, false_result)
  assert_contains(false_reason, "SetExtState")
  assert_equal(nil, false_reason:find("partial", 1, true))

  local throwing = make_api({ throw_set_key = key })
  local thrown_result, thrown_reason = presets.save(throwing, "Name", {})
  assert_equal(nil, thrown_result)
  assert_contains(thrown_reason, "SetExtState")
end)

test("save reports partial failure when index write returns false", function()
  local api, store = make_api({ false_set_key = INDEX_KEY })
  local result, reason = presets.save(api, "Written", { loops = 6 })

  assert_equal(nil, result)
  assert_contains(reason, "partial")
  assert_true(type(stored(store, presets.preset_key("Written"))) == "string")
  assert_equal(nil, stored(store, INDEX_KEY))
end)

test("save reports partial failure when index write throws", function()
  local api, store = make_api({ throw_set_key = INDEX_KEY })
  local result, reason = presets.save(api, "Written", { loops = 6 })

  assert_equal(nil, result)
  assert_contains(reason, "partial")
  assert_contains(reason, "SetExtState")
  assert_true(type(stored(store, presets.preset_key("Written"))) == "string")
end)

test("delete removes only the requested name and is idempotent", function()
  local api, store = make_api()
  assert_equal(true, presets.save(api, "Alpha", { loops = 2 }))
  assert_equal(true, presets.save(api, "Beta", { loops = 3 }))

  assert_equal(true, presets.delete(api, "Alpha"))
  assert_array({ "Beta" }, presets.list(api))
  assert_true(type(stored(store, presets.preset_key("Beta"))) == "string")

  assert_equal(true, presets.delete(api, "Alpha"))
  assert_array({ "Beta" }, presets.list(api))
end)

test("delete rejects invalid names", function()
  local invalid, invalid_reason = presets.delete({}, "bad\0name")
  assert_equal(nil, invalid)
  assert_true(type(invalid_reason) == "string")
end)

test("delete safely reports each missing required API", function()
  for _, method in ipairs({ "GetExtState", "SetExtState", "DeleteExtState" }) do
    local api = make_api()
    api[method] = nil
    local result, reason = presets.delete(api, "Name")
    assert_equal(nil, result)
    assert_contains(reason, method)
  end
end)

test("delete reports false and thrown DeleteExtState calls", function()
  local false_api = make_api({ false_delete = true })
  local false_result, false_reason = presets.delete(false_api, "Name")
  assert_equal(nil, false_result)
  assert_contains(false_reason, "DeleteExtState")
  assert_equal(nil, false_reason:find("partial", 1, true))

  local throwing = make_api({ throw_delete = true })
  local thrown_result, thrown_reason = presets.delete(throwing, "Name")
  assert_equal(nil, thrown_result)
  assert_contains(thrown_reason, "DeleteExtState")
end)

test("delete reports partial failure when index update returns false", function()
  local api, store = make_api()
  assert_equal(true, presets.save(api, "Doomed", {}))
  api = make_api({ store = store, false_set_key = INDEX_KEY })

  local result, reason = presets.delete(api, "Doomed")

  assert_equal(nil, result)
  assert_contains(reason, "partial")
  assert_equal(nil, stored(store, presets.preset_key("Doomed")))
  assert_array({ "Doomed" }, presets.decode_names(stored(store, INDEX_KEY)))
end)

test("delete reports partial failure when index update throws", function()
  local api, store = make_api()
  assert_equal(true, presets.save(api, "Doomed", {}))
  api = make_api({ store = store, throw_set_key = INDEX_KEY })

  local result, reason = presets.delete(api, "Doomed")

  assert_equal(nil, result)
  assert_contains(reason, "partial")
  assert_contains(reason, "SetExtState")
  assert_equal(nil, stored(store, presets.preset_key("Doomed")))
end)

return true
