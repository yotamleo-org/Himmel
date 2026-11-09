#!/usr/bin/env python3
"""route-rows.py -- the RAG pilot's arm-tagged trace/route rows and shared outcome classifier.

  route-rows.py row --arm V|S|Q --transcript T.jsonl [--meta BROKER_META] --result R.json --policy P.json
  route-rows.py task --row V.json --row S.json --row Q.json

`row` reads one answer session's transcript (the Claude session JSONL, collected after exit),
the host broker's private events for that session (S/Q) and the CLI result, and prints one
private route row: tool-use ids, s-qmd and s-graph calls (counted per invocation, also inside
one Bash pipeline), first route, qmd-only/graph-only/both use, empty results, cap refusals,
dropped hits, graph errors, returned files and which were later read or cited, allowed runtime
reads versus forbidden reads (blocked or content returned), integrity events, Q remote
attempts, and the design section 5 classification: service failure, answer-phase retrieval
skips (probe/fixed-phase events never count), scorable. It exits 3 when the transcript's s-qmd
invocations do not reconcile with the broker's answer-phase admissions (P5 red).

`task` joins one task's three rows: a service failure in any arm or a skip in S/Q excludes the
whole triple once, keeping every reason; any S/Q skip counts toward the two-task skip ceiling
even when a service failure co-occurs; a hard abort is reported, never downgraded.
"""
import argparse, json, re, shlex, sys

BLOCKED = re.compile(r"denied|not permitted|Permission|No such file|does not exist|outside (the )?allowed|blocked", re.I)
ANSWER_RE = re.compile(r"^ANSWER:(.*)$", re.M)
FILES_RE = re.compile(r"^FILES:\s*$", re.M)
PATH_RE = re.compile(r"(/work/(?:himmel|luna)/[^\s:'\"`]+)")


