# Hermes Pong — always use Claude when bridge is on

Hermes = orchestrator. Claude Code = coder.

If `~/.hermes-pong/active-pair.json` has a `session`, Hermes must send coding work via:

```bash
python3 ~/bin/claude-delegate.py --no-wait '… ##CLAUDE_DONE## …'
```

## Prompt bank

### Feature
In the open project, implement: <SPEC>. Edit real files. Run checks if available. Ship the change. When completely done, print exactly ##CLAUDE_DONE##, then summarize files changed.

### Bugfix
Bug: <WHAT>. Evidence: <ERROR/FILE/REPRO>. Find root cause, fix, verify. When completely done, print exactly ##CLAUDE_DONE##, then summarize the fix.

### Refactor
Refactor: <TARGET> for clarity without behavior change. Tight diff. When completely done, print exactly ##CLAUDE_DONE##, then list what moved.

### Review + implement
Review <PATH> for: <ISSUE>. Implement smallest correct fix. When completely done, print exactly ##CLAUDE_DONE##, then summary.

### Stepwise
Goal: <GOAL>. Implement step 1 only. When done, print ##CLAUDE_DONE## and propose step 2.

## Autonomy

- Every = ask Dylan after each Claude reply
- Done = ask after ##CLAUDE_DONE##
- Full = minimal human intervention; Hermes keeps looping
