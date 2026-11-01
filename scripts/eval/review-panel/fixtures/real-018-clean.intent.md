fix(hooks): [HIMMEL-8200] a write after cd into a scratch folder is no longer refused as a main-checkout write

block-write-into-main-checkout.sh re-checked every relative write after a `cd` against the payload cwd (the primary checkout), so `cd <scratch> && echo x > out.txt` was refused although the write lands in the scratch folder. A `cd` now sets a sure flag and skips that payload-cwd re-check for one small form: a plain first-of-line cd, unpiped, onto an existing directory that lies in no git repo. Everything else keeps main's verdict.
