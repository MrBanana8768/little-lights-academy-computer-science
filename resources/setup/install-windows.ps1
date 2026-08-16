#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Java toolchain for the Software Development course on Windows:
    Eclipse Temurin JDK 25 (LTS), IntelliJ IDEA, and Visual Studio Code.

.DESCRIPTION
    Git is deliberately NOT installed or configured by this script. Git is the
    bootstrap prerequisite -- you already used it to clone this repo (see README.md,
    Stage 0). The script only checks that Git is present and tells you if some
    recommended settings are missing; you run those commands yourself. That is part
    of the course.

    The script is idempotent: run it as many times as you like. Anything already
    installed is detected and skipped.

    Everything it does is written to setup\logs\setup-<timestamp>.log. If something
    goes wrong, send that file to your instructor.

.PARAMETER SkipVsCode
    Do not install Visual Studio Code.

.PARAMETER JdkVersion
    Major JDK version to install. Defaults to 25, the current LTS.

.PARAMETER DryRun
    Print every action that would be taken, and change nothing.

.PARAMETER NonInteractive
    Never wait for a keypress. Use this when running the script unattended.

.PARAMETER Relaunched
    Internal. Set automatically when the script re-launches itself elevated.

.EXAMPLE
    .\install-windows.ps1

.EXAMPLE
    .\install-windows.ps1 -DryRun

.EXAMPLE
    .\install-windows.ps1 -SkipVsCode
