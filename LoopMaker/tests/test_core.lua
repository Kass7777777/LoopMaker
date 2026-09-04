local helper = require("tests.test_helper")
local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local function load_core()
  return require("lib.core")
end

local function load_settings()
  return require("lib.settings")
end

local function load_path_utils()
  return require("tests.path_utils")
end

test("runner path resolves the LoopMaker root across launch forms", function()
  local project_root = load_path_utils().project_root
  local cases = {
    { "run.lua", ".." },
    { "./run.lua", ".." },
    { "tests/run.lua", "." },
    { "./tests/run.lua", "." },
    { "C:\\Projects\\LoopMaker\\tests\\run.lua", "C:/Projects/LoopMaker" },
    { "/opt/LoopMaker/tests/run.lua", "/opt/LoopMaker" },
  }

  for _, case in ipairs(cases) do
    assert_equal(case[2], project_root(case[1]), "wrong root for runner path: " .. case[1])
  end
end)

test("empty test registry reports failure", function()
  local empty = helper.create()
  assert_equal(0, empty.count())

  local passed, failed = empty.run(false)

  assert_equal(0, passed)
  assert_equal(1, failed)
end)

test("clamp limits values to the requested range", function()
  local core = load_core()
  assert_equal(0, core.clamp(-1, 0, 10))
  assert_equal(5, core.clamp(5, 0, 10))
  assert_equal(10, core.clamp(11, 0, 10))
end)

test("round rounds halves away from zero", function()
  local core = load_core()
  assert_equal(2, core.round(1.5))
  assert_equal(1, core.round(1.49))
  assert_equal(-2, core.round(-1.5))
  assert_equal(-1, core.round(-1.49))
end)

test("deep_copy recursively copies tables", function()
  local core = load_core()
  local source = { enabled = true, nested = { value = 3 } }
  local copy = core.deep_copy(source)

  assert_true(copy ~= source)
  assert_true(copy.nested ~= source.nested)
  assert_equal(3, copy.nested.value)

  copy.nested.value = 9
  assert_equal(3, source.nested.value)
end)

test("deep_copy preserves cycles and shared references", function()
  local core = load_core()
  local shared = { value = 3 }
  local source = { first = shared, second = shared }
  source.self = source

  local copy = core.deep_copy(source)

  assert_true(copy ~= source)
  assert_equal(copy, copy.self)
  assert_true(copy.first ~= shared)
  assert_equal(copy.first, copy.second)
end)

test("is_finite_number rejects non-numbers, NaN, and infinities", function()
  local core = load_core()
  assert_equal(true, core.is_finite_number(0))
  assert_equal(true, core.is_finite_number(-1.5))
  assert_equal(false, core.is_finite_number("1"))
  assert_equal(false, core.is_finite_number(0 / 0))
  assert_equal(false, core.is_finite_number(math.huge))
  assert_equal(false, core.is_finite_number(-math.huge))
end)

test("crossfade_length clamps ratio and loop half length", function()
  local core = load_core()
  assert_equal(0.5, core.crossfade_length(1, 0.8, 0))
  assert_equal(0.2, core.crossfade_length(2, 0.1, 0))
end)

test("crossfade_length honors a positive maximum", function()
  local core = load_core()
  assert_equal(0.15, core.crossfade_length(4, 0.25, 0.15))
  assert_equal(1, core.crossfade_length(4, 0.25, 2))
end)

test("crossfade_length safely zeros negative loop or ratio", function()
  local core = load_core()
  assert_equal(0, core.crossfade_length(-4, 0.1, 1))
  assert_equal(0, core.crossfade_length(4, -0.1, 1))
end)

test("crossfade_length safely handles non-finite inputs", function()
  local core = load_core()
  assert_equal(0, core.crossfade_length(0 / 0, 0.1, 1))
  assert_equal(0, core.crossfade_length(math.huge, 0.1, 1))
  assert_equal(0, core.crossfade_length(4, math.huge, 1))
  assert_equal(1, core.crossfade_length(4, 0.25, math.huge))
  assert_equal(0, core.crossfade_length(4, 0 / 0, 1))
end)

