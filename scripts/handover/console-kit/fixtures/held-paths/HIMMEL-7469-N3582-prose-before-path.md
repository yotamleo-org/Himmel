> **Scope / do not:** writes confined to scripts/nd-a.sh; find and fix the caller in scripts/nd-b.sh. Verify with grep -rl needle scripts/nd-read/ afterwards. Replace grep -P in scripts/nd-p.sh. SINGLE-WRITER: this leg is the one writer of scripts/nd-d.sh, which PR #3791 only reads. completes-ticket: no. Other live legs and their files: . Stay off those.

## Results
- 10:00 LIVE - go
