local M = {}

local function normalize(path)
  return (path:gsub("\\", "/"))
end

local function runner_directory(path)
  local directory = normalize(path):match("^(.*)/[^/]+$")
  if directory == nil or directory == "" then
    return "."
  end
  return directory
end

function M.project_root(runner_path)
  local directory = runner_directory(runner_path)
  if directory == "." then
    return ".."
  end

  local root = directory:match("^(.*)/[^/]+$")
  if root == nil or root == "" then
    return "."
  end
  return root
end

return M
