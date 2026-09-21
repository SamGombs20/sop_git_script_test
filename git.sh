#!/usr/bin/env bash
#
# git.sh — add, commit, pull (merge), reconcile Alembic migrations, push.
#
# Usage:  ./git.sh "commit message"
#
# Env overrides:
#   ALEMBIC_DIR       directory containing alembic.ini   (default: repo root)
#   ALEMBIC_CMD       how to invoke alembic              (default: alembic)
#   AUTO_UPGRADE=1    upgrade the database without asking
#   SKIP_DB=1         only merge heads; don't touch the database
#   PR_BASE           base branch for the PR   (default: main for hotfix/*, else dev)
#                     — also the branch offered for syncing into yours before the PR
#   SYNC_BASE         1 = always merge the base branch in, 0 = never, unset = ask when it has new commits
#   BRANCH_PREFIXES   allowed branch prefixes  (default: feature|bugfix|hotfix)
#   COMMIT_TYPES      allowed commit types     (default: feat|fix|refactor|docs|test|chore)
#   ALLOW_PROTECTED=1 allow running on main/dev (SOP says don't)

set -uo pipefail

ALEMBIC_CMD="${ALEMBIC_CMD:-alembic}"
ALEMBIC_DIR="${ALEMBIC_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
AUTO_UPGRADE="${AUTO_UPGRADE:-0}"
SKIP_DB="${SKIP_DB:-0}"
PR_BASE="${PR_BASE:-}"
BRANCH_PREFIXES="${BRANCH_PREFIXES:-feature|bugfix|hotfix}"
COMMIT_TYPES="${COMMIT_TYPES:-feat|fix|refactor|docs|test|chore}"

confirm() {  # confirm "question"  → true only on y/Y
  local a; read -r -p "$1 [y/N] " a
  case "${a:-N}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "➜ $*"; }
warn() { echo "⚠️  $*"; }

# --- 0. Sanity checks -------------------------------------------------------
[ -z "${1:-}" ] && die "Please provide a commit message: ./git.sh \"message\""
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository"

# symbolic-ref (unlike rev-parse) also works in a repo with no commits yet
BRANCH=$(git symbolic-ref --short -q HEAD || true)
[ -z "$BRANCH" ] && die "Detached HEAD — check out a branch first"

if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
  die "A merge is already in progress. Resolve it, run 'git commit', then re-run."
fi

# --- Branch rules (SOP) -----------------------------------------------------
# main = production, dev = integration; work on feature/, bugfix/ or hotfix/ branches
valid_branch() { echo "$1" | grep -qE "^($BRANCH_PREFIXES)/[A-Za-z0-9._/-]+$"; }

# Create a new branch from the current HEAD. Uncommitted changes and any local
# commits come along; the branch you were on is left untouched.
create_branch_from_here() {
  local name tries=0
  while [ "$tries" -lt 3 ]; do
    read -r -p "New branch name (${BRANCH_PREFIXES//|/, }/<description>, e.g. feature/export-report): " name
    if ! valid_branch "$name" || ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
      warn "'$name' isn't a valid name"
    elif git show-ref --verify --quiet "refs/heads/$name"; then
      warn "'$name' already exists — pick another (or 'git checkout $name' first)"
    else
      git checkout -b "$name" || die "Could not create branch '$name'"
      BRANCH="$name"
      info "Now on '$BRANCH' — your changes came with you"
      return 0
    fi
    tries=$((tries + 1))
  done
  die "No valid branch name given. Nothing was changed."
}

# Switch to an existing feature/bugfix/hotfix branch (local, or remote-only —
# git sets up tracking for those). Uncommitted changes come along; if they
# conflict with the target branch, git refuses and nothing is changed.
switch_to_existing_branch() {
  git fetch --prune origin >/dev/null 2>&1 || true

  local branches=() line name choice i=0
  while IFS= read -r line; do branches+=("$line"); done < <(
    { git for-each-ref --format='%(refname:short)' refs/heads/
      git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | sed 's#^origin/##'
    } | grep -E "^($BRANCH_PREFIXES)/" | sort -u
  )

  if [ "${#branches[@]}" -eq 0 ]; then
    warn "No ${BRANCH_PREFIXES//|/, } branches found — create a new one instead."
    return 1
  fi

  echo "Existing branches:"
  for name in "${branches[@]}"; do i=$((i + 1)); echo "   $i) $name"; done
  read -r -p "Number or branch name (Enter to cancel): " choice
  [ -z "$choice" ] && return 1

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#branches[@]}" ]; then
    name="${branches[$((choice - 1))]}"
  else
    name="$choice"
  fi

  valid_branch "$name" || { warn "'$name' isn't a ${BRANCH_PREFIXES//|/, } branch"; return 1; }

  if ! git checkout "$name"; then
    warn "Couldn't switch — you probably have uncommitted changes that conflict with '$name'."
    echo "   Try: git stash && git checkout $name && git stash pop"
    return 1
  fi
  BRANCH=$(git symbolic-ref --short -q HEAD)
  info "Now on '$BRANCH' — your changes came with you"
}

# Menu shown when you're on the wrong branch. Returns 1 if cancelled.
choose_branch_action() {
  local c
  echo "What would you like to do?"
  echo "   1) Create a new branch from here"
  echo "   2) Switch to an existing branch"
  echo "   3) Cancel"
  read -r -p "Choice [1/2/3]: " c
  case "$c" in
    1) create_branch_from_here ;;
    2) switch_to_existing_branch || die "Stopped. Nothing was committed." ;;
    *) return 1 ;;
  esac
}

