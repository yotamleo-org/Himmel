for d in /tmp/a /tmp/b; do git -C $d log --oneline -3 -- scripts/cr/write-verdicts.sh; done
