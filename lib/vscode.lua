-- Shared helpers for the vscode package plugin.
--
-- Everything goes through the VS Code CLI (`code`), which is the only
-- supported way to query/install/remove extensions. mise puts `lib/?.lua` on
-- package.path, so hooks pick this up with `require("vscode")`.

local cmd = require("cmd")
local strings = require("strings")

local M = {}

-- Marketplace hiccups (503s, resets, timeouts) are common enough that a whole
-- bootstrap should not fall over for one of them.
local MAX_ATTEMPTS = 3
local RETRY_DELAY_SECONDS = 3
local TRANSIENT_MARKERS = {
  "Server returned 429",
  "Server returned 500",
  "Server returned 502",
  "Server returned 503",
  "Server returned 504",
  "ECONNRESET",
  "ECONNREFUSED",
  "ETIMEDOUT",
  "EAI_AGAIN",
  "socket hang up",
  "network",
  "timed out",
  "Failed to fetch",
}

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

-- A raw failure carries three kinds of noise around the one line that matters:
-- Lua's own traceback, the cmd.exec status prefix, and the node deprecation
-- warnings the CLI prints to stderr. Strip all three.
local function tidy(detail)
  local kept = {}
  for _, line in ipairs(strings.split(tostring(detail), "\n")) do
    local trimmed = strings.trim_space(line)
    if strings.has_prefix(trimmed, "stack traceback:") then
      break
    end
    trimmed = trimmed:gsub("^Command failed with status exit status: %d+:%s*", "")
    trimmed = strings.trim_space(trimmed)
    if
      trimmed ~= ""
      and not strings.contains(trimmed, "DeprecationWarning")
      and not strings.contains(trimmed, "trace-deprecation")
      and not strings.has_prefix(trimmed, "(node:")
      and not strings.has_prefix(trimmed, "(Use `")
      and not strings.has_prefix(trimmed, "Installing extensions")
    then
      table.insert(kept, trimmed)
    end
  end
  if #kept == 0 then
    return strings.trim_space(tostring(detail))
  end
  return strings.join(kept, "; ")
end

local function is_transient(detail)
  for _, marker in ipairs(TRANSIENT_MARKERS) do
    if strings.contains(detail, marker) then
      return true
    end
  end
  return false
end

-- Run a CLI invocation; returns ok, output-or-tidied-error.
local function try_exec(args)
  local ok, output = pcall(cmd.exec, M.base_command() .. " " .. args)
  if ok then
    return true, output or ""
  end
  local detail = tostring(output)
  -- 127 from `sh` means the CLI itself is missing. Match that, not the CLI's
  -- own "Extension '…' not found." message for a bad extension id.
  if strings.contains(detail, "exit status: 127") or strings.contains(detail, "command not found") then
    return false,
      "VS Code CLI '"
        .. M.cli()
        .. "' not found on PATH. Install the `code` command (VS Code: Shell "
        .. "Command: Install 'code' command in PATH) or set MISE_VSCODE_CLI to "
        .. "another editor's CLI."
  end
  return false, tidy(detail)
end

-- Same, but retrying while the failure looks like a marketplace/network blip.
local function try_exec_with_retries(args)
  local ok, detail
  for attempt = 1, MAX_ATTEMPTS do
    ok, detail = try_exec(args)
    if ok or not is_transient(detail) then
      return ok, detail
    end
    if attempt < MAX_ATTEMPTS then
      print(
        "transient failure (attempt "
          .. attempt
          .. "/"
          .. MAX_ATTEMPTS
          .. "), retrying in "
          .. RETRY_DELAY_SECONDS
          .. "s: "
          .. detail
      )
      pcall(cmd.exec, "sleep " .. RETRY_DELAY_SECONDS)
    end
  end
  return ok, detail
end

local function exec(args)
  local ok, output = try_exec(args)
  if not ok then
    error(output)
  end
  return output
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

-- What `--install-extension` is handed: the id, or id@version when pinned.
function M.target(pkg)
  if M.is_pinned(pkg.version) then
    return pkg.name .. "@" .. strings.trim_space(tostring(pkg.version))
  end
  return pkg.name
end

local function install_args(packages)
  local args = {}
  for _, pkg in ipairs(packages) do
    table.insert(args, "--install-extension " .. M.quote(M.target(pkg)))
  end
  -- `--install-extension` is a no-op on an already-installed extension unless
  -- --force is passed, and --force also keeps it non-interactive, so it is
  -- always on: install, re-pin and upgrade are then the same idempotent call.
  table.insert(args, "--force")
  return strings.join(args, " ")
end

local function uninstall_args(packages)
  local args = {}
  for _, pkg in ipairs(packages) do
    table.insert(args, "--uninstall-extension " .. M.quote(pkg.name))
  end
  table.insert(args, "--force")
  return strings.join(args, " ")
end

-- Run one action over a whole batch.
--
-- The CLI takes repeated flags, so a batch is one process start instead of one
-- per extension. It stops at the first failure though, and never says which
-- extension failed, so a failed batch is replayed one extension at a time:
-- that isolates the bad one, lets every other extension through, and gives
-- each its own retries. Whatever still fails is reported together at the end
-- instead of aborting the run at the first bad extension.
local function run_batch(packages, opts, build_args, verb)
  opts = opts or {}
  if #packages == 0 then
    return
  end

  if opts.dry_run then
    print("would run: " .. M.base_command() .. " " .. build_args(packages))
    return
  end

  if #packages > 1 then
    local ok = try_exec_with_retries(build_args(packages))
    if ok then
      return
    end
    print("batch " .. verb .. " failed; falling back to one extension at a time")
  end

  local failures = {}
  for _, pkg in ipairs(packages) do
    local ok, detail = try_exec_with_retries(build_args({ pkg }))
    if not ok then
      table.insert(failures, M.target(pkg) .. " (" .. detail .. ")")
      print("failed to " .. verb .. " " .. M.target(pkg) .. ": " .. detail)
    end
  end

  if #failures > 0 then
    error(
      "failed to "
        .. verb
        .. " "
        .. #failures
        .. " of "
        .. #packages
        .. " extension(s): "
        .. strings.join(failures, ", ")
    )
  end
end

function M.install(packages, opts)
  run_batch(packages, opts, install_args, "install")
end

function M.uninstall(packages, opts)
  run_batch(packages, opts, uninstall_args, "uninstall")
end

return M