case "$BRANCH" in
  main|master|dev|develop)
    if [ "${ALLOW_PROTECTED:-0}" != "1" ]; then
      warn "You're on '$BRANCH'. Per the SOP, don't work directly on main or dev."
      # In a repo with no commits, '$BRANCH' isn't a real branch yet: branching off now
      # would make it vanish and your first commit would land on the new branch.
      if ! git rev-parse --verify -q HEAD >/dev/null; then
        echo "   This repo has no commits yet, so '$BRANCH' doesn't really exist until it has one."
        if confirm "Create an empty initial commit on '$BRANCH' first (so it exists)?"; then
          # plumbing, so anything you've already staged stays out of this commit
          init_sha=$(git commit-tree "$(git mktree </dev/null)" -m "chore: initial commit") \
            && git update-ref "refs/heads/$BRANCH" "$init_sha" \
            || die "Couldn't create the initial commit (are git user.name / user.email set?)"
          info "Created '$BRANCH' with an empty initial commit. Publish it later: git push -u origin $BRANCH"
        else
          warn "Continuing without it — '$BRANCH' won't exist afterwards."
        fi
      fi
      if git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
        ahead=$(git rev-list --count "origin/$BRANCH..$BRANCH")
        if [ "$ahead" -gt 0 ]; then
          echo "   '$BRANCH' has $ahead local commit(s) not on origin. They stay on '$BRANCH' if you switch,"
          echo "   and come along if you create a new branch (then tidy up: git checkout $BRANCH && git reset --hard origin/$BRANCH)."
        fi
      fi
      choose_branch_action \
        || die "Stopped. Switch branches yourself, or set ALLOW_PROTECTED=1 to override."
    fi ;;
esac

if ! valid_branch "$BRANCH"; then
  warn "Branch '$BRANCH' doesn't follow the naming convention ($BRANCH_PREFIXES)/<description>"
  if ! choose_branch_action; then
    confirm "Continue on '$BRANCH' anyway?" || die "Stopped."
  fi
fi

# SOP: commit messages like "fix: correct table sorting logic"
if ! echo "$1" | grep -qE "^($COMMIT_TYPES)(\([^)]+\))?!?: .+"; then
  warn "Commit message should be 'type: short summary' with type one of: ${COMMIT_TYPES//|/, }"
  echo "   e.g. \"fix: correct table sorting logic\""
  confirm "Commit with it anyway?" || die "Re-run with a conventional message."
fi

# --- Alembic helpers --------------------------------------------------------
alembic_run() { (cd "$ALEMBIC_DIR" && $ALEMBIC_CMD "$@"); }

# Revision ids only, sorted, one per line
# Only real revision lines, e.g. "e0988833ea88 (head)" — not alembic's "INFO  [alembic..." log lines
rev_ids() { grep -E '^[0-9a-zA-Z_]+( \([^)]*\))*$' | awk '{print $1}' | sort; }

