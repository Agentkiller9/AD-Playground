# AD-Playground

> A single-script, interactive vulnerable Active Directory lab environment for red team training.

Drop one PowerShell script onto any Windows Server, run it as Administrator, and get a fully populated AD with 31 individual technique labs and 7 chained attack scenarios — all deployable and cleanable without re-imaging.

---

## Before You Run — Required Steps

> **This script intentionally references offensive security tool names and attack techniques.**
> Windows Defender will block it. Adding a folder exclusion is NOT enough.
> You must disable AMSI and real-time scanning. Follow all three steps below.

---

### Why folder exclusions do NOT work

Windows Defender has two separate scanning engines:

| Engine | What it scans | Bypassed by folder exclusion? |
|---|---|---|
| **File scanner** | Files on disk | YES |
| **AMSI** (Antimalware Scan Interface) | Script content **in memory** as PowerShell parses it | **NO** |

The error `ScriptContainedMaliciousContent` is thrown by **AMSI**, not the file scanner.
AMSI hooks directly into the PowerShell parser and scans the script content before a single
line runs — completely bypassing any path-based exclusion you configure.

The only fix is to disable real-time monitoring and script scanning at the engine level.

---

### Step 1 — Disable Defender scanning (Lab VM only)

Open PowerShell as Administrator and run **all three**:

```powershell
Set-MpPreference -DisableRealtimeMonitoring $true
Set-MpPreference -DisableScriptScanning $true
Set-MpPreference -DisableIOAVProtection $true
```

Verify it worked:

```powershell
Get-MpPreference | Select DisableRealtimeMonitoring, DisableScriptScanning, DisableIOAVProtection
# All three should return True
```

> This is safe to do on an isolated lab VM. Never do this on a production or internet-facing machine.

### Step 2 — Set Execution Policy

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```

### Step 3 — Run as Administrator

```powershell
.\AD-Playground.ps1
```

On first run, select **[1] Setup Baseline** to install AD DS and populate users.

---

## Why Defender Flags It

The script contains strings used as student hints and status messages — tool names,
attack command examples, and technique references. These are **informational strings only**.
The script does not download, execute, or bundle any actual offensive tools.

AMSI's heuristic engine pattern-matches on keywords regardless of context, so even
a string like `"Attack: secretsdump.py [domain]/[user]@[dc]"` inside a `Write-Host`
call is enough to trigger a block. This is the same reason PowerSploit, Empire, and
every AD lab toolkit requires AV to be disabled before use.

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows Server 2016 / 2019 / 2022 |
| Privileges | Run as **Administrator** |
| Role | AD DS (script installs it if missing) |
| PowerShell | 5.1+ |
| Windows Defender | Disabled or folder excluded (see above) |

---

## Full Setup Sequence (Clean VM)

```powershell
# 1. Open PowerShell as Administrator

# 2. Exclude the lab folder from Defender
Add-MpPreference -ExclusionPath "C:\Path\To\AD-Playground"

# 3. Set execution policy for this session
Set-ExecutionPolicy Bypass -Scope Process -Force

# 4. Run the script
cd "C:\Path\To\AD-Playground"
.\AD-Playground.ps1

