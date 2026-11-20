#!/usr/bin/env bash
# Tests for feed-clip.mjs. Fixtures are synthetic: local files and a loopback http server, never a real feed.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/feed-clip.mjs"
TGLIB="$TOOLS_DIR/lib/telegram-clip.mjs"
FIX="$SCRIPT_DIR/fixtures/feeds"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/feed-clip-test.XXXXXX")"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$tmpdir"; }
trap cleanup EXIT

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

export FEED_CLIP_TODAY=2026-11-20

out=""; rc=0
run_tool() { out="$(node "$SCRIPT" "$@" 2>&1)"; rc=$?; }

run_bounded() {
    local secs="$1" pid dog
    shift
    node "$SCRIPT" "$@" >"$tmpdir/_bounded.out" 2>&1 &
    pid=$!
    ( sleep "$secs"; kill "$pid" ) >/dev/null 2>&1 &
    dog=$!
    wait "$pid"; rc=$?
    pkill -P "$dog" >/dev/null 2>&1
    kill "$dog" >/dev/null 2>&1
    out="$(cat "$tmpdir/_bounded.out")"
}

newvault() { local v="$tmpdir/$1"; mkdir -p "$v/.obsidian" "$v/Clippings"; echo "$v"; }
pick() { local f; for f in "$1"/Clippings/$2; do [ -e "$f" ] && echo "$f"; done; }
nclips() { pick "$1" 'feed-*.md' | wc -l | tr -d ' '; }
seen_lines() { if [ -f "$V/.feed-clip-seen.jsonl" ]; then wc -l < "$V/.feed-clip-seen.jsonl" | tr -d ' '; else echo 0; fi; }
has() { if grep -q -- "$1" <<<"$2"; then echo ok; else echo no; fi; }
hasline() { if grep -qxF -- "$1" <<<"$2"; then echo ok; else echo no; fi; }

echo "Test 1: parse + usage + vault validation"
if [ -r "$SCRIPT" ]; then s=yes; else s=no; fi
assert "feed-clip.mjs exists" yes "$s"
if node --check "$SCRIPT" 2>/dev/null; then s=ok; else s=fail; fi
assert "feed-clip.mjs parses" ok "$s"
node "$SCRIPT" -h >/dev/null 2>&1; assert "-h exits 0" 0 "$?"
node "$SCRIPT" --weird >/dev/null 2>&1; assert "unknown arg exits 1" 1 "$?"
node "$SCRIPT" --cap 0 >/dev/null 2>&1; assert "--cap 0 exits 1" 1 "$?"
node "$SCRIPT" --cap abc >/dev/null 2>&1; assert "--cap abc exits 1" 1 "$?"
node "$SCRIPT" --cap >/dev/null 2>&1; assert "--cap with no value exits 1" 1 "$?"
NOVAULT="$tmpdir/novault"; mkdir -p "$NOVAULT"
node "$SCRIPT" --vault "$NOVAULT" >/dev/null 2>&1; assert "vault without .obsidian exits 2" 2 "$?"
node "$SCRIPT" --vault "$tmpdir/does-not-exist" >/dev/null 2>&1; assert "missing vault exits 2" 2 "$?"

