#!/usr/bin/env bash
# Review run bookkeeping: one directory per run holding the resolved config, metadata and an event
# log that every script appends to while the run is active. Used for the report's "Run details"
# section and for debugging a run afterwards.
#
#   run.sh start [--model <id>] [--worktree] [config flags: --enable/--disable/--severity/--strict]
#       Creates the run, resolves config into <run>/config.json (exit 2 on config errors), prints
#       run=, config=, config_hash=, model=, warnings=. Scripts run afterwards log into this run.
#   run.sh step <name> [detail]   mark progress through the workflow (timings per step)
#   run.sh note <text>            free-form note into the log (decisions, skipped files, surprises)
#   run.sh end                    write <run>/run-details.md (paste into REVIEW.md), print it, close the run
#   run.sh current                print the active run directory
#   run.sh show [<run-dir>|latest] summary + last events of a run
#   run.sh list                   recent runs for this repository
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_require git jq python3

cdir=$(dr_cache_dir)
runs="$cdir/runs"

need_run() { dr_current_run || dr_die "no active run (start one with: run.sh start)"; }

cmd_start() {
  local model="unknown" worktree=0 cfg_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) model="$2"; shift ;;
      --worktree) worktree=1 ;;
      *) cfg_args+=("$1") ;;
    esac
    shift
  done
  mkdir -p "$runs"
  local run
  run="$runs/$(date -u +%Y%m%dT%H%M%SZ)-$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  mkdir -p "$run"
  dr_run_pointer >/dev/null
  echo "$run" >"$(dr_run_pointer)"
  : >"$run/events.jsonl"
  local root branch head
  root=$(dr_root)
  branch=$(git rev-parse --abbrev-ref HEAD)
  head=$(git rev-parse HEAD)
  jq -n --arg root "$root" --arg branch "$branch" --arg head "$head" --arg model "$model" \
    --arg skill_dir "$DR_SKILL_DIR" --arg skill_hash "$(dr_skill_hash)" --argjson worktree "$worktree" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg started_epoch "$(date +%s)" \
    --arg git "$(git --version | cut -d' ' -f3)" --arg python "$(python3 -c 'import sys;print(sys.version.split()[0])')" \
    --arg jq "$(jq --version)" --arg args "${cfg_args[*]+"${cfg_args[*]}"}" \
    '{root:$root, branch:$branch, head:$head, model:$model, worktree:($worktree==1), skill_dir:$skill_dir,
      skill_hash:$skill_hash, started:$started, started_epoch:($started_epoch|tonumber),
      tools:{git:$git, python:$python, jq:$jq}, config_args:$args}' >"$run/meta.json"
  dr_event run_start "$(cat "$run/meta.json")"
  local code=0
  python3 "$DR_SCRIPT_DIR/dr.py" config resolve --out "$run/config.json" "${cfg_args[@]+"${cfg_args[@]}"}" || code=$?
  prune_runs
  echo "run=$run"
  echo "config=$run/config.json"
  echo "config_hash=$(jq -r .hash "$run/config.json" 2>/dev/null || echo none)"
  echo "model=$model"
  echo "warnings=$(jq '.warnings | length' "$run/config.json" 2>/dev/null || echo 0)"
  echo "suppressed_safety=$(jq '.suppressed_safety | length' "$run/config.json" 2>/dev/null || echo 0)"
  if [ "$code" -ne 0 ]; then
    echo "errors=$(jq '.errors | length' "$run/config.json" 2>/dev/null || echo '?')"
    dr_die "configuration has errors (see above); fix them or run with --strict to audit without disables"
  fi
}

prune_runs() {
  local keep
  keep=$(jq -r '.debug["keep-runs"] // 20' "$(dr_current_run)/config.json" 2>/dev/null || echo 20)
  find "$runs" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((keep + 1)) | xargs -r rm -rf
}

cmd_step() { need_run >/dev/null; dr_event step "$(jq -nc --arg n "${1:?step name}" --arg d "${2:-}" '{name:$n, detail:$d}')"; }
cmd_note() { need_run >/dev/null; dr_event note "$(jq -nc --arg t "$*" '{text:$t}')"; }
cmd_current() { need_run; }

