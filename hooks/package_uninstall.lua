-- Uninstall hook: only reached via
-- `mise bootstrap packages prune --manager vscode`, and only for
-- the identities mise hands over — never for other extensions it finds.
local vscode = require("vscode")

function PLUGIN:PackageUninstall(ctx)
  for _, pkg in ipairs(ctx.packages or {}) do
    vscode.uninstall(pkg, { dry_run = ctx.dry_run })
  end
  return {}
end
