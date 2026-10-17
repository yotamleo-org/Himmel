cd scripts/cr && python3 -c "from os import execv; import sys; execv('/bin/bash', ['bash', sys.argv[1], 'aggregate'])" write-verdicts.sh
