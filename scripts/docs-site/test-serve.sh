#!/usr/bin/env bash
# scripts/docs-site/test-serve.sh — journey J1: the operator opens
# the local docs site. Runs serve.sh for real on 127.0.0.1:4321.
# The mid-build port race runs against stub npm/npx; the real serve needs
# `npm ci` in site/ (network) and skips loudly without it.
set -u
repo=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

if (exec 3<>/dev/tcp/127.0.0.1/4321) 2>/dev/null; then
  echo "SKIP: port 4321 is busy on this host; free it to run J1"
  exit 0
fi

tmp=$(mktemp -d -t docs-site-j1.XXXXXX) || exit 1
srv=""
blocker=""
foreign=""
owned=0
stop_server() {
  # astro detaches into its own session; the lock in site/.astro names the one server this run started
  if [ "$owned" -eq 1 ]; then
    (cd "$repo/site" && npx astro preview stop) >/dev/null 2>&1
    owned=0
  fi
  [ -n "$srv" ] && kill "$srv" 2>/dev/null
  srv=""
}
cleanup() {
  stop_server
  [ -n "$blocker" ] && kill "$blocker" 2>/dev/null
  [ -n "$foreign" ] && kill "$foreign" 2>/dev/null
  [ -f "$tmp/racer.pid" ] && kill "$(cat "$tmp/racer.pid")" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

listening() { (exec 3<>"/dev/tcp/$1/4321") 2>/dev/null; } # listening <host>
wait_free() { # wait_free <host>
  for _ in 1 2 3 4 5 6 7 8 9 10; do listening "$1" || return 0; sleep 0.3; done
  ko "port 4321 on $1 never freed"
}

# --- port claimed mid-build: non-zero exit, port named, no URL, preview never started
mkdir "$tmp/bin"
cat >"$tmp/bin/npm" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  ci) exit 0 ;;
  "run build") ;;
  *) echo "stub npm: unexpected args: $*" >&2; exit 97 ;;
esac
node -e "require('net').createServer().listen(4321,'127.0.0.1');setTimeout(()=>{},60000)" >/dev/null 2>&1 &
echo $! >"$J1_RACER_PID"
for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>/dev/tcp/127.0.0.1/4321) 2>/dev/null && exit 0; sleep 0.3; done
exit 1
STUB
cat >"$tmp/bin/npx" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$J1_NPX_LOG"
STUB
chmod +x "$tmp/bin/npm" "$tmp/bin/npx"
if out=$(PATH="$tmp/bin:$PATH" J1_RACER_PID="$tmp/racer.pid" J1_NPX_LOG="$tmp/npx.log" bash "$repo/scripts/docs-site/serve.sh" 2>&1); then
  ko "port claimed mid-build exits non-zero"
else
  case "$out" in *4321*) ok "port claimed mid-build exits non-zero and names 4321" ;; *) ko "port claimed mid-build names the port (got: $out)" ;; esac
fi
case "$out" in *'docs site: http'*) ko "port claimed mid-build prints no URL" ;; *) ok "port claimed mid-build prints no URL" ;; esac
if [ ! -e "$tmp/npx.log" ]; then ok "port claimed mid-build never starts preview"; else ko "port claimed mid-build never starts preview"; fi
[ -f "$tmp/racer.pid" ] && kill "$(cat "$tmp/racer.pid")" 2>/dev/null
rm -f "$tmp/racer.pid"
wait_free 127.0.0.1

# --- a stranger on [::1]:4321 makes astro shift ports: serve.sh must refuse, not print 4321
node -e "require('net').createServer().listen(4321,'::1');setTimeout(()=>{},60000)" >/dev/null 2>&1 &
foreign=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do listening ::1 && break; sleep 0.3; done
if listening ::1; then
  if out=$(PATH="$tmp/bin:$PATH" J1_RACER_PID="$tmp/racer.pid" J1_NPX_LOG="$tmp/npx6.log" bash "$repo/scripts/docs-site/serve.sh" 2>&1); then
    ko "IPv6-busy port exits non-zero"
  else
    case "$out" in *4321*) ok "IPv6-busy port exits non-zero and names 4321" ;; *) ko "IPv6-busy port names the port (got: $out)" ;; esac
  fi
  if [ ! -e "$tmp/npx6.log" ]; then ok "IPv6-busy port never starts preview"; else ko "IPv6-busy port never starts preview"; fi
else
  echo "SKIP: no IPv6 loopback; IPv6 rows not run"
fi
kill "$foreign" 2>/dev/null
foreign=""
[ -f "$tmp/racer.pid" ] && kill "$(cat "$tmp/racer.pid")" 2>/dev/null
rm -f "$tmp/racer.pid"
wait_free ::1
wait_free 127.0.0.1

# --- lockfile change: serve.sh reinstalls only when package-lock.json differs from the install stamp
fake="$tmp/fake"
mkdir -p "$fake/scripts/docs-site" "$fake/site" "$tmp/lbin"
cp "$repo/scripts/docs-site/serve.sh" "$fake/scripts/docs-site/serve.sh"
echo '{"lock":1}' >"$fake/site/package-lock.json"
cat >"$tmp/lbin/npm" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  ci) echo ci >>"$J1_NPM_LOG"; mkdir -p node_modules/astro; exit 0 ;;
  "run build") exit 0 ;;
  *) echo "stub npm: unexpected args: $*" >&2; exit 97 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/lbin/npx"
