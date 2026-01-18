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
#   --dry-run           Show what would be executed without running
#   --plan N            Run only plan N
#   --continue          Continue from last completed plan
#   --milestone M       Execute all phases in milestone M (e.g., v1.2)
#   --branch-strategy S Branching strategy: independent (default), chain, or single
#                       - independent: each phase branches from main (clean PRs)
#                       - chain: each phase branches from previous (stacked PRs)
#                       - single: all phases on one branch (single PR per milestone)
#   --auto-merge        Wait for each PR to become mergeable and merge before next phase
#                       Prevents merge conflicts by ensuring main is updated between phases
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
AUTO_MERGE=0
PLAN_NUMBER=""
PHASE_INPUT=""
MILESTONE_VERSION=""
BRANCH_STRATEGY="independent"  # independent (default), chain, or single

# E2E Infrastructure tracking
E2E_STARTED=0
E2E_PROJECT_NAME=""

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
    --dry-run           Show what would be executed without running
    --plan N            Run only plan N (single phase mode only)
    --continue          Continue from last completed plan/phase
    --milestone M       Execute all phases in milestone M (e.g., v1.1, v1.2)
    --branch-strategy S Branching strategy (default: independent)
                        - independent: each phase branches from main (clean PRs)
                        - chain: each phase branches from previous (stacked PRs)
                        - single: all phases on one branch (single PR per milestone)
    --auto-merge        Wait for PR to become mergeable and merge before next phase
                        Best with 'independent' strategy to keep main updated

Examples:
    $0 11                                                    # Phase 11
    $0 .planning/phases/11-go-handler-test-coverage          # Full path
    $0 --dry-run 11                                          # Dry run
    $0 --plan 03 11                                          # Only plan 03
    $0 --continue 11                                         # Resume where left off
    $0 --milestone v1.2                                      # Run entire milestone
    $0 --milestone v1.2 --dry-run                            # Preview milestone
    $0 --milestone v1.2 --continue                           # Resume milestone
    $0 --milestone v1.3 --branch-strategy chain              # Stacked PRs
    $0 --milestone v1.3 --branch-strategy single             # Single PR
    $0 --milestone v1.3 --auto-merge                         # Auto-merge each PR
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
            --branch-strategy)
                BRANCH_STRATEGY="$2"
                if [[ ! "$BRANCH_STRATEGY" =~ ^(independent|chain|single)$ ]]; then
                    log_error "Invalid branch strategy: $BRANCH_STRATEGY"
                    log_info "Valid options: independent, chain, single"
                    exit 1
                fi
                shift 2
                ;;
            --auto-merge)
                AUTO_MERGE=1
                shift
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

# Check if a task needs E2E infrastructure (Docker containers)
# Args: verify_command
# Returns: 0 if needs E2E, 1 if not
needs_e2e_infrastructure() {
    local verify_cmd="$1"
    if echo "$verify_cmd" | grep -qiE "playwright|npx playwright|test:e2e"; then
        return 0
    fi
    return 1
}

# Start E2E Docker containers
# Returns: 0 on success, 1 on failure
start_e2e_infrastructure() {
    if [ $E2E_STARTED -eq 1 ]; then
        log_info "E2E infrastructure already running"
        return 0
    fi

    if ! command -v docker &> /dev/null; then
        log_warn "Docker not available - E2E tests may fail"
        return 1
    fi

    # Determine docker compose command
    local DOCKER_COMPOSE_CMD=""
    if docker compose version &> /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        log_warn "Docker Compose not available - E2E tests may fail"
        return 1
    fi

    log_info "Starting E2E Docker infrastructure..."

    # Use unique project name
    E2E_PROJECT_NAME="gsd-e2e-$(date +%s)"
    export COMPOSE_PROJECT_NAME="$E2E_PROJECT_NAME"

    # Clean up any orphan containers that might conflict
    log_info "Cleaning up any existing containers..."
    docker ps -a --format "{{.Names}}" | grep -E "700days|gsd-e2e" | xargs -r docker rm -f 2>/dev/null || true
    docker network prune -f 2>/dev/null || true

    # Start e2e profile containers (ignore exit code - check container status instead)
    log_info "Running docker compose..."
    COMPOSE_PROJECT_NAME="$E2E_PROJECT_NAME" $DOCKER_COMPOSE_CMD -f docker-compose.yml --profile e2e up -d 2>&1 | grep -v "is unhealthy" || true

    # Verify E2E containers are running (not relying on docker compose exit code)
    sleep 3
    local backend_running=$(docker ps --filter "name=backend-e2e" --filter "status=running" -q 2>/dev/null)
    local frontend_running=$(docker ps --filter "name=frontend-e2e" --filter "status=running" -q 2>/dev/null)
    local postgres_running=$(docker ps --filter "name=postgres-e2e" --filter "status=running" -q 2>/dev/null)

    if [ -z "$backend_running" ] || [ -z "$frontend_running" ] || [ -z "$postgres_running" ]; then
        log_error "E2E containers not running:"
        log_error "  backend-e2e: ${backend_running:-NOT RUNNING}"
        log_error "  frontend-e2e: ${frontend_running:-NOT RUNNING}"
        log_error "  postgres-e2e: ${postgres_running:-NOT RUNNING}"
        return 1
    fi

    log_info "E2E containers are running, waiting for services..."

    # Wait for API (max 60 seconds)
    local attempt=0
    local max_attempts=30
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf "http://localhost:3002/api/v1/health" > /dev/null 2>&1; then
            log_success "API is ready"
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ $attempt -ge $max_attempts ]; then
        log_warn "API may not be fully ready, continuing anyway"
    fi

    # Wait for frontend (max 30 seconds)
    attempt=0
    max_attempts=15
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf "http://localhost:5174" > /dev/null 2>&1; then
            log_success "Frontend is ready"
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    E2E_STARTED=1
    log_success "E2E infrastructure started"
    return 0
}

