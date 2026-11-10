"""scripts/eval/review-panel/adjudication.py - the reviewed gold (key/validation.json) and the bound finding
labels (a private adjudications JSONL kept outside the raw bundles) behind the verified metric family. score.py
imports it; it reads no git tree and calls no model.

A label is bound to case input + gold revision + canonical finding: case_input_sha256 hashes the case's diff,
context, intent and base digests; gold_revision the exact sidecar bytes; finding_sha256 the finding's severity,
file, line and text (never its bullet id, critic or model). An identical finding in a repeated execution reuses
the label; a changed case input, gold or text voids it. Verified metrics never read the keyword matcher.
"""
import hashlib
import json
import re

GATING = ("crit", "imp")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
STATES = ("pending", "validated", "excluded")
KINDS = ("seeded", "clean", "excluded")
CORRECTNESS = ("correct", "incorrect", "unresolved")
SCOPES = ("in", "out", "unknown")
ENTRY_KEYS = {"state", "effective_kind", "mechanism", "trigger", "expected_behavior", "contract", "target_ids",
              "added_targets", "residuals", "repair_evidence", "evidence_refs", "curator", "reviewer",
              "reviewed_at", "curation"}
TEXT_KEYS = ("mechanism", "trigger", "expected_behavior", "repair_evidence")
LABEL_KEYS = ("v", "case_id", "case_input_sha256", "gold_revision", "finding_sha256", "observed_execution_ids",
              "correctness", "target_ids", "scope", "severity_valid", "rationale", "evidence_refs", "adjudicator",
              "reviewed_by", "adjudicated_at")
TARGET_KEYS = ("v", "kind", "case_id", "case_input_sha256", "gold_revision", "target_id", "ruling",
               "reviewed_findings", "rationale", "evidence_refs", "adjudicator", "reviewed_by", "adjudicated_at")


def _sha(b):
    return hashlib.sha256(b).hexdigest()


def _canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def gold_revision(path):
    with open(path, "rb") as fh:
        return _sha(fh.read())


def case_input_sha256(inputs):
    """One case's {diff_sha256, context_sha256, intent_sha256, base} (the run manifest's inputs entry)."""
    return _sha(_canon(inputs))


def finding_sha256(f):
    return _sha(_canon([f["sev"], f["file"], f["line"], f["text"]]))


def _text(v):
    return isinstance(v, str) and v.strip() != ""


def _is_one(v):
    return type(v) is int and v == 1


def load_validation(path, key_cases):
    """(entries, problems, gold_revision) of a validation sidecar. Every entry names an existing key case; a
    validated or excluded entry needs an independent reviewer (not its curator), a review date and evidence; a
    residual is an id and a description, never a pattern."""
    gold = gold_revision(path)
    with open(path, encoding="utf-8") as fh:
        try:
            doc = json.load(fh)
        except ValueError as e:
            return {}, ["%s: not JSON (%s)" % (path, e)], gold
    if not isinstance(doc, dict) or not _is_one(doc.get("v")) or not isinstance(doc.get("cases"), dict) \
            or set(doc) != {"v", "cases"}:
        return {}, ["%s: a validation sidecar is {\"v\": 1, \"cases\": {...}}" % path], gold
    problems, out = [], {}
    for cid, e in sorted(doc["cases"].items()):
        say = lambda msg, cid=cid: problems.append("validation %s: %s" % (cid, msg))  # noqa: E731
        key = key_cases.get(cid)
        if key is None:
            say("names no case of the key")
            continue
        if not isinstance(e, dict):
            say("is not an object")
            continue
        for k in sorted(set(e) - ENTRY_KEYS):
            say("unknown field %r" % k)
        if e.get("state") not in STATES:
            say("state must be one of %s" % ", ".join(STATES))
        kind = e.get("effective_kind")
        if kind not in KINDS:
            say("effective_kind must be one of %s" % ", ".join(KINDS))
        if (e.get("state") == "excluded") != (kind == "excluded") and e.get("state") != "pending":
            say("an excluded state and an excluded kind go together")
        for k in TEXT_KEYS:
            if not isinstance(e.get(k), str):
                say("%s must be a string" % k)
        if not _text(e.get("curator")):
            say("names no curator")
        refs = e.get("evidence_refs")
        if not isinstance(refs, list) or not all(_text(r) for r in refs):
            say("evidence_refs must be a list of references")
            refs = []
        added = e.get("added_targets", [])
        if not isinstance(added, list) or not all(
                isinstance(t, dict) and set(t) == {"id", "file", "line", "description"} and _text(t["id"])
                and _text(t["file"]) and type(t["line"]) is int and _text(t["description"]) for t in added):
            say("added_targets must be a list of {id, file, line, description}")
            added = []
        known = {d.get("id") for d in key.get("defects", [])} | {t["id"] for t in added}
        targets = e.get("target_ids")
        if not isinstance(targets, list) or not all(isinstance(t, str) for t in targets):
            say("target_ids must be a list of ids")
            targets = []
        for t in targets:
            if t not in known:
                say("target %r is neither a key defect of the case nor an added target" % t)
        residuals = e.get("residuals", [])
        if not isinstance(residuals, list):
            say("residuals must be a list")
            residuals = []
        for r in residuals:
            if not isinstance(r, dict) or not _text(r.get("id")) or not _text(r.get("description")):
                say("a residual needs an id and a description")
            elif set(r) != {"id", "description"}:
                say("residual %s carries %s: a residual is an id and a description, never a pattern or match rule"
                    % (r["id"], ", ".join(sorted(set(r) - {"id", "description"}))))
        if kind == "seeded" and not targets:
            say("a seeded case names its target ids")
        if kind == "clean":
            if targets or added:
                say("a clean case names no target")
            if not _text(e.get("contract")):
                say("a clean case states its intended contract")
        if e.get("state") in ("validated", "excluded"):
            if not _text(e.get("reviewer")) or e.get("reviewer") == e.get("curator"):
                say("a %s case needs an independent reviewer who is not its curator" % e.get("state"))
            if not _text(e.get("reviewed_at")):
                say("a %s case needs reviewed_at" % e.get("state"))
            if not refs:
                say("a %s case needs evidence_refs" % e.get("state"))
        out[cid] = e
    return out, problems, gold