chmod +x "$tmp/lbin/npm" "$tmp/lbin/npx"
serve_fake() { PATH="$tmp/lbin:$PATH" J1_NPM_LOG="$tmp/lock.log" bash "$fake/scripts/docs-site/serve.sh" >/dev/null 2>&1; }
installs() { [ -f "$tmp/lock.log" ] && wc -l <"$tmp/lock.log" || echo 0; }
serve_fake
if [ "$(installs)" -eq 1 ]; then ok "lockfile: first serve installs"; else ko "lockfile: first serve installs (got $(installs))"; fi
serve_fake
if [ "$(installs)" -eq 1 ]; then ok "lockfile: unchanged lockfile does not reinstall"; else ko "lockfile: unchanged lockfile does not reinstall (got $(installs))"; fi
echo '{"lock":2}' >"$fake/site/package-lock.json"
serve_fake
if [ "$(installs)" -eq 2 ]; then ok "lockfile: changed lockfile reinstalls"; else ko "lockfile: changed lockfile reinstalls (got $(installs))"; fi
serve_fake
if [ "$(installs)" -eq 2 ]; then ok "lockfile: reinstall is stamped, next serve skips"; else ko "lockfile: reinstall is stamped, next serve skips (got $(installs))"; fi
rm "$fake/site/package-lock.json"
if serve_fake || [ "$(installs)" -ne 2 ]; then ko "lockfile: unhashable lockfile fails without installing"; else ok "lockfile: unhashable lockfile fails without installing"; fi

if [ ! -d "$repo/site/node_modules/astro" ]; then
  echo "SKIP: site/node_modules absent (run: cd site && npm ci); real serve not run in the hermetic shell shards"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

# --- port busy: non-zero exit, port named, no silent shift
node -e "require('net').createServer().listen(4321,'127.0.0.1');setTimeout(()=>{},60000)" &
blocker=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>/dev/tcp/127.0.0.1/4321) 2>/dev/null && break; sleep 0.3; done
if out=$(bash "$repo/scripts/docs-site/serve.sh" 2>&1); then ko "busy port exits non-zero"; else
  case "$out" in *4321*) ok "busy port exits non-zero and names 4321" ;; *) ko "busy port names the port (got: $out)" ;; esac
fi
kill "$blocker" 2>/dev/null
wait "$blocker" 2>/dev/null
blocker=""

wait_free 127.0.0.1

# --- serve for real
bash "$repo/scripts/docs-site/serve.sh" >"$tmp/out" 2>"$tmp/err" &
srv=$!
owned=1
up=0
for _ in $(seq 1 120); do
  curl -fs -o /dev/null http://127.0.0.1:4321/Himmel/ 2>/dev/null && { up=1; break; }
  sleep 1
done
if [ "$up" -eq 1 ]; then ok "site answers on http://127.0.0.1:4321/Himmel/"; else ko "site answers"; tail -5 "$tmp/err"; fi
# a stranger on [::1]:4321 (astro binds IPv4 only) is not ours: it must outlive the run
node -e "require('net').createServer().listen(4321,'::1');setTimeout(()=>{},300000)" >/dev/null 2>&1 &
foreign=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do listening ::1 && break; sleep 0.3; done
listening ::1 || { kill "$foreign" 2>/dev/null; foreign=""; echo "SKIP: no IPv6 loopback; foreign-listener row not run"; }
if [ "$(grep -c '^docs site: http://127.0.0.1:4321/Himmel/$' "$tmp/out")" -eq 1 ]; then ok "serve.sh prints exactly the one URL line"; else ko "serve.sh prints the URL line"; fi

for p in "" why-himmel/ getting-started/ setup/install/ adoption-trail.html; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4321/Himmel/$p")
  if [ "$code" = 200 ]; then ok "200 /Himmel/$p"; else ko "200 /Himmel/$p (got $code)"; fi
done
page=$(curl -s http://127.0.0.1:4321/Himmel/getting-started/)
if printf '%s' "$page" | grep -q 'href="/Himmel/setup/install/"'; then ok "no-JS page carries its rewritten .md link"; else ko "no-JS page carries its rewritten .md link"; fi
if printf '%s' "$page" | grep -q 'href="https://github.com/yotamleo-org/Himmel/blob/main/CLAUDE.md"'; then ok "repo-path link points at GitHub"; else ko "repo-path link points at GitHub"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4321/Himmel/pagefind/pagefind.js)
if [ "$code" = 200 ]; then ok "search index (pagefind) is served"; else ko "search index is served (got $code)"; fi

# --- mermaid really renders, when a headless browser is present
if command -v chromium >/dev/null 2>&1; then
  dom=$(chromium --headless --no-sandbox --disable-gpu --virtual-time-budget=15000 --dump-dom http://127.0.0.1:4321/Himmel/architecture/ 2>/dev/null)
  case "$dom" in *'data-processed="true"'*) ok "mermaid renders to SVG in a headless browser" ;; *) ko "mermaid renders to SVG in a headless browser" ;; esac
else
  echo "SKIP: no chromium; mermaid render not checked in a browser"
fi

# --- stop our own server, then the stranger must still be listening
stop_server
if [ -n "$foreign" ]; then
  if listening ::1; then ok "cleanup leaves a foreign [::1]:4321 listener alive"; else ko "cleanup leaves a foreign [::1]:4321 listener alive"; fi
fi
if listening 127.0.0.1; then ko "cleanup stops our own server"; else ok "cleanup stops our own server"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
