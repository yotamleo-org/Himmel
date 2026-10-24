# Third-Party License Audit

Pre-tag blocker for `v1.0.0-pre` (himmel targets MIT).
Covers every tracked `package.json` in the repo (`git ls-files "*package.json"
| grep -v node_modules`, `node_modules` excluded): 16 manifests, 19 unique
npm deps including devDependencies. **Scope: direct dependencies only**
(the ticket's own measured surface). The transitive tree (e.g. everything
`@modelcontextprotocol/server` or `playwright` pulls in) was NOT walked or
audited; a permissive direct dependency can still depend on a copyleft
transitive, so this scope limitation is a real gap, not a cleared risk, and a
future pass should run `license-checker` (or equivalent) over the full
resolved tree if that risk needs closing before release.
"Compatible" = a permissive, no-copyleft-obligation license: MIT/BSD-2/BSD-3/
Apache-2.0/ISC/0BSD/Unlicense, or another license that is verified
case-by-case to be equally or more permissive (the one instance, `left-pad`'s
WTFPL, is called out explicitly below rather than silently folded in).

## Verdict

**All 19 npm deps are MIT-compatible. Zero FLAGs.** One informational note
(left-pad/WTFPL, test-fixture-only, never installed or shipped; see below).

## SBOM

| Dep | Version declared → **locked** | License | Manifest(s) | Runtime/Dev | Verdict |
|---|---|---|---|---|---|
| `@modelcontextprotocol/server` | `2.3.1` (exact) → **2.3.1** | Apache-2.0 | marketplace/plugins/luna-correlate, marketplace/plugins/telegram-himmel, scripts/jira | runtime | COMPATIBLE |
| `commander` | `^15.0.0` → **15.0.0**; `9.4.1` (T6 fixture, exact, no lockfile) | MIT | scripts/bitbucket, scripts/himmel-run, scripts/jira, scripts/lanes/bench/fixtures/T6/.../tools/codegen/scripts | runtime | COMPATIBLE |
| `@coderabbitai/bitbucket` | `^1.1.4` → **1.1.4** | Apache-2.0 | scripts/bitbucket | runtime | COMPATIBLE |
| `env-paths` | `^4.0.0` → **4.0.0** | MIT | scripts/himmel-run | runtime | COMPATIBLE |
| `proper-lockfile` | `^4.1.2` → **4.1.2** | MIT | scripts/himmel-run | runtime | COMPATIBLE |
| `grammy` | `^1.21.0` → **1.44.0** | MIT | marketplace/plugins/telegram-himmel | runtime | COMPATIBLE |
| `js-yaml` | `5.3.0` → **5.3.0** | MIT | marketplace/plugins/obsidian-triage/tools | runtime | COMPATIBLE |
| `playwright` | `1.62.1` → **1.62.1** | Apache-2.0 | marketplace/plugins/obsidian-triage/tools | runtime | COMPATIBLE |
| `left-pad` | `1.1.0` (exact, T6 fixture only, no lockfile) | WTFPL | scripts/lanes/bench/fixtures/T6/input (+3 workspace packages) | runtime (fixture) | COMPATIBLE — see note |
| `chalk` | `4.1.2` (exact, T6 fixture only, no lockfile) | MIT | scripts/lanes/bench/fixtures/T6/input | runtime (fixture) | COMPATIBLE |
| `react` | `18.2.0` (exact, T6 fixture only, no lockfile) | MIT | scripts/lanes/bench/fixtures/T6/.../examples/demo-app | runtime (fixture) | COMPATIBLE |
| `lodash` | `4.18.1` (exact, T6 fixture only, no lockfile) | MIT | scripts/lanes/bench/fixtures/T6/.../packages/core | runtime (fixture) | COMPATIBLE |
| `@types/node` | `^26.2.0` → **26.2.0**; `^26.1.0` → **26.1.0** | MIT | scripts/bitbucket, scripts/ci-orchestrator, scripts/himmel-run, scripts/jira | dev | COMPATIBLE |
| `typescript` | `^7.0.2` → **7.0.2**; `^6.0.3` → **6.0.3** | Apache-2.0 | marketplace/plugins/claude-hud, marketplace/plugins/luna-correlate, scripts/bitbucket, scripts/ci-orchestrator, scripts/himmel-run, scripts/jira | dev | COMPATIBLE |
| `vitest` | `^4.1.11` → **4.1.11**; `^4.1.9` → **4.1.9** | MIT | plugins/himmel-gh, plugins/himmel-jira, scripts/bitbucket, scripts/ci-orchestrator, scripts/himmel-run, scripts/jira | dev | COMPATIBLE |
| `c8` | `^11.0.0` → **11.0.0** | ISC | marketplace/plugins/claude-hud | dev | COMPATIBLE |
| `bun-types` | `^1.3.14` → **1.3.14** | MIT | marketplace/plugins/luna-correlate | dev | COMPATIBLE |
| `@types/bun` | `latest` → **1.3.14** | MIT | scripts/luna-vitals | dev | COMPATIBLE |
| `@types/proper-lockfile` | `^4.1.4` → **4.1.4** | MIT | scripts/himmel-run | dev | COMPATIBLE |

