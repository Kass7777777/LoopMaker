local helper = require("tests.test_helper")
local deferred_loop = require("lib.deferred_loop")

helper.test("every deferred frame is protected and a later error stops scheduling", function()
  local scheduled
  local api = {
    defer = function(callback)
      scheduled = callback
    end,
  }
  local calls = 0
  local error_message
  local step = deferred_loop.create(api, function()
    calls = calls + 1
    if calls == 2 then error("second frame failed") end
    return true
  end, function(message)
    error_message = message
  end)

  step()
  helper.assert_true(type(scheduled) == "function")
  local second = scheduled
  scheduled = nil
  second()

  helper.assert_equal(2, calls)
  helper.assert_true(error_message:find("second frame failed", 1, true) ~= nil)
  helper.assert_equal(nil, scheduled)
end)

helper.test("deferred loop stops cleanly when the frame returns false", function()
  local scheduled = false
  local api = {
    defer = function()
      scheduled = true
    end,
  }
  local step = deferred_loop.create(api, function()
    return false
  end, function() end)

  step()

  helper.assert_equal(false, scheduled)
end)
