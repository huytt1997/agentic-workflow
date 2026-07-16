# shellcheck shell=bash
# install-common.sh — shared library for install.sh / update.sh / uninstall.sh.
# Sourced, never executed. Exposes ic_* helpers. Target layout: see
# .agentic/plans/00-overview.md D-A/D-D.
IC_PACKAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IC_VERSION="0.1.0"

# ic_resolve_target <dir> -> effective Claude config dir.
# A dir containing a .git entry (dir or file) is a project -> <dir>/.claude; else <dir>.
ic_resolve_target() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  if [ -e "$d/.git" ]; then printf '%s\n' "$d/.claude"; else printf '%s\n' "$d"; fi
}

# ic_pkg_fullname <name> -> canonical package dir name, or exit 1.
ic_pkg_fullname() {
  case "${1:-}" in
    core|agentic-core)         printf 'agentic-core\n' ;;
    engineer|agentic-engineer) printf 'agentic-engineer\n' ;;
    init|agentic-init)         printf 'agentic-init\n' ;;
    ba|agentic-ba)             printf 'agentic-ba\n' ;;
    pm|agentic-pm)             printf 'agentic-pm\n' ;;
    *) return 1 ;;
  esac
}

# ic_place <src> <dest>
# Places src at dest by recursive copy. Overwrites any existing dest cleanly --
# including a symlink left by a pre-D-13-amendment install, which is why the
# rm -rf is not merely defensive: it is the migration path from symlink installs.
# Creates parent dirs as needed. (D-13 as amended: installs are copy-only.)
ic_place() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -R "$src" "$dest"
}

# Internal: create a discovery symlink from <cfg>/<kind>/<lname> into the
# placed package tree, overwriting any existing link cleanly (idempotent).
# Prints the link's path relative to <cfg> (for manifest recording).
_ic_link_discovery() {  # <cfg> <kind> <target-in-pkg> <link-name>
  local cfg="$1" kind="$2" tgt="$3" lname="$4"
  mkdir -p "$cfg/$kind"
  ln -sfn "$tgt" "$cfg/$kind/$lname"
  printf '%s/%s\n' "$kind" "$lname"
}

# ic_manifest_path <cfg> <name-any> -> path to the package's install manifest.
# See .agentic/plans/00-overview.md D-D for the schema.
ic_manifest_path() {
  local cfg="$1" name
  name="$(ic_pkg_fullname "$2")" || return 1
  printf '%s/agentic/.agentic-installed/%s.json\n' "$cfg" "$name"
}

# ic_manifest_installed <cfg> <name-any> -> exit 0 if that package's manifest
# exists at <cfg>, else 1.
ic_manifest_installed() {
  local mf
  mf="$(ic_manifest_path "$1" "$2")" || return 1
  [ -f "$mf" ]
}

# ic_install_package <name-any> <cfg>
# Places packages/<name> at <cfg>/agentic/<name> (via ic_place), then fans out
# its discovery components (commands/*.md, agents/*.md, skills/<name>/) as
# symlinks into <cfg>/commands, <cfg>/agents, <cfg>/skills pointing back into
# the placed tree, and writes/overwrites the install manifest (schema
# agentic-install/1; hooks_added starts empty — plan 03 fills it in).
# Returns 1 on unknown name.
ic_install_package() {
  local name cfg src pkg_dest links=()
  name="$(ic_pkg_fullname "$1")" || return 1
  cfg="$2"
  src="$IC_PACKAGES_DIR/$name"
  pkg_dest="$cfg/agentic/$name"
  ic_place "$src" "$pkg_dest"

  # discovery: commands/*.md and agents/*.md -> flat links; skills/<name>/ -> dir links
  local f base
  if [ -d "$pkg_dest/commands" ]; then
    for f in "$pkg_dest"/commands/*.md; do [ -e "$f" ] || continue
      base="$(basename "$f")"; links+=("$(_ic_link_discovery "$cfg" commands "$f" "$base")"); done
  fi
  if [ -d "$pkg_dest/agents" ]; then
    for f in "$pkg_dest"/agents/*.md; do [ -e "$f" ] || continue
      base="$(basename "$f")"; links+=("$(_ic_link_discovery "$cfg" agents "$f" "$base")"); done
  fi
  if [ -d "$pkg_dest/skills" ]; then
    for f in "$pkg_dest"/skills/*/; do [ -d "$f" ] || continue
      base="$(basename "$f")"; links+=("$(_ic_link_discovery "$cfg" skills "${f%/}" "$base")"); done
  fi

  # manifest: write/overwrite a single JSON object recording what we placed.
  local mf; mf="$(ic_manifest_path "$cfg" "$name")"
  mkdir -p "$(dirname "$mf")"
  local links_json
  links_json="$(printf '%s\n' "${links[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')"
  jq -n --arg s "agentic-install/1" --arg p "$name" --arg m "copy" \
        --arg v "$IC_VERSION" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson links "$links_json" \
        '{schema:$s, package:$p, version:$v, mode:$m, installed_at:$t,
          links:$links, hooks_added:[]}' > "$mf"
}

# ic_hooks_merge <cfg> — register agentic-core hooks into <cfg>/settings.json (idempotent).
ic_hooks_merge() {
  local cfg="$1" core hj s resolved add tmp mf
  core="$cfg/agentic/agentic-core"
  hj="$core/hooks/hooks.json"
  mf="$(ic_manifest_path "$cfg" agentic-core)" || return 1
  [ -f "$hj" ] && [ -f "$mf" ] || return 1
  s="$cfg/settings.json"
  [ -f "$s" ] || echo '{}' > "$s"

  # resolve the plugin-root token to the real install path. Use jq's gsub with
  # the replacement passed via --arg so $core is substituted as a literal
  # string, not a sed pattern -- a target path containing sed metacharacters
  # (&, \, or the # delimiter) would otherwise silently corrupt the resolved
  # hook command (I-2/I-3).
  resolved="$(jq --arg root "$core" \
    'walk(if type == "string" then gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $root) else . end)' \
    "$hj")"

  # deep-merge under .hooks, replacing any prior group that carries one of our commands
  tmp="$(mktemp)"
  jq --argjson add "$resolved" '
    .hooks = (.hooks // {})
    | reduce ($add | to_entries[]) as $e (. ;
        ($e.value | map(.hooks[].command)) as $ourcmds
        | .hooks[$e.key] =
            (((.hooks[$e.key] // [])
               | map(select(([.hooks[].command] | any(. as $c | ($ourcmds | index($c)) != null)) | not)))
             + $e.value)
      )
  ' "$s" > "$tmp" && mv "$tmp" "$s"

  # record what we added into the manifest
  add="$(printf '%s' "$resolved" \
        | jq '[to_entries[] | .key as $e | .value[] | .hooks[] | {event:$e, command:.command}]')"
  tmp="$(mktemp)"
  jq --argjson h "$add" '.hooks_added = $h' "$mf" > "$tmp" && mv "$tmp" "$mf"
}

# ic_parse_common <args...> -> IC_TARGET / IC_PACKAGE
# --mode is retired (D-13 as amended: copy-only). `--mode copy` is accepted as a
# no-op for compatibility; `--mode symlink` gets a specific error rather than a
# generic unknown-arg, because it used to be the documented dev-loop flag.
ic_parse_common() {
  IC_TARGET=""; IC_PACKAGE=""; IC_MODE="copy"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)     IC_TARGET="${2:-}"; shift 2 ;;
      --target=*)   IC_TARGET="${1#*=}"; shift ;;
      --package)    IC_PACKAGE="${2:-}"; shift 2 ;;
      --package=*)  IC_PACKAGE="${1#*=}"; shift ;;
      --mode)       _ic_check_mode "${2:-}" || return 2; shift 2 ;;
      --mode=*)     _ic_check_mode "${1#*=}" || return 2; shift ;;
      *) echo "unknown argument: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$IC_TARGET" ] || { echo "--target <dir> is required" >&2; return 2; }
}

