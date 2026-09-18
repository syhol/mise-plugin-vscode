-- Upgrade hook: same contract as PackageInstall. `--install-extension --force`
-- pulls the newest marketplace build for an unpinned extension, and re-asserts
-- the exact build for a pinned one.
local vscode = require("vscode")

function PLUGIN:PackageUpgrade(ctx)
  for _, pkg in ipairs(ctx.packages or {}) do
    vscode.install(pkg, { dry_run = ctx.dry_run })
  end
  return {}
end
