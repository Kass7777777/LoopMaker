local helper = require("tests.test_helper")

local function recovery_module()
  return require("lib.recovery_loop")
end

helper.test("recovery remains pending until Cancel succeeds", function()
  local recovery = recovery_module().new("frame exploded")
  local attempts = 0
  local function cancel()
    attempts = attempts + 1
    if attempts == 1 then
      return nil, "Stop playback/recording before Cancel"
    end
    return true
  end

  local first = recovery:step(cancel)
  helper.assert_equal(true, first.pending)
  helper.assert_equal(false, first.finished)
  helper.assert_true(type(first.notice) == "string"
    and first.notice:find("stop REAPER transport", 1, true) ~= nil
    and first.notice:find("Actions > Running script", 1, true) ~= nil
    and first.notice:find("atexit", 1, true) ~= nil)

  local second = recovery:step(cancel)
  helper.assert_equal(false, second.pending)
  helper.assert_equal(true, second.finished)
  helper.assert_equal("frame exploded", second.message)
  helper.assert_equal(2, attempts)
end)

helper.test("transport recovery notice is emitted only once", function()
  local recovery = recovery_module().new("frame exploded")
  local function blocked()
    return nil, "Stop playback/recording before Cancel"
  end

  local first = recovery:step(blocked)
  local second = recovery:step(blocked)
  local third = recovery:step(blocked)

  helper.assert_true(type(first.notice) == "string")
  helper.assert_equal(nil, second.notice)
  helper.assert_equal(nil, third.notice)
  helper.assert_equal(true, recovery:is_pending())
end)

helper.test("non-transport Cancel failures stay pending and are not silent", function()
  local recovery = recovery_module().new("frame exploded")
  local first = recovery:step(function()
    return nil, "chunk restore failed"
  end)
  local second = recovery:step(function()
    return nil, "chunk restore failed"
  end)

  helper.assert_equal(true, first.pending)
  helper.assert_equal(false, first.finished)
  helper.assert_true(type(first.notice) == "string"
    and first.notice:find("chunk restore failed", 1, true) ~= nil)
  helper.assert_equal(nil, second.notice)
  helper.assert_equal(true, recovery:is_pending())
end)

helper.test("thrown Cancel errors remain retryable", function()
  local recovery = recovery_module().new("original frame failure")
  local first = recovery:step(function()
    error("Cancel exploded")
  end)

  helper.assert_equal(true, first.pending)
  helper.assert_equal(false, first.finished)
  helper.assert_true(type(first.notice) == "string"
    and first.notice:find("Cancel exploded", 1, true) ~= nil)
  helper.assert_equal(true, recovery:is_pending())

  local second = recovery:step(function() return true end)
  helper.assert_equal(true, second.finished)
  helper.assert_equal("original frame failure", second.message)
end)
