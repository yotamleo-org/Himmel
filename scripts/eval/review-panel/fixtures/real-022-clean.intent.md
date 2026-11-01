fix(console-kit): [HIMMEL-7145] count a deferral recorded at the reviewed head of a trivial-descendant PR head

ready-check.sh item 7 compared the body's deferral lines with `deferred_to` ledger rows at the PR head only. A head cleared as a trivial descendant of a reviewed head carries no finding rows of its own, so a real, ledgered deferral read as missing and blocked the GO. `cov_ledger_keys` now also reads a finding's verdict at the reviewed head named by a trivial-descendant `avail` row for the PR head. Only a same-branch row the ledger itself wrote is followed.
