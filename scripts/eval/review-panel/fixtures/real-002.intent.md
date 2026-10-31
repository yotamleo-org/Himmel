fix(console): [HIMMEL-6402] the board's milestone counts leave closed and won't-do tickets out

A ticket in `closed`, `wont do`, `won't do` or `wont fix` is left out of a milestone's done and total, as the tracker has it (HIMMEL-6241), and out of the restructure count and the slot counts of the CR-loop section. Resolved and Done tickets count as done.
