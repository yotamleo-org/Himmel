#!/usr/bin/env python3
"""scripts/eval/review-panel/replay.py - rescore retained review-panel bundles into a NEW scratch directory.

  replay.py --results FILE --eval-ledger FILE --artifacts-root DIR --out NEW_DIR [--repo DIR]

For every committed results.jsonl row and every review-panel eval-ledger row it finds the retained bundle
(<artifacts-root>/<run_id> for a results row, the basename of the ledger row's artifact for a ledger row), checks the
bundle's execution stamp against ITS recorded execution tree (never today's scoring tree), rescores the cases whose
supplied input bytes match the scoring revision's under the running committed scorer, and writes
  candidate-results.jsonl, candidate-eval-runs.jsonl, verification.json, manifests/<run_id>.json
into --out, which must not exist. Nothing else is written: the inputs, the bundles and every live ledger are read
only, and there is no default for any path. A candidate row keeps the execution's cbs_hash and confighash and the
original execution_id, names the row it supersedes (supersedes_run_id) and carries the scoring identity on its own;
eval_feedback.select_review_runs reads the chain. verification.json gives every supplied row a disposition:
rescored | diagnostic-only (rescored, ineligible, reasons named) | failed (a named failure, no candidate).
A failure is never an omitted row: missing-artifact, unsafe-bundle-name, bundle-digest-mismatch,
execution-stamp-mismatch, contradictory-mapping, no-case-replayable, unreadable-row, candidate-row-invalid.
A changed diff, context or intent for a case cannot be manufactured from old outputs: that case is not rescored
and the row is partial and ineligible. A gold-label-only change does not change the inputs, so it replays.
Promotion into tracked rows is a separate, maintainer-approved step.

Exit: 0 written, 2 refused (existing --out, an --out inside the artifacts root, an unreadable input).
Stdlib only; no network, no model call.
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_feedback  # noqa: E402
import eval_runs  # noqa: E402
import score  # noqa: E402

SAFE_NAME = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]*$")


def _digest(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def read_jsonl(path):
    """(rows, bad line numbers): the dict lines of path, file order. Read only."""
    rows, bad = [], []
    with open(path, encoding="utf-8") as fh:
        for n, ln in enumerate(fh, 1):
            if not ln.strip():
                continue
            try:
                r = json.loads(ln)
            except ValueError:
                r = None
            if isinstance(r, dict):
                rows.append(r)
            else:
                bad.append(n)
    return rows, bad


def file_sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def case_inputs(repo, rev, cache={}):
    """{case id: digest of its supplied inputs (every fixtures/<id>.* file, the key's base)} at <rev>."""
    if (repo, rev) in cache:
        return cache[(repo, rev)]
    key = json.loads(score.tree_key(repo, rev))["cases"]
    pre = score.FIXTURES_REL + "/"
    blobs = {f[len(pre):]: score.tree_blob(repo, rev, f) for f in score.tree_files(repo, rev)
             if f.startswith(pre) and "/" not in f[len(pre):]}
    out = {}
    for cid, c in key.items():
        h = hashlib.sha256()
        for n in sorted(n for n in blobs if n.startswith(cid + ".")):
            h.update(n.encode() + b"\0" + hashlib.sha256(blobs[n]).digest())
        h.update(json.dumps(c.get("base"), sort_keys=True).encode())
        out[cid] = h.hexdigest()
    cache[(repo, rev)] = out
    return out


def has_commit(repo, rev):
    try:
        score._git(repo, "cat-file", "-e", "%s^{commit}" % rev)
        return True
    except ValueError:
        return False


def read_stamp(bundle):
    try:
        with open(os.path.join(bundle, score.STAMP), encoding="utf-8") as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else None
    except (OSError, ValueError):
        return None


def replay_row(src, kind, repo, root, out, scoring, partner, digests):
    """(item, candidate row or None) for one source row. kind is results | eval-ledger."""
    run_id = src.get("run_id")
    item = {"source": kind, "run_id": run_id, "row_sha256": _digest(src), "failure": None, "changed_fields": [],
            "provenance": "unknown", "reasons": [], "supersedes_run_id": None, "disposition": "failed"}
    name = run_id if kind == "results" else os.path.basename(str(src.get("artifact") or ""))
    item["bundle"] = name or None
    if not isinstance(name, str) or not name or not SAFE_NAME.match(name):
        item["failure"] = "unsafe-bundle-name"
        return item, None
    if kind == "results" and len(digests.get(run_id, ())) > 1:
        item["failure"] = "contradictory-mapping"
        item["detail"] = "rows of this run_id record %d different bundle digests" % len(digests[run_id])
        return item, None
    bundle = os.path.join(root, name)
    if not os.path.isdir(bundle):
        item["failure"] = "missing-artifact"
        return item, None
    raw = score.outputs_sha256(bundle)
    recorded = src.get("outputs_sha256") if kind == "results" else (partner or {}).get("outputs_sha256")
    reasons = []
    if recorded is not None and recorded != raw:
        item["failure"] = "bundle-digest-mismatch"
        return item, None
    if recorded is None:
        reasons.append("bundle-bytes-unbound")

    # The execution stamp is held to its own recorded tree, never the scoring tree. A ledger row's confighash names
    # its own series (a critics-and-window config), not the stamp's, so only a results row is held to the stamp's.
    stamp = read_stamp(bundle)
    row_src = src if kind == "results" else partner or {}
    if stamp is None:
        reasons.append("stamp-missing")
        tree = row_src.get("tree")
        if tree:
            reasons.append("execution-tree-from-row")
    else:
        tree = stamp.get("tree")
        if stamp.get("clean") is not True or stamp.get("rechecked") is False:
            reasons.append("sweep-unclean")
    exec_cbs = (stamp or {}).get("cbs_hash") or row_src.get("cbs_hash")
    exec_conf = (stamp or {}).get("confighash") or row_src.get("confighash")
    available = bool(tree) and has_commit(repo, tree)
    if stamp is not None:
        for field, compute in (("cbs_hash", score.cbs_hash), ("confighash", score.confighash)):
            if (available and stamp.get(field) != compute(repo, tree)) \
                    or row_src.get(field) not in (None, stamp.get(field)):
                item["failure"] = "execution-stamp-mismatch"
                item["detail"] = "%s differs between the stamp, its recorded execution tree and the row" % field
                return item, None
    if not available:
        reasons.append("execution-tree-unavailable")

    # which cases the scoring revision's inputs reproduce
    now_inputs = case_inputs(repo, "HEAD")
    absent = []
    if available:
        then = case_inputs(repo, tree)
        replayable = sorted(c for c in now_inputs if then.get(c) == now_inputs[c])
        changed = sorted(c for c in now_inputs if c in then and then[c] != now_inputs[c])
        absent = sorted(c for c in now_inputs if c not in then)
    else:
        replayable, changed = sorted(now_inputs), []
        reasons.append("case-inputs-unverified")
    item["changed_cases"], item["cases_not_in_execution_corpus"] = changed, len(absent)
    if not replayable:
        item["failure"] = "no-case-replayable"
        return item, None
    if changed:
        reasons.append("changed-case-input:%d" % len(changed))
    if absent:
        reasons.append("case-not-in-execution-corpus:%d" % len(absent))
    subset = bool(changed or absent)

    row, res = score.score_row(repo, "HEAD", bundle, roster_rev=tree if available else "HEAD",
                               only=replayable if subset else None)
    manifest_state = row.get("provenance_status")
    legacy = manifest_state == "missing"
    exec_id = row.get("execution_id") or "legacy-" + hashlib.sha256(raw.encode()).hexdigest()[:24]
    all_reasons = list(dict.fromkeys(row["ineligibility_reasons"] + reasons))
    if legacy:
        row["provenance_status"] = "reconstructed"
        item["provenance"] = "reconstructed"
    else:
        item["provenance"] = "recorded" if manifest_state == "recorded" else "unknown"
    new_id = "%s~%s" % (run_id, (row["scorer_sha256"] or "unverified")[:12])
    status = "partial" if subset and res["status"] == "ok" else res["status"]
    row.update(run_id=new_id, execution_id=exec_id, supersedes_run_id=run_id, status=status,
               cbs_hash=exec_cbs or row["cbs_hash"], confighash=exec_conf or row["confighash"],
               tree=tree if available else row["tree"], decision_eligible=not all_reasons,
               ineligibility_reasons=all_reasons)
    sidecar = None
    if legacy:
        sidecar = {"v": 1, "execution_id": exec_id, "reconstructed": True, "outputs_sha256": raw,
                   "bundle_sha256_v2": row["bundle_sha256_v2"], "stamp": stamp, "roster": res["critics"],
                   "provenance": {"status": "reconstructed", "evidence": ["swept.json" if stamp else "result row"],
                                  "unknown": ["responding_models", "requested_effort", "overrides"]}}
        os.makedirs(os.path.join(out, "manifests"), exist_ok=True)
        with open(os.path.join(out, "manifests", name + ".json"), "w", encoding="utf-8") as fh:
            json.dump(sidecar, fh, sort_keys=True, indent=1)
    row["replay"] = {
        "source": kind, "source_run_id": run_id, "source_row_sha256": item["row_sha256"], "bundle": name,
        "execution_corpus": {"tree": tree if available else None, "cbs_hash": exec_cbs, "confighash": exec_conf,
                             "case_inputs_sha256": _digest(case_inputs(repo, tree)) if available else None},
        "scoring": {"scorer_sha256": row["scorer_sha256"], "key_sha256": scoring["key_sha256"],
                    "cases_rescored": len(replayable), "cases_changed": changed, "cases_absent": len(absent)},
        "manifest_sha256": _digest(sidecar) if sidecar else None}

    # what the rescore changed against the row it supersedes
    old = src if kind == "results" else {"status": src.get("status"), "metrics": src.get("metrics"),
                                         "confighash": src.get("confighash"),
                                         "coverage": (src.get("meta") or {}).get("coverage")}
    new = row if kind == "results" else {"status": status, "metrics": res["metrics"],
                                         "confighash": src.get("confighash"), "coverage": res["coverage"]}
    item["changed_fields"] = sorted(f for f in ("status", "confighash", "responded", "coverage")
                                    if f in old and old.get(f) != (new.get(f) if f != "responded" else row.get(f)))
    old_m, new_m = old.get("metrics") or {}, new.get("metrics") or {}
    moved = sorted(k for k in old_m if k in new_m and old_m[k] != new_m[k])
    if moved:
        item["changed_fields"].append("metrics")
        item["metrics_changed"] = moved
    if kind == "results" and isinstance(src.get("responded"), dict):
        item["participation"] = {"before": src["responded"], "after": row["responded"]}
    item.update(candidate_run_id=new_id, supersedes_run_id=run_id, execution_id=exec_id, scorer_sha256=row["scorer_sha256"],
                reasons=all_reasons, disposition="rescored" if not all_reasons else "diagnostic-only")
    if kind == "eval-ledger":
        cand = dict(src, run_id=new_id, status=status, metrics=res["metrics"], ci=res["ci"], cases=res["cases"] or None,
                    ts=score._now(),
                    meta=dict(src.get("meta") or {}, leaks=res["leaks"], unscored=res["unscored"], coverage=res["coverage"],
                              decision_eligible=not all_reasons, ineligibility_reasons=all_reasons,
                              scorer_sha256=row["scorer_sha256"], scorer_gitsha=row["scorer_gitsha"],
                              scorer_reason=row["scorer_reason"], execution_id=exec_id, supersedes_run_id=run_id,
                              provenance_status=row["provenance_status"], bundle_sha256_v2=row["bundle_sha256_v2"],
                              code_under_test_sha=row.get("code_under_test_sha"), scored_at=row["scored_at"],
                              replay=row["replay"]))
        problems = eval_runs.validate(cand)
        if problems:
            item.update(failure="candidate-row-invalid", detail="; ".join(problems), disposition="failed")
            return item, None
        return item, cand
    return item, row


def replay(results, ledger, root, out, repo=None):
    """Write the candidate rows and verification.json into the new directory out; returns verification."""
    repo = repo or score.toplevel()
    res_rows, res_bad = read_jsonl(results)
    led_rows, led_bad = read_jsonl(ledger)
    led_panel = [r for r in led_rows if r.get("eval") == "review-panel"]
    ident = score.running_scorer_identity()
    with open(os.path.join(repo, score.KEY_REL), "rb") as fh:
        scoring = {"key_sha256": hashlib.sha256(fh.read()).hexdigest()}
    os.makedirs(out)
    partner_of = {}
    digests = {}
    for r in res_rows:
        partner_of.setdefault(r.get("run_id"), r)
        digests.setdefault(r.get("run_id"), set()).add(r.get("outputs_sha256"))
    items, cand_results, cand_ledger = [], [], []

    def one(r, kind, partner):
        try:
            return replay_row(r, kind, repo, root, out, scoring, partner, digests)
        except ValueError as e:
            return {"source": kind, "run_id": r.get("run_id"), "failure": "score-error", "detail": str(e)[:200],
                    "disposition": "failed"}, None
    for r in res_rows:
        it, c = one(r, "results", None)
        items.append(it)
        cand_results.extend([c] if c else [])
    for r in led_panel:
        it, c = one(r, "eval-ledger", partner_of.get(os.path.basename(str(r.get("artifact") or ""))))
        items.append(it)
        cand_ledger.extend([c] if c else [])
    for n in res_bad:
        items.append({"source": "results", "run_id": None, "failure": "unreadable-row", "detail": "line %s" % n,
                      "disposition": "failed"})
    for n in led_bad:
        items.append({"source": "eval-ledger", "run_id": None, "failure": "unreadable-row", "detail": "line %s" % n,
                      "disposition": "failed"})
    with open(os.path.join(out, "candidate-results.jsonl"), "w", encoding="utf-8") as fh:
        fh.write("".join(json.dumps(r, sort_keys=True) + "\n" for r in cand_results))
    with open(os.path.join(out, "candidate-eval-runs.jsonl"), "w", encoding="utf-8") as fh:
        fh.write("".join(json.dumps(r, sort_keys=True) + "\n" for r in cand_ledger))
    # the supersession chains the readers would see once the candidates are appended to the inputs
    sel = {}
    for name, old, new in (("results", res_rows, cand_results), ("eval_ledger", led_panel, cand_ledger)):
        chosen, diag = eval_feedback.select_review_runs(old + new)
        sel[name] = {"selected": [r.get("run_id") for r in chosen], "diagnostics": diag}
    failed = {}
    for it in items:
        if it["disposition"] == "failed":
            failed[it["failure"]] = failed.get(it["failure"], 0) + 1
    ver = {"v": 1, "generated_at": score._now(),
           "scorer": {"scorer_sha256": ident["scorer_sha256"], "scorer_gitsha": ident["scorer_gitsha"],
                      "scorer_clean": ident["scorer_clean"], "reason": ident["reason"] or None},
           "scoring_key_sha256": scoring["key_sha256"],
           "inputs": {"results_sha256": file_sha(results), "eval_ledger_sha256": file_sha(ledger),
                      "results_rows": len(res_rows), "eval_ledger_review_panel_rows": len(led_panel),
                      "eval_ledger_other_rows": len(led_rows) - len(led_panel)},
           "items": items, "selection": sel,
           "summary": {"rows": len(items), "rescored": sum(1 for i in items if i["disposition"] == "rescored"),
                       "diagnostic_only": sum(1 for i in items if i["disposition"] == "diagnostic-only"),
                       "failed": failed},
           "writes": ["candidate-results.jsonl", "candidate-eval-runs.jsonl", "verification.json"]}
    with open(os.path.join(out, "verification.json"), "w", encoding="utf-8") as fh:
        json.dump(ver, fh, sort_keys=True, indent=1)
    return ver


def main(argv=None):
    ap = argparse.ArgumentParser(prog="replay.py", description=__doc__.split("\n")[1])
    for f in ("--results", "--eval-ledger", "--artifacts-root", "--out"):
        ap.add_argument(f, required=True)
    ap.add_argument("--repo", help="the git repo that holds the execution trees (default this checkout)")
    a = ap.parse_args(argv)
    out, root = os.path.realpath(a.out), os.path.realpath(a.artifacts_root)
    try:
        if os.path.lexists(a.out):
            raise ValueError("--out %s exists: replay writes a new directory only" % a.out)
        if out == root or out.startswith(root + os.sep):
            raise ValueError("--out lies inside the artifacts root: the retained bundles are never written")
        for p in (a.results, a.eval_ledger):
            if out == os.path.realpath(p) or os.path.realpath(p).startswith(out + os.sep):
                raise ValueError("--out is an input path: the inputs are never written")
        if not os.path.isdir(a.artifacts_root):
            raise ValueError("--artifacts-root %s is not a directory" % a.artifacts_root)
        ver = replay(a.results, a.eval_ledger, a.artifacts_root, a.out, a.repo)
    except (OSError, ValueError) as e:
        print("replay.py: %s" % e, file=sys.stderr)
        return 2
    s = ver["summary"]
    print("replay: %d rows: %d rescored, %d diagnostic-only, failed %s -> %s"
          % (s["rows"], s["rescored"], s["diagnostic_only"], json.dumps(s["failed"], sort_keys=True), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
