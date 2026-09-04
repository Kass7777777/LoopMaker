local helper = require("tests.test_helper")
local loop_builder = require("lib.loop_builder")
local audio = require("lib.audio")

local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local function assert_close(expected, actual, epsilon, message)
  assert_true(type(actual) == "number", message or "expected a number")
  assert_true(math.abs(expected - actual) <= (epsilon or 1e-9),
    message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)))
end

local function assert_contains(text, fragment)
  assert_true(type(text) == "string" and text:find(fragment, 1, true) ~= nil,
    "expected " .. tostring(text) .. " to contain " .. fragment)
end

local function assert_rejected(result, reason)
  assert_equal(nil, result)
  assert_true(type(reason) == "string" and reason ~= "", "expected a clear rejection reason")
end

local function snapshot(overrides)
  local value = {
    item = { id = "item" },
    take = { id = "take" },
    track = { id = "track" },
    position = 10,
    length = 10,
    start_offset = 2,
    playrate = 1.5,
    source_length = 30,
    name = "source.wav",
    chunk = "<ITEM\nIGUID {ITEM}\n<TAKE\nGUID {TAKE}\n>\n>",
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function base_settings(overrides)
  local value = {
    loops = 1,
    position_space = 0,
    shuffle = false,
    second_snap = false,
    match_overlap = false,
    cf_ratio = 0.1,
    cf_max = 0,
    cf_curve = 0,
    glue = false,
    number = true,
    start_number = 1,
    leading_zeros = 2,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

test("resolve_loop_length separates source span crossfade and final period", function()
  local resolved, reason = loop_builder.resolve_loop_length(
    snapshot(), base_settings({ cf_ratio = 0.25, cf_max = 0.5 }),
    { start = 4, finish = 7 })

  assert_equal(nil, reason)
  assert_close(3, resolved.requested_length)
  assert_close(3, resolved.source_span_length)
  assert_close(0.5, resolved.crossfade_length)
  assert_close(2.5, resolved.loop_length)
end)

test("resolve_loop_length supports zero crossfade and rejects invalid spans", function()
  local resolved = assert(loop_builder.resolve_loop_length(
    snapshot({ length = 2.5 }), base_settings({ cf_ratio = 0 }),
    { start = 4, finish = 4 }))
  assert_close(2.5, resolved.source_span_length)
  assert_close(2.5, resolved.loop_length)
  assert_close(0, resolved.crossfade_length)

  for _, length in ipairs({ 0, -1, math.huge }) do
    local rejected, reason = loop_builder.resolve_loop_length(
      snapshot({ length = length }), base_settings(), nil)
    assert_rejected(rejected, reason)
  end
end)

test("plan_loops keeps snapshot output base and accumulates final periods plus spacing", function()
  local plans, reason = loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 3, position_space = 0.5 }),
    { start = 20, finish = 24 })

  assert_equal(nil, reason)
  assert_equal(3, #plans)
  assert_close(10, plans[1].output_position)
  assert_close(14.1, plans[2].output_position)
  assert_close(18.2, plans[3].output_position)
  assert_close(4, plans[1].source_span_length)
  assert_close(0.4, plans[1].crossfade_length)
  assert_close(3.6, plans[1].loop_length)
  assert_equal(0, plans[1].variation_index)
  assert_equal(2, plans[3].variation_index)
end)

test("plan_loops sanitizes settings without modifying the input", function()
  local invalid_input = base_settings({ loops = "invalid" })
  local invalid_plans = assert(loop_builder.plan_loops(
    { snapshot() }, invalid_input, nil))
  assert_equal(1, #invalid_plans)
  assert_equal(1, invalid_plans[1].settings.loops)
  assert_equal("invalid", invalid_input.loops)

  local bounded_input = base_settings({ loops = 0, position_space = -2, cf_ratio = 2 })
  local bounded_plans = assert(loop_builder.plan_loops(
    { snapshot() }, bounded_input, nil))
  assert_equal(1, #bounded_plans)
  assert_equal(1, bounded_plans[1].settings.loops)
  assert_equal(0, bounded_plans[1].settings.position_space)
  assert_close(0.5, bounded_plans[1].settings.cf_ratio)
  assert_equal(0, bounded_input.loops)
  assert_equal(-2, bounded_input.position_space)
  assert_equal(2, bounded_input.cf_ratio)

  local rounded_input = base_settings({ loops = 1.6, position_space = -3, cf_ratio = -0.25 })
  local rounded_plans = assert(loop_builder.plan_loops(
    { snapshot() }, rounded_input, nil))
  assert_equal(2, #rounded_plans)
  assert_equal(2, rounded_plans[1].settings.loops)
  assert_equal(0, rounded_plans[1].settings.position_space)
  assert_equal(0, rounded_plans[1].settings.cf_ratio)
  assert_close(15, rounded_plans[2].output_position)
  assert_equal(1.6, rounded_input.loops)
  assert_equal(-3, rounded_input.position_space)
  assert_equal(-0.25, rounded_input.cf_ratio)
end)

test("single-loop offset anchors at the Item center without moving the centered span", function()
  local centered_input = base_settings({ loops = 1, cf_ratio = 0.1, offset = 0 })
  local centered = assert(loop_builder.plan_loops(
    { snapshot() }, centered_input, { start = 0, finish = 4 }))[1]
  assert_close(13, centered.source_project_start)
  assert_close(17, centered.source_end)
  assert_close(15, centered.boundary_anchor)
  assert_close(3.6, centered.loop_length)
  assert_equal(nil, centered.warning)
  assert_equal(0, centered_input.offset)

  local positive_input = base_settings({ loops = 1, cf_ratio = 0.1, offset = 1 })
  local positive = assert(loop_builder.plan_loops(
    { snapshot() }, positive_input, { start = 0, finish = 4 }))[1]
  assert_close(16, positive.boundary_anchor)
  assert_equal(1, positive_input.offset)

  local negative_input = base_settings({ loops = 1, cf_ratio = 0.1, offset = -1 })
  local negative = assert(loop_builder.plan_loops(
    { snapshot() }, negative_input, { start = 0, finish = 4 }))[1]
  assert_close(14, negative.boundary_anchor)
  assert_equal(-1, negative_input.offset)

  local clamped_input = base_settings({ loops = 1, cf_ratio = 0.1, offset = 100 })
  local clamped = assert(loop_builder.plan_loops(
    { snapshot() }, clamped_input, { start = 0, finish = 4 }))[1]
  assert_close(17 - 1e-7, clamped.boundary_anchor)
  assert_close(1e-7, clamped.crossfade_length)
  assert_contains(clamped.warning, "offset clamped")
  assert_contains(clamped.warning, "crossfade shortened")
  assert_equal(100, clamped_input.offset)
end)

test("multiple loops without a time selection divide the Item into equal unique spans", function()
  local plans = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 5, cf_ratio = 0.1, offset = 0 }), nil))

  assert_equal(5, #plans)
  for index, plan in ipairs(plans) do
    local expected_start = 10 + (index - 1) * 2
    assert_close(expected_start, plan.source_project_start)
    assert_close(expected_start + 2, plan.source_end)
    assert_close(expected_start + 1, plan.boundary_anchor)
    assert_close(0.2, plan.crossfade_length)
    assert_close(1.8, plan.loop_length)
    assert_equal(2, #plan.components)
    assert_close(0.003, plan.components[1].fade_in)
    assert_close(0.003, plan.components[2].fade_out)
    assert_equal(nil, plan.warning)
    assert_close(10 + (index - 1) * 1.8, plan.output_position)
  end
end)

test("multi-loop spans that are too short for safe boundaries are rejected", function()
  local plans, reason = loop_builder.plan_loops(
    { snapshot({ position = 0, length = 0.02 }) },
    base_settings({ loops = 2, cf_ratio = 0 }), nil)
  assert_rejected(plans, reason)
  assert_contains(reason, "boundary safety")
end)

test("multiple shorter loop variations keep each seam at its own span center", function()
  local plans = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 2, cf_ratio = 0.1, offset = 0 }),
    { start = 0, finish = 4 }))
  assert_close(10, plans[1].source_project_start)
  assert_close(14, plans[1].source_end)
  assert_close(12, plans[1].boundary_anchor)
  assert_close(0.4, plans[1].crossfade_length)
  assert_equal(nil, plans[1].warning)
  assert_close(16, plans[2].source_project_start)
  assert_close(20, plans[2].source_end)
  assert_close(18, plans[2].boundary_anchor)
  assert_close(0.4, plans[2].crossfade_length)
  assert_equal(nil, plans[2].warning)
end)

test("plan_loops shuffle permutes unique variation spans without duplicates", function()
  local calls = 0
  local plans = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 2, shuffle = true, cf_ratio = 0.1 }),
    { start = 0, finish = 4 }, function()
      calls = calls + 1
      return 0.25
    end))
  assert_close(16, plans[1].source_project_start)
  assert_close(18, plans[1].boundary_anchor)
  assert_close(10, plans[2].source_project_start)
  assert_close(12, plans[2].boundary_anchor)
  assert_equal(1, calls)
end)

test("plan_loops rejects invalid shuffle rng output safely", function()
  for _, value in ipairs({ -0.01, 1.01, math.huge }) do
    local plans, reason = loop_builder.plan_loops(
      { snapshot() }, base_settings({ shuffle = true }),
      { start = 0, finish = 4 }, function() return value end)
    assert_rejected(plans, reason)
    assert_contains(reason, "rng")
  end
  local plans, reason = loop_builder.plan_loops(
    { snapshot() }, base_settings({ shuffle = true }),
    { start = 0, finish = 4 }, function() error("rng exploded") end)
  assert_rejected(plans, reason)
  assert_contains(reason, "rng")
end)

test("second snap uses integer Item boundaries and cumulative final lengths", function()
  local plans = assert(loop_builder.plan_loops(
    { snapshot({ position = 10.4, length = 5.1 }) },
    base_settings({ loops = 2, second_snap = true, position_space = 0.25 }),
    { start = 30.25, finish = 32.45 }))

  assert_close(11, plans[1].source_project_start)
  assert_close(2, plans[1].source_span_length)
  assert_close(1.8, plans[1].loop_length)
  assert_close(13, plans[2].source_project_start)
  assert_close(2, plans[2].source_span_length)
  assert_close(1.8, plans[2].loop_length)
  assert_close(10.4, plans[1].output_position)
  assert_close(12.45, plans[2].output_position)
end)

test("plan_loops clamps sub-EPSILON variation overflow to the exact Item end", function()
  local plans, reason = loop_builder.plan_loops(
    { snapshot({ position = 0, length = 0.9 }) },
    base_settings({ loops = 2, cf_ratio = 0 }),
    { start = 0, finish = 0.3 })

  assert_true(plans ~= nil, reason)
  assert_equal(2, #plans)
  assert_equal(0.9, plans[2].source_end)
  assert_close(0.3, plans[2].source_span_length)
end)

test("second snap expands a rounded zero-width span to the nearest integer pair", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot({ position = 10, length = 10 }) },
    base_settings({ loops = 1, second_snap = true }),
    { start = 0, finish = 0.2 }))[1]

  assert_close(15, plan.source_project_start)
  assert_close(16, plan.source_end)
  assert_close(1, plan.source_span_length)
  assert_true(plan.boundary_anchor >= plan.source_project_start)
  assert_true(plan.boundary_anchor < plan.source_end)
end)

test("second snap collapsed negative span starts at the floored center", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot({ position = -20, length = 10 }) },
    base_settings({ loops = 1, second_snap = true }),
    { start = 0, finish = 0.2 }))[1]

  assert_equal(-15, plan.source_project_start)
  assert_equal(-14, plan.source_end)
  assert_equal(-14.5, plan.boundary_anchor)
  assert_true(plan.warning == nil
    or plan.warning:find("offset clamped", 1, true) == nil)
end)

