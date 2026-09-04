local function format(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  return tostring(value)
end

local function create()
  local M = {}
  local tests = {}

  function M.assert_equal(expected, actual, message)
    if expected ~= actual then
      error(message or ("expected " .. format(expected) .. ", got " .. format(actual)), 2)
    end
  end

  function M.assert_true(value, message)
    if not value then
      error(message or ("expected truthy value, got " .. format(value)), 2)
    end
  end

  function M.test(name, callback)
    tests[#tests + 1] = { name = name, callback = callback }
  end

  function M.count()
    return #tests
  end

  function M.run(write_output)
    local passed = 0
    local failed = 0
    local function write(...)
      if write_output ~= false then
        io.write(...)
      end
    end

    if #tests == 0 then
      failed = 1
      write("[FAIL] no tests registered\n")
    end

    for _, case in ipairs(tests) do
      local ok, err = pcall(case.callback)
      if ok then
        passed = passed + 1
        if write_output ~= "failures" then write("[PASS] ", case.name, "\n") end
      else
        failed = failed + 1
        write("[FAIL] ", case.name, "\n  ", tostring(err), "\n")
      end
    end

    write(string.format("\n%d passed, %d failed\n", passed, failed))
    return passed, failed
  end

  return M
end

local helper = create()
helper.create = create

return helper
