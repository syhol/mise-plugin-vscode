-- Shared helpers for the vscode package plugin.
--
-- Everything goes through the VS Code CLI (`code`), which is the only
-- supported way to query/install/remove extensions. mise puts `lib/?.lua` on
-- package.path, so hooks pick this up with `require("vscode")`.

local cmd = require("cmd")
local strings = require("strings")

local M = {}

-- The CLI to drive. Override to manage a VS Code fork's extensions instead:
--   MISE_VSCODE_CLI=cursor   (or code-insiders, codium, windsurf, ...)
function M.cli()
  local override = os.getenv("MISE_VSCODE_CLI")
  if override ~= nil and strings.trim_space(override) ~= "" then
    return strings.trim_space(override)
  end
  return "code"
end

-- An alternate extensions directory, for testing against a disposable profile:
--   MISE_VSCODE_EXTENSIONS_DIR=/tmp/vsx-test
function M.extensions_dir()
  local dir = os.getenv("MISE_VSCODE_EXTENSIONS_DIR")
  if dir ~= nil and strings.trim_space(dir) ~= "" then
    return strings.trim_space(dir)
  end
  return nil
end

-- cmd.exec runs through `sh -c`, so every interpolated value is quoted.
function M.quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- The CLI invocation without its action arguments, e.g. `code` or
-- `code --extensions-dir '/tmp/vsx-test'`.
function M.base_command()
  local base = M.quote(M.cli())
  local dir = M.extensions_dir()
  if dir ~= nil then
    base = base .. " --extensions-dir " .. M.quote(dir)
  end
  return base
end

-- Run a CLI invocation, turning the raw Lua error into something actionable.
local function exec(args)
  local command = M.base_command() .. " " .. args
  local ok, output = pcall(cmd.exec, command)
  if not ok then
    local detail = tostring(output)
    if strings.contains(detail, "not found") then
      error(
        "VS Code CLI '" .. M.cli() .. "' not found on PATH. Install the "
          .. "`code` command (VS Code: Shell Command: Install 'code' command in PATH) "
          .. "or set MISE_VSCODE_CLI to another editor's CLI."
      )
    end
    error("`" .. command .. "` failed: " .. detail)
  end
  return output or ""
end

-- Extension ids are case-insensitive; `--list-extensions` prints the
-- marketplace's canonical casing, which need not match what is configured.
function M.normalize(name)
  return tostring(name):lower()
end

-- Map of normalized id -> { name = canonical id, version = "1.2.3" }.
function M.list_installed()
  local output = exec("--list-extensions --show-versions")
  local installed = {}
  for _, line in ipairs(strings.split(output, "\n")) do
    local entry = strings.trim_space(line)
    if entry ~= "" then
      local id, version = entry:match("^(.+)@([^@]+)$")
      if id == nil then
        id, version = entry, nil
      end
      installed[M.normalize(id)] = { name = id, version = version }
    end
  end
  return installed
end

-- Version strings are opaque: a pin is satisfied only by an exact match, and
-- an unset pin (or "latest") is satisfied by any installed version.
function M.is_pinned(version)
  if version == nil then
    return false
  end
  local pin = strings.trim_space(tostring(version))
  return pin ~= "" and pin ~= "latest" and pin ~= "*"
end

function M.pin_satisfied(requested, observed)
  if not M.is_pinned(requested) then
    return true
  end
  return observed ~= nil and strings.trim_space(tostring(requested)) == observed
end

-- `code --install-extension` is a no-op on an already-installed extension
-- unless --force is passed, and --force also keeps it non-interactive, so it
-- is always on: install, re-pin and upgrade are then the same idempotent call.
function M.install(pkg, opts)
  opts = opts or {}
  local target = pkg.name
  if M.is_pinned(pkg.version) then
    target = target .. "@" .. strings.trim_space(tostring(pkg.version))
  end
  local args = "--install-extension " .. M.quote(target) .. " --force"
  if opts.dry_run then
    print("would run: " .. M.base_command() .. " " .. args)
    return
  end
  exec(args)
end

function M.uninstall(pkg, opts)
  opts = opts or {}
  local args = "--uninstall-extension " .. M.quote(pkg.name) .. " --force"
  if opts.dry_run then
    print("would run: " .. M.base_command() .. " " .. args)
    return
  end
  exec(args)
end

return M