test("second snap rejects multi-loop division that cannot stay equal and unique", function()
  local plans, reason = loop_builder.plan_loops(
    { snapshot({ position = 0, length = 2 }) },
    base_settings({ loops = 3, second_snap = true, cf_ratio = 0 }), nil)
  assert_rejected(plans, reason)
  assert_contains(reason, "equal unique")

  local selected, selected_reason = loop_builder.plan_loops(
    { snapshot({ position = 0, length = 2 }) },
    base_settings({ loops = 5, second_snap = true, cf_ratio = 0 }),
    { start = 0, finish = 0.2 })
  assert_rejected(selected, selected_reason)
  assert_contains(selected_reason, "equal unique")

  local valid = assert(loop_builder.plan_loops(
    { snapshot({ position = 10, length = 10 }) },
    base_settings({ loops = 5, second_snap = true, cf_ratio = 0 }), nil))
  for index, plan in ipairs(valid) do
    assert_close(10 + (index - 1) * 2, plan.source_project_start)
    assert_close(2, plan.source_span_length)
  end
end)

test("second snap rejects Items without two distinct integer boundaries", function()
  for _, item in ipairs({
    snapshot({ position = 10.2, length = 0.7 }),
    snapshot({ position = 10.1, length = 1.8 }),
  }) do
    local plans, reason = loop_builder.plan_loops(
      { item }, base_settings({ second_snap = true }), nil)
    assert_rejected(plans, reason)
    assert_contains(reason, "integer")
  end

  local negative_offset, offset_reason = loop_builder.plan_loops(
    { snapshot({ start_offset = -1 }) },
    base_settings({ second_snap = true }), nil)
  assert_rejected(negative_offset, offset_reason)
  assert_contains(offset_reason, "start_offset")
end)

test("plan_loops rejects every source span longer than the selected Item", function()
  for _, source in ipairs({
    snapshot({ length = 4, start_offset = 0, playrate = 2, source_length = 8 }),
    snapshot({ length = 4, start_offset = 1, playrate = 2, source_length = 8 }),
    snapshot({ length = 4, start_offset = 0, playrate = 2, source_length = 9 }),
  }) do
    local plans, reason = loop_builder.plan_loops(
      { source }, base_settings(), { start = 0, finish = 6 })
    assert_rejected(plans, reason)
    assert_contains(reason, "longer than the Item")
  end
end)

test("plan warnings account for each variation source delta", function()
  local plans = assert(loop_builder.plan_loops({ snapshot({
    start_offset = 20,
    playrate = 1,
    source_length = 25,
  }) }, base_settings({ loops = 2, cf_ratio = 0 }), { start = 0, finish = 4 }))
  assert_equal(nil, plans[1].warning)
  assert_contains(plans[2].warning, "source")
end)

test("plan components use the general rotation model around the Item-center anchor", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }),
    { start = 0, finish = 4 }))[1]
  assert_close(13, plan.source_project_start)
  assert_close(17, plan.source_end)
  assert_close(4, plan.source_span_length)
  assert_close(15, plan.boundary_anchor)
  assert_close(0.4, plan.crossfade_length)
  assert_close(3.6, plan.loop_length)
  assert_equal(false, plan.wrap_source)
  assert_equal(2, #plan.components)
  assert_equal("main", plan.components[1].kind)
  assert_close(15, plan.components[1].source_project_start)
  assert_close(2, plan.components[1].length)
  assert_close(0.4, plan.components[1].fade_out)
  assert_equal("head", plan.components[2].kind)
  assert_close(plan.output_position + 1.6, plan.components[2].position)
  assert_close(13, plan.components[2].source_project_start)
  assert_close(2, plan.components[2].length)
  assert_close(0.4, plan.components[2].fade_in)
  assert_close(plan.boundary_anchor,
    plan.components[2].source_project_start + plan.components[2].length)
end)

test("full-Item rotation uses both halves without source wrapping", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }), nil))[1]
  assert_close(10, plan.source_project_start)
  assert_close(20, plan.source_end)
  assert_close(15, plan.boundary_anchor)
  assert_close(9, plan.loop_length)
  assert_equal(false, plan.wrap_source)
  assert_equal(2, #plan.components)
  assert_close(15, plan.components[1].source_project_start)
  assert_close(5, plan.components[1].length)
  assert_close(10, plan.components[2].source_project_start)
  assert_close(5, plan.components[2].length)
end)

test("planning clamps offset to the legal anchor range and shortens crossfade", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.25, offset = -100 }),
    { start = 0, finish = 4 }))[1]
  assert_close(13, plan.source_project_start)
  assert_close(13, plan.boundary_anchor)
  assert_close(0, plan.crossfade_length)
  assert_close(4, plan.loop_length)
  assert_contains(plan.warning, "offset clamped")
  assert_contains(plan.warning, "crossfade shortened")
end)

test("anchor at source start creates only the positive-length main component", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.25, offset = -2 }),
    { start = 0, finish = 4 }))[1]
  assert_close(plan.source_project_start, plan.boundary_anchor)
  assert_close(0, plan.crossfade_length)
  assert_equal(1, #plan.components)
  assert_equal("main", plan.components[1].kind)
  assert_close(plan.source_span_length, plan.components[1].length)
end)

test("multi-loop boundary safety fades clamp an extreme anchor inside both edges", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 2, cf_ratio = 0.25, offset = -100 }),
    { start = 0, finish = 4 }))[1]
  assert_close(plan.source_project_start + 0.003, plan.boundary_anchor)
  assert_equal(2, #plan.components)
  assert_close(0.003, plan.components[1].fade_in)
  assert_close(0.003, plan.components[2].fade_out)
end)

test("multi-loop safety fade keeps three milliseconds beside a near-edge seam", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 2, cf_ratio = 0.25, offset = -1.998 }),
    { start = 0, finish = 4 }))[1]
  assert_equal(2, #plan.components)
  assert_close(0.003, plan.components[1].fade_in)
  assert_close(0.003, plan.components[2].fade_out)
end)

test("zero crossfade with an interior anchor keeps both rotation components", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0 }),
    { start = 0, finish = 4 }))[1]
  assert_true(plan.boundary_anchor > plan.source_project_start)
  assert_close(0, plan.crossfade_length)
  assert_equal(2, #plan.components)
  assert_close(15, plan.components[1].source_project_start)
  assert_close(2, plan.components[1].length)
  assert_close(13, plan.components[2].source_project_start)
  assert_close(2, plan.components[2].length)
  assert_close(plan.output_position + 2, plan.components[2].position)
end)

test("plan_loops preserves stable snapshot then variation ordering", function()
  local first = snapshot({ item = { id = "first" }, position = 0, length = 2 })
  local second = snapshot({ item = { id = "second" }, position = 5, length = 2 })
  local plans = assert(loop_builder.plan_loops(
    { first, second }, base_settings({ loops = 2 }), nil))
  assert_equal(first, plans[1].source_snapshot)
  assert_equal(first, plans[2].source_snapshot)
  assert_equal(second, plans[3].source_snapshot)
  assert_equal(second, plans[4].source_snapshot)
end)

test("apply_analysis preserves a returned anchor and shortens crossfade near S", function()
  local original = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.2, cf_max = 0.5 }),
    { start = 0, finish = 4 }))[1]
  original.warning = "existing warning"
  local adjusted, reason = loop_builder.apply_analysis(original,
    { project_time = 13.1, fallback = true, warning = "start fallback" },
    { project_time = 16.5, fallback = true, warning = "end fallback" })

  assert_equal(nil, reason)
  assert_true(adjusted ~= original)
  assert_close(13, adjusted.source_project_start)
  assert_close(16.5, adjusted.source_end)
  assert_close(13.1, adjusted.boundary_anchor)
  assert_close(0.1, adjusted.crossfade_length)
  assert_close(3.4, adjusted.loop_length)
  assert_close(13.1, adjusted.components[1].source_project_start)
  assert_close(3.4, adjusted.components[1].length)
  assert_close(13, adjusted.components[2].source_project_start)
  assert_close(0.1, adjusted.components[2].length)
  assert_close(13.1, adjusted.components[2].source_project_start
    + adjusted.components[2].length)
  assert_contains(adjusted.warning, "crossfade shortened")
  assert_contains(adjusted.warning, "existing warning")
  assert_contains(adjusted.warning, "start fallback")
  assert_contains(adjusted.warning, "end fallback")
end)

test("apply_analysis falls back invalid boundaries without moving a valid anchor", function()
  local original = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }),
    { start = 0, finish = 4 }))[1]
  local adjusted = assert(loop_builder.apply_analysis(original,
    { project_time = 16 }, { project_time = 15 }))

  assert_close(13, adjusted.source_project_start)
  assert_close(17, adjusted.source_end)
  assert_close(16, adjusted.boundary_anchor)
  assert_contains(adjusted.warning, "end analysis")
  assert_true(not adjusted.warning:find("start analysis", 1, true))

  local both = assert(loop_builder.apply_analysis(original,
    { project_time = 12 }, { project_time = 30 }))
  assert_close(original.boundary_anchor, both.boundary_anchor)
  assert_close(original.source_end, both.source_end)
  assert_contains(both.warning, "start analysis")
  assert_contains(both.warning, "end analysis")
end)

test("apply_analysis keeps a valid anchor and uses Item end when invalid end fallback crosses it", function()
  local original = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }),
    { start = 0, finish = 4 }))[1]
  local adjusted = assert(loop_builder.apply_analysis(original,
    { project_time = 18 }, { project_time = 30 }))

  assert_close(13, adjusted.source_project_start)
  assert_close(18, adjusted.boundary_anchor)
  assert_close(20, adjusted.source_end)
  assert_contains(adjusted.warning, "end analysis result invalid")
  assert_contains(adjusted.warning, "using Item end")
  assert_true(not adjusted.warning:find("start analysis result invalid", 1, true))
end)

test("apply_analysis keeps a valid end and uses source start when invalid anchor fallback crosses it", function()
  local original = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }),
    { start = 0, finish = 4 }))[1]
  local adjusted = assert(loop_builder.apply_analysis(original,
    { project_time = 12 }, { project_time = 14 }))

  assert_close(13, adjusted.source_project_start)
  assert_close(13, adjusted.boundary_anchor)
  assert_close(14, adjusted.source_end)
  assert_contains(adjusted.warning, "start analysis result invalid")
  assert_contains(adjusted.warning, "using source start")
  assert_true(not adjusted.warning:find("end analysis result invalid", 1, true))
end)

test("apply_analysis preserves a valid late anchor when end falls back", function()
  local original = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }),
    { start = 0, finish = 4 }))[1]
  local adjusted = assert(loop_builder.apply_analysis(original,
    { project_time = 16.9 }, { project_time = 15 }))

  assert_close(13, adjusted.source_project_start)
  assert_close(17, adjusted.source_end)
  assert_close(16.9, adjusted.boundary_anchor)
  assert_contains(adjusted.warning, "end analysis")
end)

test("apply_analysis extends end fallback to the Item boundary for a later valid anchor", function()
  local original = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }),
    { start = 0, finish = 4 }))[1]
  local adjusted = assert(loop_builder.apply_analysis(original,
    { project_time = 17.5 }, { project_time = 15 }))

  assert_close(13, adjusted.source_project_start)
  assert_close(20, adjusted.source_end)
  assert_close(17.5, adjusted.boundary_anchor)
  assert_contains(adjusted.warning, "end analysis")
  assert_contains(adjusted.warning, "Item boundary")
end)

test("apply_analysis rejects a multi-loop interval too short for boundary safety", function()
  local plan = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 2 }),
    { start = 0, finish = 4 }))[1]
  local adjusted, reason = loop_builder.apply_analysis(plan,
    { project_time = plan.source_project_start + 0.005 },
    { project_time = plan.source_project_start + 0.02 })
  assert_rejected(adjusted, reason)
  assert_contains(reason, "boundary safety")
end)

test("apply_analysis moves an invalid start fallback to S to preserve a valid early end", function()
  local original = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ cf_ratio = 0.1 }),
    { start = 0, finish = 4 }))[1]
  local adjusted = assert(loop_builder.apply_analysis(original,
    { project_time = 30 }, { project_time = 14 }))

  assert_close(13, adjusted.source_project_start)
  assert_close(14, adjusted.source_end)
  assert_close(13, adjusted.boundary_anchor)
  assert_contains(adjusted.warning, "start analysis")
  assert_contains(adjusted.warning, "source start")