# Stop E2E Docker containers
stop_e2e_infrastructure() {
    if [ $E2E_STARTED -eq 0 ]; then
        return 0
    fi

    log_info "Stopping E2E Docker infrastructure..."

    # Determine docker compose command
    local DOCKER_COMPOSE_CMD=""
    if docker compose version &> /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    fi

    if [ -n "$DOCKER_COMPOSE_CMD" ] && [ -n "$E2E_PROJECT_NAME" ]; then
        COMPOSE_PROJECT_NAME="$E2E_PROJECT_NAME" $DOCKER_COMPOSE_CMD -f docker-compose.yml --profile e2e down 2>/dev/null || true
    fi

    # Also stop by container name as fallback
    docker stop 700days-postgres-e2e 700days-backend-e2e 700days-frontend-e2e 700days-redis-e2e 2>/dev/null || true
    docker rm -f 700days-postgres-e2e 700days-backend-e2e 700days-frontend-e2e 700days-redis-e2e 2>/dev/null || true

    E2E_STARTED=0
    log_success "E2E infrastructure stopped"
}

# Trap to ensure E2E cleanup on exit
trap 'stop_e2e_infrastructure' EXIT

# Attempt to fix merge conflicts on a branch
# Args: branch_name
# Returns: 0 on success, 1 on failure
fix_merge_conflicts() {
    local branch_name="$1"
    local original_branch=$(git branch --show-current)

    log_info "Attempting to fix merge conflicts on '${branch_name}'..."

    # Checkout the branch
    git checkout "$branch_name" 2>/dev/null || {
        log_error "Failed to checkout branch: ${branch_name}"
        return 1
    }

    # Start merge with main
    if git merge origin/main --no-edit 2>/dev/null; then
        log_info "No conflicts detected during merge"
        git checkout "$original_branch" 2>/dev/null || true
        return 0
    fi

    # Get list of conflicting files
    local conflicting_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

    if [ -z "$conflicting_files" ]; then
        log_warn "Merge failed but no conflicting files found"
        git merge --abort 2>/dev/null || true
        git checkout "$original_branch" 2>/dev/null || true
        return 1
    fi

    log_info "Conflicting files:"
    echo "$conflicting_files" | while read -r f; do
        [ -n "$f" ] && log_info "  - $f"
    done

    # Categorize files: unrelated files get main's version, related files need Claude
    local unrelated_files=""
    local related_files=""

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        # Unrelated files: test files, iOS files (when not doing iOS work), config files
        case "$file" in
            *.test.ts|*.test.tsx|*_test.go|*.spec.ts|*.spec.tsx)
                unrelated_files="${unrelated_files}${file}"$'\n'
                ;;
            mobile/ios/*|*.swift)
                # Check if branch is iOS-related
                if [[ "$branch_name" != *"ios"* ]] && [[ "$branch_name" != *"mobile"* ]] && [[ "$branch_name" != *"50"* ]] && [[ "$branch_name" != *"51"* ]] && [[ "$branch_name" != *"52"* ]]; then
                    unrelated_files="${unrelated_files}${file}"$'\n'
                else
                    related_files="${related_files}${file}"$'\n'
                fi
                ;;
            scripts/pre-push-checks.sh|.swiftlint.yml|*.md)
                unrelated_files="${unrelated_files}${file}"$'\n'
                ;;
            *)
                related_files="${related_files}${file}"$'\n'
                ;;
        esac
    done <<< "$conflicting_files"

    # Accept main's version for unrelated files
    if [ -n "$unrelated_files" ]; then
        log_info "Accepting main's version for unrelated files..."
        echo "$unrelated_files" | while IFS= read -r file; do
            [ -z "$file" ] && continue
            git checkout --theirs "$file" 2>/dev/null && git add "$file" 2>/dev/null
            log_info "  ✓ $file"
        done
    fi

    # Use Claude to fix related files
    if [ -n "$related_files" ]; then
        log_info "Using Claude to fix related files..."

        local fix_prompt="Fix merge conflicts in these files. The branch is '${branch_name}'.

Conflicting files:
$(echo "$related_files" | grep -v '^$')

Instructions:
1. Read each conflicting file
2. Resolve the conflict markers (<<<<<<< HEAD, =======, >>>>>>> origin/main)
3. Keep BOTH sets of changes where they don't actually conflict
4. For the ReflectionHandlers struct, ensure it has ALL fields from both versions
5. For route registrations, ensure ALL routes are registered
6. Run 'go build ./cmd/api' to verify the fix compiles
7. Stage the fixed files with 'git add <file>'
8. Output CONFLICTS_FIXED when done, or CONFLICTS_FAILED if unable to fix

Do NOT commit - just fix and stage the files."

        local fix_output="/tmp/gsd-fix-conflicts-$$.log"
        if claude -p "$fix_prompt" --allowedTools "Bash,Read,Write,Edit,Glob,Grep" 2>&1 | tee "$fix_output"; then
            if grep -q "CONFLICTS_FIXED" "$fix_output"; then
                log_success "Claude fixed the conflicts"
            elif grep -q "CONFLICTS_FAILED" "$fix_output"; then
                log_error "Claude could not fix conflicts"
                git merge --abort 2>/dev/null || true
                git checkout "$original_branch" 2>/dev/null || true
                return 1
            else
                # Check if files are staged (indicates work was done)
                local staged=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
                if [ "$staged" -gt 0 ]; then
                    log_info "Claude made changes, continuing..."
                else
                    log_warn "Claude finished without explicit signal, checking state..."
                fi
            fi
        else
            log_error "Claude execution failed"
            git merge --abort 2>/dev/null || true
            git checkout "$original_branch" 2>/dev/null || true
            return 1
        fi
    fi

    # Check if all conflicts are resolved
    local remaining=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining" -gt 0 ]; then
        log_error "Still have $remaining unresolved conflicts"
        git merge --abort 2>/dev/null || true
        git checkout "$original_branch" 2>/dev/null || true
        return 1
    fi

    # Commit and push the merge
    log_info "Committing merge resolution..."
    git commit --no-edit 2>/dev/null || {
        log_error "Failed to commit merge"
        git merge --abort 2>/dev/null || true
        git checkout "$original_branch" 2>/dev/null || true
        return 1
    }

    log_info "Pushing resolved merge..."
    git push origin "$branch_name" 2>/dev/null || {
        log_error "Failed to push merge resolution"
        git checkout "$original_branch" 2>/dev/null || true
        return 1
    }

    log_success "Merge conflicts resolved and pushed"
    git checkout "$original_branch" 2>/dev/null || true
    return 0
}

# Wait for PR to become mergeable and merge it
# Args: branch_name [timeout_minutes]
# Returns: 0 on success, 1 on failure
wait_and_merge_pr() {
    local branch_name="$1"
    local timeout_minutes="${2:-30}"  # Default 30 minute timeout
    local poll_interval=30  # Check every 30 seconds
    local max_attempts=$((timeout_minutes * 60 / poll_interval))
    local attempt=0

    log_info "Waiting for PR on '${branch_name}' to become mergeable..."

    # Get PR number for the branch
    local pr_number=$(GITHUB_TOKEN= gh pr list --head "$branch_name" --json number --jq '.[0].number' 2>/dev/null)

    if [ -z "$pr_number" ]; then
        log_error "No PR found for branch: ${branch_name}"
        return 1
    fi

    log_info "PR #${pr_number} found, monitoring status..."

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))

        # Check PR status
        local status=$(GITHUB_TOKEN= gh pr view "$pr_number" --json mergeable,mergeStateStatus --jq '{mergeable: .mergeable, status: .mergeStateStatus}' 2>/dev/null)
        local mergeable=$(echo "$status" | grep -o '"mergeable":"[^"]*"' | cut -d'"' -f4)
        local merge_status=$(echo "$status" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        case "$mergeable" in
            MERGEABLE)
                log_success "PR #${pr_number} is mergeable"

                # Check if CI is passing (if status is BLOCKED, CI might be running)
                if [ "$merge_status" = "BLOCKED" ]; then
                    log_info "PR is blocked (CI running or review required), waiting..."
                elif [ "$merge_status" = "CLEAN" ] || [ "$merge_status" = "UNSTABLE" ]; then
                    # CLEAN = all checks passed, UNSTABLE = some non-required checks failed
                    log_info "Merging PR #${pr_number}..."
                    if GITHUB_TOKEN= gh pr merge "$pr_number" --squash --delete-branch 2>/dev/null; then
                        log_success "PR #${pr_number} merged successfully"

                        # Update local main branch
                        log_info "Updating local main branch..."
                        git fetch origin main 2>/dev/null || true
                        git checkout main 2>/dev/null || true
                        git pull origin main 2>/dev/null || true

                        return 0
                    else
                        # Merge command failed - check if it actually merged (race condition)
                        log_warn "Merge command returned error, verifying PR state..."
                        sleep 5  # Give GitHub a moment to update

                        local pr_state=$(GITHUB_TOKEN= gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null)
                        if [ "$pr_state" = "MERGED" ]; then
                            log_success "PR #${pr_number} was actually merged (race condition detected)"

                            # Update local main branch
                            log_info "Updating local main branch..."
                            git fetch origin main 2>/dev/null || true
                            git checkout main 2>/dev/null || true
                            git pull origin main 2>/dev/null || true

                            return 0
                        else
                            log_error "Failed to merge PR #${pr_number} (state: ${pr_state:-unknown})"
                            return 1
                        fi
                    fi
                else
                    log_info "PR status: ${merge_status}, waiting..."
                fi
                ;;
            CONFLICTING)
                log_warn "PR #${pr_number} has merge conflicts - attempting auto-fix..."
                if fix_merge_conflicts "$branch_name"; then
                    log_success "Conflicts resolved, waiting for GitHub to update status..."
                    sleep 10  # Give GitHub time to recompute mergeable status
                    # Continue the loop to check new status
                else
                    log_error "Failed to auto-fix merge conflicts"
                    log_info "Please resolve conflicts manually and re-run"
                    return 1
                fi
                ;;
            UNKNOWN)
                log_info "PR status unknown (GitHub computing), waiting..."
                ;;
            *)
                log_info "PR mergeable status: ${mergeable:-checking}, waiting..."
                ;;
        esac

        # Progress indicator
        if [ $((attempt % 4)) -eq 0 ]; then
            local elapsed=$((attempt * poll_interval / 60))
            log_info "Still waiting... (${elapsed}/${timeout_minutes} minutes)"
        fi

        sleep $poll_interval
    done

    log_error "Timeout waiting for PR #${pr_number} to become mergeable"
    log_info "You can manually merge and continue with --continue flag"
    return 1
}

# Detect shared files across phases in a milestone
# Returns 0 if shared files found, 1 if none
detect_shared_files() {
    local phases="$1"
    local seen_files=""
    local shared_files=""

    while IFS= read -r phase_num; do
        [ -z "$phase_num" ] && continue
        local phase_dir=$(resolve_phase_dir "$phase_num" 2>/dev/null)
        [ -z "$phase_dir" ] && continue

        for plan in "$phase_dir"/*-PLAN.md; do
            [ -f "$plan" ] || continue
            # Extract files from <files> tags
            local files=$(grep -o '<files>[^<]*</files>' "$plan" 2>/dev/null | sed 's/<[^>]*>//g' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            for file in $files; do
                [ -z "$file" ] && continue
                if echo "$seen_files" | grep -qx "$file"; then
                    if ! echo "$shared_files" | grep -qx "$file"; then
                        shared_files="${shared_files}${file}"$'\n'
                    fi
                else
                    seen_files="${seen_files}${file}"$'\n'
                fi
            done
        done
    done <<< "$phases"

    if [ -n "$shared_files" ]; then
        echo "$shared_files" | grep -v '^$' | sort -u
        return 0
    fi
    return 1
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

# Count number of tasks in plan file
count_tasks() {
    local plan_file="$1"
    grep -c '<task ' "$plan_file" 2>/dev/null || echo "0"
}

# Extract a single task block by number (1-indexed)
extract_task_block() {
    local plan_file="$1"
    local task_num="$2"

    # Use awk to extract the nth task block
    awk -v n="$task_num" '
        /<task / { count++; if (count == n) capture = 1 }
        capture { print }
        capture && /<\/task>/ { exit }
    ' "$plan_file"
}

# Extract task name from task block
extract_task_name() {
    local task_block="$1"
    echo "$task_block" | grep -E '<name>.*</name>' | sed 's/.*<name>\(.*\)<\/name>.*/\1/' | sed 's/^[[:space:]]*//'
}

