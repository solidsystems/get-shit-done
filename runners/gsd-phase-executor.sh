#!/bin/bash
#
# GSD Phase Executor
# Executes all plans in a GSD phase or milestone, each in a fresh Claude context
# Creates a separate branch and PR for each plan
#
# Usage: ./scripts/gsd-phase-executor.sh 11
#        ./scripts/gsd-phase-executor.sh .planning/phases/11-go-handler-test-coverage
#        ./scripts/gsd-phase-executor.sh --milestone v1.2
#
# Options:
#   --dry-run       Show what would be executed without running
#   --plan N        Run only plan N
#   --continue      Continue from last completed plan
#   --milestone M   Execute all phases in milestone M (e.g., v1.2)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Options
DRY_RUN=0
SINGLE_PLAN=0
CONTINUE_MODE=0
MILESTONE_MODE=0
PLAN_NUMBER=""
PHASE_INPUT=""
MILESTONE_VERSION=""

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

usage() {
    cat << EOF
GSD Phase Executor - Execute all plans in a phase or milestone with fresh Claude contexts

Usage: $0 [options] <phase-number|phase-directory>
       $0 --milestone <version>

Options:
    --dry-run       Show what would be executed without running
    --plan N        Run only plan N (single phase mode only)
    --continue      Continue from last completed plan/phase
    --milestone M   Execute all phases in milestone M (e.g., v1.1, v1.2)

Examples:
    $0 11                                                    # Phase 11
    $0 .planning/phases/11-go-handler-test-coverage          # Full path
    $0 --dry-run 11                                          # Dry run
    $0 --plan 03 11                                          # Only plan 03
    $0 --continue 11                                         # Resume where left off
    $0 --milestone v1.2                                      # Run entire milestone
    $0 --milestone v1.2 --dry-run                            # Preview milestone
    $0 --milestone v1.2 --continue                           # Resume milestone
EOF
    exit 1
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --plan)
                SINGLE_PLAN=1
                PLAN_NUMBER="$2"
                shift 2
                ;;
            --continue)
                CONTINUE_MODE=1
                shift
                ;;
            --milestone)
                MILESTONE_MODE=1
                MILESTONE_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                PHASE_INPUT="$1"
                shift
                ;;
        esac
    done
}

