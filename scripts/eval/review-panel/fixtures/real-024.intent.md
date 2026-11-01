fix(lib): [HIMMEL-6422] bank-preflight reclaims a live but blocked admission-lock holder past a hard ceiling

A bank preflight blocked while holding the fleet admission lock (`.admit`) stopped every launch on the host, and the refusal never named the holder. A live holder is reclaimed once its age passes `FLEET_ADMIT_MAX_HOLD_SECS` (default 10 x `FLEET_ADMIT_STALE_SECS`, so 600 s); the reclaim logs the holder pid and age. Below the ceiling the existing live-holder refusal is unchanged. The refusal names the holder: pid, age and command.
