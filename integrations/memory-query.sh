#!/bin/bash
#
# Query claude-memory for relevant learnings
#
# Usage: ./memory-query.sh "What patterns should I use for error handling?"
#
# Returns relevant memory files that match the query context.
# Used by GSD plan-phase to inform planning decisions.
#

set -e

MEMORY_DIR="$HOME/.claude/memory"
MEMORY_INDEX="$MEMORY_DIR/memory/index.yaml"

# Check if memory system is installed
if [ ! -d "$MEMORY_DIR" ]; then
    echo "Memory system not installed at $MEMORY_DIR"
    exit 0
fi

if [ ! -f "$MEMORY_INDEX" ]; then
    echo "No memory index found"
    exit 0
fi

QUERY="$1"
if [ -z "$QUERY" ]; then
    echo "Usage: $0 <query>"
    exit 1
fi

# Simple grep-based search for now
# Returns matching learnings from the index
echo "=== Relevant Memories ==="
echo ""

# Search index for relevant entries
grep -i "$QUERY" "$MEMORY_INDEX" 2>/dev/null | while read -r line; do
    # Extract filename from index entry
    filename=$(echo "$line" | sed 's/^- //' | cut -d: -f1)
    summary=$(echo "$line" | cut -d: -f2-)

    if [ -n "$filename" ]; then
        echo "**$filename**"
        echo "$summary"
        echo ""
    fi
done

# Also search memory files directly
for file in "$MEMORY_DIR/memory/learnings-"*.md; do
    if [ -f "$file" ] && grep -qi "$QUERY" "$file" 2>/dev/null; then
        basename "$file"
        head -5 "$file" | sed 's/^/  /'
        echo ""
    fi
done
