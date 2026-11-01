fix(ci): [HIMMEL-6666] bound the ciq probe's per-run jobs reads and reject a bad cap

Sample at most 32 runs, mark lower bounds explicitly, and route bounded read calls through the existing read-token helper. At 400 live runs the normal budget is 38 REST requests per probe, 76 with refused-token retries. Warn and use the default for an invalid `CI_MAX_JOBS`; log non-default caps.
