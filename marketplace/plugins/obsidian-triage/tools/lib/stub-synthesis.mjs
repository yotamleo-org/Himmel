/**
 * stub-synthesis.mjs — pure decision logic for SYNTHESIZE stub mode
 * plus the fuzzy existing-subject match used by densify.
 *
 * No I/O. Operates on plain clip objects the CLI builds from disk:
 *   { rel, id, base, type, url, canonicalUrl, author, tags:[], evidenceKind:[] }
 *
 * The anti-sprawl spine (handover HARD GUARDRAIL #2): a stub fires only when,
 * for some TOPICAL tag, the contributing clips — AFTER canonical-URL dedup —
 * number >=2 AND span >=2 distinct domains OR >=2 distinct authors.
 */

// Structural / pipeline tags that are NOT concepts — grouping on these would
// stub junk like "Concepts" or "Article". (Superset of the evidence-kind tag
// vocabulary plus clipper/vault housekeeping tags.)
export const STRUCTURAL_TAGS = new Set([
  "tool", "tools", "cli", "library", "framework", "sdk", "plugin", "repo",
  "concept", "concepts", "mental-model", "idea", "theory",
  "author", "person", "question", "questions", "open-question",
  "pattern", "patterns", "misc",
  "article", "research", "youtube", "newsletter", "reddit", "tweet",
  "synthesis", "clipping", "clip", "ai-first", "inbox", "evidence",
  "tech", "resource", "resources", "note", "notes", "moc",
]);

/** Tags eligible to key a concept group (topical, deduped, lowercased). */
export function topicalTags(tags) {
  const seen = new Set();
  const out = [];
  for (const raw of tags || []) {
    const t = String(raw).trim().toLowerCase();
    if (!t || STRUCTURAL_TAGS.has(t) || seen.has(t)) continue;
    seen.add(t);
    out.push(t);
  }
  return out;
}

/** Hostname of a canonical URL, or "" when unparseable/absent. */
export function domainOf(canonicalUrl) {
  if (!canonicalUrl) return "";
  try { return new URL(canonicalUrl).hostname.toLowerCase(); }
  catch { return ""; }
}

/**
 * Normalised match key for a subject name: lowercase, drop every non-alphanumeric.
 * "Context Windows" / "context-windows" / "Context-Windows-MOC" (after the -MOC
 * strip) all collapse to "contextwindows" — a BOUNDED match (exact normalised
 * equality + operator-declared `aliases:`), not an open-ended fuzzy guess. That
 * boundedness is the answer to the plan-critic's unbounded-matching risk.
 */
export function normalizeName(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, "");
}

// Words that end like a plural but are not one, or that must keep their form.
const KEEP_FORM = new Set([
  "news", "series", "species", "lens", "bias", "canvas", "atlas", "chaos",
  "kubernetes", "aws", "ios", "macos", "css", "gps",
]);

/**
 * Fold a regular English plural onto its singular so both forms make the same
 * key ("workflows" -> "workflow", "libraries" -> "library", "caches" and
 * "cache" -> "cach"). The result is a grouping key, never shown: it only has to
 * be the same for both forms. Irregular plurals are not handled, and words that
 * end like a plural (class, status, analysis) keep their form.
 */
function foldWord(w) {
  if (w.length <= 3 || KEEP_FORM.has(w)) return w;
  if (/ss$|us$|[sx]is$/.test(w)) return w;
  if (/[^aeiou]ies$/.test(w)) return w.slice(0, -3) + "y";
  if (/(?:x|z|ch|sh|ss)es$/.test(w)) return w.slice(0, -2);
  const bare = w.endsWith("s") ? w.slice(0, -1) : w;
  return bare.replace(/(ch|sh|x|z)e$/, "$1").replace(/ie$/, "y");
}

/** Grouping key of a tag: only its last word is folded ("api-keys" -> "api-key"). */
export function tagKey(tag) {
  const m = /^(.*[^a-z0-9])?([a-z0-9]+)$/.exec(String(tag).toLowerCase());
  return m ? (m[1] || "") + foldWord(m[2]) : String(tag).toLowerCase();
}

/** Match key of a subject name: tagKey of the name, then normalizeName. */
export function subjectKey(name) {
  return normalizeName(tagKey(String(name).trim()));
}