has_alembic() {
  [ -f "$ALEMBIC_DIR/alembic.ini" ] && command -v "${ALEMBIC_CMD%% *}" >/dev/null 2>&1
}

# Step A: make sure the migration files form a single line of history
merge_heads_if_needed() {
  local heads count
  heads=$(alembic_run heads 2>/dev/null | rev_ids)
  count=$(echo "$heads" | grep -c .)

  if [ "$count" -le 1 ]; then
    info "Alembic: single head ✔"
    return 0
  fi

  warn "Alembic: $count heads detected (a teammate added a migration too):"
  echo "$heads" | sed 's/^/     /'
  read -r -p "Create a merge migration? [Y/n] " ans
  case "${ans:-Y}" in
    [Nn]*) die "Aborting. Fix manually: alembic merge -m \"merge heads\" heads" ;;
  esac

  alembic_run merge -m "merge heads" heads || die "alembic merge failed"
  git add -A
  git commit -m "Merge alembic heads" || die "Failed to commit merge migration"
  info "Alembic heads merged ✔"
}

# Step B: bring the database in line with the migration files
reconcile_database() {
  local out db_revs head_revs

  if ! out=$(alembic_run current 2>&1); then
    if echo "$out" | grep -qi "can't locate revision"; then
      warn "Your database is at a revision that isn't in your migration files."
      echo "   Usually it was migrated from another branch, or a teammate's migration"
      echo "   hasn't been pulled. Skipping — no automatic fix ('stamp' can hide real drift)."
    elif echo "$out" | grep -q "sqlalchemy.dialects:driver"; then
      warn "alembic.ini still has the placeholder database URL (driver://user:pass@localhost/dbname)."
      echo "   Set sqlalchemy.url in alembic.ini, or read your real URL in alembic/env.py, e.g.:"
      echo "     config.set_main_option(\"sqlalchemy.url\", os.environ[\"DATABASE_URL\"])"
      echo "   For a quick local test: sqlalchemy.url = sqlite:///test.db"
    elif echo "$out" | grep -q "NoSuchModuleError"; then
      warn "SQLAlchemy can't load the database driver named in your URL."
      echo "   Check the URL's dialect (e.g. postgresql+psycopg2://...) and that the driver is"
      echo "   installed in the active virtualenv (e.g. pip install psycopg2-binary)."
    elif echo "$out" | grep -qE "OperationalError|Connection refused|could not connect|password authentication"; then
      warn "Couldn't connect to the database. Is it running, and are the URL/credentials right?"
      echo "$out" | tail -3 | sed 's/^/     /'
    elif echo "$out" | grep -q "ModuleNotFoundError"; then
      warn "A Python module is missing — is your virtualenv activated?"
      echo "$out" | tail -2 | sed 's/^/     /'
    else
      warn "Could not read the database's current revision:"
      echo "$out" | tail -5 | sed 's/^/     /'
    fi
    return 1
  fi

  db_revs=$(echo "$out" | rev_ids)
  head_revs=$(alembic_run heads 2>/dev/null | rev_ids)

  if [ "$db_revs" = "$head_revs" ]; then
    info "Database up to date ✔"
    return 0
  fi

  echo "   Database at: $(echo "${db_revs:-<none applied>}" | tr '\n' ' ')"
  echo "   Code at:     $(echo "$head_revs" | tr '\n' ' ')"
  echo "   Pending migrations:"
  alembic_run history -i -r current:head 2>/dev/null | sed 's/^/     /' || true

  if [ "$AUTO_UPGRADE" != "1" ]; then
    read -r -p "Run 'alembic upgrade head'? [y/N] " ans
    case "${ans:-N}" in
      [Yy]*) ;;
      *) warn "Skipped database upgrade"; return 0 ;;
    esac
  fi

  alembic_run upgrade head || return 1
  info "Database upgraded ✔"
}

reconcile_alembic() {
  has_alembic || { info "Alembic not configured here — skipping migrations"; return 0; }

  merge_heads_if_needed
  [ "$SKIP_DB" = "1" ] && return 0

  if ! reconcile_database; then
    read -r -p "Database reconcile failed. Push anyway? [y/N] " ans
    case "${ans:-N}" in
      [Yy]*) ;;
      *) die "Stopped before push. Fix the migration problem and re-run." ;;
    esac
  fi
}

