#!/usr/bin/env bash
# Content-addressed cache for review artifacts. An entry is keyed by a hash of every input it depends
# on, so any change produces a new key and old entries are simply never read again. Nothing is ever
# invalidated; gc only reclaims space.
#
#   cache.sh key <kind> [--worktree] (--config <resolved.json> | --no-config) [--model <id>] [--skill-scope all|scripts]
#                [--blob <path>]... [--rev-blob <rev>:<path>]... [--tree <dir>]... [--files-from <file|->]
#                [--arg <name>=<value>]... [--explain]
#       Prints the key. Always mixes in the kind and the skill hash, so editing the skill invalidates
#       dependent entries automatically. --skill-scope scripts hashes scripts/ only (for entries produced
#       purely by scripts); the default "all" hashes every file of the skill. --explain prints the
#       canonical input lines instead, for debugging a miss.
#       --blob/--files-from hash file content at HEAD, or in the working tree with --worktree.
#       --tree hashes a directory at HEAD, or its working-tree state (tracked + untracked, gitignore
#       respected) with --worktree. Use "." for the whole repository.
#   cache.sh get <kind> <key> [--out <file>]    exit 0 = hit (content on stdout or in <file>), 3 = miss
#   cache.sh put <kind> <key> <file|->          store atomically
#   cache.sh stats [--since <epoch>]            hits/misses per kind from the event log
#   cache.sh gc [--max-age-days N] [--max-mb N] remove least-recently-used entries
#   cache.sh info                               cache directory, size, entry count
#   cache.sh clear                              delete this repository's cache (asks no questions: confirm first)
#
# DEEP_REVIEW_NO_CACHE=1 or --no-cache makes every get a miss (puts still happen).
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_require git jq sha256sum

cdir=$(dr_cache_dir)
objects="$cdir/objects"
events="$cdir/events.log"
mkdir -p "$objects"

log_event() { printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "${4:-}" >>"$events"; }

worktree_tree() {
  # hash of the directory as it is on disk: copy the index, stage the directory into the copy, write the tree
  local dir="$1" idx root
  root=$(dr_root)
  idx=$(mktemp)
  cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || : >"$idx"
  (cd "$root" && GIT_INDEX_FILE="$idx" git add -A -- "$dir" >/dev/null 2>&1 || true)
  if [ "$dir" = "." ]; then
    (cd "$root" && GIT_INDEX_FILE="$idx" git write-tree)
  else
    (cd "$root" && GIT_INDEX_FILE="$idx" git write-tree --prefix="${dir%/}/" 2>/dev/null) || echo "absent"
  fi
  rm -f "$idx"
}

head_tree() {
  local dir="$1"
  if [ "$dir" = "." ]; then git rev-parse 'HEAD^{tree}'; else git rev-parse "HEAD:${dir%/}" 2>/dev/null || echo "absent"; fi
}

blob() {
  local path="$1" root
  root=$(dr_root)
  if [ "$worktree" -eq 1 ]; then
    if [ -f "$root/$path" ]; then git hash-object -- "$root/$path"; else echo "absent"; fi
  else
    git rev-parse "HEAD:$path" 2>/dev/null || echo "absent"
  fi
}

cmd_key() {
  local kind="${1:?kind required}"; shift
  worktree=0
  local config="" no_config=0 model="" explain=0 lines=() a skill_scope=all
  for a in "$@"; do [ "$a" = --worktree ] && worktree=1; done
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree) ;;
      --config) config="$2"; shift ;;
      --no-config) no_config=1 ;;
      --model) model="$2"; shift ;;
      --skill-scope) skill_scope="$2"; shift ;;
      --explain) explain=1 ;;
      --blob) lines+=("blob:$2=$(blob "$2")"); shift ;;
      --rev-blob)
        local rv="${2%%:*}" rp="${2#*:}"
        lines+=("rev-blob:$2=$(git rev-parse "$rv:$rp" 2>/dev/null || echo absent)"); shift ;;
      --tree)
        if [ "$worktree" -eq 1 ]; then lines+=("tree:$2=$(worktree_tree "$2")"); else lines+=("tree:$2=$(head_tree "$2")"); fi
        shift ;;
      --files-from)
        local src="$2" f; shift
        while IFS= read -r f; do [ -n "$f" ] && lines+=("blob:$f=$(blob "$f")"); done < <(if [ "$src" = - ]; then cat; else cat "$src"; fi)
        ;;
      --arg) lines+=("arg:$2"); shift ;;
      *) dr_die "cache.sh key: unknown option $1" ;;
    esac
    shift
  done
  if [ -n "$config" ]; then
    lines+=("config=$(jq -r .hash "$config")")
  elif [ "$no_config" -eq 0 ]; then
    dr_die "cache.sh key: pass --config <resolved.json>, or --no-config when the entry does not depend on configuration"
  fi
  [ -n "$model" ] && lines+=("model=$model")
  local canonical
  canonical=$(printf 'kind=%s\nskill=%s:%s\nmode=%s\n' "$kind" "$skill_scope" "$(dr_skill_hash "$skill_scope")" "$([ "$worktree" -eq 1 ] && echo worktree || echo head)"
    printf '%s\n' "${lines[@]+"${lines[@]}"}" | LC_ALL=C sort)
  if [ "$explain" -eq 1 ]; then echo "$canonical"; return 0; fi
  local key
  key=$(printf '%s\n' "$canonical" | dr_sha)
  dr_debug "key $kind = $key"
  echo "$key"
}