**Methodology:** every manifest here has a committed lockfile
(`package-lock.json` or `bun.lock`). The **locked** column is the exact
version pinned in that manifest's own lockfile (read directly from it, e.g.
`.packages['node_modules/<dep>'].version` in `package-lock.json`), which is
what a clean `npm ci` / `bun install` actually installs: the deterministic,
release-accurate answer, not a registry snapshot or local `node_modules`
state (both of which were independently found stale or drifted from the
lockfile in several spots during this audit, e.g. `js-yaml`'s locally
installed `5.0.0` vs. the lockfile's `5.3.0`). The four T6 benchmark-fixture
packages have no lockfile (they are synthetic prompt data, never installed;
see the fixture note below) and keep their exact declared pin. Every locked
version's license was independently confirmed via `npm view
<dep>@<locked-version> license` and matches what's shown; no dependency's
license differs across the version deltas observed in this audit.

### Note on `left-pad` / WTFPL

`left-pad@1.1.0` only appears in `scripts/lanes/bench/fixtures/T6/`, a
synthetic benchmark fixture (`prompt.md` in that dir: "bump left-pad from
1.1.0 to 1.3.0") used to test the lanes tooling's ability to edit a monorepo.
It is never installed (no `node_modules/left-pad` anywhere in the repo) and
never shipped. WTFPL is a public-domain-equivalent license (no attribution,
no copyleft, more permissive than MIT) but isn't one of the named compatible
license classes, so it's called out here rather than silently folded into
COMPATIBLE. No action needed: it's fixture data, not a real dependency.

## Bundled-artifact exposure

`scripts/jira/dist/` (the Jira/Confluence CLI build output) is **untracked**
today: `npm run build` (`tsc`) output, not committed, not distributed. `tsc`
transpiles only `jira-cli`'s own TypeScript; it does not bundle or inline
`node_modules`, so `dist/` itself contains no third-party dependency code and
triggers no attribution obligation as-is (it still requires `node_modules` at
runtime to actually run). Attribution only becomes a live question if a
FUTURE change bundles the CLI (e.g. an esbuild/pkg step that inlines
`node_modules` into a standalone distributable). At that point the audit
would need to cover the **full resolved transitive tree** of whatever gets
inlined, not just the two direct runtime deps. Today those direct runtime
deps are `@modelcontextprotocol/server` (Apache-2.0) and `commander` (MIT), both
permissive (a bundled Apache-2.0 dep must carry its NOTICE, if it ships one), but that list is a starting point for a
future bundling audit, not a substitute for one; see the transitive-tree gap
noted above. `@types/node`, `typescript`, `vitest` are devDependencies used
only for type-checking, compiling, and testing. The CLI's runtime source
never `import`s them, so a bundler that follows actual reachable imports
from the entry point (rather than being told to include them explicitly)
would not pull them in; being a devDependency doesn't by itself guarantee
exclusion from a bundle, correct usage does.

## Docs-site transitive: `sharp` prebuilt binaries (LGPL-3.0-or-later, accepted)

`site/package-lock.json` resolves `sharp` 0.35.5 (Apache-2.0) as an
**optional** dependency of `astro`, which pulls its prebuilt platform packages
`@img/sharp-libvips-*` 1.3.4 (LGPL-3.0-or-later, the libvips build) and
`@img/sharp-{wasm32,win32-*}` 0.35.5 (Apache-2.0 AND LGPL-3.0-or-later). The
site does not use `astro:assets` image processing; `sharp` is only astro's
default image service, so it is a dev-time install artifact. The two LGPL
families are `@img/sharp-libvips` and `@img/sharp`:

- Nothing from these packages is copied into `site/dist/` (the deployed
  Pages artifact is static HTML/CSS/JS), and himmel does not redistribute the
  binaries: each contributor or CI run downloads them from npm unmodified.
- The LGPL obligations (notice, relinking) attach to whoever distributes the
  library; himmel neither modifies nor distributes it, so no obligation is
  triggered. Dropping it is not worth a lockfile override, since astro lists
  it as its own optional dependency.
- **Accepted** on 2026-10-23 (HIMMEL-7169). Revisit if the site starts
  shipping processed images or a bundled `node_modules`.

## Vendored skill: `unslop` (MIT, Lauren Tan)

Added 2026-09-17 (re-synced to the pin below in HIMMEL-5812), the first single-file skill vendored outside
`marketplace/plugins/*`. Lives at `.claude/skills/unslop/SKILL.md`, sourced
from `cursor/plugins` (pstack) at pinned commit
`99743e9c151c8537cbbf1f98bb38f34ef3368453`, path
`pstack/skills/unslop/SKILL.md`. No `node_modules`/npm involvement: a
single vendored markdown file, MIT-licensed. Decision record:
`specs/adr/adr-unslop-skill.md` in the handover state repo (registry row:
[`tool-adoption/registry.md`](tool-adoption/registry.md)).

MIT License text as it appeared at that commit
(`pstack/LICENSE`, unchanged between the two pins), reproduced here per the license's own attribution
requirement:

```
MIT License

Copyright (c) 2026 Lauren Tan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Vendored plugin: `pstack` (MIT, Lauren Tan)

Added 2026-10-15 (HIMMEL-5803). `marketplace/plugins/pstack/`, seven skills
(`correct`, `blast-radius`, `create-verification-skill`,
`maintain-verification-skill`, `benchmark-checklist`,
`principle-explain-the-number`, `in-your-own-words`) sourced from
`cursor/plugins` at pinned commit `99743e9c151c8537cbbf1f98bb38f34ef3368453`, path `pstack/`. Every file
names the pin and its deviations; the `unslop`, `no-comments` and
`comment-sicko` files above are re-synced to the same pin (HIMMEL-5812). Never
sourced from the `michael-denyer/pstack-claude` fork. Opt-in, off in every worker
profile (registry row: [`tool-adoption/registry.md`](tool-adoption/registry.md)).
The same pin also feeds a take-parts digest of six principles restated in our
wording; the digest itself vendors no files (HIMMEL-5810:
[`tool-adoption/pstack-principles-digest.md`](tool-adoption/pstack-principles-digest.md)).

MIT License text as it appeared at that commit (`pstack/LICENSE`), reproduced
here per the license's own attribution requirement:

```
MIT License

Copyright (c) 2026 Lauren Tan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Vendored plugin: `humanizer` (MIT, Siqi Chen)

Added 2026-10-16 (HIMMEL-5857). `marketplace/plugins/humanizer/`, one skill
(`humanizer`) sourced from `blader/humanizer` at pinned commit
`225a6f39ac85f76ee48dbad772ea4abe4ed6c9d8`. The `SKILL.md` header names the
pin and its one deviation (an added `disable-model-invocation: true`
frontmatter line). Opt-in, off in every profile (eval:
[`tool-adoption/humanizer.md`](tool-adoption/humanizer.md)).

MIT License text as it appeared at that commit (`LICENSE`), reproduced here
per the license's own attribution requirement:

```
MIT License

Copyright (c) 2025 Siqi Chen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Vendored plugin: `domain-modeling` (MIT, Matt Pocock)

Added 2026-10-17 (HIMMEL-5498). `marketplace/plugins/domain-modeling/`, one
skill (`domain-modeling`) sourced from `mattpocock/skills` at pinned commit
`49dd158d1076134a641b33efb035946536778336`, path
`skills/engineering/domain-modeling/`. The `SKILL.md` header names the pin and
its deviations (output retargeted at `docs/glossary.md`). On in the `design`
profile only (eval: [`tool-adoption/registry.md`](tool-adoption/registry.md)).

MIT License text as it appeared at that commit (`LICENSE`), reproduced here
per the license's own attribution requirement:

```
MIT License

Copyright (c) 2026 Matt Pocock

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Vendored skill: `test-audit` (MIT, OpenClaw Foundation)

Added 2026-09-24. Lives at `.claude/skills/test-audit/`
(`SKILL.md` adapted, with its deviations listed in its own header;
`CAMPAIGN.md` verbatim), sourced from `openclaw/openclaw` at pinned commit
`1370643e394f956dfae2e42f43ee030b0072434b`, path
`.agents/skills/test-audit/`. The GitHub API reports the repo licence as
`NOASSERTION` because the `LICENSE` file carries a trailing third-party-notices
line; the file itself is the MIT text. No `node_modules`/npm involvement.

MIT License text as it appeared at that commit (`LICENSE`), reproduced here
per the license's own attribution requirement:

```text
MIT License

Copyright (c) 2026 OpenClaw Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Non-npm sweep (marketplace/plugins + scripts)

- Every `marketplace/plugins/*` plugin with a `LICENSE` file declares MIT
  (`claude-hud`: fork, upstream copyright by Jarrod Watts, preserved per
  convention; `handover`, `himmel-ops`, `obsidian-triage`, `qmd`: MIT) or
  Apache-2.0 (`telegram-himmel`, which also carries
  a `NOTICE` file). All compatible with an MIT-top-level project.
  `luna-correlate` has no separate `LICENSE` (first-party, no fork lineage;
  inherits the repo root license).
- `rg`-style sweep for `copyright` / `SPDX-License` headers and
  vendored/copied-snippet markers across `marketplace/plugins/` and
  `scripts/` (excluding `node_modules`, `dist/`) found no third-party
  license headers outside the plugin `LICENSE`/`NOTICE` files above. The
  "vendored" hits that turned up (e.g. `scripts/hooks/wire-plugin-hook-bash.mjs`,
  `scripts/lib/wire-statusline.sh`) are internal cross-copies of himmel's own
  files (byte-identical duplicates shipped inside a plugin so it's
  self-contained), not third-party code, no separate attribution needed.

## Credits metadata

[Credits](credits.md) is generated from the marketplace manifest, fork adapter
registry and this table. This is the supplement for attribution fields those
registries do not carry, not a second inventory: `plugin:` and `fork:` keys
must name a live registry entry; `skill:` rows list the standalone vendored
skill families. `—` means use the registry field. Manifest URLs, licences and
remote pins win over supplements; fork upstreams, roles and pin sites always
come from the adapter registry. In-tree pin links point to the maintained
vendoring record instead of duplicating its revision here.

Licence declarations below come from the retained local licence files,
marketplace descriptions and upstream repository licence metadata read on
2026-10-22. `home-assistant.io/LICENSE.md` declares CC-BY-NC-SA-4.0 despite
GitHub reporting NOASSERTION. `animejs-skills` declares no licence; its row is
an explicit unknown, not permission to vendor it. Anthropic's skills have
per-skill terms, including source-available document skills, not a blanket
Apache licence. These rows do not extend the npm compatibility verdict above
to every registered repository; dormant and contribution-only forks are not
claims that their code is distributed in himmel.

Regenerate and check with `node scripts/docs/generate-credits.mjs` and
`node scripts/docs/generate-credits.mjs --check`.

<!-- credits-metadata:start -->
| Item | Source | Author | Licence | Pin |
|---|---|---|---|---|
| plugin:luna-correlate | https://github.com/yotamleo-org/Himmel/tree/main/marketplace/plugins/luna-correlate | — | MIT | In-tree |
| plugin:himmel-ops | https://github.com/yotamleo-org/Himmel/tree/main/marketplace/plugins/himmel-ops | — | MIT | In-tree |
| plugin:himmel-guard | https://github.com/yotamleo-org/Himmel/tree/main/marketplace/plugins/himmel-guard | — | MIT | In-tree |
| plugin:himmel-bus | https://github.com/yotamleo-org/Himmel/tree/main/marketplace/plugins/himmel-bus | — | MIT | In-tree |
| plugin:handover | https://github.com/yotamleo-org/Himmel/tree/main/marketplace/plugins/handover | — | MIT | In-tree |
| plugin:telegram-himmel | https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/telegram | — | — | [Fork record](../marketplace/plugins/telegram-himmel/README.md) |
| plugin:qmd | https://github.com/tobi/qmd | — | — | [Fork pin](../scripts/lib/qmd-bin.sh) |
| plugin:obsidian-triage | https://github.com/yotamleo-org/Himmel/tree/main/marketplace/plugins/obsidian-triage | — | MIT | In-tree |
| plugin:lean-skills | https://github.com/obra/superpowers , https://github.com/mattpocock/skills | — | — | [Per-family pins](../marketplace/plugins/lean-skills/VENDORED.md) |
| plugin:i-have-adhd | https://github.com/ayghri/i-have-adhd | — | — | [Vendoring pin](../marketplace/plugins/i-have-adhd/VENDORED.md) |
| plugin:pstack | https://github.com/cursor/plugins/tree/main/pstack | — | — | [Vendoring pin](../marketplace/plugins/pstack/VENDORED.md) |
| plugin:humanizer | https://github.com/blader/humanizer | — | — | [Vendoring pin](../marketplace/plugins/humanizer/VENDORED.md) |
| plugin:domain-modeling | https://github.com/mattpocock/skills | — | — | [Vendoring pin](../marketplace/plugins/domain-modeling/VENDORED.md) |
| plugin:plannotator-effective-html | — | — | MIT | — |
| plugin:impeccable | — | — | Apache-2.0 | — |
| plugin:emilkowalski-skills | — | — | MIT | — |
| plugin:ui-ux-pro-max | — | — | MIT | — |
| plugin:taste-skill-core | — | — | MIT | — |
| plugin:animejs-skills | — | — | Unknown (not declared upstream) | — |
| plugin:gsap-skills | — | — | MIT | — |
| plugin:lottie-motion-design | — | — | MIT | — |
| plugin:motion-lexicon | — | — | MIT | — |
| plugin:threejs-skills | — | — | MIT | — |
| plugin:ai-image-prompts | — | — | MIT | — |
| plugin:platform-design-skills | — | — | MIT | — |
| plugin:diagram-design | — | — | MIT | — |
| plugin:builder-visual | — | — | MIT | — |
| plugin:frontend-slides | — | — | MIT | — |
| plugin:design-dna | — | — | MIT | — |
| plugin:anydesign | — | — | MIT | — |
| plugin:popular-web-designs | — | — | MIT | — |
| plugin:design-md | — | — | MIT | — |
| plugin:hermes-artifact-design | — | — | MIT | — |
| plugin:anthropic-design-skills | — | — | Mixed: Apache-2.0 design skills; source-available docx/pdf/pptx/xlsx (per-skill LICENSE.txt) | — |
| plugin:hallmark | — | — | MIT | — |
| plugin:shadcn-mcp | https://github.com/shadcn-ui/ui | shadcn / yotamleo (wrapper) | — | [Runtime pin](../marketplace/plugins/shadcn-mcp/.mcp.json) |
| plugin:graphify | https://github.com/Graphify-Labs/graphify | Graphify-Labs / yotamleo (wrapper) | — | [Package pin](../scripts/lib/graphify-bin.sh) |
| skill:unslop | https://github.com/cursor/plugins/tree/main/pstack | Lauren Tan | MIT | 99743e9c151c8537cbbf1f98bb38f34ef3368453 |
| skill:no-comments + comment-sicko | https://github.com/cursor/plugins/tree/main/pstack | Lauren Tan | MIT | 99743e9c151c8537cbbf1f98bb38f34ef3368453 |
| skill:test-audit | https://github.com/openclaw/openclaw | OpenClaw Foundation | MIT | 1370643e394f956dfae2e42f43ee030b0072434b |
| skill:writing-for-agents | https://github.com/mattpocock/skills | Matt Pocock | MIT | 49dd158d1076134a641b33efb035946536778336 |
| fork:yotamleo-org/qmd | — | Tobi Lütke | MIT | — |
| fork:yotamleo-org/graphify | — | Graphify-Labs | Apache-2.0 | — |
| fork:yotamleo-org/claude-video | — | bradautomates | MIT | — |
| fork:yotamleo-org/obsidian-skills | — | Steph Ango | MIT | — |
| fork:yotamleo-org/twitter-cli | — | public-clis | Apache-2.0 | — |
| fork:yotamleo-org/claude-obsidian | — | AgriciDaniel | MIT | — |
| fork:yotamleo-org/codex-plugin-cc | — | OpenAI | Apache-2.0 | — |
| fork:yotamleo-org/obsidian-second-brain | — | Eugeniu Ghelbur | MIT | — |
| fork:yotamleo-org/effective-html | — | plannotator | MIT | — |
| fork:yotamleo-org/claude-hud | — | Jarrod Watts | MIT | — |
| fork:yotamleo-org/claude-statusline | — | Kamran Ahmed | MIT | — |
| fork:yotamleo-org/claude-squad | — | smtg-ai | AGPL-3.0 | — |
| fork:yotamleo-org/hermes-agent | — | NousResearch | MIT | — |
| fork:yotamleo-org/caveman | — | JuliusBrussee | Apache-2.0 | — |
| fork:yotamleo-org/codex | — | OpenAI | Apache-2.0 | — |
| fork:yotamleo-org/core | — | Home Assistant contributors | Apache-2.0 | — |
| fork:yotamleo-org/home-assistant.io | — | Home Assistant contributors | CC-BY-NC-SA-4.0 | — |
<!-- credits-metadata:end -->