def _record_problem(rec, keys):
    missing = [k for k in keys if k not in rec]
    if missing:
        return "missing-field:" + ",".join(missing)
    if not _is_one(rec["v"]) or not isinstance(rec["case_id"], str):
        return "bad-value:v-or-case_id"
    for k in ("case_input_sha256", "gold_revision"):
        if not isinstance(rec[k], str) or not HEX64.match(rec[k]):
            return "bad-value:" + k
    for k in ("rationale", "adjudicator", "reviewed_by", "adjudicated_at"):
        if not _text(rec[k]):
            return "missing-field:" + k
    if not isinstance(rec["evidence_refs"], list) or not rec["evidence_refs"] \
            or not all(_text(r) for r in rec["evidence_refs"]):
        return "missing-field:evidence_refs"
    if rec["adjudicator"] == rec["reviewed_by"]:
        return "self-reviewed"
    return None


def load_adjudications(path, case_inputs, gold_revision, findings):
    """(labels, diagnostics) from an adjudications JSONL. case_inputs maps a case id to its case_input_sha256,
    findings a case id to the finding_sha256 values its outputs hold. labels is {"findings": {(case, finding_sha):
    label}, "targets": {(case, target_id): ruling}}; a rejected record (unknown case, changed case input or gold,
    missing reviewer or evidence, self-review, bad value) is a diagnostic and never a label. Two records of one
    identity that disagree are a "conflict" diagnostic and neither is used: the caller refuses verified metrics."""
    labels, diags, conflicts = {"findings": {}, "targets": {}}, [], set()
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    for n, ln in enumerate(lines, 1):
        if not ln.strip():
            continue
        try:
            rec = json.loads(ln)
        except ValueError:
            diags.append({"reason": "unparseable", "line": n})
            continue
        if not isinstance(rec, dict):
            diags.append({"reason": "unparseable", "line": n})
            continue
        is_target = rec.get("kind") == "target"
        why = _record_problem(rec, TARGET_KEYS if is_target else LABEL_KEYS)
        cid = rec.get("case_id")
        if why is None:
            if cid not in case_inputs:
                why = "unknown-case"
            elif rec["case_input_sha256"] != case_inputs[cid]:
                why = "case-input-changed"
            elif rec["gold_revision"] != gold_revision:
                why = "gold-revision-changed"
        if why is None and is_target:
            ok = rec["ruling"] == "missed" and _text(rec["target_id"]) and isinstance(rec["reviewed_findings"], list) \
                and all(isinstance(s, str) and HEX64.match(s) for s in rec["reviewed_findings"])
            why = None if ok else "bad-value:target-ruling"
        elif why is None:
            sv = rec["severity_valid"]
            ok = (isinstance(rec["finding_sha256"], str) and HEX64.match(rec["finding_sha256"])
                  and rec["correctness"] in CORRECTNESS and rec["scope"] in SCOPES and (sv is None or isinstance(sv, bool))
                  and isinstance(rec["target_ids"], list) and all(isinstance(t, str) for t in rec["target_ids"])
                  and isinstance(rec["observed_execution_ids"], list)
                  and all(isinstance(x, str) for x in rec["observed_execution_ids"])
                  and not (rec["target_ids"] and rec["correctness"] != "correct"))
            why = None if ok else "bad-value:label"
            if ok and rec["finding_sha256"] not in findings.get(cid, ()):
                diags.append({"reason": "finding-not-observed", "case": cid, "line": n})
        if why is not None:
            diags.append({"reason": why, "case": cid if isinstance(cid, str) else None, "line": n})
            continue
        if is_target:
            ident, table = (cid, rec["target_id"]), labels["targets"]
            decision = (rec["ruling"], tuple(sorted(rec["reviewed_findings"])))
        else:
            ident, table = (cid, rec["finding_sha256"]), labels["findings"]
            decision = (rec["correctness"], tuple(sorted(rec["target_ids"])), rec["scope"], rec["severity_valid"])
        if ident in conflicts:
            continue
        prev = table.get(ident)
        if prev is None:
            table[ident] = dict(rec, _decision=decision)
        elif prev["_decision"] != decision:
            conflicts.add(ident)
            del table[ident]
            diags.append({"reason": "conflict", "case": cid, "identity": ident[1][:16], "line": n})
        elif not is_target:
            prev["observed_execution_ids"] = sorted(set(prev["observed_execution_ids"])
                                                    | set(rec["observed_execution_ids"]))
    return labels, diags