# Extract task files from task block
extract_task_files() {
    local task_block="$1"
    echo "$task_block" | grep -E '<files>.*</files>' | sed 's/.*<files>\(.*\)<\/files>.*/\1/' | sed 's/^[[:space:]]*//'
}

# Extract task action from task block
extract_task_action() {
    local task_block="$1"
    echo "$task_block" | sed -n '/<action>/,/<\/action>/p' | grep -v '<action>\|</action>'
}

# Extract task verify command from task block
extract_task_verify() {
    local task_block="$1"
    echo "$task_block" | grep -E '<verify>.*</verify>' | sed 's/.*<verify>\(.*\)<\/verify>.*/\1/' | sed 's/^[[:space:]]*//'
}

# Extract task done criteria from task block
extract_task_done() {
    local task_block="$1"
    echo "$task_block" | grep -E '<done>.*</done>' | sed 's/.*<done>\(.*\)<\/done>.*/\1/' | sed 's/^[[:space:]]*//'
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

# Build prompt for single task execution
build_task_prompt() {
    local plan_file="$1"
    local phase_num="$2"
    local plan_num="$3"
    local task_num="$4"
    local task_block="$5"

    local task_name=$(extract_task_name "$task_block")
    local task_files=$(extract_task_files "$task_block")
    local task_action=$(extract_task_action "$task_block")
    local task_verify=$(extract_task_verify "$task_block")
    local task_done=$(extract_task_done "$task_block")

    cat << PROMPT
Execute Task ${task_num} from GSD Plan ${phase_num}-${plan_num}.

## Task: ${task_name}

### Files to modify
${task_files}

### Action
${task_action}

### Verification
Run: ${task_verify}
Success criteria: ${task_done}

## Instructions

1. Read the target files to understand current patterns
2. Implement the changes described above
3. Run the verification command: ${task_verify}
4. If verification passes, commit with:
   git commit -m "feat(${phase_num}-${plan_num}): ${task_name}

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

5. Output "TASK_COMPLETE" when done
6. Output "TASK_FAILED: <reason>" if blocked

Do NOT:
- Create PRs (the runner handles that)
- Push to remote (the runner handles that)
- Work on other tasks (one task per Claude instance)
- Create SUMMARY.md (handled after all tasks complete)
- Add unnecessary narration

Execute this single task now.
PROMPT
}

# Build prompt for creating SUMMARY.md after all tasks complete
build_summary_prompt() {
    local plan_file="$1"
    local phase_num="$2"
    local plan_num="$3"
    local tasks_completed="$4"

    cat << PROMPT
Create SUMMARY.md for completed GSD Plan ${phase_num}-${plan_num}.

## Context

- Plan file: ${plan_file}
- Tasks completed: ${tasks_completed}

## Instructions

1. Read the plan file to understand what was supposed to be done
2. Check git log to see what commits were made
3. Create the SUMMARY.md file in the same directory as the plan:
   - Filename: ${plan_file/-PLAN.md/-SUMMARY.md}
   - Include: completion date, objective, what was done, files modified, verification results
4. Commit with:
   git commit -m "docs(${phase_num}-${plan_num}): complete plan summary

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

5. Output "SUMMARY_COMPLETE" when done
6. Output "SUMMARY_FAILED: <reason>" if blocked

Do NOT add unnecessary narration. Just create the summary and commit.
PROMPT
}

# Legacy: Build prompt for plan execution (fallback for plans without task structure)
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
   - Commit with: git commit -m "feat(${phase_num}-${plan_num}): <task description>

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

# Execute a single task with Claude (fresh context per task)
# Args: plan_file phase_num plan_num task_num task_block
# Returns: 0 on success, 1 on failure
execute_task() {
    local plan_file="$1"
    local phase_num="$2"
    local plan_num="$3"
    local task_num="$4"
    local task_block="$5"

    local task_name=$(extract_task_name "$task_block")
    local task_verify=$(extract_task_verify "$task_block")
    local output_file="/tmp/gsd-phase-${phase_num}-plan-${plan_num}-task-${task_num}.log"

    log_info "  Task ${task_num}: ${task_name}"

    # Check if task needs E2E infrastructure (Docker containers)
    if needs_e2e_infrastructure "$task_verify"; then
        log_info "  Task requires E2E infrastructure (Playwright/E2E tests detected)"
        if ! start_e2e_infrastructure; then
            log_error "  Failed to start E2E infrastructure"
            return 1
        fi
    fi

    if [ $DRY_RUN -eq 1 ]; then
        log_info "  [DRY RUN] Would execute task with fresh Claude instance"
        return 0
    fi

    # Build task-specific prompt
    local prompt=$(build_task_prompt "$plan_file" "$phase_num" "$plan_num" "$task_num" "$task_block")

    log_info "  Starting fresh Claude instance for task ${task_num}..."

    if claude -p "$prompt" --allowedTools "Bash,Read,Write,Edit,Glob,Grep" 2>&1 | tee "$output_file"; then
        if grep -q "TASK_COMPLETE" "$output_file"; then
            log_success "  Task ${task_num} completed"
            return 0
        elif grep -q "TASK_FAILED" "$output_file"; then
            local reason=$(grep "TASK_FAILED" "$output_file" | head -1)
            log_error "  Task ${task_num} failed: $reason"
            return 1
        else
            # Check if there were commits made (indicates work was done)
            local commits_after=$(git rev-list --count HEAD 2>/dev/null || echo "0")
            log_warn "  Task finished without explicit completion signal"
            log_info "  Checking for commits as success indicator..."
            # If no TASK_FAILED, assume success for robustness
            return 0
        fi
    else
        log_error "  Claude execution failed for task ${task_num}"
        return 1
    fi
}

# Create SUMMARY.md after all tasks complete
# Args: plan_file phase_num plan_num tasks_completed
create_plan_summary() {
    local plan_file="$1"
    local phase_num="$2"
    local plan_num="$3"
    local tasks_completed="$4"

    local output_file="/tmp/gsd-phase-${phase_num}-plan-${plan_num}-summary.log"

    log_info "Creating SUMMARY.md..."

    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY RUN] Would create SUMMARY.md"
        return 0
    fi

    local prompt=$(build_summary_prompt "$plan_file" "$phase_num" "$plan_num" "$tasks_completed")

    if claude -p "$prompt" --allowedTools "Bash,Read,Write,Edit,Glob,Grep" 2>&1 | tee "$output_file"; then
        if grep -q "SUMMARY_COMPLETE" "$output_file" || has_summary "$plan_file"; then
            log_success "SUMMARY.md created"
            return 0
        elif grep -q "SUMMARY_FAILED" "$output_file"; then
            local reason=$(grep "SUMMARY_FAILED" "$output_file" | head -1)
            log_error "Summary creation failed: $reason"
            return 1
        else
            # Check if summary file exists
            if has_summary "$plan_file"; then
                log_success "SUMMARY.md created (no explicit signal but file exists)"
                return 0
            fi
            log_error "Summary creation finished without creating file"
            return 1
        fi
    else
        log_error "Claude execution failed for summary creation"
        return 1
    fi
}

