fix(ci): [HIMMEL-7045] check-ci counts failures from the newest run per check name

`filter=latest` on the REST check-runs read is per check suite, so a stale failed run of a check name from an older suite still counted after a newer run of the same name passed, and a head GitHub reports CLEAN read red in check-ci. The REST row builder in gh-ci-cache.sh keeps only the newest run per check, ordered by check-run id. Runs of a check on different events or from different apps are kept apart.