cat > "$tmpdir/server.mjs" <<'EOF'
import http from "node:http";
import { readFileSync } from "node:fs";
const ok = readFileSync(process.argv[2]);
const blog = readFileSync(process.argv[3]);
const big = "<?xml version='1.0'?><rss version='2.0'><channel>" + "<!-- pad -->".repeat(2000) + "</channel></rss>";
const s = http.createServer((q, r) => {
  if (q.url === "/ok") { r.writeHead(200, { "content-type": "application/atom+xml" }); r.end(ok); }
  else if (q.url === "/blog") { r.writeHead(200, { "content-type": "application/rss+xml" }); r.end(blog); }
  else if (q.url === "/500") { r.writeHead(500); r.end("boom"); }
  else if (q.url === "/hang") { /* never answers */ }
  else if (q.url === "/redir-walled") { r.writeHead(302, { location: "http://x.com/feed.xml" }); r.end(); }
  else if (q.url === "/loop") { r.writeHead(302, { location: "/loop" }); r.end(); }
  else if (q.url === "/redir-ok") { r.writeHead(302, { location: "/ok" }); r.end(); }
  else if (q.url === "/html") { r.writeHead(200, { "content-type": "text/html" }); r.end("<html><body>not a feed</body></html>"); }
  else if (q.url === "/big") { r.writeHead(200); r.end(big); }
  else { r.writeHead(404); r.end(); }
});
s.listen(0, "127.0.0.1", () => console.log(s.address().port + " " + process.pid));
EOF
exec 3< <(node "$tmpdir/server.mjs" "$FIX/atom-releases.xml" "$FIX/rss-blog.xml")
read -r PORT SRV_PID <&3
if [ -n "${PORT:-}" ]; then s=yes; else s=no; fi
assert "loopback fixture server started" yes "$s"

echo "Test 3: one inbox clip per entry; a second run writes none"
V="$(newvault basic)"
printf '# synthetic feeds\nfile://%s AtomRel\nfile://%s RssBlog\n' "$FIX/atom-releases.xml" "$FIX/rss-blog.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V"
assert "first run exits 0" 0 "$rc"
assert "first run wrote 4 clips (2 atom + 2 rss; no-link and script-link entries skipped)" 4 "$(nclips "$V")"
assert "seen file has 4 lines" 4 "$(seen_lines)"
run_tool --vault "$V"
assert "second run exits 0" 0 "$rc"
assert "second run wrote no clip" 4 "$(nclips "$V")"
assert "second run left the seen file alone" 4 "$(seen_lines)"

echo "Test 4: a feed clip has the shape of a Telegram clip"
rel="$(pick "$V" 'feed-*v1-2-0.md')"
assert "release clip exists" 1 "$(printf '%s\n' "$rel" | grep -c .)"
base="$(basename "$rel")"
if [[ "$base" =~ ^feed-[0-9a-f]{10}-[a-z0-9-]+\.md$ ]]; then s=ok; else s="$base"; fi
assert "file name is feed-<id hash>-<slug>.md" ok "$s"
assert "clipped_via: feed" ok "$(hasline 'clipped_via: feed' "$(cat "$rel")")"
assert "status: unread" ok "$(hasline 'status: unread' "$(cat "$rel")")"
assert "tags: []" ok "$(hasline 'tags: []' "$(cat "$rel")")"
assert "date_clipped is today" ok "$(hasline 'date_clipped: 2026-11-20' "$(cat "$rel")")"
assert "github release is type research (the Telegram classifier)" ok "$(hasline 'type: research' "$(cat "$rel")")"
assert "source line is the entry link" ok "$(hasline 'source: https://github.com/example-org/example-repo/releases/tag/v1.2.0' "$(cat "$rel")")"
assert "Source section" ok "$(hasline '[https://github.com/example-org/example-repo/releases/tag/v1.2.0](https://github.com/example-org/example-repo/releases/tag/v1.2.0)' "$(cat "$rel")")"
if grep -qE '^(harvested_at|processed|telegram_[a-z_]*):' "$rel"; then s=present; else s=absent; fi
assert "no harvested_at / processed / telegram_* key" absent "$s"
blog="$(pick "$V" 'feed-*scaling-queues-at-example.md')"
assert "non-github link is type article" ok "$(hasline 'type: article' "$(cat "$blog")")"

LIB="$TGLIB" CLIPF="$rel" node --input-type=module -e "
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const lib = await import(pathToFileURL(process.env.LIB).href);
const keys = (t) => t.split('\n---')[0].split('\n').filter((l) => /^[A-Za-z_]+:/.test(l)).map((l) => l.split(':')[0]);
const url = 'https://github.com/example-org/example-repo/releases/tag/v1.2.0';
const tg = lib.buildClip({ sender: 's', ts: 't', msgId: '1', chatId: 'c', text: url, type: 'research', source: url, today: '2026-11-20' });
const a = keys(tg).filter((k) => !k.startsWith('telegram_')).join(',');
const b = keys(readFileSync(process.env.CLIPF, 'utf8')).join(',');
console.log(a === b ? 'same' : a + ' != ' + b);
" >"$tmpdir/_keys" 2>&1
assert "front-matter keys + order match a Telegram clip (telegram_* aside)" same "$(cat "$tmpdir/_keys")"

