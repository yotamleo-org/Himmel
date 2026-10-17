python3 - <<'EOF'
from os import execv
execv('/bin/bash', ['bash', 'scripts/cr//write-verdicts.sh', 'aggregate'])
EOF
