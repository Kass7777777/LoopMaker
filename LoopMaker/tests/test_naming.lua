local helper = require("tests.test_helper")
local naming = require("lib.naming")

local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local function naming_settings(overrides)
  local result = {
    prefix = "",
    suffix = "",
    separator = "_",
    number = false,
    start_number = 1,
    leading_zeros = 2,
    remove_ext = false,
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

local function assert_rejected(result, reason)
  assert_equal(nil, result)
  assert_true(type(reason) == "string" and reason ~= "", "expected a rejection reason")
end

local function assert_contains(text, fragment)
  assert_true(type(text) == "string" and text:find(fragment, 1, true) ~= nil,
    "expected " .. tostring(text) .. " to contain " .. fragment)
end

test("remove_extension removes only the final extension", function()
  assert_equal("clip", naming.remove_extension("clip.wav"))
  assert_equal("archive.tar", naming.remove_extension("archive.tar.gz"))
  assert_equal(".hidden", naming.remove_extension(".hidden.txt"))
end)

test("remove_extension preserves hidden empty and extensionless names", function()
  assert_equal(".hidden", naming.remove_extension(".hidden"))
  assert_equal("", naming.remove_extension(""))
  assert_equal("clip", naming.remove_extension("clip"))
  assert_equal("trailing.", naming.remove_extension("trailing."))
end)

test("remove_extension safely handles a non-string", function()
  local ok, result = pcall(naming.remove_extension, false)
  assert_equal(true, ok)
  assert_equal("", result)
end)

test("build orders prefix original number and suffix with separators", function()
  local result = naming.build("kick.wav", naming_settings({
    prefix = "PRE",
    suffix = "SUF",
    number = true,
    start_number = 1,
    leading_zeros = 2,
    remove_ext = true,
  }), 2)

  assert_equal("PRE_kick_03_SUF", result)
end)

test("build skips empty components without extra separators", function()
  assert_equal("clip_END", naming.build("clip", naming_settings({ suffix = "END" }), 0))
  assert_equal("PRE_clip", naming.build("clip", naming_settings({ prefix = "PRE" }), 0))
  assert_equal("clip", naming.build("clip", naming_settings(), 0))
end)

test("build supports an empty separator", function()
  assert_equal("PREclip07END", naming.build("clip", naming_settings({
    prefix = "PRE",
    suffix = "END",
    separator = "",
    number = true,
    start_number = 7,
  }), 0))
end)

test("build uses leading_zeros as a minimum width without truncation", function()
  assert_equal("clip_0007", naming.build("clip", naming_settings({
    number = true,
    start_number = 7,
    leading_zeros = 4,
  }), 0))
  assert_equal("clip_1000", naming.build("clip", naming_settings({
    number = true,
    start_number = 98,
    leading_zeros = 2,
  }), 902))
end)

test("build can construct a name when the original name is empty", function()
  assert_equal("PRE-01-END", naming.build("", naming_settings({
    prefix = "PRE",
    suffix = "END",
    separator = "-",
    number = true,
  }), 0))
end)

test("build falls back to Loop when all components are empty", function()
  assert_equal("Loop", naming.build("", naming_settings(), 0))
end)

test("build does not modify input settings", function()
  local input = naming_settings({
    prefix = "PRE",
    suffix = "END",
    number = true,
    start_number = 2,
    leading_zeros = 3,
    remove_ext = true,
  })
  local snapshot = {}
  for key, value in pairs(input) do
    snapshot[key] = value
  end

  naming.build("clip.wav", input, 4)

  for key, value in pairs(snapshot) do
    assert_equal(value, input[key], "setting changed: " .. key)
  end
end)

test("build safely sanitizes bad input types and non-finite values", function()
  local bad_settings = {
    prefix = {},
    suffix = 1,
    separator = false,
    number = "yes",
    start_number = 0 / 0,
    leading_zeros = math.huge,
    remove_ext = "yes",
  }

  local ok, result = pcall(naming.build, false, bad_settings, 0)
  assert_equal(true, ok)
  assert_equal("01", result)
  assert_equal("yes", bad_settings.number)
end)

test("build rejects an invalid zero-based index", function()
  local configured = naming_settings({ number = true, start_number = 5 })
  local invalid = { -1, 1.5, 0 / 0, math.huge, -math.huge, "2", 1e100 }

  for _, index in ipairs(invalid) do
    local result, reason = naming.build("clip", configured, index)
    assert_rejected(result, reason)
    assert_contains(reason, "zero_based_index")
  end
end)

test("build accepts the maximum integer sum and rejects overflow", function()
  local configured = naming_settings({
    number = true,
    start_number = 1,
    leading_zeros = 0,
  })

  local result, reason = naming.build("clip", configured, math.maxinteger - 1)
  assert_equal("clip_" .. tostring(math.maxinteger), result)
  assert_equal(nil, reason)

  result, reason = naming.build("clip", configured, math.maxinteger)
  assert_rejected(result, reason)
  assert_equal("number overflow", reason)
end)

test("source_name prefers a non-empty take name", function()
  local take = {}
  local source_calls = 0
  local api = {}

  function api.GetSetMediaItemTakeInfo_String(actual_take, key, value, set_new)
    assert_equal(take, actual_take)
    assert_equal("P_NAME", key)
    assert_equal("", value)
    assert_equal(false, set_new)
    return true, "Take Name"
  end

  function api.GetMediaItemTake_Source()
    source_calls = source_calls + 1
    return {}
  end

  assert_equal("Take Name", naming.source_name(api, take))
  assert_equal(0, source_calls)
end)

test("source_name extracts Unix and Windows source basenames", function()
  local function source_api(path, take, source)
    return {
      GetSetMediaItemTakeInfo_String = function(actual_take, key, value, set_new)
        assert_equal(take, actual_take)
        assert_equal("P_NAME", key)
        assert_equal("", value)
        assert_equal(false, set_new)
        return true, ""
      end,
      GetMediaItemTake_Source = function(actual_take)
        assert_equal(take, actual_take)
        return source
      end,
      GetMediaSourceFileName = function(actual_source, buffer)
        assert_equal(source, actual_source)
        assert_equal("", buffer)
        return path
      end,
    }
  end

  local unix_take, unix_source = {}, {}
  local windows_take, windows_source = {}, {}
  assert_equal("kick.wav", naming.source_name(
    source_api("/samples/drums/kick.wav", unix_take, unix_source), unix_take))
  assert_equal("snare.wav", naming.source_name(
    source_api("C:\\samples\\snare.wav", windows_take, windows_source), windows_take))
end)

test("source_name ignores a take name when the API retval is false", function()
  local take = {}
  local source = {}
  local api = {
    GetSetMediaItemTakeInfo_String = function(actual_take, key, value, set_new)
      assert_equal(take, actual_take)
      assert_equal("P_NAME", key)
      assert_equal("", value)
      assert_equal(false, set_new)
      return false, "Stale Take Name"
    end,
    GetMediaItemTake_Source = function(actual_take)
      assert_equal(take, actual_take)
      return source
    end,
    GetMediaSourceFileName = function(actual_source, buffer)
      assert_equal(source, actual_source)
      assert_equal("", buffer)
      return "/samples/source.wav"
    end,
  }

  assert_equal("source.wav", naming.source_name(api, take))
end)

test("source_name falls back through empty missing and failed APIs", function()
  assert_equal("Item", naming.source_name({}, {}))
  assert_equal("Item", naming.source_name(nil, nil))

  local source_called = false
  local source_failure = {
    GetSetMediaItemTakeInfo_String = function()
      error("take lookup failed")
    end,
    GetMediaItemTake_Source = function()
      source_called = true
      error("source lookup failed")
    end,
    GetMediaSourceFileName = function()
      error("filename lookup must not be reached")
    end,
  }
  assert_equal("Item", naming.source_name(source_failure, {}))
  assert_equal(true, source_called)

  local filename_take, filename_source = {}, {}
  local filename_failure = {
    GetSetMediaItemTakeInfo_String = function()
      return true, ""
    end,
    GetMediaItemTake_Source = function(actual_take)
      assert_equal(filename_take, actual_take)
      return filename_source
    end,
    GetMediaSourceFileName = function(actual_source, buffer)
      assert_equal(filename_source, actual_source)
      assert_equal("", buffer)
      error("filename lookup failed")
    end,
  }
  assert_equal("Item", naming.source_name(filename_failure, filename_take))

  local empty_take, empty_source = {}, {}
  local empty = {
    GetSetMediaItemTakeInfo_String = function()
      return true, ""
    end,
    GetMediaItemTake_Source = function(actual_take)
      assert_equal(empty_take, actual_take)
      return empty_source
    end,
    GetMediaSourceFileName = function(actual_source, buffer)
      assert_equal(empty_source, actual_source)
      assert_equal("", buffer)
      return "C:\\samples\\"
    end,
  }
  assert_equal("Item", naming.source_name(empty, empty_take))
end)

test("apply_to_take writes a non-empty name", function()
  local take = {}
  local api = {}

  function api.GetSetMediaItemTakeInfo_String(actual_take, key, value, set_new)
    assert_equal(take, actual_take)
    assert_equal("P_NAME", key)
    assert_equal("Loop 01", value)
    assert_equal(true, set_new)
    return true
  end

  local result, reason = naming.apply_to_take(api, take, "Loop 01")
  assert_equal(true, result)
  assert_equal(nil, reason)
end)

test("apply_to_take rejects invalid names and missing API", function()
  local calls = 0
  local api = {
    GetSetMediaItemTakeInfo_String = function()
      calls = calls + 1
      return true
    end,
  }

  local result, reason = naming.apply_to_take(api, {}, "")
  assert_rejected(result, reason)
  result, reason = naming.apply_to_take(api, {}, 12)
  assert_rejected(result, reason)
  assert_equal(0, calls)

  result, reason = naming.apply_to_take({}, {}, "Loop")
  assert_rejected(result, reason)
end)

test("apply_to_take converts API failure and exceptions to reasons", function()
  local result, reason = naming.apply_to_take({
    GetSetMediaItemTakeInfo_String = function()
      return false
    end,
  }, {}, "Loop")
  assert_rejected(result, reason)

  result, reason = naming.apply_to_take({
    GetSetMediaItemTakeInfo_String = function()
      error("rename failed")
    end,
  }, {}, "Loop")
  assert_rejected(result, reason)
  assert_contains(reason, "rename failed")
end)

test("apply_color sets the REAPER custom-color flag", function()
  local item = {}
  local api = {}

  function api.SetMediaItemInfo_Value(actual_item, key, value)
    assert_equal(item, actual_item)
    assert_equal("I_CUSTOMCOLOR", key)
    assert_equal(0x123456 | 0x1000000, value)
    return true
  end

  local result, reason = naming.apply_color(api, item, 0x123456, true)
  assert_equal(true, result)
  assert_equal(nil, reason)
end)

test("apply_color does not call the API when disabled", function()
  local calls = 0
  local api = {
    SetMediaItemInfo_Value = function()
      calls = calls + 1
      error("must not be called")
    end,
  }

  local result, reason = naming.apply_color(api, {}, "invalid", false)
  assert_equal(true, result)
  assert_equal(nil, reason)
  assert_equal(0, calls)
end)

test("apply_color rejects invalid native colors", function()
  local calls = 0
  local api = {
    SetMediaItemInfo_Value = function()
      calls = calls + 1
      return true
    end,
  }
  local invalid = { "red", -1, 1.5, 0 / 0, math.huge, -math.huge, 1e100 }

  for _, color in ipairs(invalid) do
    local result, reason = naming.apply_color(api, {}, color, true)
    assert_rejected(result, reason)
  end
  assert_equal(0, calls)
end)

test("apply_color converts missing API failure and exceptions to reasons", function()
  local result, reason = naming.apply_color({}, {}, 1, true)
  assert_rejected(result, reason)

  result, reason = naming.apply_color({
    SetMediaItemInfo_Value = function()
      return false
    end,
  }, {}, 1, true)
  assert_rejected(result, reason)

  result, reason = naming.apply_color({
    SetMediaItemInfo_Value = function()
      error("color failed")
    end,
  }, {}, 1, true)
  assert_rejected(result, reason)
  assert_contains(reason, "color failed")
end)

return true
