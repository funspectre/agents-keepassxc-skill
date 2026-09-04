#Requires -Version 5.1
<#
.SYNOPSIS
    kpsec — use secrets from a local KeePassXC database without printing them (Windows).
.DESCRIPTION
    The master password lives in Windows Credential Manager; secrets are resolved
    in-process and handed to the child through its environment, never through argv.
    Linux and macOS use the bash version in the same directory.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"
# Piping a string to a native command encodes it with $OutputEncoding, which is
# ASCII by default in 5.1 — a non-ASCII password would reach keepassxc-cli
# mangled.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$Db = if ($env:KPSEC_DB) { $env:KPSEC_DB } else { Join-Path $HOME ".pass\agents.kdbx" }
$Target = "kpsec master key:$Db"
$SaltFile = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "kpsec\fingerprint-salt" }
            else { Join-Path $HOME ".kpsec\fingerprint-salt" }

# Write-Error is a terminating error under ErrorActionPreference=Stop, so the
# `exit $code` after it never ran and every documented exit code was lost.
function Die($msg, $code = 1) {
    [Console]::Error.WriteLine("kpsec: $msg")
    exit $code
}

function Get-KeepassxcCli {
    if ($env:KPSEC_KEEPASSXC_CLI) { return $env:KPSEC_KEEPASSXC_CLI }
    $cmd = Get-Command keepassxc-cli -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\KeePassXC\keepassxc-cli.exe",
                     "${env:ProgramFiles(x86)}\KeePassXC\keepassxc-cli.exe")) {
        if (Test-Path $p) { return $p }
    }
    return "keepassxc-cli"
}

# Credential Manager through the native API: no extra modules, no file on disk.
$CredApi = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class KpsecCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public uint Flags; public uint Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
        public uint AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL cred, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static string Read(string target) {
        IntPtr ptr;
        if (!CredReadW(target, 1, 0, out ptr)) return null;
        try {
            CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            return Encoding.Unicode.GetString(
                ReadBlob(cred.CredentialBlob, (int)cred.CredentialBlobSize));
        } finally { CredFree(ptr); }
    }

    private static byte[] ReadBlob(IntPtr p, int size) {
        byte[] buf = new byte[size];
        Marshal.Copy(p, buf, 0, size);
        return buf;
    }

    public static void Write(string target, string secret) {
        byte[] blob = Encoding.Unicode.GetBytes(secret);
        CREDENTIAL cred = new CREDENTIAL();
        cred.Type = 1;                 // CRED_TYPE_GENERIC
        cred.TargetName = target;
        cred.UserName = "kpsec";
        cred.Persist = 2;              // CRED_PERSIST_LOCAL_MACHINE
        cred.CredentialBlobSize = (uint)blob.Length;
        cred.CredentialBlob = Marshal.AllocHGlobal(blob.Length);
        try {
            Marshal.Copy(blob, 0, cred.CredentialBlob, blob.Length);
            if (!CredWriteW(ref cred, 0))
                throw new Exception("CredWrite failed: " + Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(cred.CredentialBlob); }
    }

    public static bool Delete(string target) { return CredDeleteW(target, 1, 0); }
}
'@
if (-not ("KpsecCred" -as [type])) { Add-Type -TypeDefinition $CredApi }

function Get-MasterFromKeyring { try { [KpsecCred]::Read($Target) } catch { $null } }
function Set-MasterInKeyring($secret) { [KpsecCred]::Write($Target, $secret) }
function Remove-MasterFromKeyring { try { [KpsecCred]::Delete($Target) } catch { $false } }

function Read-MasterPassword {
    $master = Get-MasterFromKeyring
    if ($master) { return $master }
    # No Credential Manager entry and no dialog — CI, a container — has no other
    # way in, and the password must not come in on the command line.
    if ($env:KPSEC_MASTER_COMMAND) {
        $out = & cmd.exe /c $env:KPSEC_MASTER_COMMAND
        if ($out) { return ([string[]]$out)[0].TrimEnd("`r", "`n") }
        return $null
    }
    if ($env:KPSEC_NO_GUI) { return $null }
    $cred = Get-Credential -UserName kpsec -Message "Master password for $(Split-Path -Leaf $Db)"
    if (-not $cred) { return $null }
    return $cred.GetNetworkCredential().Password
}

