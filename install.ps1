#Requires -Version 5.1
<#
.SYNOPSIS
    Install the keepassxc-secrets skill for coding agents on Windows.
.EXAMPLE
    .\install.ps1                     # every detected harness (user scope)
    .\install.ps1 -Project .          # project scope + AGENTS.md pointer
    .\install.ps1 -AllUser -Copy      # all known harnesses, copies instead of links
#>
param(
    [string[]]$User,
    [switch]$AllUser,
    [string]$SkillsDir,
    [string]$Project,
    [switch]$Copy,
    [switch]$List
)

$ErrorActionPreference = "Stop"
$Skill = "keepassxc-secrets"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src = Join-Path $Root "skills\$Skill"
$Snippet = Join-Path $Root "agents-snippet.md"
$Begin = "<!-- ${Skill}:begin -->"
$End = "<!-- ${Skill}:end -->"

$UserDirs = [ordered]@{
    claude = Join-Path $HOME ".claude\skills"
    codex  = Join-Path $HOME ".codex\skills"
    gemini = Join-Path $HOME ".gemini\skills"
}

function Test-Harness($name) {
    $dir = Join-Path $HOME ".$name"
    return (Test-Path $dir) -or (Get-Command $name -ErrorAction SilentlyContinue)
}

function Install-Into($dir) {
    $dest = Join-Path $dir $Skill
    if (Test-Path $dest) { Write-Host "  = $dest (exists, skipped)"; return }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($Copy) {
        Copy-Item -Recurse $Src $dest
        Write-Host "  + $dest (copy)"
    } else {
        # symlinks need Developer Mode or an elevated shell; fall back to a copy
        try {
            New-Item -ItemType SymbolicLink -Path $dest -Target $Src | Out-Null
            Write-Host "  + $dest (link)"
        } catch {
            Copy-Item -Recurse $Src $dest
            Write-Host "  + $dest (copy — symlink needs Developer Mode)"
        }
    }
}

function Write-AgentsBlock($file) {
    $body = "$Begin`n## Secrets`n`n" + (Get-Content $Snippet -Raw) + "$End`n"
    if (Test-Path $file) {
        $lines = Get-Content $file
        $kept = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($line in $lines) {
            if ($line -eq $Begin) { $skip = $true }
            elseif ($line -eq $End) { $skip = $false }
            elseif (-not $skip) { $kept.Add($line) }
        }
        while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
            $kept.RemoveAt($kept.Count - 1)
        }
        $body = ($kept -join "`n") + "`n`n" + $body
    }
    Set-Content -Path $file -Value $body -NoNewline
    Write-Host "  + $file (pointer block)"
}

function Test-Deps {
    $missing = @()
    if (-not (Get-Command keepassxc-cli -ErrorAction SilentlyContinue)) {
        $paths = @("$env:ProgramFiles\KeePassXC\keepassxc-cli.exe",
                   "${env:ProgramFiles(x86)}\KeePassXC\keepassxc-cli.exe")
        if (-not ($paths | Where-Object { Test-Path $_ })) { $missing += "keepassxc-cli" }
    }
    if ($missing) {
        Write-Error "missing dependencies: $($missing -join ', ')`nsee skills\$Skill\references\setup.md"
        exit 1
    }
}

if ($List) {
    Write-Host "skill source: $Src`n`nuser scope:"
    foreach ($h in $UserDirs.Keys) {
        $state = if (Test-Harness $h) { "detected" } else { "not detected" }
        "  {0,-8} {1,-40} {2}" -f $h, $UserDirs[$h], $state | Write-Host
    }
    Write-Host "`nproject scope (-Project DIR):"
    Write-Host "  cursor   DIR\.cursor\skills"
    Write-Host "  shared   DIR\.agents\skills"
    Write-Host "  pointer  DIR\AGENTS.md"
    exit 0
}

Test-Deps

$targets = @()
if ($User) { $targets = $User }
elseif ($AllUser) { $targets = $UserDirs.Keys }
elseif (-not $Project -and -not $SkillsDir) {
    $targets = $UserDirs.Keys | Where-Object { Test-Harness $_ }
    if (-not $targets) { Write-Error "no harness detected; use -AllUser, -Project or -SkillsDir"; exit 1 }
}

if ($targets) {
    Write-Host "user scope:"
    foreach ($h in $targets) {
        if ($UserDirs.Contains($h)) { Install-Into $UserDirs[$h] }
        else { Write-Warning "unknown harness: $h" }
    }
}

if ($SkillsDir) { Write-Host "custom:"; Install-Into $SkillsDir }

if ($Project) {
    Write-Host "project scope ($Project):"
    Install-Into (Join-Path $Project ".cursor\skills")
    Install-Into (Join-Path $Project ".agents\skills")
    Write-AgentsBlock (Join-Path $Project "AGENTS.md")
}

Write-Host "`nNext:`n  powershell -File $Src\scripts\kpsec.ps1 init`n  powershell -File $Src\scripts\kpsec.ps1 status"
