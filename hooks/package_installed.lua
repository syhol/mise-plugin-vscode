-- Status hook: side-effect free, non-interactive, never elevates.
-- One `--list-extensions` call answers the whole batch.
local vscode = require("vscode")

function PLUGIN:PackageInstalled(ctx)
  local requested = ctx.packages or {}
  local results = {}

  if #requested == 0 then
    return { packages = results }
  end

  local installed = vscode.list_installed()

  for _, pkg in ipairs(requested) do
    local entry = installed[vscode.normalize(pkg.name)]
    local result = { name = pkg.name, state = "missing" }
    if entry ~= nil then
      result.version = entry.version
      -- A pinned version that doesn't match counts as missing, so mise
      -- schedules the install that moves it onto the pin.
      if vscode.pin_satisfied(pkg.version, entry.version) then
        result.state = "installed"
      end
    end
    table.insert(results, result)
  end

  return { packages = results }
end
