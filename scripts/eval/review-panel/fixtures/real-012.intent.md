fix(chief-kit): [HIMMEL-8238] ready-check does not judge the rows of a superseded CI run

A fresh green CI run never re-reports a job (such as fail-fast-lint) that an older run of the same workflow left CANCELLED, so the old row blocked READY for good. ready-check now reads each check's run id from its detailsUrl and stops judging an older run's row when a newer run of the same workflow finished green. A row with no readable run id or no workflow is still judged.