end)

local function snapshot_api(configuration)
  configuration = configuration or {}
  local track = { id = "track" }
  local source = {
    length = 30,
    sample_rate = configuration.sample_rate == nil
      and 48000 or configuration.sample_rate,
  }
  local audio_item = { id = "audio", position = 2, length = 5, track = track,
    chunk = "AUDIO CHUNK", selected = true }
  local midi_item = { id = "midi", position = 8, length = 2, track = track,
    chunk = "MIDI CHUNK", selected = true }
  local audio_take = { id = "audio take", item = audio_item, source = source,
    start_offset = 1.25, playrate = 1.5, name = "kick.wav", midi = false }
  local midi_take = { id = "midi take", item = midi_item, source = source,
    start_offset = 0, playrate = 1, name = "notes", midi = true }
  audio_item.take = audio_take
  midi_item.take = midi_take
  local model = { project = {}, items = { audio_item, midi_item } }
  local api = {}

  function api.CountSelectedMediaItems(project)
    assert_equal(model.project, project)
    return #model.items
  end
  function api.GetSelectedMediaItem(project, index)
    assert_equal(model.project, project)
    return model.items[index + 1]
  end
  function api.GetActiveTake(item) return item.take end
  function api.TakeIsMIDI(take) return take.midi end
  function api.GetMediaItemTrack(item) return item.track end
  function api.GetMediaItemInfo_Value(item, key)
    if key == "D_POSITION" then return item.position end
    if key == "D_LENGTH" then return item.length end
    error("unexpected item key " .. tostring(key))
  end
  function api.GetMediaItemTakeInfo_Value(take, key)
    if key == "D_STARTOFFS" then return take.start_offset end
    if key == "D_PLAYRATE" then return take.playrate end
    error("unexpected take key " .. tostring(key))
  end
  function api.GetMediaItemTake_Source(take) return take.source end
  function api.GetMediaSourceLength(value)
    assert_equal(source, value)
    return value.length, false
  end
  function api.GetMediaSourceSampleRate(value)
    assert_equal(source, value)
    return value.sample_rate
  end
  function api.GetItemStateChunk(item, buffer, is_undo)
    assert_equal("", buffer)
    assert_equal(false, is_undo)
    return true, item.chunk
  end
  function api.GetSetMediaItemTakeInfo_String(take, key, value, set_new)
    assert_equal("P_NAME", key)
    if set_new then
      take.name = value
      return true, value
    end
    return true, take.name
  end

  return api, model, audio_item, audio_take
end