summary_md() {
  local run="$1"
  python3 - "$run" <<'PY'
import json, sys, datetime as dt
from pathlib import Path
run = Path(sys.argv[1])
meta = json.loads((run / "meta.json").read_text())
cfg = json.loads((run / "config.json").read_text()) if (run / "config.json").exists() else {}
events = [json.loads(l) for l in (run / "events.jsonl").read_text().splitlines() if l.strip()]
end = events[-1]["ts"] if events else meta["started"]
dur = (dt.datetime.fromisoformat(end.replace("Z", "+00:00")) - dt.datetime.fromisoformat(meta["started"].replace("Z", "+00:00"))).total_seconds()
scripts, cache, steps, warnings, notes = {}, {}, [], [], []
active, uncovered = [], {}
for e in events:
    t = e.get("type")
    if t == "script_end":
        s = scripts.setdefault(e["script"], {"runs": 0, "ms": 0, "failures": 0})
        s["runs"] += 1; s["ms"] += e.get("ms", 0); s["failures"] += e.get("exit", 0) != 0
    elif t == "cache":
        c = cache.setdefault(e["kind"], {"hit": 0, "miss": 0}); c[e["result"]] += 1
    elif t == "step":
        steps.append((e["ts"], e["name"], e.get("detail", "")))
    elif t == "warning":
        warnings.append(f'{e["script"]}: {e.get("message")}')
    elif t == "note":
        notes.append(e["text"])
    elif t == "detect":
        active, uncovered = e.get("active", []), e.get("uncovered", {})
out = []
out.append("## Run details\n")
out.append(f"- Skill: `{meta['skill_hash'][:12]}` from `{meta['skill_dir']}` · model `{meta['model']}` · {'working tree' if meta['worktree'] else 'HEAD'} at `{meta['head'][:12]}` on `{meta['branch']}`")
out.append(f"- Started {meta['started']}, last event {end} ({int(dur // 60)}m {int(dur % 60)}s) · tools: git {meta['tools']['git']}, python {meta['tools']['python']}, {meta['tools']['jq']}")
if active:
    out.append(f"- Packs active: {', '.join(f'`{a}`' for a in sorted(active))}")
if uncovered:
    out.append(f"- No language pack covered: {', '.join(f'.{k} ({v})' for k, v in uncovered.items())}")
out.append("\n### Review configuration\n")
srcs = cfg.get("sources", [])
out.append(f"- Config hash `{cfg.get('hash', '?')[:12]}`; sources: " + (", ".join(f"{s['layer']} `{s['file']}`" for s in srcs) if srcs else "none (defaults only)") + (" · **--strict**" if cfg.get("strict") else ""))
if meta.get("config_args"):
    out.append(f"- Command-line: `{meta['config_args']}`")
disabled = [(c, s) for c, s in cfg.get("checks", {}).items() if not s["enabled"] and s.get("default", True)]
enabled = [(c, s) for c, s in cfg.get("checks", {}).items() if s["enabled"] and not s.get("default", False)]
regraded = [(c, s) for c, s in cfg.get("checks", {}).items() if s.get("severity_by", "default") != "default"]
if disabled:
    out.append("- Disabled checks:")
    out += [f"  - `{c}` — {s.get('reason')} ({s['decided_by']})" for c, s in sorted(disabled)]
if enabled:
    out.append("- Opted-in checks: " + ", ".join(f"`{c}`" for c, _ in sorted(enabled)))
if regraded:
    out.append("- Re-graded: " + ", ".join(f"`{c}` → {s['severity']}" for c, s in sorted(regraded)))
if cfg.get("suppressed_safety"):
    out.append(f"- **{len(cfg['suppressed_safety'])} safety check(s) suppressed:** " + ", ".join(f"`{s['id']}` ({s['source']})" for s in cfg["suppressed_safety"]))
off_passes = [(p, s) for p, s in cfg.get("passes", {}).items() if not s["enabled"]]
if off_passes:
    out.append("- Passes off: " + ", ".join(f"`{p}` — {s['reason']}" for p, s in off_passes))
if cfg.get("overrides"):
    out.append(f"- Path overrides: {len(cfg['overrides'])} (" + "; ".join(", ".join(o["paths"]) for o in cfg["overrides"]) + ")")
acc = cfg.get("accepted", [])
if acc:
    out.append(f"- Accepted findings: {sum(not a['expired'] for a in acc)} active, {sum(a['expired'] for a in acc)} expired (expired ones are raised again)")
for w in cfg.get("warnings", []):
    out.append(f"- Config warning: {w}")
if cache:
    out.append("\n### Cache\n")
    out.append("| kind | hit | miss |\n|---|---|---|")
    out += [f"| {k} | {v['hit']} | {v['miss']} |" for k, v in sorted(cache.items())]
if scripts:
    out.append("\n### Scripts\n")
    out.append("| script | runs | total time | failures |\n|---|---|---|---|")
    out += [f"| {k} | {v['runs']} | {v['ms'] / 1000:.1f}s | {v['failures']} |" for k, v in sorted(scripts.items(), key=lambda kv: -kv[1]["ms"])]
if steps:
    out.append("\n### Steps\n")
    out += [f"- {ts} {name}" + (f" — {d}" if d else "") for ts, name, d in steps]
if warnings or notes:
    out.append("\n### Warnings and notes\n")
    out += [f"- ⚠ {w}" for w in warnings] + [f"- {n}" for n in notes]
print("\n".join(out))
PY
}

cmd_end() {
  local run
  run=$(need_run)
  dr_event run_end '{}'
  summary_md "$run" >"$run/run-details.md"
  rm -f "$(dr_run_pointer)"
  cat "$run/run-details.md"
  echo
  echo "(saved to $run/run-details.md)"
}

cmd_show() {
  local run="${1:-latest}"
  if [ "$run" = latest ]; then run=$(find "$runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -1); fi
  [ -d "$run" ] || dr_die "no such run: $run"
  summary_md "$run"
  echo
  echo "### Last events"
  tail -n 25 "$run/events.jsonl" | jq -rc '[.ts, .script, .type, (del(.ts, .script, .type) | tostring)] | join("  ")'
}

cmd_list() {
  [ -d "$runs" ] || { echo "no runs"; return 0; }
  find "$runs" -mindepth 1 -maxdepth 1 -type d | sort -r | while read -r r; do
    printf '%s\t%s\t%s\n' "$(basename "$r")" "$(jq -r '.branch + "@" + (.head[0:12])' "$r/meta.json" 2>/dev/null)" "$([ -f "$r/run-details.md" ] && echo finished || echo open)"
  done
}

sub="${1:-}"; shift || true
case "$sub" in
  start) cmd_start "$@" ;;
  step) cmd_step "$@" ;;
  note) cmd_note "$@" ;;
  end) cmd_end ;;
  current) cmd_current ;;
  show) cmd_show "$@" ;;
  list) cmd_list ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
