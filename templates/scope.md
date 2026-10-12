### <scope name> · <planned | active | review | done>

**Problem.** One or two sentences: the observable gap, who hits it, and what "fixed" looks like.

**Files and interfaces.** The files, functions, endpoints or schemas this scope touches, named,
so an agent can start without a search. Name the repo when the initiative spans more than one.

**Out of scope.** What a reasonable agent would otherwise pull in, and must not.

**Automated check.** One command whose pass/fail settles whether the scope is done, and where it
runs (local, CI, a worktree). If no such command can exist yet, say so and name what would make one.

```
<command>
```

**Manual check.** Numbered steps a reviewer follows, starting with the one command that stands up
the staging or test environment. Each step ends in something a person can see.

1. `<setup command>`
2. ...

**Done when.** The automated check passes and the manual check was performed by someone other than
the author (or by the author, when stated), with the result recorded on the initiative page as a
dated line. A PR link alone is not done.