obj_path() { echo "$objects/${2:0:2}/$2.$1"; }

cmd_get() {
  local kind="${1:?kind}" key="${2:?key}" out="" p header
  shift 2
  [ "${1:-}" = "--out" ] && out="$2"
  p=$(obj_path "$kind" "$key")
  if [ "${DEEP_REVIEW_NO_CACHE:-0}" = 1 ] || [ ! -f "$p" ]; then
    log_event get miss "$kind" "$key"; dr_event cache "$(jq -nc --arg k "$kind" '{kind:$k, result:"miss"}')"; return 3
  fi
  header=$(head -1 "$p")
  if [ "$header" != "#deep-review-cache v1 kind=$kind key=$key" ]; then
    log_event get corrupt "$kind" "$key"; dr_warn "cache entry $p has a bad header; treating as miss"; rm -f "$p"; return 3
  fi
  touch "$p"
  log_event get hit "$kind" "$key"; dr_event cache "$(jq -nc --arg k "$kind" '{kind:$k, result:"hit"}')"
  if [ -n "$out" ]; then tail -n +2 "$p" >"$out"; else tail -n +2 "$p"; fi
}

cmd_put() {
  local kind="${1:?kind}" key="${2:?key}" src="${3:?file or -}" p tmp
  p=$(obj_path "$kind" "$key")
  mkdir -p "$(dirname "$p")"
  tmp=$(mktemp "$(dirname "$p")/.tmp.XXXXXX")
  { echo "#deep-review-cache v1 kind=$kind key=$key"; if [ "$src" = - ]; then cat; else cat "$src"; fi; } >"$tmp"
  mv -f "$tmp" "$p"
  log_event put stored "$kind" "$key"
  dr_debug "stored $kind $key ($(wc -c <"$p") bytes)"
}

cmd_stats() {
  local since=0
  [ "${1:-}" = "--since" ] && since="$2"
  [ -f "$events" ] || { echo "no cache events yet"; return 0; }
  awk -F'\t' -v since="$since" '$1 >= since && $2 == "get" { n[$4 "\t" $3]++; k[$4] = 1 }
    END { printf "kind\thit\tmiss\n"; for (x in k) printf "%s\t%d\t%d\n", x, n[x "\thit"] + 0, n[x "\tmiss"] + n[x "\tcorrupt"] + 0 }' "$events" | sort
}

cmd_gc() {
  local age=30 mb=500
  while [ "$#" -gt 0 ]; do
    case "$1" in --max-age-days) age="$2"; shift ;; --max-mb) mb="$2"; shift ;; esac
    shift
  done
  find "$objects" -type f -mtime +"$age" -delete 2>/dev/null || true
  local total
  total=$(du -sm "$objects" | cut -f1)
  if [ "$total" -gt "$mb" ]; then
    # least recently used first (hits touch the file)
    find "$objects" -type f -printf '%T@ %s %p\n' | sort -n | while read -r _ size f; do
      [ "$(du -sm "$objects" | cut -f1)" -le "$mb" ] && break
      rm -f "$f"; : "$size"
    done
  fi
  find "$cdir/runs" -mindepth 1 -maxdepth 1 -type d -mtime +"$age" -exec rm -rf {} + 2>/dev/null || true
  cmd_info
}

cmd_info() {
  echo "dir=$cdir"
  echo "entries=$(find "$objects" -type f -not -name '.tmp.*' | wc -l)"
  echo "size=$(du -sh "$cdir" | cut -f1)"
  echo "runs=$(find "$cdir/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
}

cmd_clear() { rm -rf "$cdir"; echo "cleared $cdir"; }

sub="${1:-}"; shift || true
case "$sub" in
  key) cmd_key "$@" ;;
  get) cmd_get "$@" ;;
  put) cmd_put "$@" ;;
  stats) cmd_stats "$@" ;;
  gc) cmd_gc "$@" ;;
  info) cmd_info ;;
  clear) cmd_clear ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
