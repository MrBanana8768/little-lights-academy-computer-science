# Git quickstart

Every assignment in this course is a **Git repo**, not a `.zip` file. You clone it, you
work in it, you push it. Pushing *is* submitting.

This page is a reference — expect to come back to it. Run the commands in Terminal /
PowerShell / Git Bash on Windows, or your normal terminal on Linux.

---

## 1. One-time setup

Do this once per machine, before your first commit. The setup script warns you if you
haven't — it deliberately doesn't do it for you, because these are *your* details.

```bash
git config --global user.name "Your Name"
```

```bash
git config --global user.email "you@example.com"
```

Use the same email as your GitHub/GitLab account, or your commits won't be linked to
you. Until both are set, Git will refuse to commit at all.

Two more worth setting:

```bash
git config --global init.defaultBranch main
```

**Windows only** — stops Windows line endings from showing up as "every line changed"
in your diffs:

```bash
git config --global core.autocrlf true
```

Check what you've set:

```bash
git config --global --list
```

---

## 2. The assignment loop

### Get the assignment

```bash
git clone <assignment-repo-url>
```

```bash
cd <folder-it-created>
```

Then open that folder in IntelliJ IDEA (**File → Open**, pick the folder itself, not a
file inside it). On Linux you can also just run `idea .` from inside the folder.

### See what you've changed

```bash
git status
```

**Run this constantly.** It's the command that makes Git make sense: it tells you which
files you've changed, which are staged, and what to do next. If you're ever unsure what
state you're in, `git status` is the answer.

### Stage your changes

```bash
git add .
```

The `.` means "everything in this folder". To stage one file instead:

```bash
git add src/Main.java
```

### Commit

```bash
git commit -m "Implement the sorting method"
```

A commit is a save point in your history. Commit often — small, frequent commits are
much easier to work with than one giant one at the deadline. Write messages that say
what you did, not "stuff" or "update".

### Submit

```bash
git push
```

**This is your submission.** Nothing you haven't pushed exists as far as marking is
concerned. Nothing on your laptop counts.

### Confirm it landed

```bash
git log --oneline -1
```

That shows your latest local commit. Then open the repo in your browser and check the
same commit message is there. If it is, you've submitted.

> **Deadlines are judged on the timestamp of your last pushed commit.** Committing
> locally before the deadline but pushing afterwards counts as late. Push early, push
> often.

---

## 3. Getting unstuck

### "Please tell me who you are"

You skipped section 1. Run the two `git config --global` commands above, then commit
again.

### "Updates were rejected because the remote contains work that you do not have"

Someone (or you, on another machine) pushed since you last pulled. Get their changes
first, then push again:

```bash
git pull
```

```bash
git push
```

### `git pull` opened a strange editor asking for a merge message

That's Vim. Type `:wq` and press Enter to accept the default message and carry on.
To avoid it in future:

```bash
git config --global pull.rebase false
git config --global core.editor "code --wait"
```

### "Authentication failed" when cloning or pushing

For HTTPS URLs, your username and password won't work — you need a **personal access
token** in place of the password, or an **SSH key**. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md), section *"git clone or git push asks for a
password and rejects it"*.

### I committed to the wrong branch

Find out where you are:

```bash
git branch --show-current
```

Move the commit to `main` (this rewinds your last commit, keeping the file changes):

```bash
git reset --soft HEAD~1
git switch main
git commit -m "Your message"
```

### I want to throw away my changes and start over

**This deletes work permanently.** Only run it if you're sure:

```bash
git restore .
```

To also throw away files Git isn't tracking yet, preview first with `git clean -n`,
then run `git clean -f`.

### I've made a mess and want help

Don't delete the folder and re-clone — you'll lose your work and your history. Bring
the output of these two commands to your instructor:

```bash
git status
```

```bash
git log --oneline -5
```

---

## 4. Command reference

| Command | What it does |
|---|---|
| `git clone <url>` | Download a repo for the first time |
| `git status` | What's changed, what's staged, what to do next |
| `git add .` | Stage all your changes for the next commit |
| `git commit -m "msg"` | Save a snapshot with a message |
| `git push` | Send your commits to the server — **this is submitting** |
| `git pull` | Fetch and merge changes from the server |
| `git log --oneline` | Compact history |
| `git diff` | Exactly what you changed, line by line |
| `git branch --show-current` | Which branch you're on |
| `git restore <file>` | Discard changes to a file (destructive) |
