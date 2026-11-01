fix(hooks): [HIMMEL-5034] auto-approve splits words on bash's separators so a root walk cannot hide behind other whitespace

Bash splits words on space, tab and newline only, so a form-feed, vertical tab or U+2028 inside the keyword or in place of the space makes one word (command not found), never a root walk. The tokenizer and the segment trim now use the same separators. The hook must never auto-approve a root walk that it denied before.