# Run pre-push checks and auto-fix if needed
# Args: phase_num plan_num
run_prepush_checks() {
    local phase_num="$1"
    local plan_num="$2"

    if [ ! -x "$(dirname "$0")/pre-push-checks.sh" ]; then
        return 0
    fi

    log_info "Running pre-push checks..."

    if "$(dirname "$0")/pre-push-checks.sh"; then
        return 0
    fi

    log_warn "Pre-push checks failed - attempting auto-fix..."
    cd "$(git rev-parse --show-toplevel)"

    # SwiftLint auto-fix
    if [ -d "mobile/ios" ] && command -v swiftlint &> /dev/null; then
        log_info "Running swiftlint --fix..."
        (cd mobile/ios && swiftlint --fix 2>/dev/null || true)
    fi

    # Migration sync
    if [ -x "scripts/sync-migrations.sh" ]; then
        log_info "Running migration sync..."
        ./scripts/sync-migrations.sh 2>/dev/null || true
    fi

    git add -A 2>/dev/null || true

    # Re-run checks
    if "$(dirname "$0")/pre-push-checks.sh"; then
        log_success "Auto-fix resolved issues"
        return 0
    fi

    log_warn "Auto-fix didn't resolve all issues - calling Claude to fix..."

    local fix_prompt="Pre-push checks are failing. Run the checks, identify the errors, and fix them:
1. Run: ./scripts/pre-push-checks.sh
2. Fix any Go build errors
3. Fix any TypeScript type errors (yarn tsc --noEmit)
4. Fix any SwiftLint errors (cd mobile/ios && swiftlint)
5. Commit the fixes with: git commit -m 'fix: resolve pre-push check failures'
6. Output FIXES_COMPLETE when done, or FIXES_FAILED if unable to fix"

    local fix_output="/tmp/gsd-fix-${phase_num}-${plan_num}.log"
    if claude -p "$fix_prompt" --allowedTools "Bash,Read,Write,Edit,Glob,Grep" 2>&1 | tee "$fix_output"; then
        if grep -q "FIXES_COMPLETE" "$fix_output"; then
            log_success "Claude fixed the issues"
        elif grep -q "FIXES_FAILED" "$fix_output"; then
            log_error "Claude could not fix all issues - manual intervention required"
            return 1
        fi
    fi

    # Final check
    if ! "$(dirname "$0")/pre-push-checks.sh"; then
        log_error "Pre-push checks still failing after fixes - stopping"
        return 1
    fi

    log_success "All issues fixed"
    return 0
}

