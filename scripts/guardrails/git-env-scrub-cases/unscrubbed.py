#!/usr/bin/env python3
# RED: a Python entry point that runs git with the inherited environment.
import subprocess
import sys

print(subprocess.run(['git', '-C', sys.argv[1], 'status'], capture_output=True, text=True).stdout)
