python3 -c "from os import execv; import sys; execv('/usr/bin/env', sys.argv[1:])" env -S git --upload-pack=y fetch origin