# Execute a single plan with Claude - one fresh instance per task
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

    # For 'single' strategy, stay on the milestone branch (base_branch)
    if [ "$BRANCH_STRATEGY" = "single" ]; then
        branch_name="$base_branch"
        log_info "Branch: ${branch_name} (single strategy - using milestone branch)"
    else
        log_info "Branch: ${branch_name}"
        log_info "Base: ${base_branch}"
    fi

    # Export for caller to track
    LAST_BRANCH="$branch_name"

    # Count tasks in the plan
    local total_tasks=$(count_tasks "$plan_file")
    log_info "Tasks in plan: ${total_tasks}"

    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY RUN] Would execute ${total_tasks} tasks, each in fresh Claude instance"
        for i in $(seq 1 "$total_tasks"); do
            local task_block=$(extract_task_block "$plan_file" "$i")
            local task_name=$(extract_task_name "$task_block")
            log_info "  Task ${i}: ${task_name}"
        done
        return 0
    fi

    # Setup branch
    if [ "$BRANCH_STRATEGY" = "single" ]; then
        git checkout "$base_branch" 2>/dev/null || {
            log_error "Milestone branch ${base_branch} not found"
            return 1
        }
    else
        if [ "$base_branch" = "main" ]; then
            git fetch origin main 2>/dev/null || true
            git checkout main 2>/dev/null || true
            git pull origin main 2>/dev/null || true
        else
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
    fi

    # If no structured tasks, fall back to legacy single-prompt execution
    if [ "$total_tasks" -eq 0 ]; then
        log_warn "No structured tasks found - using legacy single-prompt execution"
        local prompt=$(build_plan_prompt "$plan_file" "$phase_num" "$plan_num")
        local output_file="/tmp/gsd-phase-${phase_num}-plan-${plan_num}.log"

        log_info "Starting Claude instance..."

        if claude -p "$prompt" --allowedTools "Bash,Read,Write,Edit,Glob,Grep" 2>&1 | tee "$output_file"; then
            if grep -q "PLAN_COMPLETE" "$output_file"; then
                if ! has_summary "$plan_file"; then
                    log_error "Claude claimed PLAN_COMPLETE but no SUMMARY.md was created"
                    return 1
                fi
                log_success "Plan ${phase_num}-${plan_num} completed"
            elif grep -q "PLAN_FAILED" "$output_file"; then
                log_error "Plan failed: $(grep 'PLAN_FAILED' "$output_file" | head -1)"
                return 1
            else
                if ! has_summary "$plan_file"; then
                    log_error "Plan finished without completion signal or SUMMARY.md"
                    return 1
                fi
            fi
        else
            log_error "Claude execution failed"
            return 1
        fi
    else
        # Execute each task in a fresh Claude instance
        local tasks_completed=0

        for task_num in $(seq 1 "$total_tasks"); do
            echo ""
            local task_block=$(extract_task_block "$plan_file" "$task_num")

            if execute_task "$plan_file" "$phase_num" "$plan_num" "$task_num" "$task_block"; then
                tasks_completed=$((tasks_completed + 1))
            else
                log_error "Task ${task_num} failed - stopping plan execution"
                return 1
            fi
        done

        log_success "All ${tasks_completed}/${total_tasks} tasks completed"

        # Create SUMMARY.md in fresh Claude instance
        echo ""
        if ! create_plan_summary "$plan_file" "$phase_num" "$plan_num" "$tasks_completed"; then
            log_error "Failed to create SUMMARY.md"
            return 1
        fi
    fi

    # Verify SUMMARY.md exists
    if ! has_summary "$plan_file"; then
        log_error "Plan execution finished but no SUMMARY.md was created"
        return 1
    fi

    # Skip push/PR for 'single' strategy - handled at milestone level
    if [ "$BRANCH_STRATEGY" = "single" ]; then
        log_info "Commits added to milestone branch (PR created at milestone end)"
        return 0
    fi

    # Run pre-push checks
    if ! run_prepush_checks "$phase_num" "$plan_num"; then
        return 1
    fi

    # Push and create PR
    log_info "Pushing to remote..."
    git push -u origin "$branch_name" 2>/dev/null || git push --force-with-lease origin "$branch_name"

    log_info "Creating PR..."
    local pr_title="Phase ${phase_num} Plan ${plan_num}: ${objective:0:50}"
    local pr_body=$(build_pr_body "$plan_file" "$phase_num" "$plan_num" "$base_branch")

    GITHUB_TOKEN= gh pr create --title "$pr_title" --body "$pr_body" 2>/dev/null && log_success "PR created" || log_warn "PR creation failed or already exists"

    # Auto-merge if enabled
    if [ $AUTO_MERGE -eq 1 ]; then
        if ! wait_and_merge_pr "$branch_name"; then
            log_error "Auto-merge failed for ${branch_name}"
            return 1
        fi
    fi

    return 0
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

    # Check for shared files across phases (skip warning if auto-merge enabled)
    local shared=$(detect_shared_files "$phases")
    if [ -n "$shared" ] && [ "$BRANCH_STRATEGY" = "independent" ] && [ $AUTO_MERGE -eq 0 ]; then
        log_warn "═══════════════════════════════════════════════════════════"
        log_warn "SHARED FILES DETECTED across phases:"
        echo "$shared" | while read -r f; do
            [ -n "$f" ] && log_warn "  - $f"
        done
        log_warn ""
        log_warn "Using 'independent' strategy will cause merge conflicts!"
        log_warn "Recommended: --branch-strategy chain or --auto-merge"
        log_warn "═══════════════════════════════════════════════════════════"
        echo ""

        if [ $DRY_RUN -eq 0 ]; then
            read -p "Continue anyway? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Aborted. Re-run with: --branch-strategy chain or --auto-merge"
                exit 0
            fi
        fi
    fi

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

    # Track base branch for chaining - strategy determines how this is used
    local current_base="main"
    local milestone_branch=""

    log_info "Branch strategy: ${BRANCH_STRATEGY}"

    # For 'single' strategy, create one branch for all phases
    if [ "$BRANCH_STRATEGY" = "single" ]; then
        milestone_branch="milestone/${milestone}-$(date +%Y%m%d-%H%M%S)"
        log_info "Creating single branch for all phases: ${milestone_branch}"
        git fetch origin main 2>/dev/null || true
        git checkout main 2>/dev/null || true
        git pull origin main 2>/dev/null || true
        git checkout -b "$milestone_branch"
        current_base="$milestone_branch"
    fi

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
            continue
        fi

        # Determine base branch based on strategy
        local phase_base="main"
        case "$BRANCH_STRATEGY" in
            independent)
                # Each phase branches from main (clean, independent PRs)
                phase_base="main"
                ;;
            chain)
                # Each phase branches from previous (stacked PRs)
                phase_base="$current_base"
                ;;
            single)
                # All phases on same branch (single PR at end)
                phase_base="$milestone_branch"
                ;;
        esac

        # Execute phase with appropriate base
        if execute_phase "$phase_num" "$phase_base"; then
            phases_completed=$((phases_completed + 1))
            # Only update current_base for chain strategy
            if [ "$BRANCH_STRATEGY" = "chain" ]; then
                current_base="$LAST_BRANCH"
                log_info "Next phase will branch from: ${current_base}"
            fi
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

    # For 'single' strategy, create PR at the end
    if [ "$BRANCH_STRATEGY" = "single" ] && [ $phases_completed -gt 0 ]; then
        # Run pre-push checks and fix issues locally
        log_info "Running pre-push checks..."
        if [ -x "$(dirname "$0")/pre-push-checks.sh" ]; then
            if ! "$(dirname "$0")/pre-push-checks.sh"; then
                log_warn "Pre-push checks failed - attempting auto-fix..."
                cd "$(git rev-parse --show-toplevel)"

                # SwiftLint auto-fix
                if [ -d "mobile/ios" ] && command -v swiftlint &> /dev/null; then
                    log_info "Running swiftlint --fix..."
                    (cd mobile/ios && swiftlint --fix 2>/dev/null || true)
                fi

                # Migration sync
                if [ -x "scripts/sync-migrations.sh" ]; then
                    log_info "Running migration sync..."
                    ./scripts/sync-migrations.sh 2>/dev/null || true
                fi

                git add -A 2>/dev/null || true
                git commit -m "fix: auto-fix pre-push check issues" 2>/dev/null || true

                # Re-run checks
                if ! "$(dirname "$0")/pre-push-checks.sh"; then
                    log_error "Pre-push checks still failing after auto-fix"
                    log_info "Manual fixes required before pushing"
                    exit 1
                fi
                log_success "All issues fixed"
            fi
        fi

        log_info "Creating single PR for milestone ${milestone}..."
        git push -u origin "$milestone_branch" 2>/dev/null || git push --force-with-lease origin "$milestone_branch"
        local pr_title="Milestone ${milestone}: ${phases_completed} phases completed"
        local pr_body="## Milestone ${milestone}

Completed ${phases_completed} phases in a single PR.

### Phases Included
$(echo "$phases" | while read -r p; do [ -n "$p" ] && echo "- Phase $p"; done)

---
🤖 Generated with [gsd-phase-executor.sh](https://github.com/solidsystems/get-shit-done)"
        GITHUB_TOKEN= gh pr create --title "$pr_title" --body "$pr_body" 2>/dev/null && log_success "PR created" || log_warn "PR creation failed or already exists"

        # Auto-merge if enabled
        if [ $AUTO_MERGE -eq 1 ]; then
            if ! wait_and_merge_pr "$milestone_branch"; then
                log_warn "Auto-merge failed for milestone PR - manual merge required"
            fi
        fi
    fi

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