def _ratio(k, n):
    return (k / n) if n else None


def cohort(cases, scored):
    """The verified cohort over cases {case id: {key_kind, pair, split, entry}}: whole twin pairs whose every
    twin is validated and among the scored ids (a pending, excluded, unscored or provenance-dropped twin takes its
    pair out with it), plus the relabelled and pending ids."""
    pairs = {}
    for cid, c in cases.items():
        pairs.setdefault(c["pair"], []).append(cid)

    def ok(i):
        return (cases[i]["entry"] or {}).get("state") == "validated" and i in scored
    incomplete = sorted(p for p, ids in pairs.items()
                        if any((cases[i]["entry"] or {}).get("state") == "validated" for i in ids)
                        and not all(ok(i) for i in ids))
    members = sorted(cid for cid, c in cases.items() if (c["entry"] or {}).get("state") == "validated"
                     and c["pair"] not in incomplete)
    by_state = {s: sorted(cid for cid, c in cases.items() if ((c["entry"] or {}).get("state") or "pending") == s)
                for s in STATES}
    relabelled = [{"case": cid, "from": cases[cid]["key_kind"], "to": cases[cid]["entry"]["effective_kind"]}
                  for cid in sorted(cases) if cases[cid]["entry"]
                  and cases[cid]["entry"].get("effective_kind") != cases[cid]["key_kind"]]
    return {"validated": members, "pending": by_state["pending"], "excluded": by_state["excluded"],
            "relabelled": relabelled, "incomplete_pairs": incomplete}


def _decided(lab):
    return lab is not None and lab["correctness"] in ("correct", "incorrect")


