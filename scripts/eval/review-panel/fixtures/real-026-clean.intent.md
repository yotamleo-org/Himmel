fix(hooks): [HIMMEL-3655] [HIMMEL-3985] auto-approve option scans stop at -- and attached values

`sort`: every word after a literal `--` is positional, so `sort -- -o file` is auto-approved (HIMMEL-3655). `rg`, `ripgrep` and `ag`: the short-cluster scan stops at the first value-taking letter, and the rest of the word is its value, so `rg -ezebra file` stays approved while `rg -zn pat` and `rg -nz pat` still fall through (HIMMEL-3985). The fail-closed direction is preserved: `-o` or `--output=` before `--`, and `-z` earlier in a cluster or as a separate word, still fall through.