(cd "$TOOLS_DIR" && CLIPS_DIR="$V/Clippings" node --input-type=module -e "
import {readFileSync, readdirSync} from 'node:fs';
const _y = await import('js-yaml'); const yaml = _y.default ?? _y;
let bad = 0, n = 0;
for (const f of readdirSync(process.env.CLIPS_DIR).filter((f) => f.startsWith('feed-') && f.endsWith('.md'))) {
  const t = readFileSync(process.env.CLIPS_DIR + '/' + f, 'utf8').replace(/\r\n/g, '\n');
  const fm = yaml.load(t.slice(4, t.indexOf('\n---', 4)));
  n++;
  if (fm.clipped_via !== 'feed' || fm.status !== 'unread' || !Array.isArray(fm.tags) || typeof fm.title !== 'string' || !/^https?:/.test(fm.source)) bad++;
}
console.log(bad === 0 && n === 4 ? 'valid' : 'BAD ' + bad + '/' + n);
") >"$tmpdir/_yaml" 2>&1
assert "every written clip is valid YAML (4 clips)" valid "$(cat "$tmpdir/_yaml")"

unharv=0
for f in "$V"/Clippings/*.md "$V"/Clippings/*/*.md; do
  [ -f "$f" ] || continue
  case "$f" in */_synthesis/*|*/_done/*|*/_evidence/*|*/_deferred.md) continue ;; esac
  grep -qE '^harvested_at:[[:space:]]*[^[:space:]]' "$f" || unharv=$((unharv+1))
done
assert "the harvest scan lists all 4 clips as unharvested" 4 "$unharv"

