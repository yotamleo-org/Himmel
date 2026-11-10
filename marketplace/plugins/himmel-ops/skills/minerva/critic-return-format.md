# Return format for this opted-in Claude critic

Keep the charter's independent review and prose finding list. Additionally emit exactly one critic-findings-v1 JSON block containing every finding, including minor findings. End with exactly SPEC CLEAN, SPEC FINDINGS N, PLAN CLEAN or PLAN FINDINGS N for the requested kind, where N is the exact all-severity count. Use the supplied critic_kind and requested_round in each unique positive-ordinal ID. Locations name the actual reviewed file and positive start/end lines. reviewer_id is the supplied informational label, not proof of identity or authority. Quote the SHA256 of files actually read when the existing sealing workflow requires it; this format adds no seal or approval requirement.

For CLEAN use findings:[] and a zero-finding prose verdict. Do not quote this example or emit a second tagged block: duplicate blocks are invalid. Replace the illustrative values with your actual findings; missing structured output is unsupported, never inferred as zero. Preserve the charter's substance and all existing routing and approval rules.

<!-- example-start -->
Read {{ARTIFACT}} SHA256 {{ARTIFACT_SHA}}.
Finding {{KIND}}-r{{ROUND}}-1: illustrative minor issue at line 1.
```critic-findings-v1
{"schema":1,"kind":"critic-findings","reviewer_id":"{{REVIEWER_ID}}","findings":[{"finding_id":"{{KIND}}-r{{ROUND}}-1","severity":"minor","location":{"path":{{ARTIFACT_JSON}},"start_line":1,"end_line":1}}]}
```
{{VERDICT_PREFIX}} FINDINGS 1
<!-- example-end -->
