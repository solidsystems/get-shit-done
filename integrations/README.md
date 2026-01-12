# GSD Integrations

Integration scripts for connecting GSD with other Claude tools.

## Memory Integration

Connects GSD with [claude-memory](https://github.com/solidsystems/claude-memory) for cross-project learning.

### Setup

1. Install claude-memory at `~/.claude/memory/`:
   ```bash
   cd ~/.claude
   git clone https://github.com/solidsystems/claude-memory.git memory
   cd memory && uv sync
   ```

2. Start the memory server (auto-starts via hook, or manually):
   ```bash
   cd ~/.claude/memory && uv run python server.py
   ```

### Scripts

#### memory-query.sh

Query memories for relevant learnings during planning:

```bash
# Find patterns for error handling
./integrations/memory-query.sh "error handling"

# Find preferences for testing
./integrations/memory-query.sh "test patterns"
```

Used by `plan-phase` workflow to inject relevant cross-project knowledge.

#### memory-export.sh

Export GSD decisions to memory for future reference:

```bash
# Export current project decisions
./integrations/memory-export.sh .planning/STATE.md

# Or from a specific project
./integrations/memory-export.sh /path/to/project/.planning/STATE.md
```

This captures key decisions like:
- "Dependency injection Container pattern for testability"
- "Domain-specific handler files (easier to maintain)"

### How It Works

```
┌─────────────────┐     ┌─────────────────┐
│   GSD Workflow  │     │  claude-memory  │
│                 │     │                 │
│  plan-phase ────┼────▶│  memory/index   │
│                 │     │                 │
│  STATE.md ──────┼────▶│  learnings/*.md │
└─────────────────┘     └─────────────────┘
```

1. **During planning**: GSD queries memory for relevant patterns
2. **After milestones**: GSD exports decisions to memory
3. **Cross-project**: Learnings inform future projects

### Memory Categories

Memories are categorized by source:

| Prefix | Source |
|--------|--------|
| `learnings-gsd-*` | GSD decision exports |
| `learnings-*` | Conversation extractions |

### Workflow Integration

The `plan-phase` workflow can optionally query memories:

```markdown
<!-- In plan-phase.md -->
<step name="query_memories">
If ~/.claude/memory exists, query for relevant learnings:

\`\`\`bash
~/.claude/get-shit-done/integrations/memory-query.sh "[phase topic]"
\`\`\`

Incorporate relevant patterns into the plan.
</step>
```
