local helper = require("tests.test_helper")
local regions = require("lib.regions")
local test, assert_equal, assert_true = helper.test, helper.assert_equal, helper.assert_true
local function output(position, length, source_name)
  return { plan = { output_position = position, loop_length = length,
    source_snapshot = { name = source_name } } }
end
local function settings()
  return { remove_ext = true, prefix = "", suffix = "Loop", separator = "_",
    number = true, start_number = 1, leading_zeros = 2 }
end

test("plan_outputs groups source layers that share sample boundaries", function()
  local plans = assert(regions.plan_outputs({
    output(10, 2, "wind.wav"), output(12, 2, "wind.wav"),
    output(10 + 1e-10, 2, "rain.wav"), output(12 + 1e-10, 2, "rain.wav"),
  }, 48000, settings(), 0x123456))
  assert_equal(2, #plans)
  assert_equal(10, plans[1].start)
  assert_equal(12, plans[1].finish)
  assert_equal("wind_01_Loop", plans[1].name)
  assert_equal("wind_02_Loop", plans[2].name)
  assert_equal(0x123456 | 0x1000000, plans[1].color)
end)

test("create adds planned Regions and remove deletes them", function()
  local state = { added = {}, deleted = {} }
  local api = {
    AddProjectMarker2 = function(project, is_region, start, finish, name, index, color)
      state.added[#state.added + 1] = { project, is_region, start, finish, name, index, color }
      return #state.added + 10
    end,
    DeleteProjectMarker = function(project, index, is_region)
      state.deleted[#state.deleted + 1] = { project, index, is_region }
      return true
    end,
  }
  local created = assert(regions.create(api, "project", {
    { start = 1, finish = 2, name = "Loop_01", color = 0 },
    { start = 2, finish = 3, name = "Loop_02", color = 0 },
  }))
  assert_equal(2, #created)
  assert_equal(true, state.added[1][2])
  assert_equal(-1, state.added[1][6])
  assert(regions.remove(api, "project", created))
  assert_equal(2, #state.deleted)
  assert_equal(true, state.deleted[1][3])
end)

test("create cleans earlier Regions when a later native add fails", function()
  local deleted = {}
  local api = {
    AddProjectMarker2 = function(_, _, start) if start == 2 then return -1 end return 17 end,
    DeleteProjectMarker = function(_, index) deleted[#deleted + 1] = index return true end,
  }
  local created, reason = regions.create(api, 0, {
    { start = 1, finish = 2, name = "A", color = 0 },
    { start = 2, finish = 3, name = "B", color = 0 },
  })
  assert_equal(nil, created)
  assert_true(reason:find("AddProjectMarker2", 1, true) ~= nil)
  assert_equal(17, deleted[1])
end)
return true