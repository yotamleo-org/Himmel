fix(hooks): [HIMMEL-7912] the live-settings guard finishes long commands inside its budget

block-edit-live-settings.sh forked its operand checks once per repeat of a settings-named word, so a 400-line heredoc cost 7.8 s and ran past the 15 s hook-chain budget, which failed the chain closed on harmless commands. The forking check of an operand word now skips a word it already judged. Its verdict reads only the word, the cwd and the nested-worktree primary, all fixed for the run. The memo key matches a word exactly, and a case-variant word is judged under nocasematch.