# 5. Select [1] Setup Baseline — installs AD DS + populates 44 users, groups, OUs
# 6. Reboot if prompted (AD DS promotion requires it)
# 7. Re-run the script and select [1] again to finish user population
# 8. Navigate to [2] Labs or [3] Scenarios and start practicing
```

---

## Labs (31 total)

### Enumeration (10)
| ID | Technique |
|---|---|
| E1 | LDAP Null / Authenticated Enumeration |
| E2 | SMB Null Sessions & Share Enumeration |
| E3 | SPN Enumeration |
| E4 | BloodHound / SharpHound Data Collection |
| E5 | PowerView Target Setup |
| E6 | DNS Zone Transfer |
| E7 | RPC Enumeration |
| E8 | GPO / GPP Password Enumeration |
| E9 | User Enumeration (Kerbrute targets) |
| E10 | Trust Enumeration |

### Credential Attacks (6)
| ID | Technique |
|---|---|
| C1 | AS-REP Roasting |
| C2 | Kerberoasting |
| C3 | Password Spraying |
| C4 | LLMNR / NBT-NS Poisoning |
| C5 | Credentials in AD Attributes |
| C6 | NTLMv2 Hash Capture (UNC Trigger) |

### ACL Abuse (5)
| ID | Technique |
|---|---|
| A1 | WriteDACL on Domain Object |
| A2 | GenericAll on User |
| A3 | GenericWrite on User |
| A4 | ForceChangePassword |
| A5 | AddMember to Privileged Group |

### Delegation (3)
| ID | Technique |
|---|---|
| D1 | Unconstrained Delegation |
| D2 | Constrained Delegation (S4U / Protocol Transition) |
| D3 | Resource-Based Constrained Delegation (RBCD) |

### Lateral Movement (3)
| ID | Technique |
|---|---|
| L1 | Pass-the-Hash |
| L2 | Overpass-the-Hash / Pass-the-Key |
| L3 | Pass-the-Ticket |

### Persistence (4)
| ID | Technique |
|---|---|
| P1 | AdminSDHolder Backdoor |
| P2 | DCSync Rights |
| P3 | Shadow Credentials |
| P4 | Golden Ticket Prerequisites |

---

## Scenarios (7)

| # | Name | Difficulty | Chain |
|---|---|---|---|
| 1 | New Hire Foothold | Easy | E9 -> C1 -> C3 -> C5 -> E3 |
| 2 | Internal Pivot | Medium | E2 -> C4 -> C6 -> E4 -> A1 |
| 3 | Full Domain Takeover | Hard | E3 -> D3 -> D2 -> P3 -> P2 |
| 4 | APT Simulation - Stealthy Operator | Hard | E4 -> A2 -> D2 -> P1 |
| 5 | Misconfig Hunt - The Auditor | Medium | E8 -> C5 -> A3 -> A5 -> P2 |
| 6 | Trust Attack - Cross Domain | Hard | E10 -> E1 -> D3 -> A2 -> P2 |
| 7 | Quick CTF - Speed Run | Random | 3 random labs |

---

## Menu Navigation

```
Main Menu
+-- [1] Setup Baseline      - Install AD DS + populate 44 users, groups, OUs
+-- [2] Labs                - Browse and deploy individual technique labs
|     +-- Enumeration       (E1-E10)
|     +-- Credential Attacks(C1-C6)
|     +-- ACL Abuse         (A1-A5)
|     +-- Delegation        (D1-D3)
|     +-- Lateral Movement  (L1-L3)
|     +-- Persistence       (P1-P4)
+-- [3] Scenarios           - Deploy chained attack scenarios
+-- [4] Active Lab Status   - See what is currently deployed
+-- [5] Teardown / Clean    - Remove labs individually or all at once
+-- [6] Exit
```

Each lab menu offers:
- **Deploy** - configure the vulnerability
- **Teardown** - cleanly remove it
- **Show Hints** - 3 progressive hints per lab

---

## Recommended Attack Tools

| Tool | Use |
|---|---|
| [BloodHound](https://github.com/BloodHoundAD/BloodHound) | AD attack path visualization |
| [Impacket](https://github.com/fortra/impacket) | GetNPUsers, GetUserSPNs, secretsdump, psexec |
| [Rubeus](https://github.com/GhostPack/Rubeus) | Kerberos ticket manipulation |
| [Responder](https://github.com/lgandx/Responder) | LLMNR/NBT-NS poisoning |
| [PowerView](https://github.com/PowerShellMafia/PowerSploit) | AD enumeration and ACL abuse |
| [Whisker](https://github.com/eladshamir/Whisker) | Shadow credentials |
| [Kerbrute](https://github.com/ropnop/kerbrute) | User enumeration and password spraying |
| [CrackMapExec](https://github.com/byt3bl33d3r/CrackMapExec) | SMB enumeration and lateral movement |

---

## Troubleshooting

| Error | Fix |
|---|---|
| `ScriptContainedMaliciousContent` | AMSI block — folder exclusions do NOT fix this. Run Step 1: `Set-MpPreference -DisableRealtimeMonitoring $true`, `-DisableScriptScanning $true`, `-DisableIOAVProtection $true` |
| `UnauthorizedAccess` / not digitally signed | Run `Set-ExecutionPolicy Bypass -Scope Process -Force` first |
| `The term 'Get-ADUser' is not recognized` | Script auto-imports the AD module — ensure AD DS role is installed |
| Banner shows garbled characters | Run `chcp 65001` in the console before launching the script |
| Script hangs on baseline setup | AD DS promotion requires a reboot — reboot and re-run, select [1] again |

---

## Notes

- Always run in an **isolated lab network** — never in production.
- The script tracks active labs in `adp_state.json` (same directory).
- Teardown is surgical — only removes what was deployed.
- All sensitive settings (LLMNR, SMB signing, registry keys) are restored to secure defaults on teardown.

---

## License

For educational and authorized security training use only.
