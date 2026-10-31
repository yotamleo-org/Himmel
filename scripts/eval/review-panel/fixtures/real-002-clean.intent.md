fix(console): [HIMMEL-6402] the board's milestone counts leave closed and won't-do tickets out

A ticket in `closed`, `wont do`, `won't do` or `wont fix` is out of every count, as the tracker has it (HIMMEL-6241): a milestone's done and total count only the tickets that remain, and the status table reads the same rule. Resolved and Done tickets count as done.
