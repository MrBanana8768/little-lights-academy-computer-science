# Course setup — Java 25 + IntelliJ IDEA

Everything you need for the Software Development course, in four stages.
Budget about **20 minutes** and **10 GB** of free disk space.

---

## Stage 0 — Install Git (2 minutes, do this first)

Git is the *only* thing you install by hand. Everything else is automated — but the
automation lives in a Git repo, so Git has to come first.

**Windows** — open Terminal or PowerShell and run:

```bash
winget install --exact --id Git.Git --accept-package-agreements --accept-source-agreements
```

If `winget` isn't recognised, download the installer instead — this is the one that
includes **Git Bash**, which you'll see referenced throughout the course:

<https://git-scm.com/download/win>

Accept the default options in the installer.

**Linux:**

```bash
sudo apt install git      # Debian, Ubuntu, Mint, Pop!_OS
```

```bash
sudo dnf install git      # Fedora, RHEL, Rocky
```

**Close and reopen your terminal**, then check it worked:

```bash
git --version
```

---

## Stage 1 — Clone this repo

This is your first real command-line task, and it's the same thing you'll do for
every assignment in the course.

```bash
git clone https://github.com/MrBanana8768/little-lights-academy-computer-science.git
```

That creates a folder in your current directory. Move into the setup kit:

```bash
cd little-lights-academy-computer-science/resources/setup
```

Assignments are handed out and handed in as Git repos — never as `.zip` files. Getting
comfortable with `clone` now saves you a lot of pain later.

---

## Stage 2 — Run the installer

The script installs **Eclipse Temurin JDK 25**, **IntelliJ IDEA** and **Visual Studio
Code**, wires up `JAVA_HOME` and `PATH`, then proves it all works by compiling and
running a small Java program.

**Windows** — right-click the Start button, choose **Terminal (Admin)**, `cd` to the
`setup` folder, then:

```bash
Set-ExecutionPolicy -Scope Process -Bypass -Force; .\install-windows.ps1
```

**Linux:**

```bash
chmod +x install-linux.sh && ./install-linux.sh
```

Want to see what it *would* do without changing anything? Add `-DryRun` (Windows) or
`--dry-run` (Linux).

### What you should see

The script works through seven numbered phases and ends with a summary table:

```
Component              Status  Detail
---------              ------  ------
Git (prerequisite)     OK      git version 2.55.0.windows.1
Temurin JDK 25         OK      Installed
IntelliJ IDEA          OK      C:\Program Files\JetBrains\...\idea64.exe
Compile and run        OK      javac + java round trip
```

**All `OK` or `SKIPPED`** → you're done. Close the terminal and open a new one so the
new `PATH` and `JAVA_HOME` take effect.

**Anything `FAIL`** → look it up in [TROUBLESHOOTING.md](TROUBLESHOOTING.md). If that
doesn't sort it, send your instructor the log file — the script prints its exact path
at the end, and it's in `setup/logs/`.

**Anything `WARN`** → nothing is broken, but read it. The most common warning is that
your Git identity isn't configured yet, which is Stage 3.

The script is safe to run more than once. Anything already installed is detected and
skipped, so if it fails halfway, fix the problem and just run it again.

### Options

| Windows | Linux | What it does |
|---|---|---|
| `-DryRun` | `--dry-run` | Show every action, change nothing |
| `-SkipVsCode` | `--skip-vscode` | Don't install VS Code |
| `-JdkVersion 21` | `--jdk-version 21` | Install a different JDK major version |
| `-NonInteractive` | `--non-interactive` | Never wait for a keypress |

---

## Stage 3 — Set up Git

Two commands you must run once before your first commit, plus the everyday workflow:
see **[GIT-QUICKSTART.md](GIT-QUICKSTART.md)**.

---

## Stage 4 — Write your first program by hand

Before you open the IDE, write a Java file from scratch in a plain editor, compile it
with `javac`, and run it with `java`: **[FIRST-PROGRAM.md](FIRST-PROGRAM.md)**.

It walks through what every word of `public static void main(String[] args)` actually
does, then has you break the program on purpose to learn to read compiler errors.
Twenty minutes, and `main` stops being a magic incantation you retype from memory.

Do this one before letting IntelliJ generate anything for you.

---

## What got installed, and why

| Tool | Why |
|---|---|
| **Eclipse Temurin JDK 25** | The Java compiler and runtime. 25 is the current LTS release, and the minimum the Minecraft modding toolchain needs later in the course. |
| **IntelliJ IDEA** | The IDE you'll write Java in. |
| **Visual Studio Code** | A lighter editor for notes, Markdown and config files. |

### A note on IntelliJ editions

IntelliJ IDEA now ships as a **single unified download**. It runs free with no licence
and everything in this course works in that mode. As a student you can also claim a
**free JetBrains educational licence**, which unlocks the Ultimate features in the same
install — no reinstall needed:

<https://www.jetbrains.com/community/education/#students>

Don't replace it with "IntelliJ IDEA Community Edition". Community is a separate,
discontinued download frozen at version 2025.2, and the Minecraft modding toolchain we
use later in the course needs **2025.3 or newer** for mixins to work. The unified build
this script installs is well past that; Community is not.

### Why the script doesn't install Git

Because you already installed it in Stage 0, and because managing your own tools is
part of the course. The script *checks* that Git is present and warns you about
missing settings, but it never installs or reconfigures it — your Git config is yours.
