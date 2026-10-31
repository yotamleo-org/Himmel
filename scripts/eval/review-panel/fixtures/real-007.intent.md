feat(bus): [HIMMEL-8304] the bus accepts the chief role and the flags its docs show

`bus register <name> --role chief --chief <c> [--pair <worker>]`, the command `docs/himmel-bus.md` shows, was refused: the parser took only `console` and `--console`. `chief` replaces `console` in `ROLES` as the parsed role, `--chief` is the canonical flag, and the chief launchers register with `--role chief`. The legacy spellings stay accepted while the legacy-names switch is on. Long-lived bus servers may still be running the previous release.
