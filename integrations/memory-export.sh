#!/bin/bash
#
# Export GSD decisions to claude-memory
#
# Usage: ./memory-export.sh [.planning/STATE.md]
#
# Reads decisions from STATE.md and creates memory learnings
# for cross-project knowledge.
#

set -e

MEMORY_DIR="$HOME/.claude/memory"
MEMORY_FOLDER="$MEMORY_DIR/memory"
MEMORY_INDEX="$MEMORY_FOLDER/index.yaml"

STATE_FILE="${1:-.planning/STATE.md}"

# Check if memory system is installed
if [ ! -d "$MEMORY_DIR" ]; then
    echo "Memory system not installed at $MEMORY_DIR"
    exit 1
fi

if [ ! -f "$STATE_FILE" ]; then
    echo "STATE.md not found: $STATE_FILE"
    exit 1
fi

# Extract decisions section from STATE.md
echo "Extracting decisions from $STATE_FILE..."

# Generate unique filename
TIMESTAMP=$(date +%s)
SESSION_ID=$(echo "$STATE_FILE" | md5 | cut -c1-8)
FILENAME="learnings-gsd-${SESSION_ID}-${TIMESTAMP}.md"
FILEPATH="$MEMORY_FOLDER/$FILENAME"

# Extract decisions between "### Decisions" and the next "###" header
DECISIONS=$(sed -n '/^### Decisions/,/^### /p' "$STATE_FILE" | grep -v "^### " | grep -v "^$" | head -20)

if [ -z "$DECISIONS" ]; then
    echo "No decisions found in STATE.md"
    exit 0
fi

# Create memory file
cat > "$FILEPATH" << EOF
# GSD Project Decisions

Extracted from: $STATE_FILE
Date: $(date +%Y-%m-%d)

## Key Decisions

$DECISIONS

---
*Auto-exported from GSD workflow*
EOF

echo "Created: $FILEPATH"

# Update index
# Create a summary from first decision
SUMMARY=$(echo "$DECISIONS" | head -1 | sed 's/^- //')

# Append to index if not already present
if ! grep -q "$FILENAME" "$MEMORY_INDEX" 2>/dev/null; then
    echo "- $FILENAME: GSD decisions - $SUMMARY" >> "$MEMORY_INDEX"
    echo "Updated index: $MEMORY_INDEX"
fi

echo "Done. Decision exported to memory."