/** Title-case a tag slug: "context-windows" -> "Context Windows". */
export function subjectNameFromTag(tag) {
  return String(tag)
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

/** Dedup key for a clip: canonical URL when present, else its rel (unique). */
function dedupKey(clip) {
  return clip.canonicalUrl && clip.canonicalUrl.length ? clip.canonicalUrl : `rel:${clip.rel}`;
}

function normAuthor(a) { return String(a || "").trim().toLowerCase(); }

// A topic-tag-grouped stub is only ever a Concept or a Tech subject — never a
// person note (the `authors` evidence_kind describes a clip's value, not the
// topic; routing a topic like "Quantization" to 20-Areas/ is a category error).
const KIND_TARGET = {
  concepts: { folder: "30-Resources/Concepts", template: "Concept", kind: "concepts" },
  tools:    { folder: "30-Resources/Tech",     template: "Tech",    kind: "tools" },
};

function isGithubRepo(url) {
  return /^https?:\/\/github\.com\/[^/]+\/[^/]+/.test(url || "");
}

/**
 * Pick Concept vs Tech from the CONTRIBUTORS. Tech only when a MAJORITY of the
 * deduped contributors ARE github repos — a cluster of repos about X is a Tech
 * subject (and triggers the deferred-row fan-out); a cluster of articles about X
 * that merely cite a repo is a Concept. (Routing on evidence_kind alone
 * mis-files every AI article that links github as "Tech".)
 */
export function targetForContributors(contributors) {
  const repos = contributors.filter((c) => isGithubRepo(c.canonicalUrl)).length;
  if (repos >= 1 && repos * 2 >= contributors.length) return KIND_TARGET.tools;
  return KIND_TARGET.concepts;
}

/**
 * Plan stub decisions over a clip set.
 *
 * @param {object[]} clips
 * @param {(name:string, target:object)=>({path:string}|null)} matchExisting
 *        Returns an existing-subject descriptor to DENSIFY, or null to CREATE.
 *        SYNTHESIZE passes an exact-path matcher; densify passes a fuzzy one.
 * @returns {object[]} decisions, deterministically ordered by concept key.
 */
export function planStubs(clips, matchExisting) {
  // Stable input order.
  const sorted = [...clips].sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));

  // tagKey -> { forms: tag -> clips carrying that spelling, group: clips }.
  // Singular and plural spellings share one key, so they are one subject.
  const byKey = new Map();
  for (const clip of sorted) {
    const keysOfClip = new Set();
    for (const tag of topicalTags(clip.tags)) {
      const key = tagKey(tag);
      if (!byKey.has(key)) byKey.set(key, { forms: new Map(), group: [] });
      const entry = byKey.get(key);
      entry.forms.set(tag, (entry.forms.get(tag) || 0) + 1);
      if (!keysOfClip.has(key)) { keysOfClip.add(key); entry.group.push(clip); }
    }
  }

  const decisions = [];
  for (const key of [...byKey.keys()].sort()) {
    const { forms, group } = byKey.get(key);
    if (group.length < 2) continue; // need >=2 raw clips even before dedup
    // The spelling most clips use names the subject; a tie goes to the shorter, then the earlier.
    const tag = [...forms.keys()].sort((a, b) => forms.get(b) - forms.get(a) || a.length - b.length || (a < b ? -1 : 1))[0];

    // (a) canonical-URL dedup — keep one representative per dedup key.
    const repByKey = new Map();
    for (const clip of group) {
      const k = dedupKey(clip);
      if (!repByKey.has(k)) repByKey.set(k, clip);
    }
    const contributors = [...repByKey.values()].sort((a, b) => (a.rel < b.rel ? -1 : 1));

    const subjectName = subjectNameFromTag(tag);

    if (contributors.length < 2) {
      decisions.push({
        conceptKey: tag, subjectName, action: "skip",
        reason: "url-dedup: collapsed to 1 contributor",
        contributors: contributors.map((c) => c.rel),
      });
      continue;
    }

    // (b) >=2 distinct domains OR >=2 distinct authors.
    const domains = new Set(contributors.map((c) => domainOf(c.canonicalUrl)).filter(Boolean));
    const authors = new Set(contributors.map((c) => normAuthor(c.author)).filter(Boolean));
    if (domains.size < 2 && authors.size < 2) {
      decisions.push({
        conceptKey: tag, subjectName, action: "skip",
        reason: `distinct-source floor: ${domains.size} domain(s), ${authors.size} author(s)`,
        contributors: contributors.map((c) => c.rel),
      });
      continue;
    }

    const target = targetForContributors(contributors);
    const existing = matchExisting ? matchExisting(subjectName, target) : null;

    decisions.push({
      conceptKey: tag,
      subjectName,
      target,
      action: existing ? "densify" : "create",
      existingPath: existing ? existing.path : null,
      contributors: contributors.map((c) => c.rel),
      contributorIds: contributors.map((c) => c.id),
      domains: domains.size,
      authors: authors.size,
    });
  }

  // Collapse decisions that resolve to the SAME subject page (distinct tags can
  // title-case to one name — `context-windows` vs `context windows`). Without
  // this, two `create`s would overwrite one page (losing the first's Evidence)
  // and write two ledger entries → a stranded, unrevertable `promoted_to:`
  // stamp. Merge contributors so the surviving page lists all of them, every
  // contributor is stamped, and exactly one ledger entry records the page.
  return mergeBySubject(decisions);
}

function mergeBySubject(decisions) {
  const skips = [];
  const bySubject = new Map(); // `${folder}/${name}` -> merged decision
  for (const d of decisions) {
    if (d.action === "skip") { skips.push(d); continue; }
    const key = `${d.target.folder}/${d.subjectName}`;
    const m = bySubject.get(key);
    if (!m) { bySubject.set(key, d); continue; }
    const seen = new Set(m.contributors);
    for (let i = 0; i < d.contributors.length; i++) {
      if (seen.has(d.contributors[i])) continue;
      seen.add(d.contributors[i]);
      m.contributors.push(d.contributors[i]);
      m.contributorIds.push(d.contributorIds[i]);
    }
    m.conceptKey = `${m.conceptKey}+${d.conceptKey}`;
    if (d.action === "densify") { m.action = "densify"; m.existingPath = d.existingPath; }
  }
  // Re-sort merged contributors by rel for a stable Evidence order, keeping ids aligned.
  for (const m of bySubject.values()) {
    const order = m.contributors.map((rel, i) => ({ rel, id: m.contributorIds[i] }))
      .sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
    m.contributors = order.map((o) => o.rel);
    m.contributorIds = order.map((o) => o.id);
  }
  return skips.concat([...bySubject.values()]);
}
