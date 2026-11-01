fix: [HIMMEL-6347] block-read-secrets no longer denies a plain gh api graphql thread reply

The xtrace brace-expansion clause matched any word holding a `{` whose letters contained x, t, r, a, c, e in order, so a quoted GraphQL `query=mutation{...}` argument was denied whenever the reply body happened to carry those letters. Only an unquoted, unescaped `{` expands in the shell, so the clause now needs one. Real `x{,}trace` spellings stay denied.
