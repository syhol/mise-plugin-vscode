-- Install hook: only ever touches ctx.packages, the batch mise selected.
local vscode = require("vscode")

function PLUGIN:PackageInstall(ctx)
  for _, pkg in ipairs(ctx.packages or {}) do
    vscode.install(pkg, { dry_run = ctx.dry_run })
  end
  return {}
end
