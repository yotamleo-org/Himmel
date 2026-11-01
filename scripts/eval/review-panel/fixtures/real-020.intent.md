fix(agui): [HIMMEL-6113] a console's state comes from its lock and its own wrap line, and legs follow their latest succession

The AG-UI fleet page decided a console's live or wrapped state from the first word of its last Results bullet, so a leg-describing bullet such as `WRAPPED N2470 (#2951 -> ...)` marked a live console wrapped and orphaned all its legs. A console is now wrapped only by its own wrap line, the `WRAPPED - <text>` bullet in the `## Results` section; held versus released still comes from the queue-lock status. A leg's console edge also follows the relay succession wording.
