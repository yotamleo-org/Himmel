# Fixture root for suites whose fixtures must sit outside every temp path.
# SOURCED, not a suite (no test- prefix). The FIXTURE RULE
# (test-block-write-into-main-checkout.sh) roots fixtures under the real home
# because is_temp_or_devnull exempts */tmp/* and */temp/* paths. $HOME is not
# always that home: home-canary.sh points it at a mktemp -d sandbox, and every
# DENY row then allows for the wrong reason. So a temp-shaped $HOME falls back
# to the account's passwd home, which no HOME override changes.
#   fixture_root  -> prints a non-temp-shaped directory, or fails (rc 1)
# shellcheck shell=bash
# sourced-lib

_fixture_root_temp_shaped() {
    case "$1/" in
        /|/tmp/*|*/tmp/*|*/temp/*|*[Aa]pp[Dd]ata/[Ll]ocal/[Tt]emp/*) return 0 ;;
        *) return 1 ;;
    esac
}

fixture_root() {
    local root="${HOME:-}" user
    if [ -z "$root" ] || _fixture_root_temp_shaped "$root"; then
        user="$(id -un 2>/dev/null)" || user=""  # swallow-ok: empty user reaches the fail-closed abort below
        root=""
        [ -n "$user" ] && root="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"  # swallow-ok: empty root falls through to the abort
        [ -z "$root" ] && [ -n "$user" ] && root="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"  # swallow-ok: empty root falls through to the abort
    fi
    if [ -z "$root" ] || [ ! -d "$root" ] || _fixture_root_temp_shaped "$root"; then
        echo "FIXTURE ROOT: no non-temp home for fixtures (HOME=${HOME:-}) — aborting rather than run vacuous rows" >&2
        return 1
    fi
    printf '%s\n' "$root"
}
