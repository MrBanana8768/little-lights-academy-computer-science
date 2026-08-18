# Troubleshooting

Failures the setup scripts actually produce, and what to do about each. Every section
is written so you can hand it straight to a student.

**Always start with the log.** The script prints its path at the end and writes it to
`setup/logs/setup-<timestamp>.log`. It contains every command and every response.

The scripts are **idempotent** — after fixing anything below, just run the script
again. Whatever installed successfully the first time is detected and skipped.

---

## Stage 0 and Stage 1 problems

### `winget` is not recognised

**Symptom:** `winget : The term 'winget' is not recognized...`, or the script stops in
preflight with "winget (the Windows package manager) is not available".

**Cause:** winget ships in the *App Installer* package. It's present on all current
Windows 11 and up-to-date Windows 10, but missing on machines that have never taken
Store updates.

**Fix:** install App Installer from the Store, then reopen the terminal:
<https://apps.microsoft.com/detail/9NBLGGH4NNS1>

If the Store is blocked by policy, the student can install Git from
<https://git-scm.com/download/win> and then install the JDK, IntelliJ and VS Code
manually from the vendor sites — the script's verification phase is still useful
afterwards for confirming the result.

### `git clone` or `git push` asks for a password and rejects it

**Symptom:** repeated credential prompts, or `remote: Support for password
authentication was removed`.

**Cause:** GitHub and GitLab no longer accept account passwords over HTTPS.

**Fix, HTTPS:** generate a **personal access token** (GitHub: Settings → Developer
settings → Personal access tokens → Fine-grained tokens, with `repo`/Contents access)
and paste the token where Git asks for a password. Git Credential Manager, which ships
with Git for Windows, then caches it.

**Fix, SSH:** create a key and add the public half to the account:

```bash
ssh-keygen -t ed25519 -C "you@example.com"
```

Then copy the contents of `~/.ssh/id_ed25519.pub` into the provider's SSH-keys page and
clone using the `git@...` URL rather than the `https://...` one.

**Wrong account cached on Windows:** Credential Manager may be holding an old identity.
Clear it in *Control Panel → Credential Manager → Windows Credentials*, delete the
`git:https://github.com` entry, and try again.

### `.\install-windows.ps1 is not digitally signed`

**Symptom:** `File ... cannot be loaded. The file is not digitally signed.`

**Cause:** the default PowerShell execution policy blocks local scripts.

**Fix:** use the launch line from the README — it relaxes the policy for that one
session only, which is the least invasive option:

```bash
Set-ExecutionPolicy -Scope Process -Bypass -Force; .\install-windows.ps1
```

If policy is locked down by group policy on a managed machine, the student needs to run
the installs by hand or use a personal machine.

---

## Install-phase problems

### Corporate proxy / TLS interception

**Symptom:** preflight fails with "Could not reach the internet", or winget/`curl`
report certificate errors on a school or corporate network.

**Cause:** an inspecting proxy presents its own TLS certificate, which the tools don't
trust.

**Fix:** the reliable answer is to run the setup off the managed network — a home
connection or phone hotspot. Otherwise the network's root CA has to be installed in the
Windows certificate store (and in `/usr/local/share/ca-certificates` plus
`update-ca-certificates` on Linux), which is a job for whoever administers the machine.

Some networks also block `packages.adoptium.net` or `download.jetbrains.com` outright;
the log will show exactly which host failed.

### winget succeeds but the script says the package did not install

**Cause:** the script doesn't trust winget's exit code — it re-queries `winget list`
afterwards. If that disagrees, the install genuinely didn't land, usually because a UAC
prompt was dismissed or an installer was already running.

**Fix:** close any open installers, confirm the UAC prompt this time, run again.

### Linux: `temurin-25-jdk` has no installation candidate

**Symptom:** the script warns that the package isn't available for your codename and
falls back to the tarball.

**Cause:** Adoptium doesn't publish packages for every distro release, and very new or
very old codenames lag.

**Fix:** none needed — the tarball fallback installs to `/opt/java/temurin-25` and
registers it with `update-alternatives`. It's a fully working JDK. The script removes
the broken apt source it added, so later `apt` commands aren't affected.

### Linux: IntelliJ download fails the checksum

**Symptom:** `SHA-256 mismatch -- the download is corrupt or tampered with. Nothing was
installed.`

**Cause:** almost always a truncated download over a flaky connection; occasionally a
proxy rewriting the response body.

