# Verified Field Compatibility Report

This document summarizes real-world bench testing conducted across corporate fleet ThinkPads during development of **ThinkPad Custom Logo Remover** (`v1.0.0`).

All hardware serial numbers, full 10-character customer MTMs, and machine-specific identifiers have been removed for privacy. Only 4-character Lenovo Machine Type Model (`MTM4`) prefixes, official BIOS package IDs/versions, firmware updater telemetry, and anonymized unit labels are published.

---

## Executive Summary

| Metric | Verified Result |
|---|---|
| **Unique ThinkPad `MTM4` Prefixes** | **8** (`20UE`, `20XL`, `21A7`, `21BV`, `21K4`, `21K8`, `21MM`, `21MQ`) |
| **ThinkPad Model Families** | **7** (`T14s Gen 1`, `T14 Gen 2a`, `T15p Gen 2i`, `T16 Gen 1`, `T14 Gen 4`, `T16 Gen 2`, `T14 Gen 5`) |
| **Total Bench Units Covered** | **15 units** (13 units flashed across 27 logged workflow runs + 2 additional `MTM4` variants validated in catalog/cache discovery) |
| **Archived `WINUPTP` Flash Logs** | **19 transcripts** across 5 updater engine generations |
| **Lenovo `WINUPTP` Versions Verified** | `v35.08`, `v36.33`, `v37.24`, `v42.6`, `v44.14` |
| **WMI `SecureRollBackPrevention` Auto-Restore** | **7 / 7 passed** (`REENABLE_ROLLBACK_OK`, `ExitCode 0`) |

---

## Tested Models Matrix

| `MTM4` | Model Family | Verified BIOS Version(s) | Package ID | `WINUPTP` Engine | Flash Modes Verified | WMI Rollback Auto-Restore | Observed Outcome & Notes |
|---|---|---|---|---|---|---|---|
| `21MM` | ThinkPad T14 Gen 5 | `N47ET28W (1.17)` -> `N47ET30W (1.19)` | `n47uj14w` / `n47uj12w` | `v42.6` | Standard upgrade, Fast `-s -bcp`, Full downgrade + restore cycle | **3 / 3 OK** | **6 units tested** (14 log rows). Confirmed BIOS + EC flash (`N47HT25W`/`N47HT26W`), fast same-version flash, and full cycle (~16.5–21 min). Exposed Error 182 rollback block (`ExitCode -1`) and silent flag requirement (`-bcp` alone exited `1` without flashing). |
| `21MQ` | ThinkPad T14 Gen 5 (variant) | `N47ET30* (1.19)` | `n47uj14w` | `v42.6` *(shared)* | Catalog / offline cache validation | N/A | Shares the `N47ET*` / `n47uj14w` package family with `21MM`; indexed and verified for offline preloading. |
| `21K4` | ThinkPad T14 Gen 4 | `R2FET72W (1.52)` | `r2fuj72w` | `v44.14` | Fast `-s -bcp` after BIOS rollback toggle | **1 / 1 OK** | **2 units tested** (4 log rows). Exposed `v44.14` false-positive `ExitCode 1` on Error 182 and harmless `SwissArmyKnife.IniParser` `<WARNING>`. Once rollback disabled, `-s -bcp` removed the logo cleanly (~2 min 10 s to WMI restore). |
| `21K8` | ThinkPad T16 Gen 2 | `R2FET72W (1.52)` | `r2fuj72w` | `v44.14` | Fast `-s -bcp` after BIOS rollback toggle | **1 / 1 OK** | **1 unit tested** (2 log rows). Shares `r2fuj72w` (`R2FET72W` / `R2FHT51W`) with `21K4`. Same-version silent flash + reboot + WMI re-enable completed in ~2 min 10 s between flash prep and post-reboot WMI restore. |
| `21BV` | ThinkPad T16 Gen 1 | `N3MET30W (1.29)` | `n3buj25w` (`1.49/1.29`) | `v37.24` | Fast `-s -bcp` after BIOS rollback toggle | **1 / 1 OK** | **1 unit tested** (2 log rows). Verified dual-prefix Lenovo package handling (`N3BET71*` + `N3MET30*` in `1.49/1.29`), BIOS + EC flash (`N3MHT20W`), and WMI re-enable (~2 min 40 s). |
| `21A7` | ThinkPad T15p Gen 2i | `N38ET48W (1.29)` -> `N38ET54W (1.84)`<br>`N38ET53W (1.83)` -> `N38ET54W (1.84)` | `n38uj25w` | `v36.33` | Standard upgrade `-s -bcp` | Not needed (newer version) | **2 units tested** (2 log rows). Verified standard BIOS + EC (`N38HT33W`) upgrade with factory default startup image restoration using legacy `WINUPTP v36.33`. |
| `20XL` | ThinkPad T14 Gen 2a | `R1MET65W (1.35)` | `r1muj65w` | `v35.08` | Fast `-s -bcp` after BIOS rollback toggle | **1 / 1 OK** | **1 unit tested** (3 log rows). Exposed initial `-s -bcp` hang (`PENDING`) on first attempt, README `[ Important ]` version parsing quirk, hard rollback barrier detection, and legacy `v35.08` log lines (`FeatureBit 7`, single-line flash completion). Second run succeeded cleanly and restored rollback via WMI (~6 min 09 s incl. reboot). |
| `20UE` | ThinkPad T14s Gen 1 | `R1BET85W (1.54)` -> `r1buj87w (1.56)` | `r1buj87w` | — | Catalog fallback (`Win11` -> `Win10` / direct XML) & cache | N/A | **1 unit** used to validate multi-OS catalog fallback (`_OS = Win11` empty -> direct XML `20UE_Win11.xml` fallback) and offline cache resolution. |

