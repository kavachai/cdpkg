# ===== Monorepo navigation: single public command `cdpkg` with tab completion ====

typeset -g MONO_CANONICAL_SCOPE='@repo'   # auto-scope unscoped package names
typeset -g REPO_ROOT=""                    # absolute, normalized repo root

# --- Detect repo root (via Git), normalize path --------------------------------
_detect_repo_root() {
  local r
  r=$(command git rev-parse --show-toplevel 2>/dev/null || print -r -- "")
  [[ -n "$r" ]] && REPO_ROOT=${r:A} || REPO_ROOT=""
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _detect_repo_root

# --- Canonicalize package name -------------------------------------------------
_mono_canon_name() {
  local n="$1"
  if [[ "$n" == *@*/* || "$n" == */* ]]; then
    print -r -- "$n"
  else
    print -r -- "${MONO_CANONICAL_SCOPE}/${n}"
  fi
}

# --- Helpers: package list (fast), fingerprinting incl. mtime ------------------

# Defaults; can be overridden in ~/.zshrc before functions load
: ${MONO_EXCLUDE_DIRS:=".git node_modules .turbo .next dist build coverage out"}

# Use `fd` if present; otherwise fall back to `find`. Output: relative paths.
_mono_pkg_list() {
  local -a ex; ex=(${=MONO_EXCLUDE_DIRS})
  if command -v fd >/dev/null 2>&1; then
    local args=()
    for d in $ex; do args+=(-E "$d"); done
    fd -t f -H -a --glob "package.json" "$REPO_ROOT" $args \
      | sed "s|^$REPO_ROOT/||" | LC_ALL=C sort
  else
    # build a (-name a -o -name b ...) expr
    local prunes=()
    for d in $ex; do prunes+=(-name "$d" -o); done
    prunes=(${prunes[1,-2]})  # drop trailing -o
    command find "$REPO_ROOT" \( $prunes \) -prune -o -name package.json -print \
      | sed "s|^$REPO_ROOT/||" | LC_ALL=C sort
  fi
}

# Return "relative_path<TAB>mtime" for all package.json (sorted)
_mono_pkg_list_with_mtime() {
  local rel mt
  while IFS= read -r rel; do
    if stat -f %m "$REPO_ROOT/$rel" >/dev/null 2>&1; then
      mt=$(stat -f %m "$REPO_ROOT/$rel")
    else
      mt=$(stat -c %Y "$REPO_ROOT/$rel")
    fi
    print -r -- "$rel"$'\t'"$mt"
  done < <(_mono_pkg_list)
}

# Portable hasher
_mono_hash() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q -
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# --- Lock/config files whose mtime should trigger reindex if they change -----
_mono_lockfiles() {
  print -r -- \
    "pnpm-lock.yaml" \
    "yarn.lock" \
    "package-lock.json" \
    ".pnp.cjs" \
    ".pnp.data.json" \
    "turbo.json" \
    "nx.json" \
    "package.json"
}

# Return "file<TAB>mtime" for existing files at repo root
_mono_lockfiles_with_mtime() {
  local f mt
  for f in $(_mono_lockfiles); do
    if [[ -f "$REPO_ROOT/$f" ]]; then
      if stat -f %m "$REPO_ROOT/$f" >/dev/null 2>&1; then
        mt=$(stat -f %m "$REPO_ROOT/$f")
      else
        mt=$(stat -c %Y "$REPO_ROOT/$f")
      fi
      print -r -- "$f"$'\t'"$mt"
    fi
  done | LC_ALL=C sort
}

_mono_current_fprint() {
  {
    _mono_pkg_list_with_mtime
    _mono_lockfiles_with_mtime
  } | _mono_hash
}

# Canonicalize to REPO_ROOT-relative; return 1 if it's exactly the repo root
_mono_rel() {
  local abs="${1:A}"             # canonical absolute path
  case "$abs" in
    "$REPO_ROOT") return 1 ;;    # skip the repo root entry
    "$REPO_ROOT"/*) print -r -- "${abs#$REPO_ROOT/}" ;;
    *) print -r -- "$abs" ;;     # outside the repo (shouldn't happen, but harmless)
  esac
}

# Prefer pnpm as source of truth; emit TSV "name<TAB>repo-relative path".
# Return 0 if we emitted at least one line, else 1 so caller can fallback.
_mono_cli_packages() {
  [[ -n "$REPO_ROOT" ]] || _detect_repo_root
  [[ -n "$REPO_ROOT" ]] || return 1

  # Require pnpm + jq; otherwise bail to fallback
  command -v pnpm >/dev/null 2>&1 || return 1
  command -v jq   >/dev/null 2>&1 || return 1

  # Ask pnpm once; handle both array/object outputs across versions
  local out
  out=$(cd "$REPO_ROOT" && pnpm -w list -r --depth -1 --json 2>/dev/null) || out=""

  [[ -n "$out" ]] || return 1

  # Parse strictly: produce "name<TAB>path"
  # - path may be absolute (.path) or relative (.location)
  # - filter empty fields in zsh loop
  local ok=0 n p rel abs
  while IFS=$'\t' read -r n p; do
    [[ -z "$n" || -z "$p" ]] && continue
    # canonicalize to absolute then strip REPO_ROOT/
    abs="${p:A}"
    [[ "$abs" == "$REPO_ROOT" ]] && continue        # skip root itself
    [[ "$abs" == "$REPO_ROOT"/* ]] || continue      # must live under repo
    rel="${abs#$REPO_ROOT/}"
    n=$(_mono_canon_name "$n")
    print -r -- "$n"$'\t'"$rel"
    ok=1
  done < <(
    jq -r '
      (.. | objects | select(has("name") and (has("path") or has("location")))) as $x
      | [$x.name, ($x.path // $x.location)]
      | @tsv
    ' <<< "$out"
  )

  (( ok )) || return 1
  return 0
}

# --- Build <name> <relative-path> index at $REPO_ROOT/.pkg_index ---------------
# - Skips heavy dirs
# - Skips repo-root package.json
# - Writes fingerprint of path+mtime set to .pkg_index.sha
monorepo_index() {
  [[ -n "$REPO_ROOT" ]] || _detect_repo_root
  [[ -n "$REPO_ROOT" ]] || { print -u2 "Not inside a Git repository."; return 1; }

  local index="$REPO_ROOT/.pkg_index"
  local sha_file="$REPO_ROOT/.pkg_index.sha"
  : > "$index"

  # --- Try workspace CLIs first ---
  if _mono_cli_packages > "$index" 2>/dev/null; then
    : # success, index already written
  else
    # --- Fallback: scan filesystem for package.json and read names ---
    local files rel dir name canon line
    typeset -A seen
    files=$(_mono_pkg_list) || return 1

    if command -v jq >/dev/null 2>&1; then
      while IFS= read -r rel; do
        [[ -z "$rel" || "$rel" == "package.json" ]] && continue
        dir="${REPO_ROOT}/${rel%/package.json}"
        name=$(jq -r 'select(.name!=null) | .name' "$REPO_ROOT/$rel" 2>/dev/null) || continue
        [[ -z "$name" || "$name" == "null" ]] && continue
        canon=$(_mono_canon_name "$name")
        line="$canon"$'\t'"${dir#$REPO_ROOT/}"
        [[ -n "${seen[$line]}" ]] && continue
        seen[$line]=1
        print -r -- "$line" >> "$index"
      done <<< "$files"
    else
      local first_name_line
      while IFS= read -r rel; do
        [[ -z "$rel" || "$rel" == "package.json" ]] && continue
        dir="${REPO_ROOT}/${rel%/package.json}"
        first_name_line=$(grep -m1 '"name"[[:space:]]*:' "$REPO_ROOT/$rel" 2>/dev/null) || continue
        name=${${first_name_line#*\"name\"*:}##*\"}
        name=${name%%\"*}
        [[ -z "$name" ]] && continue
        canon=$(_mono_canon_name "$name")
        line="$canon"$'\t'"${dir#$REPO_ROOT/}"
        [[ -n "${seen[$line]}" ]] && continue
        seen[$line]=1
        print -r -- "$line" >> "$index"
      done <<< "$files"
    fi
  fi

  # Fingerprint includes package.json paths+mtimes and lock/config mtimes
  print -r -- "$(_mono_current_fprint)" > "$sha_file"
}

# --- Ensure index exists and refresh if stale ----------------------------------
_mono_ensure_index() {
  [[ -n "$REPO_ROOT" ]] || _detect_repo_root
  [[ -n "$REPO_ROOT" ]] || { print -u2 "Not inside a Git repository."; return 1; }

  local index="$REPO_ROOT/.pkg_index"
  local sha_file="$REPO_ROOT/.pkg_index.sha"
  [[ -f "$index" && -f "$sha_file" ]] || { monorepo_index; return $?; }

  local current_fprint expected_fprint
  current_fprint=$(_mono_current_fprint)
  expected_fprint=$(cat "$sha_file" 2>/dev/null)
  [[ "$current_fprint" == "$expected_fprint" ]] || monorepo_index
}

# --- Public command: cdpkg -----------------------------------------------------
# cdpkg                         -> jump to repo root
# cdpkg <name> [sub/path ...]   -> jump to package (suffix allowed if unique), optional subpath
# cdpkg --rebuild               -> rebuild index
cdpkg() {
  if [[ "$1" == "--rebuild" ]]; then _mono_ensure_index || return 1; monorepo_index; return $?; fi
  _mono_ensure_index || return 1

  # No args -> root
  if [[ -z "$1" || "$1" == "-h" || "$1" == "--help" ]]; then
    if [[ -z "$1" ]]; then
      builtin cd -- "$REPO_ROOT"; return $?
    fi
    print -r -- "Usage: cdpkg [name [sub/path ...]] | --rebuild"
    print -r -- "  (no args -> repo root; suffix match allowed when unique)"
    return 0
  fi

  local key="$1" index="$REPO_ROOT/.pkg_index"
  local line name path match_path=""
  local -a suffix_hits=()

  # Exact match on canonical name
  while IFS= read -r line; do
    name=${line%%$'\t'*}; path=${line#*$'\t'}
    if [[ "$name" == "$key" ]]; then match_path="$path"; break; fi
  done < "$index"

  # Unique suffix match if not found (e.g. "web" for "@repo/web")
  if [[ -z "$match_path" && "$key" != *@*/* ]]; then
    local suffix
    while IFS= read -r line; do
      name=${line%%$'\t'*}; path=${line#*$'\t'}
      suffix="${name##*/}"
      [[ "$suffix" == "$key" ]] && suffix_hits+=("$path")
    done < "$index"
    if (( ${#suffix_hits[@]} == 1 )); then
      match_path="${suffix_hits[1]}"
    elif (( ${#suffix_hits[@]} > 1 )); then
      print -u2 -- "Ambiguous: '$key' matches multiple packages:"
      # list canonical names for each path
      while IFS= read -r line; do
        name=${line%%$'\t'*}; path=${line#*$'\t'}
        for p in "${suffix_hits[@]}"; do [[ "$p" == "$path" ]] && print -u2 "  - $name ($path)"; done
      done < "$index"
      return 1
    fi
  fi

  [[ -n "$match_path" ]] || { print -u2 -- "Package not found: $key"; return 1; }

  # Append optional subpath segments, preserving spaces and slashes
  shift   # drop <name>
  if (( $# > 0 )); then
    # join remaining args with "/" using zsh join flag
    local extra="${(j:/:)@}"
    match_path="$match_path/$extra"
  fi

  builtin cd -- "$REPO_ROOT/$match_path"
}

# --- Completion for `cdpkg` (shows "name  (path)" per row; inserts just the name) ---
_cdpkg() {
  _mono_ensure_index || return 1
  local index="$REPO_ROOT/.pkg_index"

  # If we're completing the 2nd+ arg, complete dirs inside the resolved package
  if (( CURRENT > 2 )); then
    local key="${words[2]}" line name path match=""
    while IFS= read -r line; do
      name=${line%%$'\t'*}; path=${line#*$'\t'}
      if [[ "$name" == "$key" || "${name##*/}" == "$key" ]]; then match="$path"; break; fi
    done < "$index"
    [[ -z "$match" ]] && return 1
    # complete directories under $REPO_ROOT/$match
    _files -W "$REPO_ROOT/$match" -/ && return
  fi

  # Otherwise (first arg) – suggest packages (unscoped if unique)
  local -A count; local line name suffix
  while IFS= read -r line; do
    name=${line%%$'\t'*}; suffix="${name##*/}"; (( count[$suffix]++ ))
  done < "$index"

  local -a disp insert; local path
  while IFS= read -r line; do
    name=${line%%$'\t'*}; path=${line#*$'\t'}; suffix="${name##*/}"
    if (( count[$suffix] == 1 )); then
      disp+="$suffix  ($path)"; insert+="$suffix"
    else
      disp+="$name  ($path)";  insert+="$name"
    fi
  done < "$index"

  compadd -d disp -- $insert
}

compdef _cdpkg cdpkg