def load_jsonl(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        out.append({"type": "corrupt"})
    except OSError:
        pass
    return out


def tool_events(transcript):
    uses, results = [], {}
    for e in transcript:
        content = (e.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            if c.get("type") == "tool_use":
                uses.append(c)
            elif c.get("type") == "tool_result":
                body = c.get("content")
                if isinstance(body, list):
                    body = "\n".join(x.get("text", "") for x in body if isinstance(x, dict))
                results[c.get("tool_use_id")] = (str(body or ""), bool(c.get("is_error")))
    return uses, results


def segments(cmd):
    """Each simple command of a Bash line: split on pipes and list operators, then shell words."""
    out = []
    for part in re.split(r"\|\||&&|;|\||\n", cmd):
        try:
            words = shlex.split(part)
        except ValueError:
            words = part.split()
        while words and "=" in words[0] and not words[0].startswith(("/", ".")):
            words = words[1:]
        if words:
            out.append(words)
    return out


def under(path, roots):
    return any(path == r or path.startswith(r.rstrip("/") + "/") for r in roots)


def tool_paths(use):
    inp = use.get("input") or {}
    if use.get("name") == "Bash":
        return re.findall(r"(/[^\s'\"`|;&<>()]+)", inp.get("command", ""))
    return [p for p in (inp.get("file_path"), inp.get("path")) if p]


def parse_answer(result_text):
    m = ANSWER_RE.search(result_text or "")
    fm = FILES_RE.search(result_text or "")
    if not m or not fm:
        return False, []
    files = [l.strip() for l in result_text[fm.end():].splitlines() if l.strip()]
    return True, files[:3]


def classify_result(path):
    """service reasons and (answer_block, files) from the CLI result file."""
    try:
        with open(path) as f:
            raw = f.read()
        r = json.loads(raw)
        if not isinstance(r, dict):
            raise ValueError
    except (OSError, ValueError):
        return ["no_cli_json"], False, [], None
    if r.get("subtype") == "error_max_budget_usd":   # an explicit budget stop is scored false, never service
        return [], False, [], r
    if r.get("is_error") or r.get("subtype") not in (None, "success"):
        return ["provider_or_auth_error"], False, [], r
    block, files = parse_answer(str(r.get("result", "")))
    return [], block, files, r


def row(a):
    pol = json.load(open(a.policy))
    uses, results = tool_events(load_jsonl(a.transcript))
    events = load_jsonl(a.meta + "/events.jsonl") if a.meta else []
    r = {"arm": a.arm, "tool_uses": len(uses), "unmatched_tool_uses": sum(1 for u in uses if u.get("id") not in results),
         "tools": {}, "route_events": [], "qmd_calls": 0, "graph_calls": 0, "first_route": None,
         "empty_results": 0, "cap_refusals": 0, "graph_errors": 0, "runtime_reads": 0,
         "forbidden_blocked": 0, "forbidden_content_returned": 0, "integrity": []}
    returned, read_after = [], set()
    for u in uses:
        name = u.get("name")
        r["tools"][name] = r["tools"].get(name, 0) + 1
        body, err = results.get(u.get("id"), ("", True))
        paths = tool_paths(u)
        if any(under(p, pol["channel_paths"]) for p in paths):
            r["integrity"].append("channel_access")
        for p in paths:
            if under(p, pol["forbidden_roots"]):
                if err or BLOCKED.search(body):
                    r["forbidden_blocked"] += 1
                else:
                    r["forbidden_content_returned"] += 1
            elif under(p, pol["runtime_roots"]):
                r["runtime_reads"] += 1
        for p in paths:
            if under(p, pol["work_roots"]) and p in returned:
                read_after.add(p)
        kind = name
        if name == "Bash":
            words = [s[0] for s in segments((u.get("input") or {}).get("command", ""))]
            base = [w.rsplit("/", 1)[-1] for w in words]
            nq, ng = base.count("s-qmd"), base.count("s-graph")
            if any(w in pol["qmd_binaries"] or (b == "qmd" and w.startswith("/")) for w, b in zip(words, base)):
                r["integrity"].append("direct_qmd")
            r["qmd_calls"] += nq
            r["graph_calls"] += ng
            if nq or ng:
                kind = "s-qmd" if nq else "s-graph"
                r["route_events"].append({"tool_use_id": u.get("id"), "s-qmd": nq, "s-graph": ng})
                if "s-qmd: no results" in body:
                    r["empty_results"] += body.count("s-qmd: no results")
                if "query limit reached" in body:
                    r["cap_refusals"] += 1
                if ng and "s-graph: graph unavailable" in body:
                    r["graph_errors"] += 1
                for p in PATH_RE.findall(body):
                    if p not in returned:
                        returned.append(p)
            elif base:
                kind = base[0]
        if r["first_route"] is None:
            r["first_route"] = kind
    ans = [e for e in events if e.get("phase", "answer") == "answer"]
    admits = sum(1 for e in ans if e.get("kind") == "admit")
    cap_refused = sum(1 for e in ans if e.get("kind") == "cap_refused")
    terms = [e for e in ans if e.get("kind") == "terminal"]
    r["broker_admits"] = admits
    r["reconciled"] = admits + cap_refused == r["qmd_calls"] if a.arm in ("S", "Q") else r["qmd_calls"] == 0
    r["dropped_hits"] = sum(e.get("dropped") or 0 for e in terms)
    r["skip_reasons"] = sorted({x for e in terms for x in e.get("skip_reasons", [])})
    r["skips"] = sum(1 for e in terms if e.get("skip"))
    r["probe_or_fixed_skips_ignored"] = sum(1 for e in events if e.get("kind") == "terminal" and e.get("phase", "answer") != "answer" and e.get("skip"))
    r["raw_query_only"] = sum(1 for e in terms if e.get("expansion") == "raw_query_only")
    r["q_remote_attempts"] = sum(1 for e in terms if "q_remote_attempt" in e.get("skip_reasons", []))
    r["integrity"] += [e.get("what") for e in events if e.get("kind") == "integrity"]
    r["integrity"] = sorted(set(r["integrity"]))
    r["route_use"] = {(True, True): "both", (True, False): "qmd_only", (False, True): "graph_only", (False, False): "none"}[(r["qmd_calls"] > 0, r["graph_calls"] > 0)]
    service, block, files, res = classify_result(a.result)
    r["service"] = service
    r["answer_block"] = block
    r["cited"] = files
    r["returned_files"] = len(returned)
    r["returned_read"] = len(read_after)
    r["cited_returned"] = sum(1 for p in files if p in returned)
    r["cost_usd"] = (res or {}).get("total_cost_usd")
    r["usage"] = (res or {}).get("usage")
    r["skip_union"] = a.arm in ("S", "Q") and r["skips"] > 0
    r["hard_abort"] = bool(r["forbidden_content_returned"] or r["integrity"])
    r["scorable"] = not service and not r["skip_union"] and not r["hard_abort"]
    print(json.dumps(r, sort_keys=True))
    return 0 if r["reconciled"] else 3


def task(a):
    rows = [json.load(open(p)) for p in a.row]
    reasons, skip_counted, hard = {}, False, False
    for r in rows:
        why = list(r.get("service", []))
        if r["arm"] in ("S", "Q") and r.get("skips"):
            why += r.get("skip_reasons", []) or ["skip"]
            skip_counted = True
        if r.get("hard_abort"):
            hard = True
            why += ["hard_abort"]
        if why:
            reasons[r["arm"]] = sorted(set(why))
    print(json.dumps({"excluded": bool(reasons), "hard_abort": hard, "reasons": reasons, "skip_counted": skip_counted}, sort_keys=True))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="route-rows.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("row")
    r.add_argument("--arm", required=True, choices=["V", "S", "Q"])
    r.add_argument("--transcript", required=True); r.add_argument("--meta", default="")
    r.add_argument("--result", required=True); r.add_argument("--policy", required=True)
    t = sub.add_parser("task")
    t.add_argument("--row", action="append", required=True)
    a = p.parse_args(argv)
    return row(a) if a.cmd == "row" else task(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
