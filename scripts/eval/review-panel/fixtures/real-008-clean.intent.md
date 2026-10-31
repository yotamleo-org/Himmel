fix(console): [HIMMEL-7061] check the document lock before action-zero renders legs

`action-zero.sh --render-legs` rewrote the doc's `legs:` line before it checked the document lock, so a second console opening a live console's doc changed that console's worker list before learning the lock was held. The render now checks the lock first and, when it is not free, prints `unavailable`, exits 1 and leaves `legs:` unchanged. Three new `lock held` rows in `test-action-zero.sh`. Console docs describe how a live console re-renders its legs.