# The master password goes in on stdin, never in argv.
function Invoke-Kp {
    param([string[]]$KpArgs, [string]$ExtraStdin = "", [switch]$Quiet)
    $master = Read-MasterPassword
    if (-not $master) { Die "cannot obtain the database master password" 4 }
    $stdin = "$master`n$ExtraStdin"
    if ($Quiet) { $stdin | & (Get-KeepassxcCli) @KpArgs 2>$null }
    else { $stdin | & (Get-KeepassxcCli) @KpArgs }
}

function Split-Ref($ref) {
    if ($ref -notmatch '^kp://') { Die "malformed reference: $ref (expected kp://group/entry#Attribute)" 2 }
    $body = $ref.Substring(5)
    $parts = $body -split '#', 2
    return @{ Path = $parts[0]; Attr = if ($parts.Count -gt 1) { $parts[1] } else { "Password" } }
}

function Resolve-Ref($ref, [switch]$Soft) {
    $r = Split-Ref $ref
    $value = Invoke-Kp -KpArgs @("show", "-q", "-s", "-a", $r.Attr, $Db, $r.Path) -Quiet:$Soft
    if ($value) { return ($value -join "`n").TrimEnd("`r", "`n") }
    return $null
}

# An unsalted hash prefix of a secret is an offline verifier for a guessed
# value, and check output ends up in a transcript. The salt is local, so the
# fingerprint answers "same value?" here and means nothing anywhere else.
function Get-FingerprintSalt {
    if (-not (Test-Path $SaltFile) -or (Get-Item $SaltFile).Length -eq 0) {
        New-Item -ItemType Directory -Force -Path (Split-Path $SaltFile -Parent) | Out-Null
        $bytes = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $hex = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
        Set-Content -Path $SaltFile -Value $hex -NoNewline
    }
    return (Get-Content $SaltFile -Raw)
}

function Get-Fingerprint($value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-FingerprintSalt) + $value))
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 8)
}

# reveal — put something in front of the human; non-zero/false means it was not
# shown, so a caller must not treat it as read.
function Show-ToUser($title, $text) {
    if ($env:KPSEC_NO_GUI) { return $false }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($text, $title) | Out-Null
        return $true
    } catch { return $false }
}

