# cdpkg
zsh script to easily switch between projects in a monorepo

## Installation

Copy `cdpkg.zsh` to `~/.zsh/cdpkg.zsh`.

Update your `~/.zshrc`:

```bash
autoload -Uz compinit
compinit

source ~/.zsh/cdpkg.zsh
zcompile -R ~/.zsh/cdpkg.zwc ~/.zsh/cdpkg.zsh 2>/dev/null || true
```

Optionally, add contents of `prompt.zsh` to `~/.zshrc` to modify the prompt when a repo is detected.

## Usage

1. Calling `cdpkg` without parameters navigates to the repo root.
2. Calling `cdpkg <package_name>` navigates to that package. For example, `cdpkg docs` -> `<repo_root>/apps/docs`.
3. Calling `cdpkg --rebuild` rebuilds the index file. You typically don't need to call it manually.
4. Calling `cdpkg <package_name> <subdirectory>` navigates to nested folders inside the package. For example, `cdpkg ui src/components/button` -> `<repo_root>/packages/ui/src/components/button`.
5. Tab completion is available for both package names and subdirectories.

## Ignoring index files

Run this in your terminal to add generated `.pkg_index` and `.pkg_index.sha` to the global gitignore:

```bash
git config --global core.excludesfile "$HOME/.gitignore_global"
grep -qxF ".pkg_index" "$HOME/.gitignore_global" || echo ".pkg_index" >> "$HOME/.gitignore_global"
grep -qxF ".pkg_index.sha" "$HOME/.gitignore_global" || echo ".pkg_index.sha" >> "$HOME/.gitignore_global"
```

> [!WARNING]
> The code is 100% generated with AI. Only shallow manual testing was performed.