echo "Test 5: titles and body text"
assert "label prefixes a bare version title" ok "$(hasline 'title: "AtomRel: v1.2.0"' "$(cat "$rel")")"
assert "release body: list item text kept" ok "$(hasline '- Added the --fast flag' "$(cat "$rel")")"
assert "release body: list items sit on consecutive lines" "- Fixed a crash & a hang" "$(grep -A1 -xF -- '- Added the --fast flag' "$rel" | tail -n 1)"
assert "release body: entity decoded once" ok "$(has 'Fixed a crash & a hang' "$(cat "$rel")")"
if grep -q '<' "$rel"; then s=markup; else s=clean; fi
assert "release body has no markup" clean "$s"
assert "quoted/angle title survives in YAML" ok "$(hasline 'title: "RssBlog: Scaling \"queues\" at <Example>"' "$(cat "$blog")")"
second="$(pick "$V" 'feed-*second-post*.md')"
assert "content:encoded wins over description" ok "$(has 'Second paragraph with a link\.' "$(cat "$second")")"
if grep -q 'short teaser' "$second"; then s=teaser; else s=full; fi
assert "description dropped when content:encoded is present" full "$s"
if grep -q 'alert(1)' "$second"; then s=script; else s=none; fi
assert "script element dropped" none "$s"
assert "blog description kept when it is all there is" ok "$(has 'How we scaled & tuned the queue\.' "$(cat "$blog")")"
nolink=$(grep -l 'Entry without a link' "$V"/Clippings/*.md 2>/dev/null | wc -l | tr -d ' ')
assert "entry without a link is not clipped" 0 "$nolink"
nojs=$(grep -l 'javascript:' "$V"/Clippings/*.md 2>/dev/null | wc -l | tr -d ' ')
assert "entry with a non-http link is not clipped" 0 "$nojs"

echo "Test 6: failing feeds"
V="$(newvault failing)"
cat > "$V/.feed-clip-feeds" <<EOF
file://$tmpdir/nope.xml Missing
http://127.0.0.1:$PORT/500 Err500
http://127.0.0.1:$PORT/hang Hang
https://x.com/example/feed.xml Walled
http://127.0.0.1:$PORT/redir-walled RedirWalled
http://127.0.0.1:$PORT/html NotAFeed
http://127.0.0.1:$PORT/big Big
http://127.0.0.1:$PORT/redir-ok RedirOk
file://$FIX/rss-blog.xml Blog
not a url
EOF
FEED_CLIP_TIMEOUT_MS=400 FEED_CLIP_MAX_BYTES=2000 run_tool --vault "$V"
assert "exit code is 0 with failing feeds" 0 "$rc"
assert "8 failures, one line each" 8 "$(grep -c '^✗ feed-clip:' <<<"$out")"
assert "missing file reported" ok "$(has '^✗ feed-clip: Missing' "$out")"
assert "HTTP 500 reported" ok "$(has '^✗ feed-clip: Err500.*HTTP 500' "$out")"
assert "hang reported as a timeout" ok "$(has '^✗ feed-clip: Hang.*timed out' "$out")"
assert "walled host refused" ok "$(has '^✗ feed-clip: Walled.*walled' "$out")"
assert "redirect to a walled host refused" ok "$(has '^✗ feed-clip: RedirWalled.*walled' "$out")"
assert "non-feed reported" ok "$(has '^✗ feed-clip: NotAFeed.*not a feed' "$out")"
assert "oversized feed reported" ok "$(has '^✗ feed-clip: Big.*larger than' "$out")"
assert "malformed list line reported with its line number" ok "$(has 'feed-clip: .*feed-clip-feeds:10' "$out")"
assert "the good feeds still wrote their clips (2 via redirect + 2 blog)" 4 "$(nclips "$V")"
assert "failed feeds wrote no seen line" 4 "$(seen_lines)"

echo "Test 6a: http feed with a link-less entry"
V="$(newvault httpblog)"
printf 'http://127.0.0.1:%s/blog Blog\n' "$PORT" > "$V/.feed-clip-feeds"
run_tool --vault "$V"
assert "http blog feed: exit 0" 0 "$rc"
assert "http blog feed: 2 clips (the link-less and the script-link entries skipped)" 2 "$(nclips "$V")"
if grep -l '^source: http://127.0.0.1' "$V"/Clippings/*.md >/dev/null 2>&1; then s=feed-url; else s=none; fi
assert "no clip carries the feed URL as its source" none "$s"

echo "Test 6c: a walled host spelled with a trailing dot"
V="$(newvault dotted)"
{ printf 'https://x.com./example/feed.xml Dotted\n'; printf 'file://%s AtomRel\n' "$FIX/atom-releases.xml"; } > "$V/.feed-clip-feeds"
run_tool --vault "$V"
assert "dotted host: exit 0" 0 "$rc"
assert "a walled host with a trailing dot is refused" 1 "$(grep -c '^✗ feed-clip: Dotted.*walled' <<<"$out")"
assert "dotted host: the other feed still wrote its 2 clips" 2 "$(nclips "$V")"

echo "Test 6b: a crafted feed cannot stall the parser"
V="$(newvault hostile)"
{
  printf '<feed xmlns="http://www.w3.org/2005/Atom"><title>Hostile</title>'
  yes '<entry<entry' | head -n 100000 | tr -d '\n'
  printf '<entry><id>h1</id><link href="https://example.com/h1"/><title>t</title><content type="html">'
  yes '<script <![CDATA[ <title <a ' | head -n 30000 | tr -d '\n'
  printf '</content></entry></feed>'
} > "$tmpdir/hostile.xml"
printf 'file://%s Hostile\n' "$tmpdir/hostile.xml" > "$V/.feed-clip-feeds"
SECONDS=0
run_bounded 15 --vault "$V"
elapsed=$SECONDS
assert "crafted feed: exit 0" 0 "$rc"
if [ "$elapsed" -le 15 ]; then s=fast; else s="${elapsed}s"; fi
assert "crafted feed parsed in 15 s or less" fast "$s"
assert "crafted feed still yielded its one entry" 1 "$(nclips "$V")"
hostile_clip="$(pick "$V" 'feed-*hostile-t.md')"
assert "crafted feed: the entry's title" ok "$(hasline 'title: "Hostile: t"' "$(cat "$hostile_clip")")"
assert "crafted feed: the entry's source" ok "$(hasline 'source: https://example.com/h1' "$(cat "$hostile_clip")")"
assert "crafted feed: the long body ends at the cap with an ellipsis" ok "$(has '…$' "$(tail -n 4 "$hostile_clip" | head -n 1)")"
assert "crafted feed: the clip stays under 7 KB" small "$([ "$(wc -c < "$hostile_clip")" -lt 7000 ] && echo small || echo big)"

echo "Test 7: per-feed cap"
V="$(newvault cap)"
{
  printf '<?xml version="1.0"?>\n<feed xmlns="http://www.w3.org/2005/Atom"><title>Ten feed</title>\n'
  n=1
  while [ "$n" -le 10 ]; do
    printf '<entry><id>ten-%s</id><updated>2026-11-%02dT10:00:00Z</updated><link rel="alternate" href="https://example.com/ten/%s"/><title>Ten entry %s</title><content type="html">&lt;p&gt;Body %s&lt;/p&gt;</content></entry>\n' "$n" "$n" "$n" "$n" "$n"
    n=$((n+1))
  done
  printf '</feed>\n'
} > "$tmpdir/ten.xml"
printf 'file://%s Ten\n' "$tmpdir/ten.xml" > "$V/.feed-clip-feeds"
FEED_CLIP_MAX_BYTES=500 run_tool --vault "$V"
assert "a local feed larger than the size limit is one failure line" 1 "$(grep -c '^✗ feed-clip: Ten.*larger than' <<<"$out")"
assert "an oversized local feed clips nothing" 0 "$(nclips "$V")"
run_tool --vault "$V" --cap 3
assert "run 1 exits 0" 0 "$rc"
assert "run 1 wrote exactly 3 clips" 3 "$(nclips "$V")"
n10=$(find "$V/Clippings" -name '*ten-entry-10.md' | wc -l | tr -d ' ')
n9=$(find "$V/Clippings" -name '*ten-entry-9.md' | wc -l | tr -d ' ')
n8=$(find "$V/Clippings" -name '*ten-entry-8.md' | wc -l | tr -d ' ')
assert "run 1 took the 3 newest entries" "1 1 1" "$n10 $n9 $n8"
assert "run 1 says 7 are pending" ok "$(has '7 pending' "$out")"
run_tool --vault "$V" --cap 3; assert "run 2 total" 6 "$(nclips "$V")"
run_tool --vault "$V" --cap 3; assert "run 3 total" 9 "$(nclips "$V")"
run_tool --vault "$V" --cap 3; assert "run 4 total (the last one)" 10 "$(nclips "$V")"
run_tool --vault "$V" --cap 3; assert "run 5 wrote nothing" 10 "$(nclips "$V")"
assert "run 5 exits 0" 0 "$rc"
distinct=$(find "$V/Clippings" -name 'feed-*.md' | sed 's/.*feed-\([0-9a-f]*\)-.*/\1/' | sort -u | wc -l | tr -d ' ')
assert "10 distinct clips" 10 "$distinct"
V2="$(newvault cap-default)"
printf 'file://%s Ten\n' "$tmpdir/ten.xml" > "$V2/.feed-clip-feeds"
run_tool --vault "$V2"
assert "default cap is 3" 3 "$(nclips "$V2")"

echo "Test 8: seen state"
V="$(newvault state)"
printf 'file://%s Ten\n' "$tmpdir/ten.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --cap 10
assert "10 clips" 10 "$(nclips "$V")"
rm "$(find "$V/Clippings" -name '*ten-entry-5.md')"
run_tool --vault "$V" --cap 10
assert "a deleted clip is not clipped again" 9 "$(nclips "$V")"
V="$(newvault lost-state)"
printf 'file://%s Ten\n' "$tmpdir/ten.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --cap 10
first="$(find "$V/Clippings" -name '*ten-entry-7.md')"
printf 'EDITED BY HAND\n' >> "$first"
rm "$V/.feed-clip-seen.jsonl"
run_tool --vault "$V" --cap 10
assert "lost state: exit 0" 0 "$rc"
assert "lost state: no duplicate clip" 10 "$(nclips "$V")"
assert "lost state: existing clip never overwritten" ok "$(has 'EDITED BY HAND' "$(cat "$first")")"
assert "lost state: seen file rebuilt" 10 "$(seen_lines)"
V="$(newvault truncated)"
printf 'file://%s Ten\n' "$tmpdir/ten.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --cap 3
printf '{"feed":"x","id":"y' >> "$V/.feed-clip-seen.jsonl"
run_tool --vault "$V" --cap 3
assert "a truncated seen line does not fail the run" 0 "$rc"
assert "after a truncated seen line the next 3 entries were clipped" 6 "$(nclips "$V")"
assert "the record written after a truncated line starts its own line" 7 "$(seen_lines)"
valid_records="$(SEEN="$V/.feed-clip-seen.jsonl" node --input-type=module -e "
import {readFileSync} from 'node:fs';
let n = 0;
for (const l of readFileSync(process.env.SEEN, 'utf8').split('\n')) {
  if (!l) continue;
  try { const r = JSON.parse(l); if (r.feed && r.id) n++; } catch { continue; }
}
console.log(n);
")"
assert "every record but the truncated one is valid JSON" 6 "$valid_records"
run_tool --vault "$V" --cap 10
assert "no record was lost: the remaining 4 entries clip and none is written twice" 0 "$(grep -c 'already exists' <<<"$out")"
assert "all 10 entries are clipped exactly once" 10 "$(nclips "$V")"

echo "Test 9: --dry-run"
V="$(newvault dry)"
printf 'file://%s AtomRel\n' "$FIX/atom-releases.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --dry-run
assert "dry-run exits 0" 0 "$rc"
assert "dry-run lists what it would clip" 2 "$(grep -c 'would clip' <<<"$out")"
assert "dry-run names the entry link" ok "$(has 'https://github.com/example-org/example-repo/releases/tag/v1.2.0' "$out")"
assert "dry-run wrote no clip" 0 "$(nclips "$V")"
if [ -e "$V/.feed-clip-seen.jsonl" ]; then s=written; else s=absent; fi
assert "dry-run wrote no seen file" absent "$s"
run_tool --vault "$V"
assert "the real run after a dry run still clips both" 2 "$(nclips "$V")"

echo "Test 10: feed list location"
V="$(newvault nolist)"
run_tool --vault "$V"
assert "no feed list exits 0" 0 "$rc"
assert "no feed list is reported" ok "$(has 'no feed list' "$out")"
assert "no feed list wrote nothing" 0 "$(nclips "$V")"
printf 'file://%s AtomRel\n' "$FIX/atom-releases.xml" > "$tmpdir/elsewhere.list"
run_tool --vault "$V" --feeds "$tmpdir/elsewhere.list"
assert "--feeds reads a list from another path" 2 "$(nclips "$V")"
run_tool --vault "$V" --feeds "$tmpdir/does-not-exist.list"
assert "--feeds with a missing file exits 0 with a note" ok "$(has 'no feed list' "$out")"

echo "Test 12: redirect loop, body caps, non-printable characters"
V="$(newvault loop)"
printf 'http://127.0.0.1:%s/loop Loop\nfile://%s AtomRel\n' "$PORT" "$FIX/atom-releases.xml" > "$V/.feed-clip-feeds"
run_bounded 10 --vault "$V"
assert "redirect loop: the run ends by itself with exit 0" 0 "$rc"
assert "redirect loop: one line, too many redirects" 1 "$(grep -c '^✗ feed-clip: Loop.*too many redirects' <<<"$out")"
assert "redirect loop: the next feed still ran" 2 "$(nclips "$V")"

{
  printf '<feed xmlns="http://www.w3.org/2005/Atom"><title>Caps</title>\n'
  printf '<entry><id>long</id><updated>2026-11-02T10:00:00Z</updated><link rel="alternate" href="https://example.com/long"/><title>Long body</title><summary>'
  yes word | head -n 8000 | tr '\n' ' '
  printf '</summary></entry>\n'
  printf '<entry><id>wide</id><updated>2026-11-01T10:00:00Z</updated><link rel="alternate" href="https://example.com/wide"/><title>Wide markup</title><content type="html"><![CDATA[HEADMARK '
  yes '<i></i>' | head -n 30000 | tr -d '\n'
  printf 'TAILMARK]]></content></entry>\n</feed>\n'
} > "$tmpdir/caps.xml"
V="$(newvault caps)"
printf 'file://%s Caps\n' "$tmpdir/caps.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V"
longclip="$(pick "$V" 'feed-*long-body.md')"
wideclip="$(pick "$V" 'feed-*wide-markup.md')"
assert "long body: the clip stays under 7 KB" small "$([ "$(wc -c < "$longclip")" -lt 7000 ] && echo small || echo big)"
assert "long body: the text ends at the cap with an ellipsis" ok "$(has '…$' "$(tail -n 4 "$longclip" | head -n 1)")"
assert "wide markup: text inside the HTML limit is kept" ok "$(has 'HEADMARK' "$(cat "$wideclip")")"
if grep -q TAILMARK "$wideclip"; then s=present; else s=absent; fi
assert "wide markup: text past the HTML limit is dropped" absent "$s"

printf '<feed xmlns="http://www.w3.org/2005/Atom"><title>NP</title><entry><id>np1</id><link rel="alternate" href="https://example.com/np1"/><title>A&#x90;B&#xFFFE;C&#xFFFF;D&#xD800;E&#x7F;F\302\237G</title><summary>body &#x90; text</summary></entry></feed>\n' > "$tmpdir/np.xml"
V="$(newvault nonprintable)"
printf 'file://%s NP\n' "$tmpdir/np.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V"
npclip="$(pick "$V" 'feed-*np-*.md')"
assert "non-printable title: the printable characters are kept, the rest dropped" ok "$(hasline 'title: "NP: ABCDEFG"' "$(cat "$npclip")")"
nonprint="$(CLIPF="$npclip" node --input-type=module -e "
import {readFileSync} from 'node:fs';
const t = readFileSync(process.env.CLIPF, 'utf8');
console.log(/[^\t\n\r\x20-\x7E\xA0-\u{D7FF}\u{E000}-\u{FFFD}\u{10000}-\u{10FFFF}]/u.test(t.slice(0, t.indexOf('\n---', 4))) ? 'unprintable' : 'printable');
")"
assert "non-printable title: the front matter holds only YAML-printable characters" printable "$nonprint"
if python3 -I -c 'import yaml' 2>/dev/null; then
    py="$(CLIPF="$npclip" python3 -I -c '
import os, yaml
t = open(os.environ["CLIPF"], encoding="utf8").read()
try:
    yaml.safe_load(t[4:t.index("\n---", 4)])
    print("ok")
except Exception:
    print("error")
')"
    assert "non-printable title: PyYAML parses the written front matter" ok "$py"
fi

echo "Test 13: the README names the nightly harvest runner as what schedules the tool"
readme="$SCRIPT_DIR/../README.md"
feed_section="$(awk '/^### Feed clips/{p=1; next} /^### /{p=0} p' "$readme")"
assert "README: the feed section names the nightly harvest runner" 1 "$(printf '%s\n' "$feed_section" | grep -c 'nightly harvest runner')"
assert "README: the feed section no longer says no repository job runs the tool" 0 "$(printf '%s\n' "$feed_section" | grep -c 'No repository job runs the tool')"

echo "Test 11: unreadable state"
V="$(newvault badstate)"
printf 'file://%s AtomRel\n' "$FIX/atom-releases.xml" > "$V/.feed-clip-feeds"
mkdir "$V/.feed-clip-seen.jsonl"
run_tool --vault "$V"
assert "an unreadable seen file exits 2" 2 "$rc"
assert "an unreadable seen file clips nothing" 0 "$(nclips "$V")"
V="$(newvault badlist)"
mkdir "$V/.feed-clip-feeds"
run_tool --vault "$V"
assert "an unreadable feed list exits 2" 2 "$rc"

echo "Test 12: a per-feed skip filter on entry titles"
PRE="$FIX/atom-prerelease.xml"
V="$(newvault prerel-open)"
printf 'file://%s Prerel\n' "$PRE" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --cap 10
assert "control: with no filter all five entries are clipped" 5 "$(nclips "$V")"

V="$(newvault prerel)"
printf 'file://%s Prerel skip=alpha,nightly,rc,mobile\n' "$PRE" > "$V/.feed-clip-feeds"
run_tool --vault "$V"
assert "skip filter: exits 0" 0 "$rc"
assert "skip filter: five entries, three matching, two clips" 2 "$(nclips "$V")"
assert "skip filter: no nightly clip" 0 "$(grep -l 'nightly' "$V"/Clippings/feed-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "skip filter: no alpha clip" 0 "$(grep -l 'alpha' "$V"/Clippings/feed-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "skip filter: no release-candidate clip" 0 "$(grep -l 'rc1' "$V"/Clippings/feed-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "skip filter: a title holding rc inside a word is not skipped" 1 "$(grep -l 'source maps fix' "$V"/Clippings/feed-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "skip filter: the label stays the label, the skip= word is not part of it" ok "$(hasline 'title: "Prerel: v2.0.0"' "$(cat "$(pick "$V" 'feed-*v2-0-0.md')")")"
assert "skip filter: the feed line reports the skipped count" ok "$(has '3 skipped by filter' "$out")"
assert "skip filter: skipped entries are not recorded as seen" 2 "$(seen_lines)"
run_tool --vault "$V"
assert "skip filter: a second run clips nothing more" 2 "$(nclips "$V")"

V="$(newvault prerel-cap)"
printf 'file://%s Prerel skip=alpha,nightly,rc\n' "$PRE" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --cap 1
assert "skip filter: skipped newest entries do not use up the cap (cap 1 clips one)" 1 "$(nclips "$V")"
assert "skip filter: the pending count leaves skipped entries out" ok "$(has '1 pending' "$out")"

V="$(newvault prerel-dry)"
printf 'file://%s Prerel skip=alpha,nightly,rc\n' "$PRE" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --dry-run
assert "skip filter: a dry run lists no nightly tag" 0 "$(grep -c 'nightly' <<<"$out")"
assert "skip filter: a dry run lists no alpha tag" 0 "$(grep -c 'alpha' <<<"$out")"
assert "skip filter: a dry run lists the two kept entries" 2 "$(grep -c 'would clip' <<<"$out")"

V="$(newvault bound)"
printf 'file://%s Bound skip=rc\n' "$FIX/atom-boundary.xml" > "$V/.feed-clip-feeds"
run_tool --vault "$V" --cap 10
assert "skip word at the end of a longer word is not skipped (arc)" 1 "$(grep -l 'The arc release' "$V"/Clippings/feed-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "skip word at the start of a longer word is not skipped (rcs)" 1 "$(grep -l 'rcs update' "$V"/Clippings/feed-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "skip word followed by a digit is skipped (rc2)" 0 "$(grep -l 'rc2' "$V"/Clippings/feed-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "skip word boundaries: three clips, one skipped" 3 "$(nclips "$V")"

for bad in 'skip=' 'skip=a;b' 'skip=,' 'skip=alpha skip=rc'; do
    V="$(newvault prerel-bad)"
    printf 'file://%s Prerel %s\n' "$PRE" "$bad" > "$V/.feed-clip-feeds"
    run_tool --vault "$V"
    assert "malformed '$bad': the line is reported and skipped, nothing clipped" ok "$([ "$(nclips "$V")" = 0 ] && grep -q 'skip' <<<"$out" && echo ok || echo no)"
    rm -rf "$V"
done

echo ""
echo "feed-clip tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
