fix(hooks): [HIMMEL-8008] the evaldata write-guard suite runs under its macOS cap on bash 3.2

Counting a clause's substitution stubs with `${x//[!$'\001']/}` is quadratic in the string length on bash 3.2. One helper, `_bwimc_count_stubs`, counts them in windows instead. New boundary rows prove that a stub at the second character of the second window (index 128) and of the third (index 257) is still counted, so a counter that skips those indexes fails them.
