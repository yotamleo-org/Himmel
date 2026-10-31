fix(hooks): [HIMMEL-5385] destructive guard denies a force-with-lease push to main through the heads/ shorthand

`git push --force-with-lease origin heads/main` and `... origin HEAD:heads/master` reach the remote's `refs/heads/main` through git's `refs/%s` match rule, but the lease carve-out in `_gp_lease_protected` stripped only a leading `refs/heads/`, so both were allowed. The carve-out now strips `refs/` then `heads/`, so the whole spelling family (`main`, `heads/main`, `refs/heads/main`, and the `master` and refspec forms) is denied. The change must only ever add denials.