**Fix:** run the script again on a stable connection. It refuses to unpack anything
that fails verification, so nothing is left half-installed. Persistent mismatches on
a managed network point at the proxy — see *Corporate proxy* above.

---

## Verification-phase problems

These are the failures that matter most: the tools installed, but the machine still
can't build.

### An older Java is earlier on PATH

**Symptom:** `java reports Java 8, expected 25` (or 11, or 17).

**Cause:** another JDK — Oracle, an old Temurin, one bundled with a game or an Adobe
product — appears earlier in `PATH` than the one we installed.

**Fix, Windows:** the script prepends the new JDK to the **machine** `PATH`, so this
usually means a *user* `PATH` entry is also involved, or a `JAVA_HOME` set by hand
years ago. Open *Settings → System → About → Advanced system settings → Environment
Variables* and remove the stale Java entries from both lists, then run the script
again. Check what you're actually getting with:

```bash
where.exe java
```

**Fix, Linux:**

```bash
sudo update-alternatives --config java
```

Pick the Temurin 25 entry, and repeat for `javac`.

### JAVA_HOME and PATH disagree

**Symptom:** `JAVA_HOME -> ...\jdk-17...` but `PATH -> ...\jdk-25...` (or vice versa).

**Cause:** a leftover `JAVA_HOME` from a previous install. It matters because Gradle,
Maven and IntelliJ prefer `JAVA_HOME` while your terminal follows `PATH` — so the same
project builds differently depending on how you launch it. This is the single most
confusing failure mode in the whole toolchain.

**Fix, Windows:** delete the `JAVA_HOME` entry in Environment Variables (both the User
and System sections), then re-run the script — it sets a correct one.

**Fix, Linux:** something is exporting `JAVA_HOME` before `/etc/profile.d/jdk.sh` runs,
usually a line in `~/.bashrc`, `~/.profile` or `~/.zshrc`. Find it:

```bash
grep -rn JAVA_HOME ~/.bashrc ~/.profile ~/.zshrc /etc/environment 2>/dev/null
```

Remove the stale line, open a new terminal, re-run the script.

### `java` or `javac` is not on PATH right after a successful install

**Cause:** environment changes reach a shell when it starts, not while it's running.

**Fix:** close the terminal and open a new one. The script refreshes its *own* session
so it can verify the install, but it can't reach back into terminals you already had
open. On Linux, log out and back in if a new terminal isn't enough — `/etc/profile.d`
is read at login.

### IntelliJ opens a project but uses the wrong JDK

**Symptom:** everything verifies green, but IntelliJ shows "Project SDK is not defined"
or compiles against a different Java version.

**Cause:** IntelliJ stores the SDK per project and ships its own bundled runtime; it
does not automatically adopt `JAVA_HOME`.

**Fix:** *File → Project Structure → Project → SDK* → pick **temurin-25**, and set
*Language level* to 25. If it isn't listed, *Add SDK → JDK* and point it at
`C:\Program Files\Eclipse Adoptium\jdk-25...` or `/usr/lib/jvm/temurin-25-jdk...` (or
`/opt/java/current` if the tarball fallback was used).

### Linux: `code` is installed but not on PATH

**Cause:** the shell cached its command lookup table before the install.

**Fix:** `hash -r`, or open a new terminal. If it's still missing, check whether a
`snap` copy of VS Code is fighting the repo copy:

```bash
snap list code 2>/dev/null && sudo snap remove code
```

Then re-run the script.

### WSL / headless

**Symptom:** `No graphical desktop detected` warning; IntelliJ won't launch.

**Cause:** no `DISPLAY` or `WAYLAND_DISPLAY` — a server, a container, or WSL without
WSLg.

**Fix:** this is a warning, not a failure; the JDK and the command-line tools work
fine. For a GUI, either update to a WSL2 release with WSLg (`wsl --update` from
Windows), or install IntelliJ on the Windows side with `install-windows.ps1` and keep
using WSL for the terminal.

---

## When none of this helps

Ask the student for:

1. `setup/logs/setup-<timestamp>.log` — the full transcript.
2. The output of `java -version`, `javac -version` and `git --version`.
3. Windows: `where.exe java` and `echo $env:JAVA_HOME`.
   Linux: `which -a java` and `echo $JAVA_HOME`.

That's almost always enough to diagnose it without touching the machine.
