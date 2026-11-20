#!/usr/bin/env python3
"""Compute waves of independent tasks from a writing-plans plan.

usage: python3 waves.py <plan.md> [--json]
"""
import json
import re
import sys

NOISE = {"None", "str", "int", "float", "bool", "dict", "list", "tuple", "set",
         "True", "False", "{}", "[]"}
IDENT = re.compile(r"[A-Za-z_][\w.-]*")
TICK = re.compile(r"`([^`]+)`")
FIXTURE_SENTENCE = re.compile(r"\bfixtures?\b.*\bexist|\bexist\w*\b.*\bfixtures?\b", re.I)
CONSUMES_ALL = re.compile(r"\b(?:everything|all)\s+(?:above|previous|earlier|prior)\b", re.I)
FILE_BULLET = re.compile(r"\s*- (Create|Modify|Test|Fixtures?)\b([^:]*):")


def expand(path):
    path = re.sub(r":\d[\d-]*$", "", path.strip())
    if path.startswith("./"):
        path = path[2:]
    m = re.search(r"\{([^{}]*,[^{}]*)\}", path)
    if not m:
        return [path]
    return [p for alt in m.group(1).split(",")
            for p in expand(path[:m.start()] + alt + path[m.end():])]


def block(lines, label):
    """Lines of a **Label:** block (inline remainder first), up to the next bold label or step."""
    for i, line in enumerate(lines):
        if line.startswith("**%s:**" % label):
            out = [line[len(label) + 5:]]
            for nxt in lines[i + 1:]:
                if nxt.startswith("**") or nxt.startswith("- [ ]"):
                    break
                out.append(nxt)
            return out
    return []


def section(lines, label):
    """A `- Label:` bullet plus its more-indented sub-bullets."""
    out, indent = [], None
    for line in lines:
        cur = len(line) - len(line.lstrip())
        if indent is None:
            if re.match(r"\s*- %s:" % label, line):
                indent, out = cur, [line]
        elif line.strip() and cur <= indent:
            indent = None
        else:
            out.append(line)
    return out


def ident(token):
    name = token.split("(")[0].strip()
    return name if IDENT.fullmatch(name) and name not in NOISE else None


def parse_plan(text):
    parts = re.split(r"^### Task (\d+)[:.]?\s*(.*)$", text, flags=re.M)
    tasks = []
    for i in range(1, len(parts), 3):
        lines = re.split(r"^## ", parts[i + 2], flags=re.M)[0].splitlines()
        files, readonly = set(), set()
        fl = block(lines, "Files")
        if fl:  # inline line: drop sentences about existing fixtures
            inline = " ".join(s for s in re.split(r"\.\s", fl[0]) if not FIXTURE_SENTENCE.search(TICK.sub("", s)))
            files.update(p for t in TICK.findall(inline) for p in expand(t))
        for line in fl[1:]:
            m = FILE_BULLET.match(line)
            if not m:
                continue
            paths = {p for t in TICK.findall(line[m.end():]) for p in expand(t)}
            (readonly if m.group(1).startswith("Fixture") and "(exist" in m.group(2)
             else files).update(paths)
        il = block(lines, "Interfaces")
        cons = " ".join(section(il, "Consumes"))
        ctoks = TICK.findall(cons)
        ptoks = TICK.findall(" ".join(section(il, "Produces")))
        tasks.append({
            "n": int(parts[i]), "title": parts[i + 1].strip(),
            "files": files, "readonly": readonly,
            "consumes_ids": {x for x in map(ident, ctoks) if x},
            "consumes_all": bool(CONSUMES_ALL.search(cons)),
            "consumes_tasks": {int(n) for n in re.findall(r"\bTask (\d+)", cons)},
            "consumes_paths": {p for t in ctoks for p in expand(t)},
            "produces_ids": {x for x in map(ident, ptoks) if x},
            "files_known": bool(files or readonly),
        })
    return tasks


def short(name):
    return name.rsplit(".", 1)[-1]


def edges(tasks):
    out = []
    for i, t in enumerate(tasks):
        for u in tasks[:i]:
            if not t["files_known"]:
                reasons = ["no Files block"]
            else:
                reasons = []
                if t["consumes_all"]:
                    reasons.append("consumes everything above")
                if u["n"] in t["consumes_tasks"]:
                    reasons.append("consumes Task %d" % u["n"])
                prod = {short(p) for p in u["produces_ids"]}
                reasons += ["consumes %s" % c for c in sorted(t["consumes_ids"]) if short(c) in prod]
                reasons += ["consumes %s" % p for p in sorted(t["consumes_paths"] & u["files"])]
                reasons += ["file %s" % f for f in sorted(t["files"] & u["files"])]
            if reasons:
                out.append({"from": u["n"], "to": t["n"], "reason": "; ".join(dict.fromkeys(reasons))})
    return out


def waves(tasks, edges, cap=5):
    level = {}
    for t in tasks:
        level[t["n"]] = 1 + max((level[e["from"]] for e in edges
                                 if e["to"] == t["n"] and e["from"] in level), default=0)
    out = []
    for w in sorted(set(level.values())):
        group = [n for n in level if level[n] == w]
        out += [group[i:i + cap] for i in range(0, len(group), cap)]
    return out


def table(tasks, es, ws):
    known = {t["n"]: t["files_known"] for t in tasks}
    rows = ["| Wave | Tasks | Waits for |", "|---|---|---|"]
    for i, w in enumerate(ws, 1):
        waits = []
        for n in w:
            mine = [e for e in es if e["to"] == n]
            if not known[n] and mine:
                waits.append("T%d after all earlier: no Files block" % n)
            else:
                waits += ["T%d after T%d: %s" % (n, e["from"], e["reason"]) for e in mine]
        rows.append("| %d | %s | %s |" % (i, ", ".join("T%d" % n for n in w),
                                          "; ".join(waits) or "-"))
    return "\n".join(rows)


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(argv[0]) as f:
        tasks = parse_plan(f.read())
    if not tasks:
        print("no '### Task' headings in %s" % argv[0], file=sys.stderr)
        return 1
    es = edges(tasks)
    ws = waves(tasks, es)
    print(json.dumps({"waves": ws, "edges": es}) if "--json" in argv[1:] else table(tasks, es, ws))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