---

## Representative Sanitized `WINUPTP` Log Excerpts

No hardware serial numbers appear inside Lenovo's internal `winuptp.log` content shown below.

### 1. Legacy Console Engine (`WINUPTP v35.08` — ThinkPad T14 Gen 2a / `20XL`)

```text
[2026/11/20 12:6:55] version 35.08
OS = Windows 10 64bit
Driver Loading....FeatureBit 7
Applying BIOS Version -> R1MET65W
Apply the default start up image to the system.
Battery check....OK.
Battery check....OK.
BIOS Flashing....BIOS Flash completed.
```

### 2. Legacy Console Engine (`WINUPTP v36.33` — ThinkPad T15p Gen 2i / `21A7`)

```text
[2026/11/20 12:36:14] version 36.33
OS = Windows 10 64bit
Driver Loading....Done
Applying BIOS Version -> N38ET54W
Apply the default start up image to the system.
Applying EC Version -> N38HT33W
Battery check....OK.
Battery check....OK.
BIOS Flashing....BIOS Flash completed.
EC Flashing....EC Flash completed.
```

### 3. Modern Updater Engine (`WINUPTP v37.24` — ThinkPad T16 Gen 1 / `21BV`)

```text
2026-11-20 12:48:41.937 <NOTICE> LenovoBiosUpdateTool starting ...
2026-11-20 12:48:42.111 <NOTICE> Lenovo BIOS update tool version: 37.24
2026-11-20 12:48:43.352 <NOTICE> Driver has been installed successfully.
2026-11-20 12:49:47.221 <NOTICE> Applying BIOS Version -> N3MET30W
2026-11-20 12:49:47.221 <NOTICE> Applying EC Version -> N3MHT20W
2026-11-20 12:49:47.221 <NOTICE> Apply the default start up image to the system.
2026-11-20 12:49:48.239 <NOTICE> BIOS Flashing ...
2026-11-20 12:50:06.694 <NOTICE> BIOS Flash completed.
2026-11-20 12:50:06.697 <NOTICE> EC Flashing ...
2026-11-20 12:50:11.939 <NOTICE> EC Flash completed.
```

### 4. Modern Updater Engine (`WINUPTP v42.6` — ThinkPad T14 Gen 5 / `21MM`, Downgrade -> Upgrade-Back)

