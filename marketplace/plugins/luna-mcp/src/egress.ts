import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const PURPOSE = "luna-mcp-read";

export interface EgressDecision {
  allow: boolean;
  corpora: string[];
  reason: string | null;
}

export interface Egress {
  check(collection: string, provider: string): Promise<EgressDecision>;
}

interface Rule {
  corpus?: unknown;
  provider?: unknown;
  purpose?: unknown;
  verdict?: unknown;
}

interface Matrix {
  rules: Rule[];
}

interface EvalModule {
  loadMatrix(path: string): unknown;
  evaluate(matrix: unknown, corpus: string, provider: string, purpose: string): unknown;
}

interface Loaded {
  sig: string;
  mod: EvalModule;
  matrix: Matrix;
  corpora: Record<string, unknown>;
}

const deny = (reason: string, corpora: string[] = []): EgressDecision => ({ allow: false, corpora, reason });

const fileSig = (s: { ino: bigint; size: bigint; mtimeNs: bigint; ctimeNs: bigint }): string => [s.ino, s.size, s.mtimeNs, s.ctimeNs].join(":");

export function createEgress(himmelRepo: string | undefined): Egress {
  let cache: Loaded | undefined;

  async function load(): Promise<Loaded> {
    if (!himmelRepo) throw new Error("HIMMEL_REPO is not set");
    const evalFile = join(himmelRepo, "scripts", "guardrails", "egress-matrix-eval.mjs");
    const matrixFile = join(himmelRepo, "scripts", "guardrails", "egress-matrix.json");
    const corpusFile = join(himmelRepo, "scripts", "qmd", "qmd-collection-corpus.json");
    const [e, m, c] = await Promise.all([stat(evalFile, { bigint: true }), stat(matrixFile, { bigint: true }), stat(corpusFile, { bigint: true })]);
    const evalSig = fileSig(e);
    const sig = [evalSig, fileSig(m), fileSig(c)].join("|");
    if (cache?.sig === sig) return cache;
    const imported = (await import(`${pathToFileURL(evalFile).href}?v=${evalSig}`)) as Partial<EvalModule>;
    if (typeof imported.evaluate !== "function" || typeof imported.loadMatrix !== "function") {
      throw new Error("egress evaluator does not export loadMatrix and evaluate");
    }
    const mod = imported as EvalModule;
    const matrix = mod.loadMatrix(matrixFile) as Matrix | null;
    if (!matrix || !Array.isArray(matrix.rules)) throw new Error("egress matrix has no rules");
    const corpusMap = JSON.parse(await readFile(corpusFile, "utf8")) as { collections?: unknown };
    if (!corpusMap.collections || typeof corpusMap.collections !== "object") throw new Error("corpus map has no collections");
    cache = { sig, mod, matrix, corpora: corpusMap.collections as Record<string, unknown> };
    return cache;
  }

  return {
    async check(collection, provider) {
      let loaded: Loaded;
      try {
        loaded = await load();
      } catch {
        return deny("egress-unavailable");
      }
      const evaluator = loaded.mod;
      const mapped = Object.hasOwn(loaded.corpora, collection) ? loaded.corpora[collection] : undefined;
      if (!Array.isArray(mapped) || mapped.length === 0 || !mapped.every((c) => typeof c === "string" && c.length > 0)) {
        return deny(`unmapped:${collection}`);
      }
      const corpora = mapped as string[];
      for (const corpus of corpora) {
        const literal = loaded.matrix.rules.some(
          (r) => r.corpus === corpus && r.provider === provider && r.purpose === PURPOSE && r.verdict === "allow+log",
        );
        if (!literal) return deny(`egress-denied:${corpus}:no-literal-row`, corpora);
        let verdict: unknown;
        try {
          verdict = (evaluator.evaluate(loaded.matrix, corpus, provider, PURPOSE) as { verdict?: unknown } | null)?.verdict;
        } catch {
          return deny(`egress-denied:${corpus}:evaluator-error`, corpora);
        }
        if (verdict !== "allow+log") return deny(`egress-denied:${corpus}:${String(verdict)}`, corpora);
      }
      return { allow: true, corpora: [...corpora], reason: null };
    },
  };
}
