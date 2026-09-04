local source = debug.getinfo(1, "S").source
local script_path = source:sub(1, 1) == "@" and source:sub(2) or source
local normalized_script_path = script_path:gsub("\\", "/")
local runner_directory = normalized_script_path:match("^(.*)/[^/]+$") or "."
if runner_directory == "" then
  runner_directory = "."
end

local path_utils_chunk, load_error = loadfile(runner_directory .. "/path_utils.lua")
if not path_utils_chunk then
  error(load_error, 0)
end
local path_utils = path_utils_chunk()
local root = path_utils.project_root(script_path)

local path_list_separator = package.config:sub(3, 3)
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, path_list_separator)

local helper = require("tests.test_helper")
local modules = {
  "tests.test_core",
  "tests.test_audio",
  "tests.test_state",
  "tests.test_naming",
  "tests.test_presets",
  "tests.test_timeline_fill",
  "tests.test_loop_builder",
  "tests.test_shepard",
  "tests.test_ui_model",
  "tests.test_app",
  "tests.test_main_window",
  "tests.test_deferred_loop",
  "tests.test_recovery_loop",
  "tests.test_preset_actions",
}

-- Default output is concise. Choose focused modules while iterating.
local requested, verbose = nil, false
for _, option in ipairs(arg or {}) do
  if option == "--verbose" then
    verbose = true
  elseif option == "--ui" then
    requested = { "ui_model", "main_window", "preset_actions" }
  elseif option:match("^%-%-modules=") then
    requested = {}
    for name in option:sub(11):gmatch("[^,]+") do requested[#requested + 1] = name end
    if #requested == 0 then error("No test modules specified", 0) end
  elseif option ~= "--full" then
    error("Unknown test option: " .. option, 0)
  end
end
if requested then
  local available, selected, seen = {}, {}, {}
  for _, name in ipairs(modules) do available[name] = true end
  for _, name in ipairs(requested) do
    local module_name = name:match("^tests%.") and name or "tests.test_" .. name:gsub("^test_", "")
    if not available[module_name] then error("Unknown test module: " .. name, 0) end
    if not seen[module_name] then selected[#selected + 1], seen[module_name] = module_name, true end
  end
  modules = selected
end
io.write(string.format("Running %d test modules (%s)\n", #modules, requested and "focused" or "full"))

for _, module_name in ipairs(modules) do
  local ok, err = pcall(require, module_name)
  if not ok then
    helper.test("load " .. module_name, function()
      error(err, 0)
    end)
  end
end

local _, failed = helper.run(verbose and true or "failures")
if failed > 0 then
  os.exit(1)
end
