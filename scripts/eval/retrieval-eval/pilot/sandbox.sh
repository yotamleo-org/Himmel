#!/usr/bin/env bash
# sandbox.sh -- the per-session bwrap namespace for one V, S or Q answer session (design §2).
#
#   sandbox.sh --arm V|S|Q --home DIR --himmel DIR --luna DIR --claude BIN --settings FILE
#              [--env K=V]... [S/Q: --tools DIR --binding FILE --socket SOCK --index FILE
#              --qmd-pkg DIR --qmd-config DIR --graph DIR --manifests DIR]
#              [S: --key FILE] [Q: --models DIR] [--print] -- <argv>...
#
# Every arm: a clean environment (only --env pairs), its own PID/IPC/UTS namespaces, read-only
# /usr and the pinned Claude binary, the two read-only exports at /work/himmel and /work/luna,
# a fresh writable home at /session, a private /tmp, cwd /work. Nothing else of the host:
# no live repo, index or config, no private task/scorer/ledger, no other session, no station
# credential root. S and Q add the SAME retrieval mounts at the same paths (wrappers, binding,
# broker socket, disposable index, pinned qmd, its locked config, frozen graph, manifests); S
# alone gets the dedicated key file; Q alone gets the read-only pinned weights and the GPU
# device nodes (its qmd child runs under its own network namespace, see the binding). V gets
# no retrieval mount at all. --print prints the bwrap argv, one word per line, and runs nothing.
set -uo pipefail
arm='' home='' himmel='' luna='' claude='' settings='' tools='' binding='' sock='' index='' qpkg='' qcfg='' graph=''
manifests='' key='' models='' print=0 envs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --arm) arm=$2; shift 2 ;; --home) home=$2; shift 2 ;; --himmel) himmel=$2; shift 2 ;; --luna) luna=$2; shift 2 ;;
    --claude) claude=$2; shift 2 ;; --settings) settings=$2; shift 2 ;; --env) envs+=("$2"); shift 2 ;;
    --tools) tools=$2; shift 2 ;; --binding) binding=$2; shift 2 ;; --socket) sock=$2; shift 2 ;; --index) index=$2; shift 2 ;;
    --qmd-pkg) qpkg=$2; shift 2 ;; --qmd-config) qcfg=$2; shift 2 ;; --graph) graph=$2; shift 2 ;; --manifests) manifests=$2; shift 2 ;;
    --key) key=$2; shift 2 ;; --models) models=$2; shift 2 ;; --print) print=1; shift ;;
    --) shift; break ;;
    *) echo "sandbox: unknown argument $1" >&2; exit 2 ;;
  esac
done
refuse() { echo "sandbox: refused: $*" >&2; exit 3; }
case "$arm" in V|S|Q) ;; *) refuse "arm must be V, S or Q" ;; esac
for v in home himmel luna claude settings; do [ -n "${!v}" ] || refuse "--$v is required"; done
[ $# -gt 0 ] || refuse "no command"
if [ "$arm" = V ]; then
  for v in tools binding sock index qpkg qcfg graph manifests key models; do [ -z "${!v}" ] || refuse "V gets no retrieval mount (--$v)"; done
else
  for v in tools binding sock index qpkg qcfg graph manifests; do [ -n "${!v}" ] || refuse "$arm needs --$v"; done
  [ "$arm" = S ] && { [ -n "$key" ] || refuse "S needs its dedicated --key"; [ -z "$models" ] || refuse "S gets no Q weights"; }
  [ "$arm" = Q ] && { [ -z "$key" ] || refuse "Q never gets the S key"; [ -n "$models" ] || refuse "Q needs --models"; }
fi
lib64=$(readlink /lib64 2>/dev/null) || lib64=usr/lib
[ -n "$lib64" ] || lib64=usr/lib
a=(bwrap --die-with-parent --new-session --unshare-pid --unshare-ipc --unshare-uts --clearenv
   --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/bin /sbin --symlink usr/lib /lib --symlink "$lib64" /lib64)
for e in /etc/resolv.conf /etc/hosts /etc/nsswitch.conf /etc/ssl /etc/ca-certificates /etc/passwd /etc/group /etc/localtime; do
  [ -e "$e" ] && a+=(--ro-bind "$e" "$e")
done
a+=(--proc /proc --dev /dev --tmpfs /tmp --bind "$home" /session --ro-bind "$himmel" /work/himmel --ro-bind "$luna" /work/luna
    --ro-bind "$claude" /opt/claude/claude --ro-bind "$settings" /opt/claude/settings.json --chdir /work)
path=/usr/bin:/bin
if [ "$arm" != V ]; then
  a+=(--ro-bind "$tools" /run/pilot/tools --ro-bind "$binding" /run/pilot/binding.json --bind "$sock" /run/pilot/broker.sock
      --bind "$index" /run/pilot/index/eval.sqlite --ro-bind "$qpkg" /opt/qmd --ro-bind "$qcfg" /run/pilot/qmd-config
      --ro-bind "$graph" /run/pilot/graph --ro-bind "$manifests" /run/pilot/manifests)
  path=/run/pilot/tools:$path
fi
if [ "$arm" = S ]; then a+=(--ro-bind "$key" /run/pilot/key); fi
if [ "$arm" = Q ]; then
  a+=(--ro-bind "$models" /run/pilot/models)
  for d in /dev/nvidia* /dev/dri; do [ -e "$d" ] && a+=(--dev-bind "$d" "$d"); done
fi
a+=(--setenv PATH "$path" --setenv HOME /session --setenv LANG C.UTF-8 --setenv TMPDIR /tmp)
for kv in "${envs[@]}"; do a+=(--setenv "${kv%%=*}" "${kv#*=}"); done
a+=(-- "$@")
if [ "$print" = 1 ]; then printf '%s\n' "${a[@]}"; exit 0; fi
exec "${a[@]}"