# Base branch for this branch's PR: hotfix/* goes to main, everything else to dev
pr_base() {
  if [ -n "$PR_BASE" ]; then echo "$PR_BASE"; return; fi
  case "$BRANCH" in hotfix/*) echo "main" ;; *) echo "dev" ;; esac
}

report_conflicts() {
  echo
  warn "Merge conflicts in:"
  git diff --name-only --diff-filter=U | sed 's/^/     /'

  if git diff --name-only --diff-filter=U | grep -q 'alembic/versions/'; then
    echo
    echo "   Conflicts inside alembic/versions/ usually mean two people edited the"
    echo "   same migration file. Resolve by hand — don't tweak down_revision to"
    echo "   'make it fit'; use 'alembic merge' after resolving instead."
  fi

  echo
  echo "Resolve, then:  git add <files> && git commit"
  echo "Re-run this script afterwards (it goes straight to reconcile + push)."
}

# If the PR's base branch (dev, or main for hotfixes) has moved on since you
# branched, offer to merge it into your branch — so conflicts and new Alembic
# migrations show up now, not at PR time. Merge only: no rebase, no force-push.
sync_from_base() {
  local base behind
  base=$(pr_base)
  [ "$BRANCH" = "$base" ] && return 0
  [ "${SYNC_BASE:-ask}" = "0" ] && return 0

  if ! git fetch -q origin "$base" 2>/dev/null; then
    info "Couldn't fetch origin/$base — skipping the sync check"
    return 0
  fi
  git rev-parse --verify -q "origin/$base" >/dev/null || return 0

  behind=$(git rev-list --count "HEAD..origin/$base")
  if [ "$behind" -eq 0 ]; then
    info "Up to date with origin/$base ✔"
    return 0
  fi

  echo
  info "origin/$base has $behind commit(s) that '$BRANCH' doesn't have yet:"
  git log --oneline --no-decorate -5 "HEAD..origin/$base" | sed 's/^/     /'
  [ "$behind" -gt 5 ] && echo "     ... and $((behind - 5)) more"

  if [ "${SYNC_BASE:-ask}" != "1" ] && ! confirm "Merge origin/$base into '$BRANCH' now?"; then
    warn "Skipped — expect to resolve any differences at PR time."
    return 0
  fi

  if ! git merge --no-edit "origin/$base"; then
    report_conflicts
    exit 1
  fi
  info "Merged origin/$base ✔"
}

# --- 1. Commit local work ---------------------------------------------------
info "Staging and committing on '$BRANCH'"
git add -A
if git diff --cached --quiet; then
  info "Nothing new to commit — continuing to sync"
else
  git commit -m "$1" || die "Commit failed"
fi

# --- 2. Pull remote changes (merge, not rebase) -----------------------------
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  info "Pulling origin/$BRANCH"
  if ! git pull --no-rebase --no-edit origin "$BRANCH"; then
    report_conflicts
    exit 1
  fi
else
  info "Remote branch doesn't exist yet — skipping pull"
fi

# --- 2b. Bring in the base branch (dev / main) if it has moved on ----------
sync_from_base

# --- 3. Reconcile migrations ------------------------------------------------
reconcile_alembic

# --- 4. Push ----------------------------------------------------------------
echo
info "Pushing to origin/$BRANCH"
if git push -u origin "$BRANCH"; then
  echo "✅ Pushed."

  # --- 5. Open a Pull Request (SOP step 5) ----------------------------------
  base=$(pr_base)
  remote_url=$(git remote get-url origin 2>/dev/null || true)
  web_url=$(echo "$remote_url" \
    | sed -E 's#^git@([^:]+):#https://\1/#; s#^ssh://git@([^/]+)/#https://\1/#; s#\.git$##')

  echo
  echo "Open a PR ($BRANCH → $base):"
  echo "   $web_url/compare/$base...$BRANCH?expand=1"
  case "$BRANCH" in hotfix/*) echo "   (hotfix → production: also merge it back into dev afterwards)" ;; esac
  if command -v gh >/dev/null 2>&1 && confirm "Create the PR now with the GitHub CLI?"; then
    gh pr create --base "$base" --head "$BRANCH"   # prompts for title + description
  fi
else
  die "Push failed — someone may have pushed in the meantime. Re-run the script."
fi