test("snapshot_selected filters MIDI and captures audio state and chunk", function()
  local api, model, item, take = snapshot_api()
  local snapshots, reason = loop_builder.snapshot_selected(api, model.project)

  assert_equal(nil, reason)
  assert_equal(1, #snapshots)
  assert_equal(item, snapshots[1].item)
  assert_equal(take, snapshots[1].take)
  assert_equal(item.track, snapshots[1].track)
  assert_close(2, snapshots[1].position)
  assert_close(5, snapshots[1].length)
  assert_close(1.25, snapshots[1].start_offset)
  assert_close(1.5, snapshots[1].playrate)
  assert_close(30, snapshots[1].source_length)
  assert_equal(48000, snapshots[1].sample_rate)
  assert_equal("kick.wav", snapshots[1].name)
  assert_equal("AUDIO CHUNK", snapshots[1].chunk)
end)

test("snapshot_selected treats missing invalid and failed source sample rates as unavailable", function()
  local cases = {
    {
      configure = function(api)
        api.GetMediaSourceSampleRate = nil
      end,
    },
    {
      configure = function(api)
        function api.GetMediaSourceSampleRate() return 0 end
      end,
    },
    {
      configure = function(api)
        function api.GetMediaSourceSampleRate() return -1 end
      end,
    },
    {
      configure = function(api)
        function api.GetMediaSourceSampleRate() return 0 / 0 end
      end,
    },
    {
      configure = function(api)
        function api.GetMediaSourceSampleRate() return math.huge end
      end,
    },
    {
      configure = function(api)
        function api.GetMediaSourceSampleRate() return 48000.5 end
      end,
    },
    {
      configure = function(api)
        function api.GetMediaSourceSampleRate() error("rate unavailable") end
      end,
    },
  }

  for _, case in ipairs(cases) do
    local api, model = snapshot_api()
    case.configure(api)

    local snapshots, reason = loop_builder.snapshot_selected(api, model.project)

    assert_equal(nil, reason)
    assert_equal(1, #snapshots)
    assert_equal(nil, snapshots[1].sample_rate)
  end
end)

test("snapshot_selected converts injected API exceptions to reasons", function()
  local api, model = snapshot_api()
  function api.GetItemStateChunk() error("chunk exploded") end
  local snapshots, reason = loop_builder.snapshot_selected(api, model.project)
  assert_rejected(snapshots, reason)
  assert_contains(reason, "chunk")
end)

local function clone_api(configuration)
  configuration = configuration or {}
  local model = {
    added = {},
    deleted = {},
    guid_index = 0,
    item_values = {},
    take_values = {},
    chunks = {},
  }
  local api = {}

  function api.AddMediaItemToTrack(track)
    if configuration.add_returns_nil then return nil end
    local item = { track = track }
    item.take = { item = item }
    model.added[#model.added + 1] = item
    return item
  end
  function api.genGuid()
    model.guid_index = model.guid_index + 1
    return "{NEW-" .. model.guid_index .. "}"
  end
  function api.SetItemStateChunk(item, chunk, is_undo)
    assert_equal(false, is_undo)
    if configuration.chunk_false then return false end
    item.chunk = chunk
    model.chunks[#model.chunks + 1] = chunk
    return true
  end
  function api.GetActiveTake(item) return item.take end
  function api.SetMediaItemInfo_Value(item, key, value)
    if configuration.item_false_key == key then return false end
    model.item_values[#model.item_values + 1] = { item = item, key = key, value = value }
    item[key] = value
    return true
  end
  function api.SetMediaItemTakeInfo_Value(take, key, value)
    if configuration.take_false_key == key then return false end
    model.take_values[#model.take_values + 1] = { take = take, key = key, value = value }
    take[key] = value
    return true
  end
  function api.DeleteTrackMediaItem(track, item)
    model.deleted[#model.deleted + 1] = item
    return true
  end

  return api, model
end

test("clone_from_chunk replaces line IGUID and GUID without changing source GUID", function()
  local api, model = clone_api()
  local source = snapshot({
    start_offset = 0,
    source_length = 15,
    chunk = "<ITEM\n  IGUID {ITEM}\nD_FADEINLEN_AUTO 0.5\nD_FADEOUTLEN_AUTO 0.75\nSOURCE GUID {SOURCE}\n<TAKE\nGUID {TAKE-1}\nGUID {TAKE-2}\n>\n>",
  })
  local item, take = loop_builder.clone_from_chunk(api, source, {
    kind = "main",
    position = 20,
    length = 4,
    source_project_start = 12,
    fade_out = 0.25,
    fade_shape = 3,
    wrap_source = false,
  })

  assert_true(item ~= nil)
  assert_equal(item.take, take)
  assert_equal(3, model.guid_index)
  assert_contains(item.chunk, "  IGUID {NEW-1}")
  assert_contains(item.chunk, "GUID {NEW-2}")
  assert_contains(item.chunk, "GUID {NEW-3}")
  assert_contains(item.chunk, "SOURCE GUID {SOURCE}")
  assert_close(20, item.D_POSITION)
  assert_close(4, item.D_LENGTH)
  assert_close(0, item.B_LOOPSRC)
  assert_close(-1, item.D_FADEINLEN_AUTO)
  assert_close(-1, item.D_FADEOUTLEN_AUTO)
  assert_close(0.25, item.D_FADEOUTLEN)
  assert_close(3, item.C_FADEOUTSHAPE)
  assert_close(3, take.D_STARTOFFS)
  assert_close(1.5, take.D_PLAYRATE)
  assert_equal(0, #model.deleted)
end)

test("clone_from_chunk deletes the new item after any setup failure", function()
  local api, model = clone_api({ chunk_false = true })
  local item, reason = loop_builder.clone_from_chunk(api, snapshot(), {
    kind = "head", position = 1, length = 0.2, source_project_start = 10,
    fade_in = 0.2, fade_shape = 2,
  })

  assert_rejected(item, reason)
  assert_equal(1, #model.deleted)
end)

test("clone_from_chunk rejects non-wrapped source reads beyond source bounds", function()
  local api, model = clone_api()
  local item, reason = loop_builder.clone_from_chunk(api, snapshot({
    start_offset = 4,
    playrate = 1,
    source_length = 5,
  }), {
    kind = "main", position = 1, length = 2, source_project_start = 10,
    fade_out = 0, fade_shape = 0, wrap_source = false,
  })

  assert_rejected(item, reason)
  assert_contains(reason, "source")
  assert_equal(1, #model.deleted)

  local unknown_api, unknown_model = clone_api()
  local unknown_snapshot = snapshot()
  unknown_snapshot.source_length = nil
  local unknown, unknown_reason = loop_builder.clone_from_chunk(
    unknown_api, unknown_snapshot, {
      kind = "main", position = 1, length = 1, source_project_start = 10,
      fade_out = 0, fade_shape = 0, wrap_source = false,
    })
  assert_rejected(unknown, unknown_reason)
  assert_contains(unknown_reason, "source")
  assert_equal(1, #unknown_model.deleted)

  local negative_api, negative_model = clone_api()
  local negative, negative_reason = loop_builder.clone_from_chunk(
    negative_api, snapshot({ start_offset = 0 }), {
      kind = "main", position = 1, length = 1, source_project_start = 9,
      fade_out = 0, fade_shape = 0, wrap_source = false,
    })
  assert_rejected(negative, negative_reason)
  assert_contains(negative_reason, "source")
  assert_equal(1, #negative_model.deleted)
end)

local function apply_api(configuration)
  configuration = configuration or {}
  local project = { id = "project" }
  local track = { id = "track" }
  local source_item = {
    id = "original", track = track, selected = true,
    chunk = "<ITEM\nIGUID {ORIGINAL}\nD_FADEINLEN_AUTO 0.5\nD_FADEOUTLEN_AUTO 0.75\n<TAKE\nGUID {ORIGINAL-TAKE}\n>\n>",
  }
  local source_take = { id = "original take", item = source_item, name = "source.wav" }
  source_item.take = source_take
  local model = {
    project = project,
    items = { source_item },
    source_item = source_item,
    source_take = source_take,
    add_calls = 0,
    guid_index = 0,
    names = {},
    selection_snapshots = {},
    delete_order = {},
    restore_calls = 0,
    name_calls = 0,
  }
  local api = {}

  function api.CountMediaItems(value)
    assert_equal(project, value)
    return #model.items
  end
  function api.GetMediaItem(value, index)
    assert_equal(project, value)
    return model.items[index + 1]
  end
  function api.SetMediaItemSelected(item, selected)
    item.selected = selected
    if configuration.setters_void then return nil end
    return true
  end
  function api.AddMediaItemToTrack(value)
    assert_equal(track, value)
    model.add_calls = model.add_calls + 1
    if configuration.fail_add_at == model.add_calls then
      return nil
    end
    local item = { id = "clone " .. model.add_calls, track = track, selected = false }
    item.take = { id = "clone take " .. model.add_calls, item = item }
    model.items[#model.items + 1] = item
    return item
  end
  function api.genGuid()
    model.guid_index = model.guid_index + 1
    return "{G" .. model.guid_index .. "}"
  end
  function api.SetItemStateChunk(item, chunk, is_undo)
    assert_equal(false, is_undo)
    if item == model.source_item then
      model.restore_calls = model.restore_calls + 1
      if configuration.restore_false then return false end
      item.take = { id = "restored take", item = item, name = "source.wav" }
    end
    item.chunk = chunk
    return true
  end
  function api.GetActiveTake(item) return item.take end
  function api.SetMediaItemInfo_Value(item, key, value)
    if configuration.item_false_key == key then return false end
    item[key] = value
    return true
  end
  function api.SetMediaItemTakeInfo_Value(take, key, value)
    if configuration.take_false_key == key then return false end
    take[key] = value
    return true
  end
  function api.DeleteTrackMediaItem(value, item)
    assert_equal(track, value)
    if configuration.delete_false then return false end
    for index, candidate in ipairs(model.items) do
      if candidate == item then
        table.remove(model.items, index)
        model.delete_order[#model.delete_order + 1] = item.id
        return true
      end
    end
    return false
  end
  function api.GetSetMediaItemTakeInfo_String(take, key, value, set_new)
    assert_equal("P_NAME", key)
    if set_new then
      model.name_calls = model.name_calls + 1
      if configuration.fail_name_at == model.name_calls then return false end
      take.name = value
      model.names[#model.names + 1] = { take = take, name = value }
      return true, value
    end
    return true, take.name or ""
  end

  return api, model
end

test("apply_plan reuses first original main clones later mains and all heads", function()
  local api, model = apply_api()
  local source = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.source_item.track,
    chunk = model.source_item.chunk,
    position = 10,
    length = 10,
    name = "source.wav",
  })
  local apply_settings = base_settings({
    loops = 2, shuffle = true, cf_curve = 4, color_items = true,
  })
  local plans = assert(loop_builder.plan_loops(
    { source }, apply_settings, { start = 20, finish = 24 },
    function() return 0.5 end))

  local outputs, warnings = loop_builder.apply_plan(api, plans, {
    project = model.project,
    settings = apply_settings,
    color = 0x123456,
  })

  assert_equal(0, #warnings)
  assert_equal(2, #outputs)
  assert_equal(model.source_item, outputs[1].main)
  assert_true(outputs[2].main ~= model.source_item)
  assert_equal(2, #outputs[1].items)
  assert_equal(2, #outputs[2].items)
  assert_equal(3, model.add_calls)
  local seen_chunks = {}
  for _, output in ipairs(outputs) do
    for _, item in ipairs(output.items) do
      assert_true(not seen_chunks[item.chunk], "expected unique cloned GUID chunks")
      seen_chunks[item.chunk] = true
    end
  end
  assert_close(10, model.source_item.D_POSITION)
  assert_close(2, model.source_item.D_LENGTH, 1e-6)
  assert_close(0.003, model.source_item.D_FADEINLEN)
  assert_close(0.4, model.source_item.D_FADEOUTLEN)
  assert_close(4, model.source_item.C_FADEOUTSHAPE)
  assert_close(5, model.source_take.D_STARTOFFS, 1e-6)
  assert_close(0.003, outputs[1].items[2].D_FADEOUTLEN)
  assert_close(1.5, model.source_take.D_PLAYRATE)
  assert_close(0, model.source_item.B_LOOPSRC)
  assert_close(-1, model.source_item.D_FADEINLEN_AUTO)
  assert_close(-1, model.source_item.D_FADEOUTLEN_AUTO)
  assert_close(-1, outputs[1].items[2].D_FADEINLEN_AUTO)
  assert_close(-1, outputs[1].items[2].D_FADEOUTLEN_AUTO)
  assert_equal("source.wav_01", outputs[1].main.take.name)
  assert_equal("source.wav_01", outputs[1].items[2].take.name)
  assert_equal("source.wav_02", outputs[2].main.take.name)
  for _, output in ipairs(outputs) do
    for _, item in ipairs(output.items) do
      assert_equal(0x123456 | 0x1000000, item.I_CUSTOMCOLOR)
    end
  end
  assert_equal(true, outputs[1].main.selected)
  assert_equal(true, outputs[1].items[2].selected)
  assert_equal(true, outputs[2].main.selected)
  assert_equal(true, outputs[2].items[2].selected)
end)

test("apply_plan preflights all APIs and validates enabled colors before mutation", function()
  local api, model = apply_api()
  api.GetSetMediaItemTakeInfo_String = nil
  local plans = assert(loop_builder.plan_loops({ snapshot({
    item = model.source_item, take = model.source_take, track = model.source_item.track,
    chunk = model.source_item.chunk,
  }) }, base_settings(), nil))
  local outputs, reason, partial = loop_builder.apply_plan(api, plans, {
    project = model.project,
    settings = base_settings(),
  })
  assert_rejected(outputs, reason)
  assert_contains(reason, "GetSetMediaItemTakeInfo_String")
  assert_equal(0, #partial)
  assert_equal(0, model.add_calls)

  local color_api, color_model = apply_api()
  local color_plans = assert(loop_builder.plan_loops({ snapshot({
    item = color_model.source_item, take = color_model.source_take,
    track = color_model.source_item.track, chunk = color_model.source_item.chunk,
  }) }, base_settings({ color_items = true }), nil))
  local colored, color_reason = loop_builder.apply_plan(color_api, color_plans, {
    project = color_model.project,
    settings = base_settings({ color_items = true }),
    color = -1,
  })
  assert_rejected(colored, color_reason)
  assert_contains(color_reason, "color")
  assert_equal(0, color_model.add_calls)

  local function_api, function_model = apply_api()
  local function_plans = assert(loop_builder.plan_loops({ snapshot({
    item = function_model.source_item, take = function_model.source_take,
    track = function_model.source_item.track, chunk = function_model.source_item.chunk,
  }) }, base_settings({ color_items = true }), nil))
  local function_result, function_reason = loop_builder.apply_plan(
    function_api, function_plans, {
      project = function_model.project,
      settings = base_settings({ color_items = true }),
      color = function() return 1.5 end,
    })
  assert_rejected(function_result, function_reason)
  assert_contains(function_reason, "color")
  assert_equal(0, function_model.add_calls)
end)

test("apply_plan treats the void selection setter as success and selects every output item", function()
  local api, model = apply_api({ setters_void = true })
  local source = snapshot({
    item = model.source_item, take = model.source_take, track = model.source_item.track,
    chunk = model.source_item.chunk,
  })
  local apply_settings = base_settings({ loops = 2, cf_ratio = 0 })
  local plans = assert(loop_builder.plan_loops(
    { source }, apply_settings, { start = 20, finish = 24 }))
  local outputs, warnings = loop_builder.apply_plan(api, plans, {
    project = model.project,
    settings = apply_settings,
  })
  assert_equal(0, #warnings)
  assert_equal(2, #outputs)
  for _, output in ipairs(outputs) do
    for _, item in ipairs(output.items) do assert_equal(true, item.selected) end
  end
end)

test("apply_plan restores the original when a component setter fails mid-write", function()
  local api, model = apply_api({ take_false_key = "D_STARTOFFS" })
  local original_chunk = model.source_item.chunk
  local source = snapshot({
    item = model.source_item, take = model.source_take, track = model.source_item.track,
    chunk = original_chunk,
  })
  local plans = assert(loop_builder.plan_loops(
    { source }, base_settings(), { start = 20, finish = 24 }))
  local outputs, reason, partial = loop_builder.apply_plan(api, plans, {
    project = model.project,
    settings = base_settings(),
  })
  assert_rejected(outputs, reason)
  assert_contains(reason, "cleaned")
  assert_equal(0, #partial)
  assert_equal(1, model.restore_calls)
  assert_equal(original_chunk, model.source_item.chunk)
end)

test("apply_plan rolls back current output clones and restores a reused original", function()
  local api, model = apply_api({ fail_name_at = 2 })
  local original_chunk = model.source_item.chunk
  local source = snapshot({
    item = model.source_item, take = model.source_take, track = model.source_item.track,
    chunk = original_chunk,
  })
  local plans = assert(loop_builder.plan_loops(
    { source }, base_settings(), { start = 20, finish = 24 }))
  local outputs, reason, partial = loop_builder.apply_plan(api, plans, {
    project = model.project,
    settings = base_settings(),
  })
  assert_rejected(outputs, reason)
  assert_contains(reason, "cleaned")
  assert_equal(0, #partial)
  assert_equal(1, #model.delete_order)
  assert_equal(1, model.restore_calls)
  assert_equal(original_chunk, model.source_item.chunk)
  assert_equal(model.source_item.take, source.take)
end)

test("apply_plan deletes multiple current-output clones in reverse order", function()
  local api, model = apply_api({ fail_name_at = 1 })
  local source = snapshot({
    item = model.source_item, take = model.source_take, track = model.source_item.track,
    chunk = model.source_item.chunk,
  })
  local plan = assert(loop_builder.plan_loops(
    { source }, base_settings(), { start = 20, finish = 24 }))[1]
  local head = plan.components[2]
  plan.components[3] = {
    kind = "head",
    position = head.position,
    length = head.length,
    source_project_start = head.source_project_start,
    fade_in = head.fade_in,
    fade_shape = head.fade_shape,
    wrap_source = head.wrap_source,
  }
  local outputs, reason, partial = loop_builder.apply_plan(api, { plan }, {
    project = model.project,
    settings = base_settings(),
  })
  assert_rejected(outputs, reason)
  assert_equal(0, #partial)
  assert_equal(2, #model.delete_order)
  assert_equal("clone 2", model.delete_order[1])
  assert_equal("clone 1", model.delete_order[2])
end)

test("apply_plan reports cleanup failures and only returns completed partial outputs", function()
  local api, model = apply_api({ fail_add_at = 3, delete_false = true })
  local source = snapshot({
    item = model.source_item, take = model.source_take, track = model.source_item.track,
    chunk = model.source_item.chunk,
  })
  local apply_settings = base_settings({ loops = 2, shuffle = true })
  local plans = assert(loop_builder.plan_loops(
    { source }, apply_settings, { start = 20, finish = 24 },
    function() return 0.5 end))
  local outputs, reason, partial = loop_builder.apply_plan(api, plans, {
    project = model.project,
    settings = apply_settings,
  })
  assert_rejected(outputs, reason)
  assert_contains(reason, "cleanup failed")
  assert_equal(1, #partial)
  assert_equal(model.source_item, partial[1].main)
end)

local function glue_api(configuration)
  configuration = configuration or {}
  local project = { id = "project" }
  local model = {
    project = project,
    items = {},
    calls = {},
    command_count = 0,
    names = {},
  }
  local api = {}

  local function add_item(id)
    local item = { id = id, guid = "{" .. id .. "}", selected = false, valid = true }
    item.take = { item = item, name = id }
    model.items[#model.items + 1] = item
    return item
  end

  function api.CountMediaItems(value)
    assert_equal(project, value)
    return #model.items
  end
  function api.GetMediaItem(value, index)
    assert_equal(project, value)
    return model.items[index + 1]
  end
  function api.SetMediaItemSelected(item, selected)
    assert_true(item.valid, "Glue mock received a stale item pointer")
    item.selected = selected
  end
  function api.Main_OnCommandEx(command, flag, value)
    assert_equal(loop_builder.GLUE_COMMAND, command)
    assert_equal(0, flag)
    assert_equal(project, value)
    model.command_count = model.command_count + 1
    local selected = {}
    for _, item in ipairs(model.items) do
      if item.selected then selected[#selected + 1] = item end
    end
    model.calls[#model.calls + 1] = selected
    if configuration.no_op then
      for _, item in ipairs(model.items) do item.selected = false end
      if selected[1] ~= nil then selected[1].selected = true end
      return
    end
    if configuration.preserve_old then
      for _, item in ipairs(model.items) do item.selected = false end
      add_item("glued-" .. model.command_count).selected = true
      return
    end
    for index = #model.items, 1, -1 do
      local item = model.items[index]
      if item.selected then
        item.valid = false
        table.remove(model.items, index)
      else
        item.selected = false
      end
    end
    if configuration.fail_at == model.command_count then
      add_item("bad-a-" .. model.command_count).selected = true
      add_item("bad-b-" .. model.command_count).selected = true
    elseif configuration.reuse_pointer then
      -- REAPER can recycle a deleted component's address for the new Item.
      local result = selected[configuration.reuse_pointer]
      result.id = "glued-" .. model.command_count
      result.guid = "{" .. result.id .. "}"
      result.valid, result.selected = true, true
      result.take = { item = result, name = result.id }
      model.items[#model.items + 1] = result
    else
      add_item("glued-" .. model.command_count).selected = true
    end
  end
  function api.GetSetMediaItemInfo_String(item, key, value, set_new)
    assert_true(item.valid, "Glue mock received a stale item pointer")
    assert_equal("GUID", key)
    assert_equal(false, set_new)
    return item.guid_read_ok ~= false, item.guid
  end
  function api.CountSelectedMediaItems(value)
    assert_equal(project, value)
    local count = 0
    for _, item in ipairs(model.items) do
      if item.selected then count = count + 1 end
    end
    return count
  end
  function api.GetSelectedMediaItem(value, index)
    assert_equal(project, value)
    local selected = {}
    for _, item in ipairs(model.items) do
      if item.selected then selected[#selected + 1] = item end
    end
    return selected[index + 1]
  end
  function api.GetActiveTake(item)
    assert_true(item.valid, "Glue mock received a stale item pointer")
    return item.take
  end
  function api.GetSetMediaItemTakeInfo_String(take, key, value, set_new)
    assert_equal("P_NAME", key)
    if set_new then
      if configuration.fail_name then return false end
      take.name = value
      model.names[#model.names + 1] = value
      return true, value
    end
    return true, take.name
  end
  function api.SetMediaItemInfo_Value(item, key, value)
    assert_true(item.valid, "Glue mock received a stale item pointer")
    item[key] = value
    return true
  end

  model.add_item = add_item
  return api, model
end

test("glue_outputs uses command 40362 then renames colors and selects every result", function()
  local api, model = glue_api()
  local a1, a2 = model.add_item("a1"), model.add_item("a2")
  local b1, b2 = model.add_item("b1"), model.add_item("b2")
  local glue_settings = base_settings({ color_items = true })
  local outputs = {
    { plan = { source_snapshot = { name = "a.wav" }, variation_index = 0,
      settings = glue_settings }, items = { a1, a2 }, main = a1 },
    { plan = { source_snapshot = { name = "b.wav" }, variation_index = 1,
      settings = glue_settings }, items = { b1, b2 }, main = b1 },
  }

  local glued, reason = loop_builder.glue_outputs(api, model.project, outputs, {
    settings = glue_settings,
    color = 0x234567,
  })

  assert_equal(nil, reason)
  assert_equal(40362, loop_builder.GLUE_COMMAND)
  assert_equal(2, model.command_count)
  assert_equal(2, #model.calls[1])
  assert_equal(2, #model.calls[2])
  assert_equal(1, #glued[1].items)
  assert_equal("glued-1", glued[1].main.id)
  assert_equal("glued-2", glued[2].main.id)
  assert_equal("a.wav_01", glued[1].main.take.name)
  assert_equal("b.wav_02", glued[2].main.take.name)
  assert_equal(0x234567 | 0x1000000, glued[1].main.I_CUSTOMCOLOR)
  assert_equal(0x234567 | 0x1000000, glued[2].main.I_CUSTOMCOLOR)
  assert_equal(true, glued[1].main.selected)
  assert_equal(true, glued[2].main.selected)
end)

test("glue_outputs accepts new GUIDs at recycled main and secondary component pointers", function()
  for _, recycled_index in ipairs({ 1, 2 }) do
    local api, model = glue_api({ reuse_pointer = recycled_index })
    local settings = base_settings({ color_items = true })
    local outputs, recycled, old_guids = {}, {}, {}
    for i = 1, 5 do
      local first = model.add_item("main-" .. i)
      local second = model.add_item("tail-" .. i)
      outputs[i] = {
        plan = { source_snapshot = { name = "signal.wav" },
          variation_index = i - 1, settings = settings },
        items = { first, second }, main = first,
      }
      recycled[i] = outputs[i].items[recycled_index]
      old_guids[i] = recycled[i].guid
    end
    local glued, reason = loop_builder.glue_outputs(api, model.project, outputs, {
      settings = settings, color = 0x123456,
    })
    assert_true(glued ~= nil, tostring(reason))
    assert_equal(5, model.command_count)
    assert_equal(5, #model.items)
    for i, output in ipairs(glued) do
      assert_equal(recycled[i], output.main)
      assert_true(old_guids[i] ~= output.main.guid)
      assert_equal(1, #output.items)
      assert_equal(1, #output.takes)
      assert_equal(output.main.take, output.takes[1])
      assert_equal("signal.wav_0" .. i, output.main.take.name)
      assert_equal(0x123456 | 0x1000000, output.main.I_CUSTOMCOLOR)
      assert_true(output.main.selected)
    end
  end
end)

test("glue_outputs validates all component GUIDs before the first render", function()
  for _, failure in ipairs({ "empty", "api_failure" }) do
    local api, model = glue_api()
    local outputs = {}
    for i = 1, 2 do
      local item = model.add_item("item-" .. i)
      outputs[i] = { plan = { source_snapshot = { name = "signal.wav" },
        variation_index = i - 1, settings = base_settings() },
        items = { item }, main = item }
    end
    if failure == "empty" then outputs[2].main.guid = ""
    else outputs[2].main.guid_read_ok = false end
    local glued, reason, partial = loop_builder.glue_outputs(api, model.project, outputs)
    assert_rejected(glued, reason)
    assert_contains(reason, "GUID")
    assert_equal(0, model.command_count)
    assert_equal(0, #partial)
  end
end)

test("glue_outputs accepts a generic output name index for Shepard layers", function()
  local api, model = glue_api()
  local first = model.add_item("first")
  local second = model.add_item("second")
  local settings = base_settings({ color_items = false })
  local outputs = {
    {
      plan = {
        source_snapshot = { name = "shepard.wav" },
        settings = settings,
      },
      name_index = 4,
      items = { first, second },
      takes = { first.take, second.take },
      main = first,
    },
  }

  local glued, reason = loop_builder.glue_outputs(api, model.project, outputs)
  assert_equal(nil, reason)
  assert_equal("shepard.wav_05", glued[1].main.take.name)
  assert_equal(1, #glued[1].takes)
  assert_equal(glued[1].main.take, glued[1].takes[1])
end)

test("glue_outputs exposes the glued item when final naming fails", function()
  local api, model = glue_api({ fail_name = true })
  local first = model.add_item("first")
  local outputs = {
    { plan = {
        source_snapshot = { name = "failed.wav" },
        variation_index = 0,
        settings = base_settings(),
      }, items = { first }, main = first },
  }

  local glued, reason, partial, failed_context = loop_builder.glue_outputs(
    api, model.project, outputs)
  assert_rejected(glued, reason)
  assert_contains(reason, "name")
  assert_equal(0, #partial)
  assert_equal("glued-1", failed_context.glued_item.id)
  assert_equal(outputs[1], failed_context.output)
  assert_equal(true, failed_context.glue_side_effect_possible)
end)

test("glue_outputs legacy call still applies the final name without color", function()
  local api, model = glue_api()
  local first = model.add_item("first")
  local settings = base_settings({ color_items = false })
  local outputs = {
    { plan = {
        source_snapshot = { name = "legacy.wav" },
        variation_index = 0,
        settings = settings,
      }, items = { first }, main = first },
  }

  local glued, reason = loop_builder.glue_outputs(api, model.project, outputs)
  assert_equal(nil, reason)
  assert_equal(1, model.command_count)
  assert_equal("legacy.wav_01", glued[1].main.take.name)
  assert_equal(nil, glued[1].main.I_CUSTOMCOLOR)
end)

test("glue_outputs rejects missing legacy color before any Glue command", function()
  local api, model = glue_api()
  local first = model.add_item("first")
  local outputs = {
    { plan = {
        source_snapshot = { name = "colored.wav" },
        variation_index = 0,
        settings = base_settings({ color_items = true }),
      }, items = { first }, main = first },
  }

  local glued, reason, partial = loop_builder.glue_outputs(
    api, model.project, outputs)
  assert_rejected(glued, reason)
  assert_contains(reason, "color")
  assert_equal(0, #partial)
  assert_equal(0, model.command_count)
end)

test("glue_outputs preflights every output before invoking Glue", function()
  local api, model = glue_api()
  local first = model.add_item("first")
  local glued, reason, partial = loop_builder.glue_outputs(api, model.project, {
    { plan = {
        source_snapshot = { name = "first.wav" }, variation_index = 0,
        settings = base_settings(),
      }, items = { first }, main = first },
    { plan = {}, items = {}, main = nil },
  })
  assert_rejected(glued, reason)
  assert_contains(reason, "output 2")
  assert_equal(0, #partial)
  assert_equal(0, model.command_count)
end)

test("glue_outputs requires exactly one selected result and returns partial", function()
  local api, model = glue_api({ fail_at = 2 })
  local a1, a2 = model.add_item("a1"), model.add_item("a2")
  local b1, b2 = model.add_item("b1"), model.add_item("b2")
  local outputs = {
    { plan = {
        source_snapshot = { name = "a.wav" }, variation_index = 0,
        settings = base_settings(),
      }, items = { a1, a2 }, main = a1 },
    { plan = {
        source_snapshot = { name = "b.wav" }, variation_index = 1,
        settings = base_settings(),
      }, items = { b1, b2 }, main = b1 },
  }

  local glued, reason, partial, failed_output = loop_builder.glue_outputs(
    api, model.project, outputs)
  assert_rejected(glued, reason)
  assert_contains(reason, "exactly one")
  assert_contains(reason, "disk")
  assert_equal(1, #partial)
  assert_equal("glued-1", partial[1].main.id)
  assert_equal(outputs[2], failed_output.output)
  assert_equal(true, failed_output.glue_side_effect_possible)
end)

test("glue_outputs rejects a new result when original components remain", function()
  local api, model = glue_api({ preserve_old = true })
  local first = model.add_item("first")
  local second = model.add_item("second")
  local settings = base_settings({ color_items = true })
  local outputs = {
    { plan = {
        source_snapshot = { name = "preserved.wav" }, variation_index = 0,
        settings = settings,
      }, items = { first, second }, main = first },
  }

  local glued, reason, partial, failed_context = loop_builder.glue_outputs(
    api, model.project, outputs, { settings = settings, color = 0x123456 })
  assert_rejected(glued, reason)
  assert_contains(reason, "original components remain")
  assert_equal(0, #partial)
  assert_equal("glued-1", failed_context.glued_item.id)
  assert_equal(outputs[1], failed_context.output)
  assert_equal(true, failed_context.glue_side_effect_possible)
  assert_equal(0, #model.names)
  assert_equal("glued-1", failed_context.glued_item.take.name)
  assert_equal(nil, failed_context.glued_item.I_CUSTOMCOLOR)
end)

test("glue_outputs rejects a no-op command that leaves an original component selected", function()
  local api, model = glue_api({ no_op = true })
  local original = model.add_item("original")
  local settings = base_settings({ color_items = true })
  local outputs = {
    { plan = {
        source_snapshot = { name = "no-op.wav" }, variation_index = 0,
        settings = settings,
      }, items = { original }, main = original },
  }

  local glued, reason, partial, failed_output = loop_builder.glue_outputs(
    api, model.project, outputs, { settings = settings, color = 0x123456 })
  assert_rejected(glued, reason)
  assert_contains(reason, "new item")
  assert_equal(0, #partial)
  assert_equal(original, failed_output.glued_item)
  assert_equal(true, failed_output.glue_side_effect_possible)
  assert_equal(0, #model.names)
  assert_equal("original", original.take.name)
  assert_equal(nil, original.I_CUSTOMCOLOR)
end)

local function with_zero_crossing_stub(stub, callback)
  local original_find = audio.find_zero_crossing
  audio.find_zero_crossing = stub
  local ok, result_or_error = pcall(callback)
  audio.find_zero_crossing = original_find
  if not ok then error(result_or_error, 0) end
  return result_or_error
end

test("analyze_plans preserves successful sides and creates explicit one-sided fallbacks", function()
  local call = 0
  with_zero_crossing_stub(function(_, _, target)
    call = call + 1
    if call == 1 then return nil, "start analysis failed" end
    if call == 2 then return { project_time = target - 0.2 } end
    if call == 3 then return { project_time = target - 0.1 } end
    return nil, "end analysis failed"
  end, function()
    local plans = assert(loop_builder.plan_loops(
      { snapshot() }, base_settings({ loops = 2 }), { start = 0, finish = 4 }))
    local analyzed, reason = loop_builder.analyze_plans({}, plans, base_settings())
    assert_equal(nil, reason)
    assert_equal(4, call)
    assert_close(10, analyzed[1].source_project_start)
    assert_close(13.8, analyzed[1].source_end)
    assert_close(3.42, analyzed[1].loop_length)
    assert_close(12, analyzed[1].boundary_anchor)
    assert_contains(analyzed[1].warning, "start analysis failed")
    assert_true(not analyzed[1].warning:find("end analysis failed", 1, true))
    assert_close(16, analyzed[2].source_project_start)
    assert_close(19.8, analyzed[2].source_end)
    assert_close(3.42, analyzed[2].loop_length, 1e-6)
    assert_close(17.9, analyzed[2].boundary_anchor)
    assert_contains(analyzed[2].warning, "end analysis failed")
    assert_contains(analyzed[2].warning, "matched variation length")
    assert_close(10, analyzed[1].output_position)
    assert_close(13.42, analyzed[2].output_position)
  end)
end)

test("analyze_plans searches each variation boundary anchor and preserves zero-anchor continuity", function()
  local targets = {}
  local returned = {}
  with_zero_crossing_stub(function(_, _, target)
    targets[#targets + 1] = target
    local result
    if #targets % 2 == 1 then
      local delta = #targets == 1 and 0.01 or -0.01
      result = { project_time = target + delta }
    else
      result = { project_time = target - 0.02 }
    end
    returned[#returned + 1] = result.project_time
    return result
  end, function()
    local plans = assert(loop_builder.plan_loops(
      { snapshot() }, base_settings({ loops = 2 }), { start = 0, finish = 4 }))
    local analyzed = assert(loop_builder.analyze_plans({}, plans, nil))
    assert_equal(4, #targets)
    for index, plan in ipairs(plans) do
      local call_index = (index - 1) * 2 + 1
      assert_close(plan.boundary_anchor, targets[call_index])
      assert_close(plan.source_end, targets[call_index + 1])
      assert_close(returned[call_index], analyzed[index].boundary_anchor)
      assert_close(returned[call_index],
        analyzed[index].components[1].source_project_start)
      assert_close(returned[call_index],
        analyzed[index].components[2].source_project_start
          + analyzed[index].components[2].length)
      assert_close(analyzed[index].source_span_length
        - analyzed[index].crossfade_length, analyzed[index].loop_length)
    end
  end)
end)

test("analyze_plans keeps three unique variations at one common final length", function()
  local plans = assert(loop_builder.plan_loops(
    { snapshot({ length = 12 }) }, base_settings({ loops = 3 }), nil))
  local call = 0
  with_zero_crossing_stub(function(_, _, target)
    call = call + 1
    local adjustments = { 0.01, -0.15, -0.01, -0.05, 0, 0 }
    return { project_time = target + adjustments[call] }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans({}, plans, nil))
    assert_equal(3, #analyzed)
    assert_close(analyzed[1].loop_length, analyzed[2].loop_length, 1e-6)
    assert_close(analyzed[1].loop_length, analyzed[3].loop_length, 1e-6)
    assert_true(analyzed[1].source_project_start
      ~= analyzed[2].source_project_start)
    assert_true(analyzed[2].source_project_start
      ~= analyzed[3].source_project_start)
    for _, plan in ipairs(analyzed) do
      assert_true(plan.components[1].fade_in > 0)
      assert_true(plan.components[#plan.components].fade_out > 0)
    end
  end)
end)

test("analyze_plans merges both fallback reasons when both searches fail", function()
  local call = 0
  with_zero_crossing_stub(function()
    call = call + 1
    if call == 1 then return nil, "start missing" end
    return nil, "end missing"
  end, function()
    local plans = assert(loop_builder.plan_loops(
      { snapshot() }, base_settings(), { start = 0, finish = 4 }))
    local analyzed = assert(loop_builder.analyze_plans({}, plans, base_settings()))
    assert_equal(2, call)
    assert_close(plans[1].source_project_start, analyzed[1].source_project_start)
    assert_close(plans[1].source_span_length, analyzed[1].source_span_length)
    assert_contains(analyzed[1].warning, "start missing")
    assert_contains(analyzed[1].warning, "end missing")
  end)
end)

test("analyze_plans inherits plan settings for nil and partial overrides", function()
  local first = snapshot({ item = {}, track = {}, position = 0, length = 5 })
  local second = snapshot({ item = {}, track = {}, position = 4, length = 2 })
  local settings = base_settings({ match_overlap = true })

  local function analyze(input_settings)
    local plans = assert(loop_builder.plan_loops({ first, second }, settings, nil))
    return with_zero_crossing_stub(function(_, _, target)
      return { project_time = target }
    end, function()
      return assert(loop_builder.analyze_plans({}, plans, input_settings))
    end)
  end

  local nil_settings = analyze(nil)
  assert_close(1.8, nil_settings[1].loop_length)
  assert_close(1.8, nil_settings[2].loop_length)

  local partial = analyze({ analysis_window = 0.01 })
  assert_close(1.8, partial[1].loop_length)
  assert_close(1.8, partial[2].loop_length)

  local disabled = analyze({ match_overlap = false })
  assert_close(4.5, disabled[1].loop_length)
  assert_close(1.8, disabled[2].loop_length)
end)

test("analyze_plans relayout uses each plan existing layout settings", function()
  local plans = assert(loop_builder.plan_loops(
    { snapshot() }, base_settings({ loops = 2, position_space = 0.2 }),
    { start = 0, finish = 4 }))
  plans[1].settings.position_space = 1
  plans[2].settings.position_space = 3
  with_zero_crossing_stub(function(_, _, target)
    return { project_time = target }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans(
      {}, plans, { analysis_window = 0.01 }))
    assert_close(10, analyzed[1].output_position)
    assert_close(14.6, analyzed[2].output_position)
    assert_equal(1, analyzed[1].settings.position_space)
    assert_equal(3, analyzed[2].settings.position_space)
  end)
end)

test("analyze_plans matches cross-track transitive groups per variation then relayouts", function()
  local track_one, track_two = {}, {}
  local a = snapshot({ item = {}, track = track_one, position = 0, length = 5 })
  local b = snapshot({ item = {}, track = track_two, position = 4, length = 3 })
  local c = snapshot({ item = {}, track = track_one, position = 6, length = 2 })
  local settings = base_settings({ loops = 2, match_overlap = true, position_space = 0.2 })
  local plans = assert(loop_builder.plan_loops({ a, b, c }, settings, nil))

  with_zero_crossing_stub(function(_, _, target)
    return { project_time = target }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans({}, plans, settings))
    assert_equal(6, #analyzed)
    for _, plan in ipairs(analyzed) do
      assert_close(1, plan.source_span_length, 1e-6)
      assert_close(0.9, plan.loop_length, 1e-6)
    end
    assert_contains(analyzed[1].warning, "matched overlap length")
    assert_contains(analyzed[2].warning, "matched overlap length")
    assert_contains(analyzed[3].warning, "matched overlap length")
    assert_contains(analyzed[4].warning, "matched overlap length")
    assert_true(analyzed[5].warning == nil
      or not analyzed[5].warning:find("matched overlap length", 1, true))
    assert_true(analyzed[6].warning == nil
      or not analyzed[6].warning:find("matched overlap length", 1, true))
    assert_close(0, analyzed[1].output_position)
    assert_close(1.1, analyzed[2].output_position, 1e-6)
    assert_close(4, analyzed[3].output_position)
    assert_close(5.1, analyzed[4].output_position, 1e-6)
    assert_close(6, analyzed[5].output_position)
    assert_close(7.1, analyzed[6].output_position, 1e-6)
  end)
end)

test("overlap matching preserves each analyzed zero boundary anchor", function()
  local first = snapshot({ item = {}, track = {}, position = 0, length = 5 })
  local second = snapshot({ item = {}, track = {}, position = 4, length = 2 })
  local settings = base_settings({ match_overlap = true })
  local plans = assert(loop_builder.plan_loops({ first, second }, settings, nil))
  local first_anchor = plans[1].boundary_anchor
  with_zero_crossing_stub(function(_, _, target)
    return { project_time = target }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans({}, plans, nil))
    assert_close(first_anchor, analyzed[1].boundary_anchor)
    assert_close(first_anchor, analyzed[1].components[1].source_project_start)
    assert_close(first_anchor,
      analyzed[1].components[2].source_project_start
        + analyzed[1].components[2].length)
  end)
end)

test("analyze_plans matches overlap lengths only within the same variation", function()
  local first = snapshot({ item = {}, track = {}, position = 0, length = 5 })
  local second = snapshot({ item = {}, track = {}, position = 4, length = 4 })
  local settings = base_settings({ loops = 2, match_overlap = true, position_space = 0.2 })
  local plans = assert(loop_builder.plan_loops({ first, second }, settings, nil))
  local call = 0
  with_zero_crossing_stub(function(_, _, target)
    call = call + 1
    if call == 7 then return { project_time = target - 1.8 } end
    if call == 8 then return { project_time = target - 2 } end
    return { project_time = target }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans({}, plans, settings))
    assert_close(1.8, analyzed[1].loop_length, 1e-6)
    assert_close(1.8, analyzed[2].loop_length, 1e-6)
    assert_close(1.8, analyzed[3].loop_length, 1e-6)
    assert_close(1.8, analyzed[4].loop_length, 1e-6)
    assert_close(0, analyzed[1].output_position)
    assert_close(2, analyzed[2].output_position, 1e-6)
    assert_close(4, analyzed[3].output_position)
    assert_close(6, analyzed[4].output_position, 1e-6)
  end)
end)

test("overlap matching shortens source intervals without changing either anchor", function()
  local first = snapshot({ item = {}, track = {}, position = 0, length = 6 })
  local second = snapshot({ item = {}, track = {}, position = 4, length = 2 })
  local settings = base_settings({ match_overlap = true })
  local plans = assert(loop_builder.plan_loops({ first, second }, settings, nil))
  local first_anchor = plans[1].boundary_anchor
  local second_anchor = plans[2].boundary_anchor

  with_zero_crossing_stub(function(_, _, target)
    return { project_time = target }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans({}, plans, settings))
    assert_close(1.8, analyzed[1].loop_length)
    assert_close(1.8, analyzed[2].loop_length)
    assert_close(first_anchor, analyzed[1].boundary_anchor)
    assert_close(second_anchor, analyzed[2].boundary_anchor)
    assert_true(analyzed[1].source_project_start >= first.position)
    assert_true(analyzed[1].source_end <= first.position + first.length)
    assert_contains(analyzed[1].warning, "matched overlap length")
  end)
end)

test("overlap matching keeps the closest feasible source start when crossfade shortens", function()
  local first = snapshot({ item = {}, track = {}, position = 0, length = 5 })
  local second = snapshot({ item = {}, track = {}, position = 4, length = 5 })
  local settings = base_settings({ match_overlap = true, cf_ratio = 0.2 })
  local plans = assert(loop_builder.plan_loops(
    { first, second }, settings, { start = 0, finish = 4 }))

  local call = 0
  with_zero_crossing_stub(function(_, _, target)
    call = call + 1
    if call == 1 then return { project_time = 0.6 } end
    if call == 3 then return { project_time = 5.25 } end
    if call == 4 then return { project_time = 8.25 } end
    return { project_time = target }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans({}, plans, settings))
    assert_close(3, analyzed[1].loop_length)
    assert_close(0.6, analyzed[1].boundary_anchor)
    assert_close(0.5, analyzed[1].source_project_start)
    assert_close(3.6, analyzed[1].source_end)
    assert_close(0.1, analyzed[1].crossfade_length)
    assert_contains(analyzed[1].warning, "crossfade shortened")
    assert_contains(analyzed[1].warning, "matched overlap length")
  end)
end)

test("overlap matching reports an impossible fixed anchor interval", function()
  local first = snapshot({ item = {}, track = {}, position = 0, length = 2 })
  local second = snapshot({ item = {}, track = {}, position = 1, length = 1 })
  local settings = base_settings({ match_overlap = true })
  local first_plan = assert(loop_builder.plan_loops({ first }, settings, nil))[1]
  local second_plan = assert(loop_builder.plan_loops({ second }, settings, nil))[1]
  first_plan.boundary_anchor = first.position + first.length

  with_zero_crossing_stub(function(_, _, target)
    return { project_time = target }
  end, function()
    local analyzed, reason = loop_builder.analyze_plans(
      {}, { first_plan, second_plan }, settings)
    assert_rejected(analyzed, reason)
    assert_contains(reason, "anchor")
  end)
end)

test("analyze_plans does not match overlapping snapshots on the same track", function()
  local track = {}
  local first = snapshot({ item = {}, track = track, position = 0, length = 5 })
  local second = snapshot({ item = {}, track = track, position = 4, length = 2 })
  local settings = base_settings({ match_overlap = true })
  local plans = assert(loop_builder.plan_loops({ first, second }, settings, nil))
  with_zero_crossing_stub(function(_, _, target)
    return { project_time = target }
  end, function()
    local analyzed = assert(loop_builder.analyze_plans({}, plans, settings))
    assert_close(4.5, analyzed[1].loop_length)
    assert_close(1.8, analyzed[2].loop_length)
  end)
end)

local function analyzed_unique_variations(sources, settings)
  local planned = assert(loop_builder.plan_loops(sources, settings, nil))
  return with_zero_crossing_stub(function(_, _, target)
    return { project_time = target }
  end, function()
    return assert(loop_builder.analyze_plans({}, planned, settings))
  end)
end

local function rounded_sample(value, sample_rate)
  local samples = value * sample_rate
  if samples >= 0 then return math.floor(samples + 0.5) end
  return math.ceil(samples - 0.5)
end

local function assert_balanced_assets(plans, variation_count)
  local counts = {}
  for variation = 0, variation_count - 1 do counts[variation] = 0 end
  for index, plan in ipairs(plans) do
    counts[plan.asset_variant_index] = counts[plan.asset_variant_index] + 1
    if index > 1 and variation_count > 1 then
      assert_true(plan.asset_variant_index ~= plans[index - 1].asset_variant_index,
        "expected adjacent timeline slots to use different assets")
    end
  end
  local minimum, maximum = math.huge, -math.huge
  for variation = 0, variation_count - 1 do
    minimum = math.min(minimum, counts[variation])
    maximum = math.max(maximum, counts[variation])
  end
  assert_true(maximum - minimum <= 1, "expected balanced asset counts")
end

test("fill_time_selection expands five analyzed variations across a long exact sample range", function()
  local sample_rate = 48000
  local settings = base_settings({
    loops = 5,
    shuffle = true,
    position_space = 0.75,
    cf_ratio = 0.1,
  })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local starts = {}
  for _, plan in ipairs(unique) do
    assert_true(not starts[plan.source_project_start], "expected unique source spans")
    starts[plan.source_project_start] = true
  end

  local expanded, summary = loop_builder.fill_time_selection(
    unique, { start = 100, finish = 160 }, sample_rate, settings,
    function() return 0 end)

  assert_equal(5, #unique)
  assert_true(#expanded > #unique)
  assert_equal(summary.slot_count, #expanded)
  assert_equal(100 * sample_rate, summary.start_sample)
  assert_equal(160 * sample_rate, summary.end_sample)
  assert_equal(60 * sample_rate, summary.total_samples)
  assert_equal(summary.total_samples, summary.slot_count * summary.slot_samples)
  assert_close(summary.slot_samples / sample_rate, summary.slot_length)
  assert_close(summary.start_sample / sample_rate, expanded[1].output_position)
  for index, plan in ipairs(expanded) do
    assert_equal(index - 1, plan.sequence_index)
    assert_equal(summary.slot_samples, plan.slot_samples)
    assert_close(summary.slot_length, plan.loop_length)
    assert_equal(plan.variation_index, plan.asset_variant_index)
    assert_equal(0.75, plan.settings.position_space)
    if index > 1 then
      assert_close(expanded[index - 1].output_position + summary.slot_length,
        plan.output_position)
    end
    assert_close(0.003, plan.components[1].fade_in)
    assert_close(0.003, plan.components[#plan.components].fade_out)
  end
  local last = expanded[#expanded]
  assert_equal(summary.end_sample,
    rounded_sample(last.output_position + last.loop_length, sample_rate))
  assert_balanced_assets(expanded, 5)
end)

test("fill_time_selection preserves equal analyzed sample lengths without stretching", function()
  local sample_rate = 48000
  local settings = base_settings({ loops = 5, shuffle = false, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local original_start = unique[1].source_project_start
  local original_end = unique[1].source_end
  local original_anchor = unique[1].boundary_anchor

  local expanded, summary = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 9 }, sample_rate, settings)

  assert_equal(5, summary.slot_count)
  assert_equal(86400, summary.slot_samples)
  assert_close(unique[1].loop_length, summary.slot_length)
  assert_close(original_start, expanded[1].source_project_start)
  assert_close(original_end, expanded[1].source_end)
  assert_close(original_anchor, expanded[1].boundary_anchor)
  assert_close(original_start, unique[1].source_project_start)
  assert_close(original_end, unique[1].source_end)
  assert_close(original_anchor, unique[1].boundary_anchor)
end)

test("fill_time_selection uses round robin when shuffle is disabled", function()
  local settings = base_settings({ loops = 5, shuffle = false, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local expanded = assert(loop_builder.fill_time_selection(
    unique, { start = 0, finish = 18 }, 48000, settings))

  assert_equal(10, #expanded)
  for index, plan in ipairs(expanded) do
    assert_equal((index - 1) % 5, plan.asset_variant_index)
    assert_equal(index - 1, plan.sequence_index)
  end
end)

test("fill_time_selection shares one sequence and slot positions across source layers", function()
  local settings = base_settings({ loops = 5, shuffle = true, cf_ratio = 0.1 })
  local first = snapshot({ item = { id = "first" }, take = {}, track = {}, position = 0 })
  local second = snapshot({ item = { id = "second" }, take = {}, track = {}, position = 0 })
  local unique = analyzed_unique_variations({ first, second }, settings)
  local expanded, summary = loop_builder.fill_time_selection(
    unique, { start = 20, finish = 38 }, 48000, settings,
    function() return 0 end)

  assert_equal(summary.slot_count * 2, #expanded)
  for slot = 1, summary.slot_count do
    local left = expanded[slot]
    local right = expanded[summary.slot_count + slot]
    assert_equal(first, left.source_snapshot)
    assert_equal(second, right.source_snapshot)
    assert_equal(left.sequence_index, right.sequence_index)
    assert_equal(left.asset_variant_index, right.asset_variant_index)
    assert_close(left.output_position, right.output_position)
  end
end)

test("fill_time_selection deep copies mutable instance fields for repeated assets", function()
  local settings = base_settings({
    loops = 5,
    shuffle = false,
    position_space = 0.5,
    cf_ratio = 0.1,
  })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local original_component_position = unique[1].components[1].position
  local expanded = assert(loop_builder.fill_time_selection(
    unique, { start = 0, finish = 18 }, 48000, settings))
  assert_equal(expanded[1].asset_variant_index, expanded[6].asset_variant_index)

  expanded[1].settings.position_space = 99
  expanded[1].components[1].position = 99
  assert_equal(0.5, expanded[6].settings.position_space)
  assert_true(expanded[6].components[1].position ~= 99)
  assert_equal(0.5, unique[1].settings.position_space)
  assert_close(original_component_position, unique[1].components[1].position)
end)

test("fill_time_selection rejects a range too short to include every variation", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local expanded, reason = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 5759 / 48000 }, 48000, settings)
  assert_rejected(expanded, reason)
  assert_contains(reason, "too short")
end)

test("fill_time_selection reports when the sample window has no legal divisor", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local expanded, reason = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 6001 / 48000 }, 48000, settings)
  assert_rejected(expanded, reason)
  assert_contains(reason, "no legal divisor")
end)

test("fill_time_selection rejects missing and duplicate variation indexes", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local missing = analyzed_unique_variations({ snapshot() }, settings)
  table.remove(missing, 3)
  local expanded, reason = loop_builder.fill_time_selection(
    missing, { start = 0, finish = 9 }, 48000, settings)
  assert_rejected(expanded, reason)
  assert_contains(reason, "variation")

  local duplicate = analyzed_unique_variations({ snapshot() }, settings)
  duplicate[5].variation_index = 3
  expanded, reason = loop_builder.fill_time_selection(
    duplicate, { start = 0, finish = 9 }, 48000, settings)
  assert_rejected(expanded, reason)
  assert_contains(reason, "variation")
end)

test("fill_time_selection rejects source groups with inconsistent variation sets", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local first = snapshot({ item = {}, take = {}, track = {}, position = 0 })
  local second = snapshot({ item = {}, take = {}, track = {}, position = 20 })
  local unique = analyzed_unique_variations({ first, second }, settings)
  table.remove(unique, #unique)

  local expanded, reason = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 9 }, 48000, settings)
  assert_rejected(expanded, reason)
  assert_contains(reason, "source group")
end)

test("fill_time_selection reports a variation that cannot fit its fixed anchor", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  unique[1].boundary_anchor = unique[1].source_snapshot.position
    + unique[1].source_snapshot.length

  local expanded, reason = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 9 }, 48000, settings)
  assert_rejected(expanded, reason)
  assert_contains(reason, "fit")
end)

test("fill_time_selection rejects invalid inputs and rng failures", function()
  local settings = base_settings({ loops = 5, shuffle = true, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local cases = {
    { nil, { start = 0, finish = 9 }, 48000, settings, nil },
    { {}, { start = 0, finish = 9 }, 48000, settings, nil },
    { unique, nil, 48000, settings, nil },
    { unique, { start = 0, finish = 9 }, 0, settings, nil },
    { unique, { start = 0, finish = 9 }, 48000, "invalid", nil },
    { unique, { start = 0, finish = 9 }, 48000, settings, "invalid" },
  }
  for _, arguments in ipairs(cases) do
    local expanded, reason = loop_builder.fill_time_selection(table.unpack(arguments))
    assert_rejected(expanded, reason)
  end

  local expanded, reason = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 9 }, 48000, settings,
    function() error("rng exploded") end)
  assert_rejected(expanded, reason)
  assert_contains(reason, "rng")
end)

local function assert_fill_rejects_without_throw(plans, settings, fragment)
  local ok, expanded, reason = pcall(loop_builder.fill_time_selection,
    plans, { start = 0, finish = 9 }, 48000, settings)
  assert_true(ok, "fill_time_selection leaked a Lua exception: " .. tostring(expanded))
  assert_rejected(expanded, reason)
  assert_contains(reason, fragment)
end

test("fill_time_selection validates every analyzed plan geometry field", function()
  local settings = base_settings({ loops = 1, cf_ratio = 0.1 })
  local cases = {
    { field = "plan", mutate = function(plans) plans[1] = "invalid" end },
    { field = "source_snapshot", mutate = function(plans) plans[1].source_snapshot = {} end },
    { field = "loop_length", mutate = function(plans) plans[1].loop_length = 0 end },
    { field = "source_project_start", mutate = function(plans) plans[1].source_project_start = nil end },
    { field = "source_end", mutate = function(plans) plans[1].source_end = plans[1].source_project_start end },
    { field = "boundary_anchor", mutate = function(plans) plans[1].boundary_anchor = math.huge end },
    { field = "components", mutate = function(plans) plans[1].components = "invalid" end },
    { field = "settings", mutate = function(plans) plans[1].settings = "invalid" end },
    { field = "variation", mutate = function(plans) plans[1].variation_index = 1 end },
  }

  for _, case in ipairs(cases) do
    local plans = analyzed_unique_variations({ snapshot() }, settings)
    case.mutate(plans)
    assert_fill_rejects_without_throw(plans, settings, case.field)
  end
end)

test("fill_time_selection validates snapshot numeric fields and positive lengths", function()
  local settings = base_settings({ loops = 1, cf_ratio = 0.1 })
  local cases = {
    { field = "position", value = 0 / 0 },
    { field = "length", value = 0 },
    { field = "start_offset", value = "invalid" },
    { field = "playrate", value = 0 },
  }

  for _, case in ipairs(cases) do
    local plans = analyzed_unique_variations({ snapshot() }, settings)
    plans[1].source_snapshot[case.field] = case.value
    assert_fill_rejects_without_throw(plans, settings, case.field)
  end
end)

test("fill_time_selection converts unexpected fitting exceptions into a clear rejection", function()
  local settings = base_settings({ loops = 1, cf_ratio = 0.1 })
  local plans = analyzed_unique_variations({ snapshot() }, settings)
  local original = plans[1].source_snapshot
  local reads = 0
  plans[1].source_snapshot = setmetatable({
    length = original.length,
    start_offset = original.start_offset,
    playrate = original.playrate,
    source_length = original.source_length,
    item = original.item,
    take = original.take,
    track = original.track,
  }, {
    __index = function(_, key)
      if key == "position" then
        reads = reads + 1
        if reads <= 2 then return original.position end
        error("fit exploded")
      end
      return original[key]
    end,
  })

  assert_fill_rejects_without_throw(plans, settings, "fit failed")
end)

test("fill_time_selection uses the global shortest natural length across source groups", function()
  local settings = base_settings({ loops = 5, shuffle = false, cf_ratio = 0.1 })
  local first = snapshot({ item = {}, take = {}, track = {}, position = 0, length = 10 })
  local second = snapshot({ item = {}, take = {}, track = {}, position = 20, length = 5 })
  local unique = analyzed_unique_variations({ first, second }, settings)
  local shortest = math.huge
  for _, plan in ipairs(unique) do shortest = math.min(shortest, plan.loop_length) end

  local expanded, summary = loop_builder.fill_time_selection(
    unique, { start = 40, finish = 49 }, 48000, settings)

  assert_close(shortest, summary.slot_length)
  assert_equal(10, summary.slot_count)
  assert_equal(summary.slot_count * 2, #expanded)
end)

test("fill_time_selection shortening preserves anchors Item bounds and warnings", function()
  local settings = base_settings({ loops = 5, shuffle = false, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({ snapshot() }, settings)
  local original_anchors = {}
  for index, plan in ipairs(unique) do original_anchors[index] = plan.boundary_anchor end

  local expanded, summary = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 8 }, 48000, settings)

  assert_close(1.6, summary.slot_length)
  for variation = 1, 5 do
    local plan = expanded[variation]
    local item_start = plan.source_snapshot.position
    local item_end = item_start + plan.source_snapshot.length
    assert_close(original_anchors[variation], plan.boundary_anchor)
    assert_true(plan.source_project_start >= item_start)
    assert_true(plan.source_end <= item_end)
    assert_contains(plan.warning, "matched timeline slot length")
  end
end)

test("fill_time_selection summary reports variation and source counts", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local unique = analyzed_unique_variations({
    snapshot({ item = {}, take = {}, track = {}, position = 0 }),
    snapshot({ item = {}, take = {}, track = {}, position = 20 }),
  }, settings)

  local _, summary = loop_builder.fill_time_selection(
    unique, { start = 0, finish = 9 }, 48000, settings)
  assert_equal(5, summary.variation_count)
  assert_equal(2, summary.source_count)
end)

test("fill_time_selection rejects a forged loop length that exceeds derived geometry", function()
  local settings = base_settings({ loops = 1, cf_ratio = 0.1 })
  local plans = analyzed_unique_variations({ snapshot() }, settings)
  assert_close(9, plans[1].loop_length)
  plans[1].loop_length = 12

  assert_fill_rejects_without_throw(plans, settings, "derived geometry")
end)

test("fill_time_selection rejects forged scalar derived geometry fields", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  for _, field in ipairs({
    "source_span_length",
    "crossfade_length",
    "boundary_fade_length",
  }) do
    local plans = analyzed_unique_variations({ snapshot() }, settings)
    plans[1][field] = plans[1][field] + 0.25
    assert_fill_rejects_without_throw(plans, settings, "derived geometry")
  end
end)

test("fill_time_selection rejects forged component positions lengths and fades", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local mutations = {
    function(component) component.position = component.position + 0.25 end,
    function(component) component.length = component.length + 0.25 end,
    function(component) component.fade_in = component.fade_in + 0.25 end,
    function(component) component.fade_out = component.fade_out + 0.25 end,
  }

  for _, mutate in ipairs(mutations) do
    local plans = analyzed_unique_variations({ snapshot() }, settings)
    mutate(plans[1].components[1])
    assert_fill_rejects_without_throw(plans, settings, "derived geometry")
  end
end)

test("fill_time_selection rejects forged component structure", function()
  local settings = base_settings({ loops = 5, cf_ratio = 0.1 })
  local plans = analyzed_unique_variations({ snapshot() }, settings)
  table.remove(plans[1].components)

  assert_fill_rejects_without_throw(plans, settings, "derived geometry")
end)

local function short_analyzed_sources(source_count)
  local sources = {}
  for index = 1, source_count do
    sources[index] = snapshot({
      item = { id = "short-item-" .. index },
      take = { id = "short-take-" .. index },
      track = { id = "short-track-" .. index },
      position = index,
      length = 0.024,
      start_offset = 0,
      playrate = 1,
      source_length = 1,
    })
  end
  local settings = base_settings({ loops = 1, shuffle = false, cf_ratio = 0 })
  return analyzed_unique_variations(sources, settings), settings
end

test("fill_time_selection rejects slot counts above the timeline limit", function()
  local plans, settings = short_analyzed_sources(1)
  local actual_slots = 10001
  local expanded, reason = loop_builder.fill_time_selection(
    plans, { start = 0, finish = actual_slots * 1152 / 48000 },
    48000, settings)

  assert_rejected(expanded, reason)
  assert_contains(reason, tostring(actual_slots))
  assert_contains(reason, tostring(loop_builder.MAX_TIMELINE_SLOTS))
end)

test("fill_time_selection rejects total instances above the timeline limit", function()
  local plans, settings = short_analyzed_sources(3)
  local slot_count = 10000
  local actual_instances = 3 * slot_count
  local expanded, reason = loop_builder.fill_time_selection(
    plans, { start = 0, finish = slot_count * 1152 / 48000 },
    48000, settings)

  assert_rejected(expanded, reason)
  assert_contains(reason, tostring(actual_instances))
  assert_contains(reason, tostring(loop_builder.MAX_TIMELINE_INSTANCES))
end)

test("fill_time_selection rejects a plans array with a middle hole", function()
  local settings = base_settings({ loops = 3, cf_ratio = 0.1 })
  local plans = analyzed_unique_variations({ snapshot() }, settings)
  plans[2] = nil

  assert_fill_rejects_without_throw(plans, settings, "dense array")
end)

test("fill_time_selection rejects non-array keys in plans", function()
  local settings = base_settings({ loops = 1, cf_ratio = 0.1 })
  local plans = analyzed_unique_variations({ snapshot() }, settings)
  plans.extra = plans[1]

  assert_fill_rejects_without_throw(plans, settings, "dense array")
end)

test("fill_time_selection keeps a normal long selection below output limits", function()
  local settings = base_settings({ loops = 5, shuffle = false, cf_ratio = 0.1 })
  local plans = analyzed_unique_variations({ snapshot() }, settings)
  local expanded, summary = loop_builder.fill_time_selection(
    plans, { start = 100, finish = 160 }, 48000, settings)

  assert_true(summary.slot_count < loop_builder.MAX_TIMELINE_SLOTS)
  assert_equal(summary.slot_count, #expanded)
end)

test("rounded Glue Item tails are bounded before no-selection planning and apply", function()
  for _, rate in ipairs({ 0.5, 1, 1.5, 2 }) do
    local api, model, item, take = snapshot_api()
    take.source.length = 2.4093958333333
    take.source.sample_rate = 96000
    take.start_offset, take.playrate = 0.125, rate
    local readable = (take.source.length - take.start_offset) / rate
    item.length = readable + 0.000000532 / rate
    local original_length, original_chunk = item.length, item.chunk
    local sources = assert(loop_builder.snapshot_selected(api, model.project))
    assert_close(readable, sources[1].length, 1e-12)
    assert_equal(original_length, item.length)
    assert_equal(original_chunk, sources[1].chunk)
    for _, loops in ipairs({ 1, 5 }) do
      local plans = assert(loop_builder.plan_loops(sources, base_settings({ loops = loops }), nil))
      for _, plan in ipairs(plans) do
        for _, component in ipairs(plan.components) do
          local copy_api = clone_api()
          local clone, reason = loop_builder.clone_from_chunk(copy_api, sources[1], component)
          assert_true(clone ~= nil, tostring(reason))
          local finish = clone.take.D_STARTOFFS + clone.D_LENGTH * rate
          assert_true(finish <= take.source.length + 1e-12)
        end
      end
    end
  end
end)

test("snapshot rounding does not truncate genuine source overruns", function()
  local api, model, item, take = snapshot_api()
  take.source.length, take.source.sample_rate = 2, 48000
  take.start_offset, take.playrate, item.length = 0, 1, 2 + 2 / 48000
  local sources = assert(loop_builder.snapshot_selected(api, model.project))
  assert_equal(item.length, sources[1].length)
  local plan = assert(loop_builder.plan_loops(sources, base_settings(), nil))[1]
  local clone, reason = loop_builder.clone_from_chunk(clone_api(), sources[1], plan.components[1])
  assert_rejected(clone, reason)
  assert_contains(reason, "exceeds the available source")
end)

test("snapshot rounding never expands shorter Items or guesses missing sample rate", function()
  for _, missing_rate in ipairs({ false, true }) do
    local api, model, item, take = snapshot_api()
    take.source.length, take.source.sample_rate = 2, 48000
    take.start_offset, take.playrate = 0, 1
    item.length = missing_rate and (2 + 0.000000532) or 1.999
    if missing_rate then api.GetMediaSourceSampleRate = nil end
    local sources = assert(loop_builder.snapshot_selected(api, model.project))
    assert_equal(item.length, sources[1].length)
  end
end)

test("time-selection fitting aligns crossfades across offset source layers", function()
  local settings = base_settings({ loops = 1, cf_ratio = 0.1, match_overlap = false })
  local long = snapshot({ item = {}, take = {}, track = {},
    position = 10, length = 29, start_offset = 0, playrate = 1,
    source_length = 29 })
  local short = snapshot({ item = {}, take = {}, track = {},
    position = 25, length = 7.0766938819381, start_offset = 0, playrate = 1,
    source_length = 10 })
  local unique = analyzed_unique_variations({ long, short }, settings)
  local expanded, summary = loop_builder.fill_time_selection(
    unique, { start = 100, finish = 140 }, 100, settings)

  assert_equal(2 * summary.slot_count, #expanded)
  local expected_center = summary.slot_length / 2
  for source = 0, 1 do
    local plan = expanded[source * summary.slot_count + 1]
    assert_equal(2, #plan.components)
    local overlap_start = plan.components[2].position - plan.output_position
    local overlap_end = plan.components[1].length
    assert_close(expected_center, (overlap_start + overlap_end) / 2, 1e-8)
    assert_close(plan.crossfade_length, overlap_end - overlap_start, 1e-8)
  end
end)

return true
