# Windows and WSL are dropped platforms. gen-briefs.py and next-dispatchable.sh both read the
# one regex below (Python syntax, applied case-insensitively) and refuse work that matches it
# unless it is a removal: a leg sets platform_removal, a ticket carries the label windows-removal.
# The first line that is neither blank nor a # comment is the pattern. The OS name is matched
# case-sensitively (Windows / WINDOWS) so lowercase console wording ('console windows', '5-hour
# windows') passes; it is also not the tail of a context/time/token/rate/sliding/usage window
# (each qualifier a whole word, so 'runtime Windows' still matches); 'Windowed' never matches.
(?<!\bcontext )(?<!\btime )(?<!\btoken )(?<!\brate )(?<!\bsliding )(?<!\busage )(?-i:\b(?:Windows|WINDOWS)\b)|\bwsl2?\b|\bpowershell\b|\bpwsh\b|\.ps1\b|\bgit[ -]bash\b|\bmsys2?\b|\bmingw(?:32|64)?\b|\bwin32\b|\bcmd\.exe\b