_ic_check_mode() {
  case "${1:-}" in
    copy) return 0 ;;
    symlink) echo "symlink mode removed; installs are copy-only" >&2; return 1 ;;
    *) echo "unknown --mode: ${1:-} (installs are copy-only)" >&2; return 1 ;;
  esac
}

# ic_expand_selection <token> -> ordered canonical package names (one per line)
ic_expand_selection() {
  case "${1:-}" in
    all) printf 'agentic-core\nagentic-engineer\nagentic-init\nagentic-ba\nagentic-pm\n' ;;
    *)   ic_pkg_fullname "$1" ;;
  esac
}

# ic_pkg_deps <name-any> -> direct dependencies, one canonical name per line
# (empty for agentic-core). Returns 1 on unknown name. This is the single
# declarative dependency map -- install/update both resolve through it.
ic_pkg_deps() {
  local name
  name="$(ic_pkg_fullname "${1:-}")" || return 1
  case "$name" in
    agentic-core)       : ;;
    agentic-engineer)   printf 'agentic-core\n' ;;
    agentic-init)       printf 'agentic-core\n' ;;
    agentic-ba)         printf 'agentic-core\n' ;;
    agentic-pm)         printf 'agentic-core\nagentic-engineer\n' ;;
  esac
}

# ic_with_deps <names...> -> the transitive closure of the selection in
# dependency order (every package appears after everything it depends on),
# deduped. Depth-first post-order: emit a package's deps before the package.
ic_with_deps() {
  local out="" name
  _icwd_visit() {
    local n d
    n="$(ic_pkg_fullname "$1")" || return 1
    case "
$out" in *"
$n"*) return 0 ;; esac          # already emitted
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      _icwd_visit "$d" || return 1
    done <<< "$(ic_pkg_deps "$n")"
    out="$out
$n"
  }
  for name in "$@"; do _icwd_visit "$name" || return 1; done
  printf '%s\n' "$out" | sed '/^$/d'
}

# ic_menu -> read a 1-6 choice from stdin, echo the selection token
ic_menu() {
  {
    echo "Select a package:"
    echo "  1) agentic-core"
    echo "  2) agentic-engineer"
    echo "  3) agentic-init"
    echo "  4) agentic-ba"
    echo "  5) agentic-pm"
    echo "  6) all"
    printf 'Choice [1-6]: '
  } >&2
  local n; read -r n
  case "$n" in
    1) echo core ;; 2) echo engineer ;; 3) echo init ;; 4) echo ba ;; 5) echo pm ;; 6) echo all ;;
    *) echo "invalid choice: $n" >&2; return 1 ;;
  esac
}

# ic_hooks_unmerge <cfg> — remove exactly the hook entries this installer added.
ic_hooks_unmerge() {
  local cfg="$1" s mf removed tmp
  s="$cfg/settings.json"
  mf="$(ic_manifest_path "$cfg" agentic-core)" || return 0
  [ -f "$s" ] && [ -f "$mf" ] || return 0
  removed="$(jq -c '.hooks_added // []' "$mf")"
  tmp="$(mktemp)"
  jq --argjson rm "$removed" '
    .hooks = (.hooks // {})
    | reduce ($rm[]) as $r (. ;
        .hooks[$r.event] =
          ((.hooks[$r.event] // [])
            | map(select(([.hooks[].command] | any(. == $r.command)) | not)))
      )
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$s" > "$tmp" && mv "$tmp" "$s"
}