```text
2026-11-19 18:49:37.802 <NOTICE> Applying BIOS Version -> N47ET28W
2026-11-19 18:49:37.802 <NOTICE> Applying BIOS is older than System BIOS.
2026-11-19 18:49:37.802 <NOTICE> Applying EC Version -> N47HT25W
2026-11-19 18:49:37.802 <NOTICE> Applying EC is older than System EC.
2026-11-19 18:49:37.802 <NOTICE> Apply the default start up image to the system.
2026-11-19 18:49:38.819 <NOTICE> BIOS Flashing ...
2026-11-19 18:50:04.729 <NOTICE> BIOS Flash completed.
2026-11-19 18:50:04.729 <NOTICE> EC Flashing ...
2026-11-19 18:50:10.792 <NOTICE> EC Flash completed.
```

### 5. System Firmware Tool (`WINUPTP v44.14` — ThinkPad T16 Gen 2 / `21K8` & T14 Gen 4 / `21K4`)

```text
2026-11-20 12:17:48.557 <NOTICE> LenovoBiosUpdateTool starting ...
2026-11-20 12:17:49.031 <NOTICE> ThinkPad System Firmware update tool version: 44.14
2026-11-20 12:17:50.046 <NOTICE> Driver has been installed successfully.
2026-11-20 12:18:09.041 <NOTICE> Applying BIOS Version -> R2FET72W
2026-11-20 12:18:09.041 <NOTICE> Applying EC Version -> R2FHT51W
2026-11-20 12:18:09.058 <NOTICE> Apply the default start up image to the system.
2026-11-20 12:18:10.064 <NOTICE> BIOS Flashing ...
2026-11-20 12:18:28.665 <NOTICE> BIOS Flash completed.
```

---

## Engineering Findings Resolved During Bench Testing

1. **False-Positive `ExitCode 1` on `WINUPTP v44.14` (`21K4` / `21K8`)**  
   When `SecureRollBackPrevention` was enabled, `v44.14` wrote `[Flash Error] <ERROR> Secure RollBack prevention is enabled.` (Error 182) to `winuptp.log` yet still returned `ExitCode 1`. `Get-WinuptpLogAnalysis` overrides `ExitCode 1` as failed whenever a rollback error or fatal error appears, or when `BIOS Flash completed` never occurred, and automatically offers a one-key reboot into firmware setup (`shutdown /r /fw /t 0`) with auto-resume.

2. **`WINUPTP -bcp` Without `-s` Is a No-Op (`21MM`)**  
   Running `winuptp64.exe -bcp` without `-s` exited with `ExitCode 1` after only logging `Apply the default start up image to the system.` — without flashing BIOS or EC. Always passing `-s -bcp` resolves this cleanly.

3. **Legacy `v35.08` / `v36.33` Live Progress & Manual Hang Abort (`20XL` / `21A7`)**  
   Older `WINUPTP` builds do not emit separate `BIOS Flashing ...` / `BIOS Flash completed.` lines or `<NOTICE>` prefixes; they append both states onto a single line (`BIOS Flashing....BIOS Flash completed.`). `Get-WinuptpLiveEvent` matches completion markers before in-progress markers, shows an elapsed timer and spinner during execution, and supports pressing `[Q]` if a silent flash hangs (recording `ExitCode -999`).

4. **README Package ID Quirks & Hard Rollback Barriers (`20XL`)**  
   Some Lenovo README files place an unrelated package ID inside an `[ Important ]` / `[ New ]` header note above the summary-of-changes table, and include critical security updates marked `(Note) Once updated... cannot roll back`. The parser restricts candidate previous-package extraction to package IDs sharing the target BIOS family prefix and blocks downgrade cycles across hard anti-rollback barriers.

5. **Dual-Prefix BIOS Packages (`21BV` / `n3buj25w`)**  
   Lenovo occasionally ships two platform BIOS prefixes in one package (`1.49/1.29` covering `N3BET71*` and `N3MET30*`). Version comparison matches against every `DetectInstall` `Bios` level reported by the package XML so same-version and upgrade checks remain accurate across shared packages.
