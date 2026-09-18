-- Install hook: only ever touches ctx.packages, the batch mise selected. The
-- whole batch goes out in one `code` invocation, falling back to one call per
-- extension if that fails, so a single bad or flaky extension doesn't stop the
-- rest from installing.
local vscode = require("vscode")

function PLUGIN:PackageInstall(ctx)
  vscode.install(ctx.packages or {}, { dry_run = ctx.dry_run })
  return {}
end
