# graphify

The graphify knowledge-graph skill as a profile-controlled plugin. The `skills/`
tree is not committed: `scripts/lib/graphify-bin.sh` (`_graphify_skill_refresh`,
run by `himmel-update`) generates it from the pinned `graphifyy` pip package, so
the skill always matches the installed CLI. Enable it per profile with
`graphify@himmel`; the `user` profile carries it.
