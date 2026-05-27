# AD-Playground

> A single-script, interactive vulnerable Active Directory lab environment for red team training.

Drop one PowerShell script onto any Windows Server, run it as Administrator, and get a fully populated AD with 31 individual technique labs and 7 chained attack scenarios — all deployable and cleanable without re-imaging.

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows Server 2016 / 2019 / 2022 |
| Privileges | Run as **Administrator** |
| Role | AD DS (script installs it if missing) |
| PowerShell | 5.1+ |

---

## Quick Start

```powershell
# 1. Clone or copy AD-Playground.ps1 to the server
# 2. Open PowerShell as Administrator
Set-ExecutionPolicy Bypass -Scope Process -Force
.\AD-Playground.ps1
```

On first run → select **[1] Setup Baseline** to install AD DS and populate users.

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
| 1 | New Hire Foothold | Easy | E9 → C1 → C3 → C5 → E3 |
| 2 | Internal Pivot | Medium | E2 → C4 → C6 → E4 → A1 |
| 3 | Full Domain Takeover | Hard | E3 → D3 → D2 → P3 → P2 |
| 4 | APT Simulation — Stealthy Operator | Hard | E4 → A2 → D2 → P1 |
| 5 | Misconfig Hunt — The Auditor | Medium | E8 → C5 → A3 → A5 → P2 |
| 6 | Trust Attack — Cross Domain | Hard | E10 → E1 → D3 → A2 → P2 |
| 7 | Quick CTF — Speed Run | Random | 3 random labs |

---

## Menu Navigation

```
Main Menu
├── [1] Setup Baseline      — Install AD DS + populate 44 users, groups, OUs
├── [2] Labs                — Browse and deploy individual technique labs
│     ├── Enumeration       (E1–E10)
│     ├── Credential Attacks(C1–C6)
│     ├── ACL Abuse         (A1–A5)
│     ├── Delegation        (D1–D3)
│     ├── Lateral Movement  (L1–L3)
│     └── Persistence       (P1–P4)
├── [3] Scenarios           — Deploy chained attack scenarios
├── [4] Active Lab Status   — See what's currently deployed
├── [5] Teardown / Clean    — Remove labs individually or all at once
└── [6] Exit
```

Each lab menu offers:
- **Deploy** — configure the vulnerability
- **Teardown** — cleanly remove it
- **Show Hints** — 3 progressive hints per lab

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

## Notes

- Always run in an **isolated lab network** — never in production.
- The script tracks active labs in `adp_state.json` (same directory).
- Teardown is surgical — only removes what was deployed.
- All sensitive settings (LLMNR, SMB signing, registry keys) are restored to secure defaults on teardown.

---

## License

For educational and authorized security training use only.