# Check dependencies
check_deps() {
    local missing=0
    for cmd in claude gh git grep sed awk; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# Resolve phase directory from input
resolve_phase_dir() {
    local input="$1"

    # If it's already a directory path
    if [[ -d "$input" ]]; then
        echo "$input"
        return 0
    fi

    # If it's a phase number, find the matching directory
    local phase_num="$input"
    local phase_dir=$(find .planning/phases -maxdepth 1 -type d -name "${phase_num}-*" 2>/dev/null | head -1)

    if [[ -n "$phase_dir" ]]; then
        echo "$phase_dir"
        return 0
    fi

    # Try with leading zero
    phase_dir=$(find .planning/phases -maxdepth 1 -type d -name "0${phase_num}-*" 2>/dev/null | head -1)

    if [[ -n "$phase_dir" ]]; then
        echo "$phase_dir"
        return 0
    fi

    return 1
}

# Extract phase number from directory name
extract_phase_number() {
    local phase_dir="$1"
    basename "$phase_dir" | sed 's/-.*//'
}

# Find all plan files in phase
find_plan_files() {
    local phase_dir="$1"
    find "$phase_dir" -name "*-PLAN.md" -type f 2>/dev/null | sort
}

# Check if plan has a summary (completed)
has_summary() {
    local plan_file="$1"
    local summary_file="${plan_file/-PLAN.md/-SUMMARY.md}"
    [[ -f "$summary_file" ]]
}

# Extract plan number from filename
extract_plan_number() {
    local plan_file="$1"
    basename "$plan_file" | sed 's/-.*//' | sed 's/^[0-9]*-//'
}

# Extract objective from plan file
extract_objective() {
    local plan_file="$1"
    sed -n '/<objective>/,/<\/objective>/p' "$plan_file" | grep -v '<objective>\|</objective>' | head -1 | sed 's/^[[:space:]]*//'
}

# Extract purpose from plan file (second line of objective block)
extract_purpose() {
    local plan_file="$1"
    sed -n '/<objective>/,/<\/objective>/p' "$plan_file" | grep -E '^Purpose:' | sed 's/^Purpose:[[:space:]]*//'
}

# Extract task names from plan file
extract_tasks() {
    local plan_file="$1"
    grep -E '<name>.*</name>' "$plan_file" | sed 's/.*<name>\(.*\)<\/name>.*/\1/' | sed 's/^[[:space:]]*//'
}

# Extract files modified from plan file
extract_files() {
    local plan_file="$1"
    grep -E '<files>.*</files>' "$plan_file" | sed 's/.*<files>\(.*\)<\/files>.*/\1/' | tr ',' '\n' | sed 's/^[[:space:]]*//' | sort -u
}

# Extract verification checklist from plan file
extract_verification() {
    local plan_file="$1"
    sed -n '/<verification>/,/<\/verification>/p' "$plan_file" | grep -E '^\s*-\s*\[' | sed 's/^[[:space:]]*//'
}

# Build detailed PR body from plan file
build_pr_body() {
    local plan_file="$1"
    local phase_num="$2"
    local plan_num="$3"
    local base_branch="$4"

    local objective=$(extract_objective "$plan_file")
    local purpose=$(extract_purpose "$plan_file")
    local tasks=$(extract_tasks "$plan_file")
    local files=$(extract_files "$plan_file")
    local verification=$(extract_verification "$plan_file")

    local base_info=""
    if [ "$base_branch" != "main" ] && [ -n "$base_branch" ]; then
        base_info="
> **Note:** This branch is based on \`${base_branch}\` (stacked changes).
> Merge previous PRs first, then rebase this PR on main.
"
    fi

    local task_list=""
    if [ -n "$tasks" ]; then
        task_list="## Tasks

"
        while IFS= read -r task; do
            if [ -n "$task" ]; then
                task_list="${task_list}- [x] ${task}
"
            fi
        done <<< "$tasks"
    fi

    local file_list=""
    if [ -n "$files" ]; then
        file_list="## Files Modified

"
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                file_list="${file_list}- \`${file}\`
"
            fi
        done <<< "$files"
    fi

    local verify_list=""
    if [ -n "$verification" ]; then
        verify_list="## Verification

"
        while IFS= read -r item; do
            if [ -n "$item" ]; then
                # Convert [ ] to [x] since we completed these
                item=$(echo "$item" | sed 's/\[ \]/[x]/')
                verify_list="${verify_list}${item}
"
            fi
        done <<< "$verification"
    fi

    cat << EOF
## Summary

${objective}
${base_info}
${purpose:+**Purpose:** ${purpose}

}${task_list}${file_list}${verify_list}
---
📋 Plan: \`${plan_file}\`
🤖 Generated with [gsd-phase-executor.sh](https://github.com/solidsystems/get-shit-done)
EOF
}

# Find all phases in a milestone from ROADMAP.md
# Returns phase numbers separated by newlines
find_milestone_phases() {
    local milestone="$1"
    local roadmap=".planning/ROADMAP.md"

    if [ ! -f "$roadmap" ]; then
        log_error "ROADMAP.md not found"
        return 1
    fi

    # Extract phase numbers from milestone section
    # Only match actual phase definitions (#### Phase N:) not references
    local in_milestone=0
    local phases=""

    while IFS= read -r line; do
        # Check if we're entering the milestone section (summary tag or ### heading)
        if echo "$line" | grep -qE "<summary>.*${milestone}|^### .* ${milestone}"; then
            in_milestone=1
            continue
        fi

        # Check if we're leaving the milestone section (next milestone, section, or closing tag)
        if [ $in_milestone -eq 1 ]; then
            if echo "$line" | grep -qE "^### |^## |</details>"; then
                break
            fi

            # Match phase definitions: "- [ ] **Phase N:" or "- [x] **Phase N:" or "#### Phase N:"
            if echo "$line" | grep -qE "^- \[.\] \*\*Phase [0-9]+:|^#### Phase [0-9]+:"; then
                local phase_num=$(echo "$line" | grep -oE "Phase ([0-9]+):" | grep -oE "[0-9]+" | head -1)
                if [ -n "$phase_num" ]; then
                    if [ -z "$phases" ]; then
                        phases="$phase_num"
                    else
                        phases="$phases $phase_num"
                    fi
                fi
            fi
        fi
    done < "$roadmap"

    # Convert to newline-separated and sort
    echo "$phases" | tr ' ' '\n' | sort -n | uniq
}

# Check if phase is complete (all plans have summaries)
is_phase_complete() {
    local phase_dir="$1"
    local plan_count=$(find "$phase_dir" -name "*-PLAN.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    local summary_count=$(find "$phase_dir" -name "*-SUMMARY.md" -type f 2>/dev/null | wc -l | tr -d ' ')

    if [ "$plan_count" -eq 0 ]; then
        return 1  # No plans = not complete (needs planning)
    fi

    [ "$plan_count" -eq "$summary_count" ]
}

# Build prompt for plan execution
build_plan_prompt() {
    local plan_file="$1"
    local phase_num="$2"
    local plan_num="$3"

    cat << PROMPT
Execute GSD Plan ${phase_num}-${plan_num}.

## Instructions

1. Read the plan file: ${plan_file}
2. Execute ALL tasks in the plan sequentially
3. For each task:
   - Read source files to understand patterns
   - Implement the changes
   - Run the verification command
   - Commit with: git commit -m "test(${phase_num}-${plan_num}): <task description>

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

4. After ALL tasks complete:
   - Create SUMMARY.md for the plan
   - Update STATE.md with progress
   - Commit metadata: git commit -m "docs(${phase_num}-${plan_num}): complete <plan name>

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

5. Output "PLAN_COMPLETE" when done
6. Output "PLAN_FAILED: <reason>" if blocked

Do NOT:
- Create PRs (the runner handles that)
- Push to remote (the runner handles that)
- Add unnecessary narration

Execute now.
PROMPT
}

# Execute a single plan with Claude
# Args: plan_file phase_num plan_num [base_branch]
# Sets LAST_BRANCH global to the branch created/used
execute_plan() {
    local plan_file="$1"
    local phase_num="$2"
    local plan_num="$3"
    local base_branch="${4:-main}"  # Default to main if not specified

    log_step "Plan ${phase_num}-${plan_num}: $(basename "$plan_file")"

    # Generate branch name
    local objective=$(sed -n '/<objective>/,/<\/objective>/p' "$plan_file" | grep -v '<objective>' | grep -v '</objective>' | grep -v '^$' | head -1 | sed 's/^[[:space:]]*//')
    local desc=$(echo "$objective" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-30)
    local branch_name="phase-${phase_num}/plan-${plan_num}-${desc}"

    log_info "Branch: ${branch_name}"
    log_info "Base: ${base_branch}"

    # Export for caller to track
    LAST_BRANCH="$branch_name"

    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY RUN] Would execute plan with Claude"
        echo "--- Prompt Preview ---"
        build_plan_prompt "$plan_file" "$phase_num" "$plan_num" | head -20
        echo "..."
        echo "---"
        return 0
    fi

    # Checkout base branch and create new branch from it
    if [ "$base_branch" = "main" ]; then
        git fetch origin main 2>/dev/null || true
        git checkout main 2>/dev/null || true
        git pull origin main 2>/dev/null || true
    else
        # For non-main base, just checkout the branch (it should already exist locally)
        git checkout "$base_branch" 2>/dev/null || {
            log_error "Base branch ${base_branch} not found"
            return 1
        }
    fi

    if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
        log_info "Branch exists, checking out..."
        git checkout "$branch_name"
    else
        log_info "Creating new branch from ${base_branch}..."
        git checkout -b "$branch_name"
    fi

    # Build and execute prompt
    local prompt=$(build_plan_prompt "$plan_file" "$phase_num" "$plan_num")
    local output_file="/tmp/gsd-phase-${phase_num}-plan-${plan_num}.log"

    log_info "Starting Claude instance..."

    if claude -p "$prompt" --allowedTools "Bash,Read,Write,Edit,Glob,Grep" 2>&1 | tee "$output_file"; then
        if grep -q "PLAN_COMPLETE" "$output_file"; then
            log_success "Plan ${phase_num}-${plan_num} completed"

            # Push and create PR
            log_info "Pushing to remote..."
            git push -u origin "$branch_name" 2>/dev/null || git push --force-with-lease origin "$branch_name"

            log_info "Creating PR..."
            local pr_title="Phase ${phase_num} Plan ${plan_num}: ${objective:0:50}"
            local pr_body=$(build_pr_body "$plan_file" "$phase_num" "$plan_num" "$base_branch")

            GITHUB_TOKEN= gh pr create --title "$pr_title" --body "$pr_body" 2>/dev/null && log_success "PR created" || log_warn "PR creation failed or already exists"

            return 0
        elif grep -q "PLAN_FAILED" "$output_file"; then
            local reason=$(grep "PLAN_FAILED" "$output_file" | head -1)
            log_error "Plan ${phase_num}-${plan_num} failed: $reason"
            return 1
        else
            log_warn "Plan finished but no explicit completion signal"
            # Check for summary file as success indicator
            if has_summary "$plan_file"; then
                log_success "Found SUMMARY.md - assuming success"

                # Still push and create PR
                git push -u origin "$branch_name" 2>/dev/null || git push --force-with-lease origin "$branch_name"
                local pr_title="Phase ${phase_num} Plan ${plan_num}: ${objective:0:50}"
                local pr_body=$(build_pr_body "$plan_file" "$phase_num" "$plan_num" "$base_branch")
                GITHUB_TOKEN= gh pr create --title "$pr_title" --body "$pr_body" 2>/dev/null || true

                return 0
            fi
            return 1
        fi
    else
        log_error "Claude execution failed"
        return 1
    fi
}

# Execute a single phase (all its plans)
# Args: phase_num [base_branch]
# Sets LAST_BRANCH global to the final branch created/used
execute_phase() {
    local phase_num="$1"
    local base_branch="${2:-main}"  # Default to main if not specified

    # Resolve phase directory
    local phase_dir=$(resolve_phase_dir "$phase_num")
    if [ -z "$phase_dir" ] || [ ! -d "$phase_dir" ]; then
        log_error "Phase directory not found: $phase_num"
        return 1
    fi

    log_info "Phase: ${phase_num}"
    log_info "Directory: ${phase_dir}"
    log_info "Base branch: ${base_branch}"
    echo ""

    # Find all plans
    local plan_files=$(find_plan_files "$phase_dir")
    local total_plans=$(echo "$plan_files" | grep -c "PLAN.md" || echo "0")

    log_info "Total plans: ${total_plans}"

    if [ "$total_plans" -eq 0 ]; then
        log_warn "No plan files found in phase ${phase_num} - needs planning"
        return 2  # Special return code for "needs planning"
    fi

    # Determine starting plan
    local start_plan=1
    if [ $CONTINUE_MODE -eq 1 ]; then
        # Count existing summaries
        local completed_count=$(find "$phase_dir" -name "*-SUMMARY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
        start_plan=$((completed_count + 1))
        if [ $start_plan -gt 1 ]; then
            log_info "Continuing from plan ${start_plan}"
        fi
    fi

    # Track current base branch (starts with provided base, then chains)
    local current_base="$base_branch"

    # Execute plans - use process substitution to avoid subshell
    local completed=0
    local failed=0
    local plan_index=0

    while IFS= read -r plan_file; do
        if [ -z "$plan_file" ]; then
            continue
        fi

        plan_index=$((plan_index + 1))
        # Extract plan number from filename like "14-01-PLAN.md" -> "01"
        local plan_num=$(basename "$plan_file" | sed 's/^[0-9]*-//' | sed 's/-.*//')

        # Skip if before start_plan
        if [ $plan_index -lt $start_plan ]; then
            log_info "Skipping plan ${plan_num} (already completed)"
            continue
        fi

        # Skip if not the single plan requested
        if [ $SINGLE_PLAN -eq 1 ] && [ "$plan_num" != "$PLAN_NUMBER" ]; then
            continue
        fi

        # Skip if already has summary
        if has_summary "$plan_file"; then
            log_info "Skipping plan ${plan_num} (has SUMMARY.md)"
            continue
        fi

        echo ""
        log_info "═══════════════════════════════════════════════════════════"

        if execute_plan "$plan_file" "$phase_num" "$plan_num" "$current_base"; then
            completed=$((completed + 1))
            # Chain: next plan builds on this one
            current_base="$LAST_BRANCH"
        else
            failed=$((failed + 1))
            log_error "Plan failed. Stopping execution."
            return 1
        fi
    done <<< "$plan_files"

    # LAST_BRANCH is already set by the last execute_plan call
    log_success "Phase ${phase_num} complete (${completed} plans executed)"
    return 0
}

# Execute all phases in a milestone
execute_milestone() {
    local milestone="$1"

    log_info "╔═══════════════════════════════════════════════════════════╗"
    log_info "║           MILESTONE: ${milestone}                              "
    log_info "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    # Find all phases in milestone
    local phases=$(find_milestone_phases "$milestone")

    if [ -z "$phases" ]; then
        log_error "No phases found for milestone ${milestone}"
        log_info "Check that ROADMAP.md has a section for ${milestone}"
        exit 1
    fi

    local phase_count=$(echo "$phases" | wc -l | tr -d ' ')
    log_info "Found ${phase_count} phases in milestone ${milestone}"
    log_info "Phases: $(echo $phases | tr '\n' ' ')"
    echo ""

    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY RUN] Would execute these phases:"
        echo "$phases" | while IFS= read -r phase_num; do
            if [ -z "$phase_num" ]; then continue; fi
            local phase_dir=$(resolve_phase_dir "$phase_num")
            local plan_count=$(find "$phase_dir" -name "*-PLAN.md" -type f 2>/dev/null | wc -l | tr -d ' ')
            local summary_count=$(find "$phase_dir" -name "*-SUMMARY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
            local status="pending"
            if [ "$plan_count" -eq 0 ]; then
                status="needs planning"
            elif [ "$plan_count" -eq "$summary_count" ]; then
                status="complete"
            else
                status="${summary_count}/${plan_count} done"
            fi
            log_info "  Phase ${phase_num}: ${status}"
        done
        return 0
    fi

    # Execute each phase
    local phases_completed=0
    local phases_failed=0
    local phases_skipped=0

    # Track base branch for chaining - starts with main, then uses last branch from each phase
    local current_base="main"

    while IFS= read -r phase_num; do
        if [ -z "$phase_num" ]; then continue; fi

        echo ""
        log_info "╔═══════════════════════════════════════════════════════════╗"
        log_info "║           PHASE ${phase_num}                                    "
        log_info "╚═══════════════════════════════════════════════════════════╝"
        echo ""

        # Check if phase is already complete
        local phase_dir=$(resolve_phase_dir "$phase_num")
        if [ -n "$phase_dir" ] && is_phase_complete "$phase_dir"; then
            log_info "Phase ${phase_num} already complete, skipping..."
            phases_skipped=$((phases_skipped + 1))
            # Note: we don't update current_base here since we're skipping
            # This means if phase 14 is complete but 15 isn't, 15 will start from main
            # That's intentional - completed phases should already be merged to main
            continue
        fi

        # Execute phase, passing the base branch from previous phase
        if execute_phase "$phase_num" "$current_base"; then
            phases_completed=$((phases_completed + 1))
            # Chain: next phase builds on the last branch from this phase
            current_base="$LAST_BRANCH"
            log_info "Next phase will branch from: ${current_base}"
        else
            local exit_code=$?
            if [ $exit_code -eq 2 ]; then
                log_warn "Phase ${phase_num} needs planning. Stopping milestone execution."
                log_info "Run: /gsd:plan-phase ${phase_num}"
                phases_failed=$((phases_failed + 1))
                break
            else
                phases_failed=$((phases_failed + 1))
                log_error "Phase ${phase_num} failed. Stopping milestone execution."
                break
            fi
        fi
    done <<< "$phases"

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "MILESTONE EXECUTION SUMMARY"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Milestone: ${milestone}"
    log_info "Phases completed: ${phases_completed}"
    log_info "Phases skipped: ${phases_skipped}"

    if [ $phases_failed -gt 0 ]; then
        log_error "Phases failed/blocked: ${phases_failed}"
        exit 1
    fi

    log_success "Milestone ${milestone} execution complete!"
}

# Main execution
main() {
    parse_args "$@"

    echo ""
    log_info "╔═══════════════════════════════════════════════════════════╗"
    log_info "║           GSD Phase Executor                              ║"
    log_info "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    check_deps

    # Milestone mode
    if [ $MILESTONE_MODE -eq 1 ]; then
        if [ -z "$MILESTONE_VERSION" ]; then
            log_error "Milestone version required with --milestone"
            usage
        fi
        execute_milestone "$MILESTONE_VERSION"
        exit $?
    fi

    # Single phase mode
    if [ -z "$PHASE_INPUT" ]; then
        usage
    fi

    # Resolve phase directory
    PHASE_DIR=$(resolve_phase_dir "$PHASE_INPUT")
    if [ -z "$PHASE_DIR" ] || [ ! -d "$PHASE_DIR" ]; then
        log_error "Phase directory not found: $PHASE_INPUT"
        exit 1
    fi

    PHASE_NUM=$(extract_phase_number "$PHASE_DIR")

    echo ""
    log_info "═══════════════════════════════════════════════════════════"

    if execute_phase "$PHASE_NUM"; then
        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info "PHASE EXECUTION SUMMARY"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "Phase: ${PHASE_NUM}"
        log_success "Phase execution complete!"
    else
        exit 1
    fi
}

main "$@"
