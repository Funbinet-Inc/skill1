#!/usr/bin/env bash
# funbinet-skills installer
# Installs offensive security skills into the skills directories of installed
# AI coding agents (Claude Code, OpenCode, Pi, Antigravity, Codex, GitHub
# Copilot, Gemini CLI) using each platform's official skills location.
#
# Usage:
#   ./install.sh                                  # interactive: pick detected platforms
#   ./install.sh --all                            # install to every detected platform
#   ./install.sh --platform claude,opencode       # specific platforms
#   ./install.sh --list                           # show supported platforms + detection status
#   ./install.sh --category web                   # one category only
#   ./install.sh --scope personal|project         # personal (global) or current-project install
#   ./install.sh --target DIR                     # explicit target directory (overrides platform detection)
#   ./install.sh --dry-run                        # show what would be installed
#   ./install.sh -y                               # non-interactive: accept defaults / detected platforms
#
# Platforms are detected by the presence of their binary or config directory;
# the installer never creates folders for platforms that are not installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$SCRIPT_DIR/Skills"

# Platform registry.
# Fields: id|human label|binaries (space-separated, optional)|config dirs (colon-separated)|personal skills dir|project skills dir
# Skills-dir conventions follow each platform's official documentation and the
# Agent Skills standard (https://agentskills.io).
PLATFORMS=(
  "claude|Claude Code|claude|$HOME/.claude|$HOME/.claude/skills|.claude/skills"
  "opencode|OpenCode|opencode|$HOME/.config/opencode|$HOME/.config/opencode/skills|.opencode/skills"
  "pi|Pi coding agent|pi|$HOME/.pi:$HOME/.pi/agent|$HOME/.pi/agent/skills|.pi/skills"
  "antigravity|Antigravity|agy|$HOME/.gemini:$HOME/.gemini/config|$HOME/.gemini/config/skills|.agents/skills"
  "codex|Codex CLI|codex|$HOME/.codex:$HOME/.agents|$HOME/.agents/skills|.agents/skills"
  "copilot|GitHub Copilot (VS Code / CLI)|copilot:code:$HOME/.vscode-server:$HOME/.vscode|$HOME/.copilot:$HOME/.config/github-copilot|$HOME/.copilot/skills|.github/skills"
  "gemini|Gemini CLI|gemini|$HOME/.gemini|$HOME/.gemini/skills|.gemini/skills"
  "agents|Universal (Agent Skills standard)|-|$HOME/.agents|$HOME/.agents/skills|.agents/skills"
)

TARGET=""
SCOPE="personal"
CATEGORIES=()
DRY_RUN=0
ASSUME_YES=0
LIST_ONLY=0
WANT_ALL=0
WANT_PLATFORMS=""

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

platform_field() { # id field_index
  local entry
  for entry in "${PLATFORMS[@]}"; do
    if [ "${entry%%|*}" = "$1" ]; then
      echo "$entry" | cut -d'|' -f"$2"
      return 0
    fi
  done
  return 1
}

platform_ids() {
  local entry
  for entry in "${PLATFORMS[@]}"; do echo "${entry%%|*}"; done
}

platform_exists_on_disk() { # id
  local dirs binaries b d
  dirs="$(platform_field "$1" 4)"
  binaries="$(platform_field "$1" 3)"
  IFS=':' read -ra dirs <<< "$dirs"
  for d in "${dirs[@]}"; do
    [ "$d" != "-" ] && [ -d "$d" ] && return 0
  done
  IFS=' ' read -ra binaries <<< "$binaries"
  for b in "${binaries[@]}"; do
    [ "$b" != "-" ] && have "$b" && return 0
  done
  return 1
}

detect_platforms() {
  local id
  for id in $(platform_ids); do
    platform_exists_on_disk "$id" && echo "$id"
  done
}

list_platforms() {
  echo "Supported platforms (detect * = detected on this machine):"
  local id label entry marker
  for entry in "${PLATFORMS[@]}"; do
    id="${entry%%|*}"
    label="$(echo "$entry" | cut -d'|' -f2)"
    marker=" "
    platform_exists_on_disk "$id" && marker="*"
    printf "  %s %-12s %s\n" "$marker" "$id" "$label"
  done
}

list_categories() {
  echo "Available categories:"
  local d name count
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    count=$(find "$d" -name SKILL.md | wc -l | tr -d ' ')
    printf "  %-20s %s skill(s)\n" "$name" "$count"
  done
}

# Collect all individual skill directories (Skills/<category>/<skill>/SKILL.md),
# flattened so every platform sees skills at its documented layout.
collect_skill_dirs() {
  local cat_dir skill_dir md
  for cat_dir in "$SKILLS_DIR"/*/; do
    [ -d "$cat_dir" ] || continue
    if [ ${#CATEGORIES[@]} -gt 0 ]; then
      case " ${CATEGORIES[*]} " in
        *"$(basename "$cat_dir")"*) ;;
        *) continue ;;
      esac
    fi
    for md in "$cat_dir"*/SKILL.md; do
      [ -f "$md" ] || continue
      echo "$(dirname "$md")"
    done
  done
}

install_to() { # dest_root
  local dest_root="$1" dest
  local total=0
  mkdir -p "$dest_root"
  local skill_dirs
  skill_dirs="$(collect_skill_dirs)"
  local src name
  for src in $skill_dirs; do
    name="$(basename "$src")"
    dest="$dest_root/$name"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] $src -> $dest"
    else
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$src/" "$dest/"
      else
        rm -rf "$dest"
        cp -r "$src" "$dest"
      fi
    fi
    total=$((total + 1))
  done
  if [ "$DRY_RUN" -eq 0 ]; then
    echo "Installed $total skill(s) to $dest_root"
  fi
}

