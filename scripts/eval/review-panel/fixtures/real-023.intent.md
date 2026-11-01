feat(qmd): [HIMMEL-5882] reembed resumes a partial copy and passes a 4096-doc batch

`qmd-embed-model.sh reembed`: an existing `--copy` is resumed (no new sqlite backup, `embed` without `--force`) instead of refused, but only when an interrupted reembed left it: a `<copy>.partial` sidecar marker is created before the copy is built and removed on success. A finished copy of an older live index is refused; a copy holding another model is refused. The embed call passes a 4096-doc batch.
