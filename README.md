# mise-plugin-vscode

A [mise package plugin](https://mise.jdx.dev/package-plugin-development.html)
that manages VS Code extensions from `[bootstrap.packages]`, the same way mise
manages Homebrew formulae and casks.

> **Note:** this is a 100% vibecoded project — every line of it was written by
> an AI agent. It is also in active daily use: it manages the extensions in my
> own [dotfiles](https://github.com/syhol/dotfiles), so it gets fixed when it
> breaks. Read it before you trust it with yours.

```toml
[settings]
experimental = true # [bootstrap.*] is experimental

[bootstrap.packages]
"vscode:biomejs.biome" = "latest"
"vscode:catppuccin.catppuccin-vsc" = "3.19.0" # pinned
```

```sh
mise bootstrap packages status   # what's installed / missing
mise bootstrap packages apply    # install the missing ones
mise bootstrap packages prune -m vscode  # remove the undeclared ones
```

## Install

```sh
mise plugins install vscode https://github.com/syhol/mise-plugin-vscode
```

For local development, link a checkout instead — edits take effect with no
reinstall:

```sh
mise plugins link vscode ~/Code/syhol/mise-plugin-vscode
```

Everything runs through the VS Code CLI (`code`), which the plugin declares in
`requires`; mise will not install it for you. If `code` is not on `PATH`, run
*Shell Command: Install 'code' command in PATH* from VS Code's command palette.

## Configuration

Package names are marketplace extension ids (`publisher.name`), and casing does
not matter — `BiomeJS.Biome` and `biomejs.biome` are the same extension.

| Version | Meaning |
| --- | --- |
| `"latest"` (or `"*"`) | any installed version satisfies it |
| `"3.19.0"` | that exact build; anything else is reinstalled onto the pin, including a downgrade |

Two environment variables change what gets driven:

- `MISE_VSCODE_CLI` — a different CLI, to manage a fork's extensions instead:
  `cursor`, `code-insiders`, `codium`, `windsurf`, …
- `MISE_VSCODE_EXTENSIONS_DIR` — an alternate extensions directory, i.e. a
  disposable profile to test against rather than your real one.

## Behaviour worth knowing

- **Installs are idempotent.** Every install goes out as
  `code --install-extension <id>[@<version>] --force`. Without `--force` the CLI
  refuses to touch an already-installed extension, and `--force` also keeps it
  non-interactive, which the plugin contract requires.
- **A batch is one `code` invocation**, not one per extension — 50 extensions
  start the CLI once.
- **One bad extension doesn't sink the batch.** The CLI stops at its first
  failure and won't say which extension failed, so a failed batch is replayed
  one extension at a time: the good ones still install, and the error names
  exactly what failed and why.
- **Marketplace blips are retried.** A 503/timeout/reset is retried up to three
  times, a few seconds apart, before it counts as a failure.
- **Unpinned extensions are never upgraded by mise.** A package plugin can only
  report `installed` or `missing`, so mise sees an unpinned extension as
  satisfied and `mise bootstrap packages upgrade` leaves it alone. VS Code
  auto-updates extensions itself; pin a version if you want mise to decide.
- **Extensions you installed by hand are safe from `prune`.** mise only claims
  ownership of what it installed, `prune` defaults to Homebrew (`-m
  vscode` scopes it here), and it keeps anything still declared in
  any trusted config it tracks — which includes configs in other projects.
- **A removed extension folder can linger.** The CLI drops the extension from
  its registry immediately and deletes the directory on the next VS Code start.

## Migrating a list of extensions

To turn a plain list of ids (one per line, `#` comments) into config entries:

```sh
grep -v '^\s*#' extensions.txt | grep -v '^\s*$' \
  | sed 's/.*/"vscode:&" = "latest"/'
```

To capture what you have installed right now:

```sh
code --list-extensions | sed 's/.*/"vscode:&" = "latest"/'
```

## Layout

```
metadata.lua                  plugin name, version, description
mise.plugin.toml              [package-manager]: requires, version pins, os
hooks/package_installed.lua   PackageInstalled — status for a batch, read-only
hooks/package_install.lua     PackageInstall   — install the batch mise picked
hooks/package_upgrade.lua     PackageUpgrade   — same, for upgrades
hooks/package_uninstall.lua   PackageUninstall — prune, scoped to this manager
lib/vscode.lua                CLI helpers: quoting, listing, pin comparison
test/test.sh                  end-to-end test
```

## Tests

`test/test.sh` runs the whole lifecycle — missing → dry run → install → pin →
prune, plus partial-failure and retry handling — against a temporary extensions
directory, mise config and state dir, so it never touches your real VS Code
profile or your real packages. It needs `code`, `mise`, and network access.

```sh
./test/test.sh                        # defaults to mikestead.dotenv
./test/test.sh <extension-id> <older-version>
```
