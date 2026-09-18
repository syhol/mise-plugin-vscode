-- Upgrade hook: same contract as PackageInstall. `--install-extension --force`
-- pulls the newest marketplace build for an unpinned extension, and re-asserts
-- the exact build for a pinned one.
local vscode = require("vscode")

function PLUGIN:PackageUpgrade(ctx)
  vscode.install(ctx.packages or {}, { dry_run = ctx.dry_run })
  return {}
end