install_for_platform() { # id
  local id="$1" dest
  if [ -n "$TARGET" ]; then
    dest="$TARGET"
  elif [ "$SCOPE" = "project" ]; then
    dest="$PWD/$(platform_field "$id" 6)"
  else
    dest="$(platform_field "$id" 5)"
  fi
  echo "==> $(platform_field "$id" 2): $dest"
  install_to "$dest"
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  read -r -p "$1 [y/N]: " reply || return 1
  [ "$reply" = "y" ] || [ "$reply" = "Y" ] || [ "$reply" = "yes" ]
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --all)       WANT_ALL=1; shift ;;
    --platform)  WANT_PLATFORMS="${2:-}"; shift 2 ;;
    --scope)     SCOPE="${2:-personal}"; shift 2 ;;
    --target)    TARGET="${2:-}"; shift 2 ;;
    --category)  CATEGORIES+=("$2"); shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    --list)      LIST_ONLY=1; shift ;;
    -h|--help)   usage 0 ;;
    *)           echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [ "$LIST_ONLY" -eq 1 ]; then
  list_platforms
  echo
  list_categories
  exit 0
fi

if [ ! -d "$SKILLS_DIR" ]; then
  echo "Error: Skills directory not found at $SKILLS_DIR" >&2
  exit 1
fi

if [ -n "$SCOPE" ] && [ "$SCOPE" != "personal" ] && [ "$SCOPE" != "project" ]; then
  echo "Error: --scope must be 'personal' or 'project'" >&2
  exit 1
fi

# Validate categories
if [ ${#CATEGORIES[@]} -gt 0 ]; then
  for c in "${CATEGORIES[@]}"; do
    if [ ! -d "$SKILLS_DIR/$c" ]; then
      echo "Error: Category '$c' not found." >&2
      echo >&2
      list_categories >&2
      exit 1
    fi
  done
fi

# ---------------------------------------------------------------------------
# Select target platforms
# ---------------------------------------------------------------------------
selected=()
final_selection=()

if [ -n "$TARGET" ]; then
  selected=("custom")
  echo "Explicit target: $TARGET"
elif [ "$WANT_ALL" -eq 1 ]; then
  mapfile -t selected < <(detect_platforms)
elif [ -n "$WANT_PLATFORMS" ]; then
  IFS=',' read -ra requested <<< "$WANT_PLATFORMS"
  for id in "${requested[@]}"; do
    id="$(echo "$id" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    found=0
    for known in $(platform_ids); do
      [ "$id" = "$known" ] && found=1 && break
    done
    if [ "$found" -ne 1 ]; then
      echo "Error: unknown platform '$id'" >&2
      echo "Valid platforms: $(platform_ids | tr '\n' ' ')" >&2
      exit 1
    fi
    selected+=("$id")
  done
else
  # Interactive selection
  mapfile -t detected < <(detect_platforms)
  if [ ${#detected[@]} -eq 0 ]; then
    echo "No supported AI coding agent platforms were detected on this machine."
    echo "You can still install to the universal Agent Skills location (~/.agents/skills),"
    echo "which is read by Codex, Pi, OpenCode, Antigravity and other standard-compliant agents."
    if confirm "Install to ~/.agents/skills?"; then
      selected=("agents")
    else
      echo "Nothing to do."
      exit 0
    fi
  else
    echo "Detected platforms:"
    i=1
    for id in "${detected[@]}"; do
      echo "  $i) $id  ($(platform_field "$id" 2))"
      i=$((i + 1))
    done
    echo "  a) all of the above"
    echo
    read -r -p "Select platform(s) to install to (comma-separated, or 'a') [a]: " choice || choice="a"
    choice="${choice:-a}"
    if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
      selected=("${detected[@]}")
    else
      IFS=',' read -ra picks <<< "$choice"
      for p in "${picks[@]}"; do
        p="$(echo "$p" | tr -d '[:space:]')"
        case "$p" in
          ''|*[!0-9]*) echo "Invalid selection: $p" >&2; exit 1 ;;
        esac
        if [ "$p" -lt 1 ] || [ "$p" -gt ${#detected[@]} ]; then
          echo "Invalid selection: $p" >&2
          exit 1
        fi
        selected+=("${detected[$((p - 1))]}")
      done
    fi
  fi
fi

# Guard: warn when an explicitly requested platform is not detected on disk.
for id in "${selected[@]}"; do
  if [ "$id" = "custom" ]; then
    final_selection+=("$id")
    continue
  fi
  if ! platform_exists_on_disk "$id"; then
    echo "Warning: platform '$id' was not detected (no binary or config directory found)." >&2
    if confirm "Install there anyway?"; then
      :
    else
      echo "Skipping $id."
      continue
    fi
  fi
  final_selection+=("$id")
done

if [ ${#final_selection[@]} -eq 0 ]; then
  echo "No platforms selected. Nothing to do."
  exit 0
fi

echo
[ "$DRY_RUN" -eq 1 ] && echo "[dry-run] Would install to:"
[ "$DRY_RUN" -eq 0 ] && echo "Installing to:"

for id in "${final_selection[@]}"; do
  if [ "$id" = "custom" ]; then
    echo "==> Custom target: $TARGET"
    install_to "$TARGET"
  else
    install_for_platform "$id"
  fi
done

echo
if [ "$DRY_RUN" -eq 0 ]; then
  echo "Done. Restart your agent session(s) so the new skills are discovered."
fi
