# Git Command Reference

A scenario-based cheat sheet for this repo. Find your situation below and copy the commands.

## Check where you stand

**"What's changed / what am I on?"**
```bash
git status              # what's modified, staged, untracked, current branch
git branch --show-current
git log --oneline -10   # recent commit history
git diff                # unstaged changes, file by file
git diff --stat         # just a summary of which files changed
```

## Starting new work

**"I want to start a new feature/fix, based on the latest main"**
```bash
git checkout main
git pull origin main          # make sure local main matches GitHub
git checkout -b fix/my-change # branch off it
```

**"I'm not sure if my local main is behind GitHub"**
```bash
git fetch origin
git status    # will say "behind 'origin/main' by N commits" if so
```

## Saving work

**"I've edited files and want to commit them"**
```bash
git add path/to/file.md     # stage specific file(s) — safer than `git add .`
git status                  # double-check what's staged before committing
git commit -m "Short description of the change"
```

**"I staged the wrong file"**
```bash
git restore --staged path/to/file.md   # unstages it, keeps your edits
```

**"I want to discard an edit entirely (not commit it)"**
```bash
git restore path/to/file.md   # reverts the file to its last committed state — DESTRUCTIVE, edit is gone
```

## Publishing work

**"I want to push a new branch for the first time"**
```bash
git push -u origin branch-name   # -u links local branch to the remote one
```

**"I've already pushed this branch before, just pushing new commits"**
```bash
git push
```

**"I want to open a PR after pushing"**
```bash
gh pr create --fill    # uses your last commit message as the PR title/body
# or just open the compare link GitHub prints after `git push`
```

## Switching branches mid-work

**"I have uncommitted changes but need to switch branches"**

Git will refuse if the switch would overwrite those changes. Two options:

```bash
# Option A: you're not ready to commit yet
git stash                # shelves the changes, working directory goes clean
git checkout other-branch
git stash pop             # brings the shelved changes back, on the new branch

# Option B: you're ready to commit
git add path/to/file.md
git commit -m "message"
git checkout other-branch  # now works cleanly, the commit stays on the original branch
```

**"I have several things stashed and lost track"**
```bash
git stash list             # see everything you've stashed
git stash pop               # applies + removes the most recent one
git stash apply stash@{1}    # applies a specific one without removing it from the list
```

## Cleaning up a branch after it's merged

**"My PR got merged on GitHub, now what locally?"**
```bash
git checkout main
git pull origin main         # brings the merged commit(s) into local main
git branch -d fix/my-change   # deletes the now-merged local branch (safe: only deletes if fully merged)
```

**"I want to delete the remote branch too"**
```bash
git push origin --delete fix/my-change
```
(GitHub often does this automatically after a PR merge if "Automatically delete head branches" is enabled in repo Settings → General.)

## Undoing things

**"I committed but haven't pushed yet, want to undo the commit but keep the edits"**
```bash
git reset --soft HEAD~1   # uncommits, keeps changes staged
```

**"I want to see what a specific commit changed"**
```bash
git show <commit-hash>
```

**"I pushed something wrong and need to revert it"**
```bash
git revert <commit-hash>   # creates a NEW commit that undoes the old one — safe for shared branches
```
Avoid `git reset --hard` + force-push on any branch others might have pulled — it rewrites history.

## Quick glossary

| Term | Meaning |
|---|---|
| **staged** | Marked to be included in the next commit (`git add` does this) |
| **committed** | Permanently recorded in this branch's local history |
| **pushed** | Uploaded to GitHub (`origin`) — visible to others |
| **stash** | A temporary shelf for uncommitted changes, separate from any branch |
| **origin** | The default name for this repo's GitHub remote |
