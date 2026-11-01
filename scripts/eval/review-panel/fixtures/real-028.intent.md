fix(arm): [HIMMEL-1332] default worktree isolation ON for himmel code arms

arm-resume.sh: a handover whose file name carries a `HIMMEL-<n>` ticket and whose `resume_cwd:` is this checkout's primary tree now relaunches in worktree `fix/himmel-<n>-arm` by default, through the existing validated `--worktree` path. Opt-outs: `resume_isolation: primary`, `--worktree` / `resume_worktree:`, or a cwd that is not the primary (`--cwd` naming the primary still isolates). Vault arms and other repos are untouched. Worktree creation fails closed when the default applies.