switch ($Command) {
    "status" {
        $state = if (Test-Path $Db) { "present" } else { "MISSING" }
        Write-Host "db:             $Db ($state)"
        Write-Host "keepassxc-cli:  $(Get-KeepassxcCli)"
        $key = if (Get-MasterFromKeyring) { "key present" } else { "no key" }
        Write-Host "keyring:        credential manager ($key)"
        Write-Host "cache:          unsupported on this platform"
        if (Test-Path $Db) {
            Invoke-Kp -KpArgs @("db-info", "-q", $Db) -Quiet | Out-Null
            $ok = if ($LASTEXITCODE -eq 0) { "ok" } else { "FAILED" }
            Write-Host "unlock:         $ok"
        }
    }

    "ls" {
        $group = if ($Rest) { $Rest[0] } else { "/" }
        Invoke-Kp -KpArgs @("ls", "-q", "-R", "-f", $Db, $group)
    }

    "check" {
        if (-not $Rest) { Die "usage: kpsec check <ref>..." 2 }
        $rc = 0
        foreach ($ref in $Rest) {
            $value = Resolve-Ref $ref -Soft
            if ($value) {
                Write-Host ("OK   {0}  len={1} fp:{2}" -f $ref, $value.Length, (Get-Fingerprint $value))
            } else {
                Write-Host "FAIL $ref  (no such entry or attribute)"
                $rc = 1
            }
        }
        exit $rc
    }

    "run" {
        $pairs = @(); $envFile = $null; $i = 0
        # A plain `while` with an inner `switch`: `break` in a switch leaves the
        # switch, not the loop, so the old version spun forever on the first
        # argument that was not an option (i.e. any `run` without `--`).
        while ($i -lt $Rest.Count) {
            $arg = $Rest[$i]
            if ($arg -eq '--') { $i++; break }
            elseif ($arg -eq '--env-file') {
                if ($i + 1 -ge $Rest.Count) { Die "--env-file needs a path" 2 }
                $envFile = $Rest[$i + 1]; $i += 2
            }
            elseif ($arg -like '--env-file=*') {
                $envFile = $arg.Substring('--env-file='.Length); $i++
            }
            elseif ($arg -eq '-e' -or $arg -eq '--env') {
                if ($i + 1 -ge $Rest.Count) { Die "$arg needs NAME=value" 2 }
                $pairs += $Rest[$i + 1]; $i += 2
            }
            else { break }
        }
        if ($i -ge $Rest.Count) { Die "no command given after --" 2 }
        $cmd = @($Rest[$i..($Rest.Count - 1)])
        if ($envFile) {
            if (-not (Test-Path $envFile)) { Die "cannot read env file: $envFile" 2 }
            foreach ($line in Get-Content $envFile) {
                if ($line.Trim() -and -not $line.Trim().StartsWith("#")) { $pairs += $line.Trim() }
            }
        }
        foreach ($pair in $pairs) {
            if ($pair -notmatch '=') { Die "malformed assignment: $pair (expected NAME=value)" 2 }
            $name, $value = $pair.Split('=', 2)
            if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Die "not a usable variable name: $name" 2 }
            # One matched pair only: .Trim() would eat every leading and
            # trailing quote, and a value that merely ends in one keeps it.
            if ($value.Length -ge 2 -and
                (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                 ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if ($value -like "kp://*") { $value = Resolve-Ref $value }
            Set-Item -Path "env:$name" -Value $value
        }
        # `1..0` counts *down* in PowerShell, so slicing a one-element $cmd
        # handed the child a null argument and its own name.
        if ($cmd.Count -gt 1) { & $cmd[0] @($cmd[1..($cmd.Count - 1)]) }
        else { & $cmd[0] }
        exit $LASTEXITCODE
    }

    "add" {
        $path = $null; $username = $null; $url = $null; $generate = $false; $length = 32
        for ($i = 0; $i -lt $Rest.Count; $i++) {
            $arg = $Rest[$i]
            if ($arg -eq "-u" -or $arg -eq "--username") {
                if ($i + 1 -ge $Rest.Count) { Die "$arg needs a username" 2 }
                $username = $Rest[++$i]
            }
            elseif ($arg -eq "--url") {
                if ($i + 1 -ge $Rest.Count) { Die "--url needs a URL" 2 }
                $url = $Rest[++$i]
            }
            elseif ($arg -eq "-g" -or $arg -eq "--generate") { $generate = $true }
            elseif ($arg -eq "-L" -or $arg -eq "--length") {
                if ($i + 1 -ge $Rest.Count) { Die "$arg needs a length" 2 }
                $length = $Rest[++$i]
                if ($length -notmatch '^[0-9]+$') { Die "$arg needs a number: $length" 2 }
            }
            elseif ($arg -like "-*") { Die "unknown option: $arg" 2 }
            else { $path = $arg }
        }
        if (-not $path) { Die "usage: kpsec add <group>/<entry> [-u user] [--url u] [-g]" 2 }

        $group = Split-Path $path -Parent
        if ($group) {
            $prefix = ""
            foreach ($part in ($group -split '[\\/]')) {
                $prefix = if ($prefix) { "$prefix/$part" } else { $part }
                Invoke-Kp -KpArgs @("mkdir", "-q", $Db, $prefix) -Quiet | Out-Null
            }
        }
        $verb = if (Resolve-Ref "kp://$path#Title" -Soft) { "edit" } else { "add" }
        $kpArgs = @($verb, "-q")
        if ($username) { $kpArgs += @("-u", $username) }
        if ($url) { $kpArgs += @("--url", $url) }

        if ($generate) {
            Invoke-Kp -KpArgs ($kpArgs + @("-g", "-L", "$length", "-l", "-U", "-n", "-s", $Db, $path))
        } else {
            $cred = Get-Credential -UserName kpsec -Message "Value for $path"
            if (-not $cred) { Die "no value entered" 3 }
            Invoke-Kp -KpArgs ($kpArgs + @("-p", $Db, $path)) `
                      -ExtraStdin ($cred.GetNetworkCredential().Password + "`n")
        }
        Write-Host "$($verb)ed $path"
    }

    "clip" {
        if (-not $Rest) { Die "usage: kpsec clip <ref> [seconds]" 2 }
        $r = Split-Ref $Rest[0]
        $seconds = if ($Rest.Count -gt 1) { $Rest[1] } else { "15" }
        Invoke-Kp -KpArgs @("clip", "-q", "-a", $r.Attr, $Db, $r.Path, $seconds)
        Write-Host "copied $($Rest[0]) to clipboard for ${seconds}s"
    }

    "init" {
        if (Test-Path $Db) { Die "database already exists: $Db" 3 }
        $cli = Get-KeepassxcCli
        $master = (& $cli generate -L 40 -l -U -n).Trim()
        if (-not $master) { Die "cannot generate a master password" 5 }

        # Show it before anything depends on it: the old order created the
        # database, stored the key, then displayed it, so a Credential Manager
        # failure left a database nobody could open.
        if (-not (Show-ToUser "kpsec master password" (
            "Master password for $Db`n`n$master`n`n" +
            "Back it up in your main KeePassXC now — the database is worthless without it."))) {
            Die "cannot show the master password: no dialog available, nothing created" 6
        }

        New-Item -ItemType Directory -Force -Path (Split-Path $Db -Parent) | Out-Null
        "$master`n$master" | & $cli db-create -q -p $Db
        if ($LASTEXITCODE -ne 0) { Die "db-create failed" 5 }
        try { Set-MasterInKeyring $master }
        catch {
            Write-Host "created $Db"
            Die "could not store the master password in Credential Manager — keep the copy you were just shown" 4
        }
        Write-Host "created $Db; master password stored in Credential Manager"
    }

    "show-master" {
        $master = Get-MasterFromKeyring
        if (-not $master) { Die "master password not found in Credential Manager" 4 }
        if (-not (Show-ToUser "kpsec master password" "Database: $Db`n`nMaster password:`n`n$master")) {
            Die "cannot show the master password: no dialog available" 6
        }
        Write-Host "master password shown to the user"
    }

    "relocate" {
        if (-not $Rest) { Die "usage: kpsec relocate <new-path>" 2 }
        $newDb = $Rest[0]
        if (-not (Test-Path $newDb)) { Die "no database at $newDb" 3 }
        if ($newDb -eq $Db) { Die "source and target paths are the same" 3 }
        $master = Read-MasterPassword
        if (-not $master) { Die "no master password known for $Db" 4 }
        # Verify before touching Credential Manager. Storing first and rolling
        # back with a delete destroyed whatever the target path already had —
        # for the documented multi-database setup, another database's master
        # password, gone on a mistyped path.
        "$master" | & (Get-KeepassxcCli) @("db-info", "-q", "--", $newDb) 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Die "$newDb does not open with that master password — nothing changed" 5
        }
        $oldTarget = $Target
        $script:Target = "kpsec master key:$newDb"
        Set-MasterInKeyring $master
        $script:Db = $newDb
        [KpsecCred]::Delete($oldTarget) | Out-Null
        Write-Host "relocated to $newDb"
        Write-Host "set KPSEC_DB if the new path is not the default"
    }

    "lock" { Write-Host "no cache on this platform; the key stays in Credential Manager" }

    default {
        @"
kpsec — use secrets from a local KeePassXC database without printing them

  kpsec.ps1 status                    database, keyring, unlock check
  kpsec.ps1 ls [group]                list entries (never values)
  kpsec.ps1 check <ref>...            verify refs resolve: length + sha256 prefix
  kpsec.ps1 run [--env-file F] [-e VAR=ref] -- cmd
  kpsec.ps1 add <group>/<entry> [-u user] [--url u] [-g] [-L n]
  kpsec.ps1 clip <ref> [seconds]
  kpsec.ps1 init
  kpsec.ps1 relocate <path>
  kpsec.ps1 show-master

References: kp://<group>/<entry>[#<Attribute>], default attribute Password.
Environment: KPSEC_DB, KPSEC_KEEPASSXC_CLI, KPSEC_MASTER_COMMAND, KPSEC_NO_GUI.

KPSEC_MASTER_COMMAND is run by cmd.exe and its first line of output is used as
the master password — for sessions with neither Credential Manager nor a dialog.
"@ | Write-Host
        # Help on request is success; an unknown command is a usage error, as in
        # the bash script.
        if ($Command -and $Command -notin @("-h", "--help", "help")) {
            Die "unknown command: $Command (try kpsec --help)" 2
        }
    }
}
