#!/usr/bin/env python3
"""deep-review helper: check catalog, configuration, stack detection, repo profile, evidence anchors.

Called through the thin wrappers next to it (list-checks.sh, config.sh, detect-stack.sh,
profile-repo.sh, check-evidence.sh). Requires Python 3.11+ (tomllib) and git.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

if sys.version_info < (3, 11):
    sys.exit("deep-review: Python 3.11+ is required (tomllib); found " + sys.version.split()[0])

import tomllib  # noqa: E402

SKILL_DIR = Path(__file__).resolve().parent.parent
DEBUG = os.environ.get("DEEP_REVIEW_DEBUG") == "1"

META_REQUIRED = ["kind", "safety", "default", "severity", "scope", "pass"]
META_VALUES = {
    "kind": {"defect", "practice"},
    "safety": {"yes", "no"},
    "default": {"on", "off"},
    "severity": {"blocker", "correctness", "architecture", "maintainability", "minor"},
    "scope": {"local", "cross"},
    "pass": {"correctness", "security", "contracts", "data", "tests", "duplication", "architecture", "conventions", "config"},
}
META_KEYS = set(META_REQUIRED) | {"tags", "instance-of"}
PACK_KINDS = {"language", "runtime", "framework", "library", "data", "infra", "domain", "project"}
PACK_KEYS = {"id", "kind", "maturity", "extends", "detect-files", "detect-deps", "applies-to", "description"}
SEVERITIES = ["blocker", "correctness", "architecture", "maintainability", "minor"]
PASSES = sorted(META_VALUES["pass"])
CONFIG_KEYS = {"version", "checks", "severity", "packs", "passes", "thresholds", "output", "overrides", "accepted", "debug", "cache"}
THRESHOLD_DEFAULTS = {
    "subagent-min-files": 30,
    "subagent-min-areas": 3,
    "clone-min-lines": 5,
    "clone-min-tokens": 40,
    "literal-min-areas": 2,
    "literal-max": 400,
    "max-file-lines": 300,
    "flat-directory-files": 30,
}
OUTPUT_DEFAULTS = {
    "path": None,
    "chat-summary": "short",
    "sections": {"configuration": True, "rules": True, "checks-run": True, "coverage": True, "rejected": True, "run-details": True},
}
CACHE_DEFAULTS = {"enabled": True, "include-model": True, "max-age-days": 30, "max-mb": 500}
DEBUG_DEFAULTS = {"keep-runs": 20}


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[debug dr.py] {msg}", file=sys.stderr)


def die(msg: str, code: int = 1) -> None:
    print(f"deep-review: {msg}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- git and paths

def git(*args: str, check: bool = True, cwd: Path | None = None) -> str:
    r = subprocess.run(["git", *args], capture_output=True, text=True, cwd=cwd)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def repo_root() -> Path | None:
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(r.stdout.strip()) if r.returncode == 0 else None


def user_dir() -> Path:
    if os.environ.get("DEEP_REVIEW_USER_DIR"):
        return Path(os.environ["DEEP_REVIEW_USER_DIR"])
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "deep-review"


def repo_dir() -> Path | None:
    root = repo_root()
    return root / ".deep-review" if root else None


def tracked_files() -> list[str]:
    root = repo_root()
    if not root:
        return []
    return [p for p in git("-c", "core.quotePath=false", "ls-files", cwd=root).splitlines() if p]


# ---------------------------------------------------------------- run events (mirrors lib.sh)

def _cache_root() -> Path:
    if os.environ.get("DEEP_REVIEW_CACHE_DIR"):
        return Path(os.environ["DEEP_REVIEW_CACHE_DIR"])
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "deep-review"


def _repo_cache_dir() -> Path | None:
    root = repo_root()
    if not root:
        return None
    roots = sorted(git("rev-list", "--max-parents=0", "HEAD", check=False, cwd=root).split())
    rid = roots[0][:16] if roots else hashlib.sha256(str(root).encode()).hexdigest()[:16]
    return _cache_root() / rid


def event(etype: str, **fields) -> None:
    try:
        root = repo_root()
        cdir = _repo_cache_dir()
        if not root or not cdir:
            return
        ptr = cdir / f"current-run.{hashlib.sha256((str(root) + chr(10)).encode()).hexdigest()[:12]}"
        if not ptr.is_file():
            return
        run = Path(ptr.read_text().strip())
        if not run.is_dir():
            return
        rec = {"ts": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "script": "dr.py", "type": etype, **fields}
        with open(run / "events.jsonl", "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:  # logging must never break a review
        pass


# ---------------------------------------------------------------- globs

def glob_to_regex(glob: str) -> re.Pattern:
    i, out = 0, []
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def glob_match(path: str, globs: list[str]) -> bool:
    return any(glob_to_regex(g).match(path) for g in globs)


def split_list(v: str | None) -> list[str]:
    return [x.strip() for x in (v or "").split(",") if x.strip()]


# ---------------------------------------------------------------- catalog

@dataclass
class Pack:
    id: str
    layer: str
    file: str
    meta: dict
    overrides: list = field(default_factory=list)  # (layer, file) of packs this one replaced


@dataclass
class Check:
    id: str
    layer: str
    pack: str  # "core" or a pack id
    file: str
    line: int
    meta: dict
    shadows: list = field(default_factory=list)


LAYERS = ["skill", "user", "repo"]


def layer_dirs() -> list[tuple[str, Path]]:
    dirs = [("skill", SKILL_DIR / "packs"), ("user", user_dir() / "packs")]
    rd = repo_dir()
    if rd:
        dirs.append(("repo", rd / "packs"))
    return dirs


def pack_files() -> list[tuple[str, Path]]:
    out = []
    for layer, d in layer_dirs():
        if d.is_dir():
            for p in sorted(d.rglob("*.md")):
                if p.name == "README.md" or p.name.startswith("_"):
                    continue
                out.append((layer, p))
    return out


def parse_frontmatter(text: str) -> tuple[dict, list[str]]:
    lines = text.splitlines()
    fm, problems = {}, []
    if not lines or lines[0].strip() != "---":
        return fm, ["missing frontmatter"]
    for i, line in enumerate(lines[1:], start=2):
        if line.strip() == "---":
            return fm, problems
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*(#.*)?$", line)
        if m:
            fm[m.group(1)] = m.group(2)
        elif line.strip():
            problems.append(f"line {i}: unparsable frontmatter line")
    return fm, problems + ["frontmatter not closed"]


CHECK_HEAD = re.compile(r"^###\s+(\S+)\s*$")


def parse_checks(path: Path) -> tuple[list[tuple[str, int, dict, list[str]]], list[str]]:
    """Return [(id, line, meta, problems)] and file-level problems."""
    lines = path.read_text().splitlines()
    out, file_problems = [], []
    for i, line in enumerate(lines):
        m = CHECK_HEAD.match(line)
        if not m:
            continue
        cid = m.group(1)
        j = i + 1
        while j < len(lines) and not lines[j].strip():
            j += 1
        problems, meta = [], {}
        if j >= len(lines) or not lines[j].startswith("meta:"):
            problems.append("no meta: line after heading")
        else:
            for tok in lines[j][len("meta:"):].split():
                if "=" not in tok:
                    problems.append(f"meta token without '=': {tok}")
                    continue
                k, v = tok.split("=", 1)
                if k not in META_KEYS:
                    problems.append(f"unknown meta key '{k}'")
                meta[k] = v
            for k in META_REQUIRED:
                if k not in meta:
                    problems.append(f"missing meta key '{k}'")
                elif meta[k] not in META_VALUES[k]:
                    problems.append(f"invalid {k}='{meta[k]}' (allowed: {', '.join(sorted(META_VALUES[k]))})")
        meta["tags"] = split_list(meta.get("tags"))
        out.append((cid, i + 1, meta, problems))
    return out, file_problems


class Catalog:
    def __init__(self) -> None:
        self.packs: dict[str, Pack] = {}
        self.checks: dict[str, Check] = {}
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.infos: list[str] = []
        self._load()

    def _load(self) -> None:
        core = SKILL_DIR / "core" / "issue-classes.md"
        self._add_checks("skill", "core", core, core_file=True)
        seen_in_layer: dict[tuple[str, str], str] = {}
        for layer, path in pack_files():
            fm, probs = parse_frontmatter(path.read_text())
            for p in probs:
                self.errors.append(f"{path}: {p}")
            pid = fm.get("id")
            if not pid:
                self.errors.append(f"{path}: frontmatter has no id")
                continue
            if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", pid):
                self.errors.append(f"{path}: pack id '{pid}' must be lowercase kebab-case")
            for k in fm:
                if k not in PACK_KEYS:
                    self.warnings.append(f"{path}: unknown frontmatter key '{k}'")
            if fm.get("kind") not in PACK_KINDS:
                self.errors.append(f"{path}: kind must be one of {', '.join(sorted(PACK_KINDS))}")
            if fm.get("maturity", "seed") not in {"seed", "reviewed"}:
                self.errors.append(f"{path}: maturity must be seed or reviewed")
            if (layer, pid) in seen_in_layer:
                self.errors.append(f"{path}: duplicate pack id '{pid}' in layer {layer} (also {seen_in_layer[(layer, pid)]})")
                continue
            seen_in_layer[(layer, pid)] = str(path)
            prev = self.packs.get(pid)
            pack = Pack(pid, layer, str(path), fm)
            if prev:
                pack.overrides = prev.overrides + [(prev.layer, prev.file)]
                self.infos.append(f"pack '{pid}' from {layer} ({path}) replaces {prev.layer} ({prev.file})")
                for cid in [c for c, ch in self.checks.items() if ch.pack == pid]:
                    del self.checks[cid]
            self.packs[pid] = pack
        for pid, pack in self.packs.items():
            self._add_checks(pack.layer, pid, Path(pack.file))
            for ext in split_list(pack.meta.get("extends")):
                if ext not in self.packs:
                    self.errors.append(f"{pack.file}: extends unknown pack '{ext}'")
        core_ids = {c for c, ch in self.checks.items() if ch.pack == "core"}
        for cid, ch in self.checks.items():
            io = ch.meta.get("instance-of")
            if io and io not in core_ids:
                self.errors.append(f"{ch.file}:{ch.line}: {cid} instance-of unknown core class '{io}'")

    def _add_checks(self, layer: str, pack: str, path: Path, core_file: bool = False) -> None:
        if not path.is_file():
            self.errors.append(f"missing check file {path}")
            return
        entries, fprobs = parse_checks(path)
        for p in fprobs:
            self.errors.append(f"{path}: {p}")
        local_ids: set[str] = set()
        for cid, line, meta, probs in entries:
            where = f"{path}:{line}"
            for p in probs:
                self.errors.append(f"{where}: {cid}: {p}")
            if core_file:
                if not re.fullmatch(r"C-[A-Z0-9]+(-[A-Z0-9]+)*", cid):
                    self.errors.append(f"{where}: core id '{cid}' must look like C-UPPER-KEBAB")
            elif not cid.startswith(pack + "/") or not re.fullmatch(r"[a-z0-9-]+/[a-z0-9]+(-[a-z0-9]+)*", cid):
                self.errors.append(f"{where}: check id '{cid}' must be '{pack}/<kebab-slug>'")
            if cid in local_ids:
                self.errors.append(f"{where}: duplicate check id '{cid}' in {path}")
                continue
            local_ids.add(cid)
            ch = Check(cid, layer, pack, str(path), line, meta)
            prev = self.checks.get(cid)
            if prev:
                if LAYERS.index(layer) > LAYERS.index(prev.layer):
                    ch.shadows = prev.shadows + [f"{prev.layer}:{prev.file}:{prev.line}"]
                    self.infos.append(f"check '{cid}' at {where} shadows {prev.layer} {prev.file}:{prev.line}")
                else:
                    self.errors.append(f"{where}: duplicate check id '{cid}' (also {prev.file}:{prev.line})")
                    continue
            self.checks[cid] = ch

    def tags(self) -> set[str]:
        return {t for ch in self.checks.values() for t in ch.meta.get("tags", [])}


# ---------------------------------------------------------------- config

def config_files() -> list[tuple[str, Path]]:
    out = [("user", user_dir() / "config.toml")]
    rd = repo_dir()
    if rd:
        out.append(("repo", rd / "config.toml"))
    return [(layer, p) for layer, p in out if p.is_file()]


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


class Resolver:
    def __init__(self, catalog: Catalog, strict: bool) -> None:
        self.cat = catalog
        self.strict = strict
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.state = {
            cid: {
                "enabled": ch.meta.get("default") == "on",
                "default": ch.meta.get("default") == "on",
                "severity": ch.meta.get("severity"),
                "decided_by": "default",
                "severity_by": "default",
                "reason": None,
                "trace": [f"default: {'on' if ch.meta.get('default') == 'on' else 'off'} ({ch.file}:{ch.line})"],
            }
            for cid, ch in catalog.checks.items()
        }
        self.suppressed_safety: list[dict] = []
        self.packs = {"disable": [], "force": []}
        self.passes = {p: {"enabled": True, "paths-ignore": [], "reason": None, "decided_by": "default"} for p in PASSES}
        self.thresholds = dict(THRESHOLD_DEFAULTS)
        self.output = json.loads(json.dumps(OUTPUT_DEFAULTS))
        self.cache = dict(CACHE_DEFAULTS)
        self.debug_cfg = dict(DEBUG_DEFAULTS)
        self.overrides: list[dict] = []
        self.accepted: list[dict] = []

    def _targets(self, entry: dict, where: str) -> list[str]:
        if "id" in entry:
            if entry["id"] not in self.cat.checks:
                self.warnings.append(f"{where}: unknown check id '{entry['id']}' (typo? run list-checks.sh)")
                return []
            return [entry["id"]]
        if "tag" in entry:
            ids = [c for c, ch in self.cat.checks.items() if entry["tag"] in ch.meta.get("tags", [])]
            if not ids:
                self.warnings.append(f"{where}: tag '{entry['tag']}' matches no check")
            return ids
        if "pass" in entry:
            ids = [c for c, ch in self.cat.checks.items() if ch.meta.get("pass") == entry["pass"]]
            if not ids:
                self.warnings.append(f"{where}: pass '{entry['pass']}' matches no check")
            return ids
        self.errors.append(f"{where}: entry needs one of id, tag, pass")
        return []

    def _entries(self, value, where: str) -> list[dict]:
        if value is None:
            return []
        if not isinstance(value, list):
            self.errors.append(f"{where}: must be an array")
            return []
        out = []
        for i, e in enumerate(value):
            if isinstance(e, str):
                e = {"tag": e[4:]} if e.startswith("tag:") else {"id": e}
            if not isinstance(e, dict):
                self.errors.append(f"{where}[{i}]: must be a table or string")
                continue
            out.append(e)
        return out

    def _apply_toggles(self, checks_tbl: dict, where: str, state: dict, record_safety: bool) -> None:
        # Tag and pass toggles first, then ids, so a specific id beats a group rule within one layer.
        for action in ("disable", "enable"):
            entries = self._entries(checks_tbl.get(action), f"{where}.checks.{action}")
            for group in (False, True):
                for e in entries:
                    if ("id" in e) != group:
                        continue
                    for cid in self._targets(e, f"{where}.checks.{action}"):
                        self._toggle(state, cid, action == "enable", e, where, record_safety)

    def _toggle(self, state: dict, cid: str, enable: bool, entry: dict, where: str, record_safety: bool) -> None:
        ch = self.cat.checks[cid]
        via = f"id {cid}" if "id" in entry else (f"tag {entry.get('tag')}" if "tag" in entry else f"pass {entry.get('pass')}")
        st = state[cid]
        if not enable:
            reason = entry.get("reason")
            if not reason:
                self.errors.append(f"{where}: disabling {cid} ({via}) needs a reason")
                return
            if self.strict:
                st["trace"].append(f"{where}: disable ({via}) ignored by --strict")
                return
            if ch.meta.get("safety") == "yes":
                if not entry.get("acknowledge-risk"):
                    msg = f"{where}: {cid} is a safety check; disabling it ({via}) needs acknowledge-risk = true"
                    if "id" in entry:
                        self.errors.append(msg)
                    else:
                        self.warnings.append(msg + " — kept enabled")
                        st["trace"].append(f"{where}: group disable ({via}) skipped, safety check")
                    return
                if record_safety:
                    self.suppressed_safety = [x for x in self.suppressed_safety if x["id"] != cid]
                    self.suppressed_safety.append({"id": cid, "source": where, "reason": reason})
            st.update(enabled=False, decided_by=where, reason=reason)
            st["trace"].append(f"{where}: disabled via {via} — {reason}")
        else:
            st.update(enabled=True, decided_by=where, reason=entry.get("reason"))
            st["trace"].append(f"{where}: enabled via {via}")

    def _apply_severity(self, tbl: dict, where: str, state: dict) -> None:
        for cid, level in (tbl or {}).items():
            if cid not in self.cat.checks:
                self.warnings.append(f"{where}.severity: unknown check id '{cid}'")
                continue
            if level not in SEVERITIES:
                self.errors.append(f"{where}.severity.{cid}: '{level}' is not one of {', '.join(SEVERITIES)}")
                continue
            state[cid]["severity"] = level
            state[cid]["severity_by"] = where
            state[cid]["trace"].append(f"{where}: severity → {level}")

    def apply_layer(self, layer: str, path: Path, data: dict) -> None:
        where = f"{layer}:{path}"
        for k in data:
            if k not in CONFIG_KEYS:
                self.warnings.append(f"{where}: unknown top-level key '{k}'")
        if data.get("version", 1) != 1:
            self.errors.append(f"{where}: unsupported version {data.get('version')}")
        self._apply_toggles(data.get("checks", {}), where, self.state, record_safety=True)
        self._apply_severity(data.get("severity", {}), where, self.state)
        packs = data.get("packs", {})
        for key in ("disable", "force"):
            for pid in packs.get(key, []) or []:
                if pid not in self.cat.packs:
                    self.warnings.append(f"{where}.packs.{key}: unknown pack '{pid}'")
                if key == "disable" and self.strict:
                    continue
                if pid not in self.packs[key]:
                    self.packs[key].append(pid)
        for pname, ptbl in (data.get("passes") or {}).items():
            if pname not in self.passes:
                self.warnings.append(f"{where}.passes: unknown pass '{pname}' (allowed: {', '.join(PASSES)})")
                continue
            if "paths-ignore" in ptbl:
                self.passes[pname]["paths-ignore"] = list(ptbl["paths-ignore"])
            if ptbl.get("enabled") is False:
                if not ptbl.get("reason"):
                    self.errors.append(f"{where}.passes.{pname}: disabling a pass needs a reason")
                elif pname == "security" and not ptbl.get("acknowledge-risk"):
                    self.errors.append(f"{where}.passes.security: disabling it needs acknowledge-risk = true")
                elif not self.strict:
                    self.passes[pname].update(enabled=False, reason=ptbl["reason"], decided_by=where)
            elif ptbl.get("enabled") is True:
                self.passes[pname].update(enabled=True, decided_by=where)
        for k, v in (data.get("thresholds") or {}).items():
            if k not in THRESHOLD_DEFAULTS:
                self.warnings.append(f"{where}.thresholds: unknown key '{k}'")
            elif not isinstance(v, int) or v < 0:
                self.errors.append(f"{where}.thresholds.{k}: must be a non-negative integer")
            else:
                self.thresholds[k] = v
        out = data.get("output") or {}
        for k, v in out.items():
            if k == "sections":
                for s, on in v.items():
                    if s not in self.output["sections"]:
                        self.warnings.append(f"{where}.output.sections: unknown section '{s}'")
                    else:
                        self.output["sections"][s] = bool(on)
            elif k in self.output:
                self.output[k] = v
            else:
                self.warnings.append(f"{where}.output: unknown key '{k}'")
        for tbl, target, defaults in (("cache", self.cache, CACHE_DEFAULTS), ("debug", self.debug_cfg, DEBUG_DEFAULTS)):
            for k, v in (data.get(tbl) or {}).items():
                if k not in defaults:
                    self.warnings.append(f"{where}.{tbl}: unknown key '{k}'")
                else:
                    target[k] = v
        for i, ov in enumerate(data.get("overrides") or []):
            ow = f"{where}.overrides[{i}]"
            paths = ov.get("paths")
            if not paths:
                self.errors.append(f"{ow}: needs paths")
                continue
            # validate now against a scratch state so errors surface at resolve time
            scratch = {cid: {**v, "trace": []} for cid, v in self.state.items()}
            self._apply_toggles(ov.get("checks", {}), ow, scratch, record_safety=False)
            self._apply_severity(ov.get("severity", {}), ow, scratch)
            self.overrides.append({"source": ow, "paths": list(paths), "checks": ov.get("checks", {}), "severity": ov.get("severity", {})})
        today = dt.date.today()
        for i, acc in enumerate(data.get("accepted") or []):
            aw = f"{where}.accepted[{i}]"
            fp, reason = acc.get("fingerprint"), acc.get("reason")
            if not fp or not reason:
                self.errors.append(f"{aw}: needs fingerprint and reason")
                continue
            cid = fp.split(":", 1)[0]
            if cid not in self.cat.checks:
                self.warnings.append(f"{aw}: fingerprint check id '{cid}' is unknown")
            until = acc.get("until")
            expired = False
            if until is not None:
                try:
                    until_d = until if isinstance(until, dt.date) else dt.date.fromisoformat(str(until))
                    expired = until_d < today
                    until = until_d.isoformat()
                except ValueError:
                    self.errors.append(f"{aw}: until must be YYYY-MM-DD")
            if self.strict:
                continue
            self.accepted.append({"fingerprint": fp, "reason": reason, "until": until, "expired": expired, "source": aw})

    def apply_cli(self, enables: list[str], disables: list[str], severities: list[str], ack: bool = False) -> None:
        tbl = {"enable": [self._cli_entry(x) for x in enables],
               "disable": [{**self._cli_entry(x), "reason": "command line", "acknowledge-risk": ack} for x in disables]}
        self._apply_toggles(tbl, "cli", self.state, record_safety=True)
        sev = {}
        for s in severities:
            if "=" not in s:
                self.errors.append(f"cli: --severity expects ID=level, got '{s}'")
                continue
            k, v = s.split("=", 1)
            sev[k] = v
        self._apply_severity(sev, "cli", self.state)

    @staticmethod
    def _cli_entry(x: str) -> dict:
        if x.startswith("tag:"):
            return {"tag": x[4:]}
        if x.startswith("pass:"):
            return {"pass": x[5:]}
        return {"id": x}

    def result(self, sources: list[dict]) -> dict:
        semantic = {
            "strict": self.strict,
            "checks": {c: {k: v for k, v in s.items() if k != "trace"} for c, s in sorted(self.state.items())},
            "packs": self.packs,
            "passes": self.passes,
            "thresholds": self.thresholds,
            "output": self.output,
            "cache": self.cache,
            "debug": self.debug_cfg,
            "overrides": self.overrides,
            "accepted": self.accepted,
            "sources": [{"layer": s["layer"], "sha256": s["sha256"]} for s in sources],
        }
        h = hashlib.sha256(json.dumps(semantic, sort_keys=True, default=str).encode()).hexdigest()
        return {
            "version": 1,
            "hash": h,
            "resolved_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            **semantic,
            "sources": sources,
            "errors": self.errors,
            "warnings": self.warnings,
            "suppressed_safety": self.suppressed_safety,
            "trace": {c: s["trace"] for c, s in sorted(self.state.items())},
        }


def resolve_config(args) -> dict:
    cat = Catalog()
    r = Resolver(cat, strict=args.strict)
    sources = []
    for layer, path in config_files():
        try:
            data = tomllib.loads(path.read_text())
        except tomllib.TOMLDecodeError as e:
            r.errors.append(f"{layer}:{path}: TOML error: {e}")
            continue
        sources.append({"layer": layer, "file": str(path), "sha256": sha256_file(path)})
        r.apply_layer(layer, path, data)
    r.apply_cli(args.enable or [], args.disable or [], args.severity or [], ack=args.acknowledge_risk)
    res = r.result(sources)
    res["catalog_errors"] = cat.errors
    return res


def effective_check(cfg: dict, cid: str, path: str | None) -> dict:
    base = cfg["checks"].get(cid)
    if base is None:
        return {"known": False}
    st = {**base, "trace": list(cfg["trace"].get(cid, []))}
    if path:
        for ov in cfg["overrides"]:
            if not glob_match(path, ov["paths"]):
                continue
            src = ov["source"]
            for action in ("disable", "enable"):
                for e in ov["checks"].get(action, []) or []:
                    e = {"id": e} if isinstance(e, str) else e
                    hit = e.get("id") == cid or (e.get("tag") and e["tag"] in cfg.get("_tags", {}).get(cid, []))
                    if not hit:
                        continue
                    if action == "disable" and not cfg["strict"]:
                        if cfg.get("_safety", {}).get(cid) and not e.get("acknowledge-risk"):
                            st["trace"].append(f"{src}: disable skipped, safety check")
                            continue
                        st.update(enabled=False, decided_by=src, reason=e.get("reason"))
                        st["trace"].append(f"{src}: disabled for {path} — {e.get('reason')}")
                    elif action == "enable":
                        st.update(enabled=True, decided_by=src)
                        st["trace"].append(f"{src}: enabled for {path}")
            if cid in (ov.get("severity") or {}):
                st["severity"] = ov["severity"][cid]
                st["severity_by"] = src
                st["trace"].append(f"{src}: severity → {st['severity']} for {path}")
    st["known"] = True
    return st


def load_resolved(p: str) -> dict:
    cfg = json.loads(Path(p).read_text())
    cat = Catalog()
    cfg["_tags"] = {c: ch.meta.get("tags", []) for c, ch in cat.checks.items()}
    cfg["_safety"] = {c: ch.meta.get("safety") == "yes" for c, ch in cat.checks.items()}
    return cfg


# ---------------------------------------------------------------- detection

def manifest_declares(manifest: str, path: Path, dep: str) -> bool:
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return False
    if manifest in ("package.json", "composer.json"):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return False
        keys = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies", "require", "require-dev"]
        return any(dep in (data.get(k) or {}) for k in keys)
    return re.search(r"(^|[\s\"'=\[,(])" + re.escape(dep) + r"($|[\s\"':=@<>~^!\],;)\[])", text, re.MULTILINE | re.IGNORECASE) is not None


def detect(cfg: dict | None, changed_rows: list[dict], explain: bool) -> dict:
    changed = [r["path"] for r in changed_rows]
    cat = Catalog()
    root = repo_root()
    files = tracked_files()
    by_name: dict[str, list[str]] = {}
    for f in files:
        by_name.setdefault(f.rsplit("/", 1)[-1], []).append(f)
    forced = set(cfg["packs"]["force"]) if cfg else set()
    disabled = set(cfg["packs"]["disable"]) if cfg else set()
    reasons: dict[str, list[str]] = {}
    for pid, pack in cat.packs.items():
        why = []
        dfiles, ddeps = split_list(pack.meta.get("detect-files")), split_list(pack.meta.get("detect-deps"))
        if not dfiles and not ddeps:
            why.append("no detect-* keys: always active")
        for g in dfiles:
            rx = glob_to_regex(g)
            hit = next((f for f in files if rx.match(f)), None)
            if hit:
                why.append(f"detect-files {g} matched {hit}")
                break
        for d in ddeps:
            if ":" not in d:
                cat.errors.append(f"{pack.file}: detect-deps entry '{d}' must be <manifest>:<dependency>")
                continue
            manifest, dep = d.split(":", 1)
            for mf in by_name.get(manifest, []):
                if root and manifest_declares(manifest, root / mf, dep):
                    why.append(f"detect-deps {d} declared in {mf}")
                    break
        if pid in forced:
            why.append("forced by config packs.force")
        if why:
            reasons[pid] = why
    active = set(reasons)
    changed_extends = True
    while changed_extends:
        changed_extends = False
        for pid in list(active):
            for ext in split_list(cat.packs[pid].meta.get("extends")):
                if ext in cat.packs and ext not in active:
                    active.add(ext)
                    reasons.setdefault(ext, []).append(f"extended by {pid}")
                    changed_extends = True
    rows = []
    for pid in sorted(cat.packs):
        pack = cat.packs[pid]
        status = "active" if pid in active else "inactive"
        if pid in active and pid in disabled:
            status = "disabled"
        applies = split_list(pack.meta.get("applies-to"))
        matched = [p for p in changed if not applies or glob_match(p, applies)] if status == "active" else []
        rows.append({
            "id": pid, "status": status, "layer": pack.layer, "kind": pack.meta.get("kind"),
            "maturity": pack.meta.get("maturity", "seed"), "file": pack.file, "changed_matched": len(matched),
            "reasons": reasons.get(pid, []) + (["disabled by config packs.disable"] if status == "disabled" else []),
            "paths": matched if explain else [],
        })
    act = [r for r in rows if r["status"] == "active"]
    lang_globs = [split_list(cat.packs[r["id"]].meta.get("applies-to")) for r in act if cat.packs[r["id"]].meta.get("kind") == "language"]
    uncovered: dict[str, int] = {}
    for row in changed_rows:
        if row.get("kind") not in ("source", "test"):
            continue
        p = row["path"]
        if any(glob_match(p, g) for g in lang_globs if g):
            continue
        name = p.rsplit("/", 1)[-1]
        ext = name.rsplit(".", 1)[-1] if "." in name else "(none)"
        uncovered[ext] = uncovered.get(ext, 0) + 1
    event("detect", active=[r["id"] for r in act], uncovered=uncovered)
    return {"packs": rows, "uncovered_by_language_pack": uncovered, "catalog_errors": cat.errors}


# ---------------------------------------------------------------- profile

SHARED_DIR_NAMES = {
    "components", "component", "ui", "design-system", "designsystem", "widgets", "shared", "common", "core",
    "utils", "util", "helpers", "lib", "hooks", "composables", "services", "theme", "styles", "formatters",
    "validators", "extensions", "mixins", "pkg", "internal",
}
SOURCE_EXT = {"ts", "tsx", "js", "jsx", "mjs", "cjs", "dart", "py", "go", "rs", "java", "kt", "swift", "rb", "php", "cs", "scala", "sql", "vue", "svelte"}
EXPORT_PATTERNS = {
    ("ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts"): [
        re.compile(r"^export\s+(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?(?:function\*?|const|let|var|class|interface|type|enum)\s+([A-Za-z0-9_$]+)")],
    ("dart",): [
        re.compile(r"^(?:abstract\s+|sealed\s+|final\s+|base\s+|interface\s+|mixin\s+)*(?:class|mixin|enum|extension|typedef)\s+([A-Za-z0-9_]+)"),
        re.compile(r"^[A-Z][A-Za-z0-9_<>?, ]*\s+([a-z][A-Za-z0-9_]*)\s*\(")],
    ("py",): [re.compile(r"^(?:async\s+)?def\s+([A-Za-z][A-Za-z0-9_]*)"), re.compile(r"^class\s+([A-Za-z][A-Za-z0-9_]*)")],
    ("go",): [re.compile(r"^func\s+(?:\([^)]*\)\s+)?([A-Z][A-Za-z0-9_]*)"), re.compile(r"^type\s+([A-Z][A-Za-z0-9_]*)")],
    ("rs",): [re.compile(r"^pub(?:\([a-z]+\))?\s+(?:async\s+)?(?:fn|struct|enum|trait|type|const|static)\s+([A-Za-z0-9_]+)")],
    ("java", "kt", "scala", "cs", "swift"): [re.compile(r"^(?:public\s+|open\s+)?(?:static\s+|final\s+|abstract\s+|data\s+|sealed\s+)*(?:class|interface|enum|record|object|struct|protocol|fun|func)\s+([A-Za-z0-9_]+)")],
    ("rb",): [re.compile(r"^\s*(?:def|class|module)\s+([A-Za-z0-9_:?!.]+)")],
    ("php",): [re.compile(r"^(?:final\s+|abstract\s+)?(?:class|interface|trait|function)\s+([A-Za-z0-9_]+)")],
    ("sql",): [re.compile(r"(?i)^\s*create\s+(?:or\s+replace\s+)?(?:function|procedure|view|materialized\s+view|table|type)\s+(?:if\s+not\s+exists\s+)?([A-Za-z0-9_.\"]+)")],
}


def export_patterns_for(ext: str):
    for exts, pats in EXPORT_PATTERNS.items():
        if ext in exts:
            return pats
    return []


def role_suffix(name: str) -> str | None:
    """Naming role of a file: foo.resolver.ts → .resolver.ts, FooPage.tsx → Page.tsx, foo_repo.py → _repo.py."""
    base, _, ext = name.rpartition(".")
    if not base:
        return None
    if "." in base:
        return "." + base.rsplit(".", 1)[1] + "." + ext
    m = re.search(r"[a-z0-9]([A-Z][a-z0-9]+)$", base)
    if m:
        return m.group(1) + "." + ext
    if "_" in base:
        return "_" + base.rsplit("_", 1)[1] + "." + ext
    if "-" in base:
        return "-" + base.rsplit("-", 1)[1] + "." + ext
    return None


def profile(scope_rows: list[dict], out: Path) -> dict:
    root = repo_root()
    files = tracked_files()
    changed = {r["path"] for r in scope_rows}
    added = [r["path"] for r in scope_rows if r["status"] in ("A", "?")]
    skip = re.compile(r"(^|/)(node_modules|vendor|dist|build|generated|__generated__|\.dart_tool|coverage|test|tests|__tests__|spec|fixtures|testdata)/")
    shared_dirs: dict[str, int] = {}
    for f in files:
        parts = f.split("/")
        for i, part in enumerate(parts[:-1]):
            if part.lower() in SHARED_DIR_NAMES:
                d = "/".join(parts[: i + 1])
                if not skip.search(d + "/"):
                    shared_dirs[d] = shared_dirs.get(d, 0) + 1
                break
    exports: list[tuple[str, str]] = []
    for f in files:
        if f in changed or skip.search(f):
            continue
        if not any(f.startswith(d + "/") for d in shared_dirs):
            continue
        ext = f.rsplit(".", 1)[-1] if "." in f else ""
        pats = export_patterns_for(ext)
        if not pats:
            continue
        try:
            for line in (root / f).read_text(errors="replace").splitlines():
                for pat in pats:
                    m = pat.match(line)
                    if m:
                        exports.append((m.group(1), f))
                        break
        except OSError:
            continue
    generic = {"index", "main", "mod", "lib", "__init__", "up", "down", "types", "type", "utils", "util", "helpers",
               "constants", "config", "readme", "page", "layout", "route", "routes", "schema", "models", "model", "test",
               "spec", "setup", "app", "server", "client", "styles", "style", "theme", "hooks", "service", "controller"}

    def closeness(a: str, f: str) -> int:
        n = 0
        for x, y in zip(a.split("/"), f.split("/")):
            if x != y:
                break
            n += 1
        return n

    by_base: dict[str, list[str]] = {}
    for f in files:
        by_base.setdefault(f.rsplit("/", 1)[-1].rsplit(".", 1)[0].lower(), []).append(f)
    same_name, siblings = [], []
    for a in added:
        base = a.rsplit("/", 1)[-1].rsplit(".", 1)[0].lower()
        others = [f for f in by_base.get(base, []) if f not in changed and not skip.search(f)]
        if others and base not in generic:
            same_name.append((a, others[:5]))
        suf = role_suffix(a.rsplit("/", 1)[-1])
        if suf:
            cands = [f for f in files if f.endswith(suf) and f not in changed and not skip.search(f)]
            cands.sort(key=lambda f: (-closeness(a, f), f.count("/"), f))
            if cands:
                siblings.append((a, suf, cands[:5]))
    with open(out, "w") as fh:
        fh.write("# deep-review repo profile\n\n## Shared-code directories (files)\n")
        for d, n in sorted(shared_dirs.items(), key=lambda kv: -kv[1])[:80]:
            fh.write(f"{n}\t{d}\n")
        fh.write("\n## Same-name files elsewhere (possible re-implementation)\n")
        for a, others in same_name:
            fh.write(f"{a}\t{', '.join(others)}\n")
        fh.write("\n## Sibling candidates by naming role (pattern reference)\n")
        for a, suf, c in siblings:
            fh.write(f"{a}\t{suf}\t{', '.join(c)}\n")
        fh.write("\n## Shared exports (symbol\tfile): top-level declarations only; grep the repo for methods — check before accepting a new helper\n")
        for sym, f in sorted(exports):
            fh.write(f"{sym}\t{f}\n")
    summary = {"shared_dirs": len(shared_dirs), "exports": len(exports), "same_name": len(same_name), "siblings": len(siblings), "file": str(out)}
    event("profile", **summary)
    return summary


# ---------------------------------------------------------------- evidence anchors

ANCHOR = re.compile(r"`([^`@\s]+)@([0-9a-f]{7,40})`")
ITEM = re.compile(r"^\s*- \[( |x)\] (?:\*\*)?(.+?)(?:\*\*)?(?: — .*)?$")


def blob_of(path: str, worktree: bool) -> str | None:
    root = repo_root()
    if worktree:
        p = root / path
        if not p.is_file():
            return None
        return git("hash-object", "--", str(p), cwd=root).strip()
    r = subprocess.run(["git", "rev-parse", f"HEAD:{path}"], capture_output=True, text=True, cwd=root)
    return r.stdout.strip() if r.returncode == 0 else None


def evidence(review: Path, worktree: bool) -> list[dict]:
    rows, current_item, checked = [], None, False
    for n, line in enumerate(review.read_text().splitlines(), start=1):
        m = ITEM.match(line)
        if m and not ANCHOR.search(line.split(" — ")[0]):
            current_item, checked = m.group(2).strip(), m.group(1) == "x"
        for am in ANCHOR.finditer(line):
            path, recorded = am.group(1), am.group(2)
            cur = blob_of(path, worktree)
            if cur is None:
                status = "missing"
            elif cur.startswith(recorded):
                status = "unchanged"
            else:
                status = "changed"
            rows.append({"line": n, "item": current_item, "done": checked, "path": path, "recorded": recorded, "current": (cur or "")[:12], "status": status})
    event("evidence", total=len(rows), unchanged=sum(r["status"] == "unchanged" for r in rows))
    return rows


# ---------------------------------------------------------------- CLI

def print_tsv(rows: list[dict], cols: list[str]) -> None:
    print("\t".join(cols))
    for r in rows:
        print("\t".join(str(r.get(c, "")) if not isinstance(r.get(c), list) else ",".join(map(str, r.get(c))) for c in cols))


def cmd_checks(a) -> int:
    cat = Catalog()
    if a.lint:
        for e in cat.errors:
            print(f"error: {e}")
        for w in cat.warnings:
            print(f"warning: {w}")
        for i in cat.infos:
            print(f"info: {i}")
        print(f"{len(cat.checks)} checks in {len(cat.packs)} packs + core; {len(cat.errors)} errors, {len(cat.warnings)} warnings")
        return 1 if cat.errors else 0
    cfg = load_resolved(a.config) if a.config else None
    only = set(split_list(a.packs)) if a.packs else None
    rows = []
    for cid, ch in sorted(cat.checks.items(), key=lambda kv: (kv[1].pack != "core", kv[1].pack, kv[0])):
        if only is not None and ch.pack != "core" and ch.pack not in only:
            continue
        r = {"id": cid, "layer": ch.layer, "pack": ch.pack, **{k: ch.meta.get(k, "") for k in META_REQUIRED},
             "tags": ch.meta.get("tags", []), "instance-of": ch.meta.get("instance-of", ""), "file": f"{ch.file}:{ch.line}"}
        if cfg:
            st = effective_check(cfg, cid, a.path)
            r.update(enabled="on" if st["enabled"] else "off", effective_severity=st["severity"], decided_by=st["decided_by"],
                     severity_by=st.get("severity_by", "default"))
        rows.append(r)
    if a.json:
        print(json.dumps(rows, indent=1))
        return 0
    cols = ["id", "pack", "kind", "safety", "default", "severity", "scope", "pass", "tags", "instance-of"]
    if cfg:
        cols += ["enabled", "effective_severity", "decided_by", "severity_by"]
    if a.format == "md":
        print("| " + " | ".join(cols) + " |")
        print("|" + "---|" * len(cols))
        for r in rows:
            print("| " + " | ".join(",".join(r[c]) if isinstance(r[c], list) else str(r[c]) for c in cols) + " |")
    else:
        print_tsv(rows, cols + (["file"] if a.verbose else []))
    return 0


def cmd_config(a) -> int:
    if a.action == "resolve":
        res = resolve_config(a)
        text = json.dumps(res, indent=1, sort_keys=True, default=str)
        if a.out:
            Path(a.out).write_text(text + "\n")
        else:
            print(text)
        for w in res["warnings"]:
            print(f"deep-review: config warning: {w}", file=sys.stderr)
        for e in res["errors"] + res["catalog_errors"]:
            print(f"deep-review: config error: {e}", file=sys.stderr)
        event("config_resolved", hash=res["hash"], errors=len(res["errors"]), warnings=len(res["warnings"]),
              sources=[s["file"] for s in res["sources"]], suppressed_safety=len(res["suppressed_safety"]))
        return 2 if res["errors"] else 0
    if a.action in ("explain", "check"):
        if not a.resolved or not a.id:
            die(f"usage: config.sh {a.action} <resolved.json> <check-id> [--path P]")
        cfg = load_resolved(a.resolved)
        st = effective_check(cfg, a.id, a.path)
        if not st["known"]:
            die(f"unknown check id '{a.id}'", 3)
        if a.action == "check":
            print(f"{'enabled' if st['enabled'] else 'disabled'}\t{st['severity']}\t{st['decided_by']}\t{st.get('severity_by', 'default')}")
        else:
            print(f"{a.id}: {'ENABLED' if st['enabled'] else 'DISABLED'} · severity {st['severity']} · decided by {st['decided_by']}")
            for t in st["trace"]:
                print(f"  - {t}")
            for acc in cfg["accepted"]:
                if acc["fingerprint"].startswith(a.id + ":"):
                    print(f"  - accepted: {acc['fingerprint']} ({'expired' if acc['expired'] else 'active'}) — {acc['reason']}")
        return 0
    if a.action == "hash":
        print(json.loads(Path(a.resolved).read_text())["hash"])
        return 0
    if a.action == "sources":
        for layer, p in config_files():
            print(f"{layer}\t{p}")
        return 0
    if a.action == "init":
        cat = Catalog()
        tmpl = (SKILL_DIR / "templates" / "config.toml").read_text()
        off = [(cid, ch) for cid, ch in sorted(cat.checks.items()) if ch.meta.get("default") == "off"]
        lines = [f'#   {{ id = "{cid}" }},{" " * max(1, 44 - len(cid))}# {ch.pack}, tags: {",".join(ch.meta.get("tags", []))}' for cid, ch in off]
        print(tmpl.replace("{{OPT_IN_CHECKS}}", "\n".join(lines)))
        return 0
    die(f"unknown config action {a.action}")
    return 1


def read_scope(path: str | None) -> list[dict]:
    if path and path != "-" and not Path(path).is_file():
        die(f"scope file {path} not found (write it with: review-scope.sh --out {path})")
    src = open(path) if path and path != "-" else sys.stdin
    rows = []
    for line in src:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 6:
            rows.append({"status": parts[0], "added": parts[1], "deleted": parts[2], "kind": parts[3], "area": parts[4], "path": parts[5]})
    return rows


def cmd_detect(a) -> int:
    cfg = json.loads(Path(a.config).read_text()) if a.config else None
    rows = read_scope(a.scope) if (a.scope or not sys.stdin.isatty()) else []
    res = detect(cfg, rows, a.explain)
    if a.json:
        print(json.dumps(res, indent=1))
        return 0
    print("status\tid\tlayer\tkind\tmaturity\tchanged_files\tfile")
    for r in res["packs"]:
        if r["status"] == "inactive" and not a.explain:
            continue
        print(f"{r['status']}\t{r['id']}\t{r['layer']}\t{r['kind']}\t{r['maturity']}\t{r['changed_matched']}\t{r['file']}")
        if a.explain:
            for why in r["reasons"] or ["no detection rule matched"]:
                print(f"  why: {why}")
            for p in r["paths"][:20]:
                print(f"  applies-to: {p}")
    if res["uncovered_by_language_pack"]:
        items = ", ".join(f".{k} ({v})" for k, v in sorted(res["uncovered_by_language_pack"].items(), key=lambda kv: -kv[1]))
        print(f"uncovered\t{items}")
    for e in res["catalog_errors"]:
        print(f"deep-review: pack error: {e}", file=sys.stderr)
    return 0


def cmd_profile(a) -> int:
    rows = read_scope(a.scope)
    s = profile(rows, Path(a.out))
    print(json.dumps(s))
    return 0


def cmd_evidence(a) -> int:
    rows = evidence(Path(a.review), a.worktree)
    if a.json:
        print(json.dumps(rows, indent=1))
    else:
        print_tsv(rows, ["status", "done", "line", "path", "recorded", "current", "item"])
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="dr.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("checks")
    c.add_argument("--lint", action="store_true")
    c.add_argument("--config")
    c.add_argument("--path")
    c.add_argument("--packs")
    c.add_argument("--json", action="store_true")
    c.add_argument("--format", choices=["tsv", "md"], default="tsv")
    c.add_argument("--verbose", action="store_true")

    g = sub.add_parser("config")
    g.add_argument("action", choices=["resolve", "explain", "check", "hash", "sources", "init"])
    g.add_argument("resolved", nargs="?")
    g.add_argument("id", nargs="?")
    g.add_argument("--path")
    g.add_argument("--out")
    g.add_argument("--strict", action="store_true")
    g.add_argument("--enable", action="append")
    g.add_argument("--disable", action="append")
    g.add_argument("--severity", action="append")
    g.add_argument("--acknowledge-risk", action="store_true", help="allow --disable of safety checks")

    d = sub.add_parser("detect")
    d.add_argument("--config")
    d.add_argument("--scope")
    d.add_argument("--explain", action="store_true")
    d.add_argument("--json", action="store_true")

    pr = sub.add_parser("profile")
    pr.add_argument("--scope", required=True)
    pr.add_argument("--out", required=True)

    e = sub.add_parser("evidence")
    e.add_argument("review")
    e.add_argument("--worktree", action="store_true")
    e.add_argument("--json", action="store_true")

    a = p.parse_args()
    return {"checks": cmd_checks, "config": cmd_config, "detect": cmd_detect, "profile": cmd_profile, "evidence": cmd_evidence}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