def verified_metrics(cases, findings, labels, participation):
    """(metrics, coverage, reasons, detail) over the verified cohort; detail holds the k/n counts, the cohort, the
    panel's per-target states and the per-clean-case blocker states.

    cases: {case id: {key_kind, pair, split, entry}} for every key case scored or not; findings: {case id: [finding
    with critic, sev, sha]} for the scored cases; labels: load_adjudications' labels; participation: {case id:
    {critic: case_participation record}}. A target is found when a correct label attributes it, missed when a
    target ruling covering every finding of the case says so or every one of the member's findings is decided,
    else unresolved: recall lo counts found, hi adds unresolved, a point value only when they agree. Precision is
    correct / decided findings with coverage. A clean case blocks unjustly when a Critical/Important finding is
    labelled incorrect, out of contract or severity_valid false; a correct in-contract rightly rated blocker
    disputes the clean control; any other blocker is unsettled. The false-block rate is a value only when no
    control is disputed and every blocker of the member is settled."""
    co = cohort(cases, set(findings))
    members = sorted({s for p in participation.values() for s in p}) + ["panel"]
    flabels, truling = labels["findings"], labels["targets"]
    metrics, counts, coverage, reasons, targets, blocks, disputed = {}, {}, {}, [], {}, {}, set()

    def lab(cid, f):
        return flabels.get((cid, f["sha"]))

    def blocker_state(cid, f):
        lb = lab(cid, f)
        if lb is None or lb["correctness"] == "unresolved":
            return "unsettled"
        if lb["correctness"] == "incorrect" or lb["scope"] == "out" or lb["severity_valid"] is False:
            return "unjustified"
        if lb["scope"] == "in" and lb["severity_valid"] is True:
            return "disputed"
        return "unsettled"

    for cid in co["validated"]:
        if cid in findings and cases[cid]["entry"]["effective_kind"] == "clean":
            states = {blocker_state(cid, f) for f in findings[cid] if f["sev"] in GATING}
            for s in ("disputed", "unsettled", "unjustified"):
                if s in states:
                    blocks[cid] = s
                    break
            else:
                blocks[cid] = "none"
            if blocks[cid] == "disputed":
                disputed.add(cid)
    for cid in sorted(disputed):
        reasons.append("disputed-clean-control:%s" % cid)

    for prefix, half in (("", None), ("open.", "open"), ("sealed.", "sealed")):
        ids = [c for c in co["validated"] if c in findings and (half is None or cases[c]["split"] == half)]
        if half is not None and not ids:
            continue
        for who in members:
            name = prefix + who
            mine_ids = [c for c in ids if who == "panel" or participation[c][who]["state"] == "answered"]
            found = gate_lo = gate_hi = unres = n_t = 0
            cov = {"findings": 0, "correct": 0, "incorrect": 0, "unresolved": 0, "unlabelled": 0, "out_of_scope": 0}
            fb_n = fb_k = 0
            fb_unsettled = []
            for cid in mine_ids:
                entry = cases[cid]["entry"]
                mine = findings[cid] if who == "panel" else [f for f in findings[cid] if f["critic"] == who]
                for f in mine:
                    if f["critic"] == "citation-guard":
                        continue
                    lb = lab(cid, f)
                    cov["findings"] += 1
                    if lb is None:
                        cov["unlabelled"] += 1
                    else:
                        cov[lb["correctness"]] += 1
                        cov["out_of_scope"] += lb["scope"] == "out"
                if entry["effective_kind"] == "clean":
                    fb_n += 1
                    states = {blocker_state(cid, f) for f in mine if f["sev"] in GATING}
                    if "unsettled" in states or "disputed" in states:
                        fb_unsettled.append(cid)
                    fb_k += "unjustified" in states
                    continue
                every = {f["sha"] for f in findings[cid]}
                undecided = [f for f in mine if not _decided(lab(cid, f))]
                for t in entry["target_ids"]:
                    n_t += 1
                    hits = [f for f in mine if (lab(cid, f) or {}).get("correctness") == "correct"
                            and t in lab(cid, f)["target_ids"]]
                    ruling = truling.get((cid, t))
                    if hits:
                        status = "found"
                    elif ruling and every <= set(ruling["reviewed_findings"]):
                        status = "missed"
                    elif not undecided:
                        status = "missed"
                    else:
                        status = "unresolved"
                    conf = any(f["sev"] in GATING and lab(cid, f)["severity_valid"] is True for f in hits)
                    poss = conf or any(f["sev"] in GATING and lab(cid, f)["severity_valid"] is None for f in hits) \
                        or (status != "missed" and any(f["sev"] in GATING for f in undecided))
                    found += status == "found"
                    unres += status == "unresolved"
                    gate_lo += conf
                    gate_hi += poss
                    if name == "panel":
                        targets.setdefault(cid, {})[t] = status
            decided = cov["correct"] + cov["incorrect"]
            cov["decided"] = decided
            cov["adjudication_coverage"] = _ratio(decided, cov["findings"])
            coverage[name] = cov
            vals = {"verified_defect_recall_lo": (found, n_t), "verified_defect_recall_hi": (found + unres, n_t),
                    "verified_gating_recall_lo": (gate_lo, n_t), "verified_gating_recall_hi": (gate_hi, n_t),
                    "adjudicated_precision": (cov["correct"], decided)}
            for m, (k, n) in vals.items():
                metrics["%s.%s" % (name, m)] = _ratio(k, n)
                counts["%s.%s" % (name, m)] = {"k": k, "n": n}
            for point, lo, hi in (("verified_defect_recall", found, found + unres),
                                  ("verified_gating_recall", gate_lo, gate_hi)):
                metrics["%s.%s" % (name, point)] = _ratio(lo, n_t) if lo == hi else None
            metrics["%s.adjudication_coverage" % name] = cov["adjudication_coverage"]
            fb_key = "%s.verified_false_block_rate" % name
            counts[fb_key] = {"k": fb_k, "n": fb_n}
            if disputed or fb_unsettled:
                metrics[fb_key] = None
                if fb_unsettled and not prefix:
                    reasons.append("unsettled-blocker:%s:%s" % (who, ",".join(fb_unsettled)))
            else:
                metrics[fb_key] = _ratio(fb_k, fb_n)
    if not co["validated"]:
        reasons.append("no-validated-cases")
    if co["incomplete_pairs"]:
        reasons.append("pairs-incomplete:%s" % ",".join(co["incomplete_pairs"]))
    if co["pending"]:
        reasons.append("cases-pending:%d" % len(co["pending"]))
    co["disputed"] = sorted(disputed)
    return metrics, coverage, reasons, {"counts": counts, "cohort": co, "targets": targets, "blocks": blocks}
