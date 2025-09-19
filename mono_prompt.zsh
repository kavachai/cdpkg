relative_path_from_root() {
  local root prefix
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  prefix=$(git rev-parse --show-prefix 2>/dev/null)

  if [[ -n "$root" ]]; then
    if [[ -z "$prefix" ]]; then
      # we're exactly at the repo root
      echo -n "root"
    else
      # remove trailing slash if present
      echo -n "${prefix%/}"
    fi
  else
    # fallback if not in git repo
    echo -n "$PWD"
  fi
}

precmd() {
  PS1="%n@%m:$(relative_path_from_root) %# "
}
