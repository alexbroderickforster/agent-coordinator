# Worktree cleanup

Agents create a git worktree per task and rarely remove it. Each one is a full checkout plus build output, so a busy repo can fill a laptop within weeks. Two habits keep it under control.

## As you go
- Deploy worktrees: remove right after RELEASE.
- Feature worktrees: remove when the PR merges.
- Put both in the kickoff (templates/kickoff-template.md) and the repo's instruction files.

## Weekly sweep (or when free disk drops below ~40 GB)
Dry-run first, then act. For each worktree from `git worktree list --porcelain`:
1. **Skip** it if any process has its working directory inside it (`lsof -d cwd`), it was touched in the last 2 days, a session in the registry still owns it, or it is a deliberately named checkout.
2. **Committed work is safe.** Removing a worktree keeps its branch, so unmerged commits stay in the repo. Check that a detached HEAD has nothing unique: `git cherry origin/main HEAD` shows no `+` lines.
3. **Uncommitted work needs a backup**, including untracked files. A plain `git stash create` captures tracked files only. Instead, build a commit with a temporary index, without touching the worktree, the branch or the shared stash:
   ```sh
   cp "$(git -C <wt> rev-parse --git-path index)" /tmp/idx
   GIT_INDEX_FILE=/tmp/idx git -C <wt> add -A -- . ':(exclude,glob)**/secrets/**'   # also exclude caches and files over ~5 MB
   tree=$(GIT_INDEX_FILE=/tmp/idx git -C <wt> write-tree)
   c=$(git -C <wt> commit-tree "$tree" -p HEAD -m "WIP backup of <wt>")
   git update-ref refs/wip-backup/<wt>-<date> "$c"
   ```
   Then check that every changed file is in the backup's tree before going on. Changes that are only regenerated build files (indexes, caches) need no backup.
4. **Move, don't delete:** `mv <wt> ~/.Trash/<name>-wt-<date>`, then `git worktree prune`. To undo, move it back and run `git worktree repair`.
5. Tell the owner: how many worktrees went and how much space was freed, which ones had backups and the refs that hold them, and that local-only refs are a single copy on this machine (push them if that matters).
