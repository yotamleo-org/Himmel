Search tools: `s-qmd "<words>"` searches the notes and docs (Markdown in /work/himmel and /work/luna, collections himmel and luna) by keyword and meaning; `s-graph "<name>"` lists code and doc symbols with their files and neighbours in /work/himmel.
Use them alongside grep, rg, find and Read; at most 12 s-qmd searches per task, an exact file or symbol name works best with grep.
Run each s-qmd call through Bash with a 600000 ms timeout; a failed or empty search is not proof the answer is absent.
