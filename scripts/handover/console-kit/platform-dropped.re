# Windows and WSL are dropped platforms. gen-briefs.py and next-dispatchable.sh both read the
# one regex below (Python syntax, applied case-insensitively) and refuse work that matches it
# unless it is a removal: a leg sets platform_removal, a ticket carries the label windows-removal.
# The first line that is neither blank nor a # comment is the pattern. 'windows' is a whole word
# and not the tail of context/time/token/rate/sliding/usage windows; 'Windowed' never matches.
(?<!context )(?<!time )(?<!token )(?<!rate )(?<!sliding )(?<!usage )\bwindows\b|\bwsl2?\b|\bpowershell\b|\bpwsh\b|\.ps1\b|\bgit[ -]bash\b|\bmsys2?\b|\bmingw(?:32|64)?\b|\bwin32\b|\bcmd\.exe\b