test("defaults returns independent complete settings", function()
  local settings = load_settings()
  local first = settings.defaults()
  local second = settings.defaults()
  local required = {
    "glue", "loops", "position_space", "shuffle", "second_snap",
    "match_overlap", "cf_ratio", "cf_curve", "cf_max", "shepard",
    "pitch", "offset", "color_items", "remove_ext", "prefix", "suffix",
    "separator", "number", "start_number", "leading_zeros", "show_shepard",
    "show_zc", "show_name", "preset",
  }

  assert_true(first ~= second)
  for _, key in ipairs(required) do
    assert_true(first[key] ~= nil, "missing default setting: " .. key)
  end

  first.prefix = "changed"
  assert_equal("", second.prefix)
end)

test("defaults matches the LoopMaker design", function()
  local defaults = load_settings().defaults()
  assert_equal(true, defaults.glue)
  assert_equal(1, defaults.loops)
  assert_equal(0.1, defaults.cf_ratio)
  assert_equal(12, defaults.pitch)
  assert_equal("_", defaults.separator)
end)

test("sanitize rounds and bounds integer settings", function()
  local settings = load_settings()
  local sanitized = settings.sanitize({
    loops = 1.6,
    start_number = -3.7,
    leading_zeros = 100,
  })

  assert_equal(2, sanitized.loops)
  assert_equal(0, sanitized.start_number)
  assert_true(sanitized.leading_zeros == math.floor(sanitized.leading_zeros))
  assert_true(sanitized.leading_zeros >= 0 and sanitized.leading_zeros <= 12)

  local upper = settings.sanitize({ loops = 1000000, start_number = 100000000 })
  assert_true(upper.loops <= 1000)
  assert_true(upper.start_number <= 999999)
end)

test("sanitize makes crossfade and position spacing nonnegative", function()
  local sanitized = load_settings().sanitize({
    position_space = -2,
    cf_ratio = -0.2,
    cf_max = -3,
  })

  assert_equal(0, sanitized.position_space)
  assert_equal(0, sanitized.cf_ratio)
  assert_equal(0, sanitized.cf_max)
end)

test("sanitize returns a new table without changing input", function()
  local settings = load_settings()
  local input = {
    loops = 2.4,
    prefix = "loop",
    extra = { value = 1 },
  }
  local sanitized = settings.sanitize(input)

  assert_true(sanitized ~= input)
  assert_equal(2.4, input.loops)
  assert_equal("loop", sanitized.prefix)
  assert_equal(nil, sanitized.extra)
  assert_equal(true, sanitized.glue)
end)

test("sanitize validates every known setting by its default type", function()
  local settings = load_settings()
  local defaults = settings.defaults()
  local input = {}

  for key, default in pairs(defaults) do
    if type(default) == "boolean" then
      input[key] = 1
    elseif type(default) == "string" then
      input[key] = false
    elseif type(default) == "number" then
      input[key] = "42"
    end
  end

  local sanitized = settings.sanitize(input)
  for key, default in pairs(defaults) do
    assert_equal(default, sanitized[key], "wrong type was accepted for setting: " .. key)
  end
end)

test("sanitize rejects non-finite numeric settings", function()
  local settings = load_settings()
  local defaults = settings.defaults()
  local sanitized = settings.sanitize({
    loops = 0 / 0,
    position_space = math.huge,
    cf_ratio = -math.huge,
    cf_curve = 0 / 0,
    cf_max = math.huge,
    pitch = -math.huge,
    offset = math.huge,
    start_number = 0 / 0,
    leading_zeros = math.huge,
  })

  for _, key in ipairs({
    "loops", "position_space", "cf_ratio", "cf_curve", "cf_max",
    "pitch", "offset", "start_number", "leading_zeros",
  }) do
    assert_equal(defaults[key], sanitized[key], "non-finite value was accepted for setting: " .. key)
  end
end)

test("sanitize constrains curve pitch and offset", function()
  local settings = load_settings()
  local high = settings.sanitize({ cf_curve = 10, pitch = 100, offset = -3.25 })
  local low = settings.sanitize({ cf_curve = -2, pitch = -100 })
  local rounded = settings.sanitize({ cf_curve = 2.6 })

  assert_equal(4, high.cf_curve)
  assert_equal(96, high.pitch)
  assert_equal(-3.25, high.offset)
  assert_equal(0, low.cf_curve)
  assert_equal(-96, low.pitch)
  assert_equal(3, rounded.cf_curve)
end)

return true