#>
[CmdletBinding()]
param(
    [switch] $SkipVsCode,
    [int]    $JdkVersion = 25,
    [switch] $DryRun,
    [switch] $NonInteractive,
    [switch] $Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$JdkPackageId     = "EclipseAdoptium.Temurin.$JdkVersion.JDK"
$IdeaPackageId    = 'JetBrains.IntelliJIDEA'      # unified distribution; NOT .Community
$VsCodePackageId  = 'Microsoft.VisualStudioCode'
$AdoptiumInfoUrl  = 'https://api.adoptium.net/v3/info/available_releases'
$RequiredFreeGb   = 10

# ---------------------------------------------------------------------------
# Output helpers
#
# ASCII status markers rather than emoji: they render correctly in every Windows
# console, including the older conhost that some lab machines still default to.
# ---------------------------------------------------------------------------

$script:Results = New-Object System.Collections.ArrayList

function Write-Phase {
    param([string] $Text)
    Write-Host ''
    Write-Host "=== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(0, 74 - $Text.Length)) -ForegroundColor Cyan
}

function Write-Step { param([string] $Text) Write-Host "  ...  $Text" -ForegroundColor Gray }
function Write-Ok   { param([string] $Text) Write-Host "  OK   $Text" -ForegroundColor Green }
function Write-Skip { param([string] $Text) Write-Host "  --   $Text" -ForegroundColor DarkGray }
function Write-Warn { param([string] $Text) Write-Host "  WARN $Text" -ForegroundColor Yellow }
function Write-Fail { param([string] $Text) Write-Host "  FAIL $Text" -ForegroundColor Red }

function Add-Result {
    param(
        [string] $Component,
        [ValidateSet('OK', 'SKIPPED', 'WARN', 'FAIL')] [string] $Status,
        [string] $Detail
    )
    $null = $script:Results.Add([pscustomobject]@{
        Component = $Component
        Status    = $Status
        Detail    = $Detail
    })
}

# Stops the script with a message a first-year student can act on, rather than a
# PowerShell stack trace.
function Stop-WithGuidance {
    param([string] $Problem, [string[]] $HowToFix)
    Write-Host ''
    Write-Host '  Setup cannot continue.' -ForegroundColor Red
    Write-Host ''
    Write-Host "  Problem: $Problem" -ForegroundColor Red
    Write-Host ''
    Write-Host '  How to fix it:' -ForegroundColor Yellow
    foreach ($line in $HowToFix) { Write-Host "    $line" -ForegroundColor Yellow }
    Write-Host ''
    Complete-Run -ExitCode 1
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-reads Machine + User environment from the registry into this process, so the
# verification phase sees the JDK we just installed without needing a new terminal.
function Update-SessionEnvironment {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'

    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if (-not $javaHome) { $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User') }
    if ($javaHome) { $env:JAVA_HOME = $javaHome }
}

function Get-CommandPath {
    param([string] $Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

# Runs an external program and captures its combined output.
#
# This wrapper exists for one reason: with $ErrorActionPreference = 'Stop', a native
# program that writes to stderr under a 2>&1 redirect raises a terminating
# NativeCommandError. `java -version` writes to stderr on every JDK, so without this
# the very first verification check would blow up the script.
function Invoke-NativeCapture {
    param([string] $File, [string[]] $Arguments = @())

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $File @Arguments 2>&1 | Out-String
        return [pscustomobject]@{
            Output   = $output.Trim()
            ExitCode = $LASTEXITCODE
        }
    }
    catch {
        return [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = -1 }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

# Turns "25.0.4", "1.8.0_402" or "21" into the major version number (25, 8, 21).
function ConvertTo-JavaMajor {
    param([string] $VersionText)
    if ($VersionText -notmatch '(\d+)(?:\.(\d+))?') { return $null }

    $first  = [int] $Matches[1]
    $second = $null
    if ($Matches.ContainsKey(2) -and $Matches[2]) { $second = [int] $Matches[2] }

    if ($first -eq 1 -and $null -ne $second) { return $second }   # legacy 1.8.0 style
    return $first
}

# ---------------------------------------------------------------------------
# winget helpers
#
# We never rely on winget's exit codes to decide whether something is installed --
# they vary between winget versions and "already installed" is reported differently
# across releases. Instead we ask winget what is installed, before and after.
# ---------------------------------------------------------------------------

function Test-WingetPackage {
    param([string] $Id)
    $result = Invoke-NativeCapture -File 'winget' -Arguments @(
        'list', '--exact', '--id', $Id, '--source', 'winget', '--accept-source-agreements'
    )
    return ($result.ExitCode -eq 0)
}

function Install-WingetPackage {
    param(
        [string]   $Id,
        [string]   $FriendlyName,
        [string[]] $ExtraArgs = @()
    )

    if (Test-WingetPackage -Id $Id) {
        Write-Skip "$FriendlyName is already installed."
        Add-Result -Component $FriendlyName -Status 'SKIPPED' -Detail 'Already installed'
        return $true
    }

    if ($DryRun) {
        Write-Step "[dry run] winget install --exact --id $Id $($ExtraArgs -join ' ')"
        Add-Result -Component $FriendlyName -Status 'SKIPPED' -Detail 'Dry run'
        return $true
    }

    Write-Step "Installing $FriendlyName ($Id). This can take several minutes."
    $wingetArgs = @(
        'install', '--exact', '--id', $Id,
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements'
    ) + $ExtraArgs

    # Stream winget's own progress through so the student can see it is working,
    # but keep stderr from becoming a terminating error (see Invoke-NativeCapture).
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & winget @wingetArgs 2>&1 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    # The only answer that matters is whether it is installed now.
    if (Test-WingetPackage -Id $Id) {
        Write-Ok "$FriendlyName installed."
        Add-Result -Component $FriendlyName -Status 'OK' -Detail 'Installed'
        return $true
    }

    Write-Fail "$FriendlyName did not install (winget exit code $code)."
    Add-Result -Component $FriendlyName -Status 'FAIL' -Detail "winget exit code $code"
    return $false
}

# ---------------------------------------------------------------------------
# Phase 1 -- Preflight
# ---------------------------------------------------------------------------

function Invoke-Preflight {
    Write-Phase 'Phase 1/7  Preflight checks'

    # --- Operating system -------------------------------------------------
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Stop-WithGuidance -Problem 'This script only runs on Windows.' -HowToFix @(
            'On Linux, run install-linux.sh instead.'
        )
    }
    Write-Ok "Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion)"

    # --- Architecture -----------------------------------------------------
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -notin @('AMD64', 'ARM64')) {
        Stop-WithGuidance -Problem "Unsupported processor architecture: $arch." -HowToFix @(
            'This course needs a 64-bit machine. Contact your instructor.'
        )
    }
    Write-Ok "Architecture: $arch"

    # --- Elevation --------------------------------------------------------
    # The Temurin MSI and the IntelliJ installer both write to Program Files.
    if (-not (Test-Administrator)) {
        if ($DryRun) {
            Write-Warn 'Not running as Administrator (allowed for -DryRun).'
        }
        elseif ($Relaunched) {
            Stop-WithGuidance -Problem 'Could not obtain Administrator rights.' -HowToFix @(
                'Right-click the Start button, choose "Terminal (Admin)",',
                "then run:  cd '$PSScriptRoot'  and try again."
            )
        }
        else {
            Write-Warn 'Administrator rights are required. Re-launching with a UAC prompt...'
            $relaunchArgs = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', "`"$PSCommandPath`"",
                '-Relaunched'
            )
            if ($SkipVsCode)     { $relaunchArgs += '-SkipVsCode' }
            if ($DryRun)         { $relaunchArgs += '-DryRun' }
            if ($NonInteractive) { $relaunchArgs += '-NonInteractive' }
            $relaunchArgs += @('-JdkVersion', $JdkVersion)

            $exe = (Get-Process -Id $PID).Path
            Start-Process -FilePath $exe -ArgumentList $relaunchArgs -Verb RunAs | Out-Null
            exit 0
        }
    }
    else {
        Write-Ok 'Running as Administrator.'
    }

    # --- Disk space -------------------------------------------------------
    $systemDrive = ($env:SystemDrive).TrimEnd(':')
    $free = (Get-PSDrive -Name $systemDrive).Free
    $freeGb = [Math]::Round($free / 1GB, 1)
    if ($freeGb -lt $RequiredFreeGb) {
        Stop-WithGuidance -Problem "Only $freeGb GB free on $($env:SystemDrive) (need $RequiredFreeGb GB)." -HowToFix @(
            'Free up disk space and run this script again.',
            'Emptying the Recycle Bin and running Disk Cleanup is a good start.'
        )
    }
    Write-Ok "Disk space: $freeGb GB free on $env:SystemDrive"

    # --- winget -----------------------------------------------------------
    if (-not (Get-CommandPath 'winget')) {
        Stop-WithGuidance -Problem 'winget (the Windows package manager) is not available.' -HowToFix @(
            'Install "App Installer" from the Microsoft Store, then run this script again:',
            '  https://apps.microsoft.com/detail/9NBLGGH4NNS1',
            'After installing it, close and reopen your terminal.'
        )
    }
    Write-Ok "winget found: $(Get-CommandPath 'winget')"

    Test-GitPrerequisite
    Test-Connectivity
}

# ---------------------------------------------------------------------------
# The Git gate.
#
# This script never installs and never reconfigures Git. Git is Stage 0 in the
# README, and cloning this repo is Stage 1 -- so if you are reading this from a
# clone, Git is already here. We check, we warn, we do not fix.
# ---------------------------------------------------------------------------

function Test-GitPrerequisite {
    $gitPath = Get-CommandPath 'git'
    if (-not $gitPath) {
        Stop-WithGuidance -Problem 'Git is not installed, or is not on your PATH.' -HowToFix @(
            'Git is a prerequisite for this course -- this script does not install it.',
            '',
            'Install it with:',
            '  winget install --exact --id Git.Git --accept-package-agreements --accept-source-agreements',
            '',
            'Or download the installer (this is the one that includes Git Bash):',
            '  https://git-scm.com/download/win',
            '',
            'Then close and reopen your terminal and run this script again.'
        )
    }

    $gitVersion = (Invoke-NativeCapture -File 'git' -Arguments @('--version')).Output
    Write-Ok "$gitVersion  ($gitPath)"
    Add-Result -Component 'Git (prerequisite)' -Status 'OK' -Detail $gitVersion

    # Recommended settings. We report them; you set them. See GIT-QUICKSTART.md.
    # `git config --get` exits non-zero when the key is unset, which is how we detect it.
    $missing = @()
    foreach ($setting in @('user.name', 'user.email', 'core.autocrlf')) {
        $probe = Invoke-NativeCapture -File 'git' -Arguments @('config', '--global', '--get', $setting)
        if ($probe.ExitCode -ne 0 -or -not $probe.Output) { $missing += $setting }
    }

    if ($missing.Count -gt 0) {
        Write-Warn "Git is installed but these global settings are unset: $($missing -join ', ')"
        if ($missing -contains 'user.name' -or $missing -contains 'user.email') {
            Write-Warn 'Until user.name and user.email are set, Git will refuse to commit.'
        }
        if ($missing -contains 'core.autocrlf') {
            Write-Warn 'Without core.autocrlf, Windows line endings show up as whole-file changes.'
        }
        Write-Warn 'Set them yourself -- the exact commands are in GIT-QUICKSTART.md.'
        Add-Result -Component 'Git config' -Status 'WARN' -Detail "Unset: $($missing -join ', ') -- see GIT-QUICKSTART.md"
    }
    else {
        $who = (Invoke-NativeCapture -File 'git' -Arguments @('config', '--global', '--get', 'user.name')).Output
        Write-Ok "Git identity configured ($who)."
        Add-Result -Component 'Git config' -Status 'OK' -Detail "Identity: $who"
    }
}

function Test-Connectivity {
    Write-Step 'Checking internet connectivity...'
    try {
        $info = Invoke-RestMethod -Uri $AdoptiumInfoUrl -TimeoutSec 20
        Write-Ok 'Internet connection OK.'
        if ($info.most_recent_lts -ne $JdkVersion) {
            Write-Warn "You are installing JDK $JdkVersion; the current LTS is $($info.most_recent_lts)."
            Write-Warn 'That is fine if your course asked for it. Otherwise re-run without -JdkVersion.'
        }
    }
    catch {
        Stop-WithGuidance -Problem "Could not reach the internet ($($_.Exception.Message))." -HowToFix @(
            'Check your network connection and try again.',
            'On a school or corporate network, a proxy may be blocking the download.',
            'See TROUBLESHOOTING.md, section "Corporate proxy / TLS interception".'
        )
    }
}

# ---------------------------------------------------------------------------
# Phase 3 -- Install
# ---------------------------------------------------------------------------

function Install-Components {
    Write-Phase 'Phase 3/7  Installing components'

    $null = Install-WingetPackage -Id $JdkPackageId  -FriendlyName "Eclipse Temurin JDK $JdkVersion"
    $null = Install-WingetPackage -Id $IdeaPackageId -FriendlyName 'IntelliJ IDEA'

    if ($SkipVsCode) {
        Write-Skip 'Visual Studio Code skipped (-SkipVsCode).'
        Add-Result -Component 'Visual Studio Code' -Status 'SKIPPED' -Detail 'Skipped by -SkipVsCode'
    }
    else {
        # Machine scope on purpose. This script self-elevates, so a user-scope
        # install would land in the *administrator's* profile on managed machines
        # where the admin account differs from the student's account.
        $null = Install-WingetPackage -Id $VsCodePackageId -FriendlyName 'Visual Studio Code' `
                                      -ExtraArgs @('--scope', 'machine')
    }
}

# ---------------------------------------------------------------------------
# Phase 4 -- Configure
# ---------------------------------------------------------------------------

function Find-TemurinHome {
    param([int] $Major)

    $roots = @(
        (Join-Path $env:ProgramFiles 'Eclipse Adoptium')
    )
    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} 'Eclipse Adoptium')
    }

    $candidates = foreach ($root in $roots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Directory -Filter "jdk-$Major*" -ErrorAction SilentlyContinue
        }
    }

    # A JDK, not a JRE: it must be able to compile.
    $jdks = $candidates | Where-Object { Test-Path (Join-Path $_.FullName 'bin\javac.exe') }
    $best = $jdks | Sort-Object -Property Name -Descending | Select-Object -First 1
    if ($best) { return $best.FullName }
    return $null
}

function Set-JavaEnvironment {
    Write-Phase 'Phase 4/7  Configuring the environment'

    $javaHome = Find-TemurinHome -Major $JdkVersion
    if (-not $javaHome) {
        if ($DryRun) {
            Write-Step "[dry run] Would set JAVA_HOME to the Temurin $JdkVersion install directory."
            return
        }
        Write-Fail "Could not find a Temurin $JdkVersion JDK under Program Files."
        Add-Result -Component 'JAVA_HOME' -Status 'FAIL' -Detail 'Temurin install directory not found'
        return
    }
    Write-Ok "Found JDK: $javaHome"

    if ($DryRun) {
        Write-Step "[dry run] Would set JAVA_HOME=$javaHome (Machine scope)."
        Write-Step "[dry run] Would ensure $javaHome\bin is on the machine PATH."
        return
    }

    # --- JAVA_HOME --------------------------------------------------------
    # Machine scope, because we are elevated and because IntelliJ, Gradle and any
    # future tool should all see the same value regardless of which account runs them.
    $current = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if ($current -eq $javaHome) {
        Write-Skip "JAVA_HOME already set to $javaHome"
    }
    else {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'Machine')
        Write-Ok "JAVA_HOME set to $javaHome"
    }
    Add-Result -Component 'JAVA_HOME' -Status 'OK' -Detail $javaHome

    # --- PATH -------------------------------------------------------------
    # Rewrite rather than append: drop any stale Adoptium bin directories from a
    # previous install, then put the current one first. This makes repeated runs
    # self-healing instead of cumulative.
    $javaBin     = Join-Path $javaHome 'bin'
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $entries     = $machinePath -split ';' | Where-Object { $_ -and $_.Trim() }

    $kept = $entries | Where-Object {
        $_ -notmatch 'Eclipse\s+Adoptium' -and $_.TrimEnd('\') -ne $javaBin.TrimEnd('\')
    }
    $newPath = (@($javaBin) + $kept) -join ';'

    if ($newPath -ne $machinePath) {
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
        Write-Ok "Added $javaBin to the front of the machine PATH."
    }
    else {
        Write-Skip 'Machine PATH already correct.'
    }

    Update-SessionEnvironment
    Write-Ok 'Refreshed this session so the checks below see the new JDK.'
}

# ---------------------------------------------------------------------------
# Phase 5 -- Verify
#
# Printing version numbers is not verification. A machine with an old Java 8
# earlier on PATH passes a naive `java -version` check and still cannot build
# anything. Every check below asserts something.
# ---------------------------------------------------------------------------

function Test-JavaVersion {
    param([string] $Exe, [string] $Label)

    $path = Get-CommandPath $Exe
    if (-not $path) {
        Write-Fail "$Label is not on your PATH."
        Add-Result -Component $Label -Status 'FAIL' -Detail 'Not found on PATH'
        return $false
    }

    $output = (Invoke-NativeCapture -File $Exe -Arguments @('-version')).Output
    $major  = ConvertTo-JavaMajor -VersionText $output

    if ($major -ne $JdkVersion) {
        Write-Fail "$Label reports Java $major, expected $JdkVersion."
        Write-Fail "  Resolved to: $path"
        Write-Fail '  Another Java is earlier on your PATH. See TROUBLESHOOTING.md,'
        Write-Fail '  section "An older Java is earlier on PATH".'
        Add-Result -Component $Label -Status 'FAIL' -Detail "Found Java $major at $path, expected $JdkVersion"
        return $false
    }

    $firstLine = ($output -split "`r?`n")[0]
    Write-Ok "$Label -> $firstLine"
    Add-Result -Component $Label -Status 'OK' -Detail $firstLine
    return $true
}

function Test-JavaHomeConsistency {
    if (-not $env:JAVA_HOME) {
        Write-Fail 'JAVA_HOME is not set.'
        Add-Result -Component 'JAVA_HOME consistency' -Status 'FAIL' -Detail 'JAVA_HOME not set'
        return $false
    }

    $expected = Join-Path $env:JAVA_HOME 'bin\java.exe'
    if (-not (Test-Path $expected)) {
        Write-Fail "JAVA_HOME points at $env:JAVA_HOME, but there is no java.exe in its bin folder."
        Add-Result -Component 'JAVA_HOME consistency' -Status 'FAIL' -Detail "Stale JAVA_HOME: $env:JAVA_HOME"
        return $false
    }

    $onPath = Get-CommandPath 'java'
    $a = (Resolve-Path $expected).Path
    $b = if ($onPath) { (Resolve-Path $onPath).Path } else { '' }

    if ($a -ne $b) {
        Write-Fail 'JAVA_HOME and PATH disagree about which Java to use:'
        Write-Fail "  JAVA_HOME -> $a"
        Write-Fail "  PATH      -> $b"
        Add-Result -Component 'JAVA_HOME consistency' -Status 'FAIL' -Detail "JAVA_HOME=$a but PATH=$b"
        return $false
    }

    Write-Ok "JAVA_HOME and PATH agree: $a"
    Add-Result -Component 'JAVA_HOME consistency' -Status 'OK' -Detail $a
    return $true
}

# The check that actually matters: can this machine compile and run a Java program?
function Test-CompileAndRun {
    $work = Join-Path ([IO.Path]::GetTempPath()) ("javacheck-" + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $source = Join-Path $work 'Hello.java'
        $expected = 'course-setup-ok'

        @"
public class Hello {
    public static void main(String[] args) {
        System.out.println("$expected");
    }
}
"@ | Set-Content -Path $source -Encoding UTF8

        $compile = Invoke-NativeCapture -File 'javac' -Arguments @('-d', $work, $source)
        if ($compile.ExitCode -ne 0) {
            Write-Fail 'javac could not compile a hello-world program.'
            if ($compile.Output) { Write-Fail "  $($compile.Output)" }
            Add-Result -Component 'Compile and run' -Status 'FAIL' -Detail 'javac failed'
            return $false
        }

        $run = Invoke-NativeCapture -File 'java' -Arguments @('-cp', $work, 'Hello')
        if ($run.Output -ne $expected) {
            Write-Fail "The compiled program printed '$($run.Output)' instead of '$expected'."
            Add-Result -Component 'Compile and run' -Status 'FAIL' -Detail "Unexpected output: $($run.Output)"
            return $false
        }

        Write-Ok 'Compiled and ran a Java program successfully.'
        Add-Result -Component 'Compile and run' -Status 'OK' -Detail 'javac + java round trip'
        return $true
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-IntelliJ {
    $roots = @((Join-Path $env:ProgramFiles 'JetBrains'))
    if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'JetBrains') }

    $launcher = $null
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $launcher = Get-ChildItem -Path $root -Recurse -Depth 2 -Filter 'idea64.exe' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
        if (-not $launcher) {
            $launcher = Get-ChildItem -Path $root -Recurse -Depth 2 -Filter 'idea.exe' -ErrorAction SilentlyContinue |
                        Select-Object -First 1
        }
        if ($launcher) { break }
    }

    if (-not $launcher) {
        Write-Fail 'Could not find the IntelliJ IDEA launcher under Program Files\JetBrains.'
        Add-Result -Component 'IntelliJ IDEA' -Status 'FAIL' -Detail 'Launcher not found on disk'
        return $false
    }

    Write-Ok "IntelliJ IDEA launcher: $($launcher.FullName)"
    Add-Result -Component 'IntelliJ IDEA' -Status 'OK' -Detail $launcher.FullName
    return $true
}

function Test-VsCode {
    if ($SkipVsCode) { return $true }

    $path = Get-CommandPath 'code'
    if (-not $path) { $path = Get-CommandPath 'code.cmd' }
    if (-not $path) {
        Write-Warn 'VS Code is installed but "code" is not on your PATH yet.'
        Write-Warn 'Close and reopen your terminal; if it is still missing, see TROUBLESHOOTING.md.'
        Add-Result -Component 'VS Code CLI' -Status 'WARN' -Detail 'code not on PATH in this session'
        return $true
    }

    $version = ((Invoke-NativeCapture -File $path -Arguments @('--version')).Output -split "`r?`n")[0]
    Write-Ok "VS Code -> $version"
    Add-Result -Component 'VS Code CLI' -Status 'OK' -Detail $version
    return $true
}

function Invoke-Verification {
    Write-Phase 'Phase 5/7  Verifying the installation'

    if ($DryRun) {
        Write-Step '[dry run] Would check java, javac, JAVA_HOME/PATH agreement,'
        Write-Step '[dry run] compile and run a Hello.java, and locate IntelliJ and VS Code.'
        return
    }

    $null = Test-JavaVersion -Exe 'java'  -Label 'java'
    $null = Test-JavaVersion -Exe 'javac' -Label 'javac'
    $null = Test-JavaHomeConsistency
    $null = Test-CompileAndRun
    $null = Test-IntelliJ
    $null = Test-VsCode
}

# ---------------------------------------------------------------------------
# Phases 6 and 7 -- Summary and exit
# ---------------------------------------------------------------------------

function Write-Summary {
    Write-Phase 'Phase 6/7  Summary'

    $script:Results |
        Format-Table -AutoSize -Property @(
            @{ Label = 'Component'; Expression = { $_.Component }; Width = 26 },
            @{ Label = 'Status';    Expression = { $_.Status };    Width = 8  },
            @{ Label = 'Detail';    Expression = { $_.Detail } }
        ) | Out-String | Write-Host

    $failures = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
    $warnings = @($script:Results | Where-Object { $_.Status -eq 'WARN' })

    if ($DryRun) {
        Write-Host '  Dry run finished. Nothing was installed or changed.' -ForegroundColor Magenta
        Write-Host '  Re-run without -DryRun to install for real.' -ForegroundColor Magenta
        return 0
    }

    if ($failures.Count -eq 0) {
        Write-Host '  Everything checks out. You are ready to start the course.' -ForegroundColor Green
        Write-Host ''
        Write-Host '  Next steps:' -ForegroundColor Cyan
        Write-Host '    1. Close this terminal and open a new one, so PATH and JAVA_HOME are picked up.'
        Write-Host '    2. If Git warned you above, run the commands in GIT-QUICKSTART.md.'
        Write-Host '    3. Clone your first assignment repo and open it in IntelliJ IDEA.'
        if ($warnings.Count -gt 0) {
            Write-Host ''
            Write-Host "  $($warnings.Count) warning(s) above. Nothing is broken, but read them." -ForegroundColor Yellow
        }
        return 0
    }

    Write-Host "  $($failures.Count) check(s) failed:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "    - $($f.Component): $($f.Detail)" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  What to do:' -ForegroundColor Yellow
    Write-Host '    1. Look up the failing item in TROUBLESHOOTING.md.'
    Write-Host '    2. If that does not help, send your instructor the log file:'
    Write-Host "         $script:LogPath" -ForegroundColor Yellow
    return 1
}

function Complete-Run {
    param([int] $ExitCode)

    Write-Phase 'Phase 7/7  Done'
    Write-Host "  Full log: $script:LogPath"
    Write-Host ''

    try { Stop-Transcript | Out-Null } catch { }

    if (-not $NonInteractive -and $Relaunched) {
        # The elevated window is a new one; without this it vanishes before the
        # student can read anything.
        Read-Host '  Press Enter to close this window'
    }
    exit $ExitCode
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  Software Development course -- Windows setup' -ForegroundColor White
Write-Host '  Installs: Eclipse Temurin JDK, IntelliJ IDEA, Visual Studio Code' -ForegroundColor DarkGray
Write-Host '  Does not install Git -- that is Stage 0, and you already did it.' -ForegroundColor DarkGray
if ($DryRun) { Write-Host '  DRY RUN: nothing will be changed.' -ForegroundColor Magenta }

# Phase 2 -- start logging as early as we can.
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogPath = Join-Path $logDir ("setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
    Start-Transcript -Path $script:LogPath -Force | Out-Null
    Write-Host "  Logging to: $script:LogPath" -ForegroundColor DarkGray
}
catch {
    Write-Host "  (Could not start a transcript: $($_.Exception.Message))" -ForegroundColor DarkGray
}

try {
    Invoke-Preflight
    Install-Components
    Set-JavaEnvironment
    Invoke-Verification
    $exitCode = Write-Summary
    Complete-Run -ExitCode $exitCode
}
catch {
    Write-Host ''
    Write-Fail "Unexpected error: $($_.Exception.Message)"
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Please send the log file to your instructor:' -ForegroundColor Yellow
    Write-Host "    $script:LogPath" -ForegroundColor Yellow
    Complete-Run -ExitCode 1
}
