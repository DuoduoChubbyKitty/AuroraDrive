# Internals · BPF Permissions & LaunchDaemon Auto-Install

> Implemented in `BPFSetup.swift` (125 lines) + `BPFPasswordSheet` in `AuroraDriveApp.swift`
> Up: [Network Localization](../dev/02-network-locate.en.md) ｜ 中文: [BPF 权限与 LaunchDaemon](../bpf-daemon.md)

## 1. Problem

libpcap capture requires read/write access to `/dev/bpf*`, but macOS **resets those device nodes to root-only** (`crw-------`) on every reboot. Any pcap-dependent program silently breaks for non-root users at every boot.

## 2. Solution overview

```
App launch
  → BPFSetupManager.needsInstall()
      = !isBPFAvailable() && !isLaunchDaemonInstalled()
  → true: toolbar shows the BPF pill + BPFPasswordSheet pops (default password 123456)
  → user clicks "Install" → install(password:):
      1. write a shell script to /tmp/aurora_bpf_setup.sh (mode 0755)
      2. osascript: do shell script "bash /tmp/..." password "<pwd>"
         with administrator privileges        ← password passed as an argument,
                                                no system password dialog
      3. script contents:
         - write /usr/local/bin/aurora-bpf-setup.sh (chmod 666 /dev/bpf*)
         - write /Library/LaunchDaemons/com.aurora.bpf-setup.plist (RunAtLoad=true)
         - launchctl load that plist
         - chmod 666 /dev/bpf* immediately (takes effect this session)
         - echo "BPF_SETUP_DONE" (success marker)
      4. terminationStatus==0 && isBPFAvailable() → success
```

**Effect**: the user types the password once. After that, launchd re-runs the setup script at every boot and BPF access is restored without any interaction.

## 3. Implementation details

### 3.1 Password passed through AppleScript (no system dialog)

```swift
let escapedPwd = password.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
let appleScript = "do shell script \"bash \(scriptPath)\" password \"\(escapedPwd)\" with administrator privileges"
```

Escape `\` first, then `"` (order matters) so special characters in the password cannot break the AppleScript string. osascript runs via `Process` with stdout/stderr captured.

### 3.2 Result determination

| Case | Verdict |
|---|---|
| exit 0 + `isBPFAvailable()` | "installed, effective at boot" |
| exit 0 but BPF still unavailable | "LaunchDaemon installed, effective after reboot" (launchd timing) |
| stderr contains Authentication/password | "wrong password" |
| other non-zero exit | "install failed: <stderr>" |

### 3.3 launchd timing fallback (tryImmediateChmod)

Early in boot, launchd may not have reached our plist yet. `tryImmediateChmod()` manually kickstarts via `launchctl start com.aurora.bpf-setup`, sleeps 1s, then verifies with `test -r /dev/bpf0` — used when the Daemon is installed but BPF is still unavailable at app launch, avoiding a reboot.

### 3.4 State machine (AuroraDriveApp side)

```
access("/dev/bpf0", O_RDWR) succeeds?
├─ yes → bpfAuthorized=true, pill hidden
└─ no → BPFSetupManager.needsInstall()?
    ├─ true (Daemon not installed) → showBPFPasswordSheet=true → password sheet
    └─ false (Daemon installed) → tryImmediateChmod() → re-probe
```

## 4. Security trade-offs (stated honestly)

- The password is **never persisted**: it exists only as an osascript argument for one process run; it is briefly visible in that process's launch arguments (`ps`) — acceptable on a single-user personal machine
- The LaunchDaemon script runs `chmod 666 /dev/bpf*` as root: this opens capture devices to all local users — the same standard approach Wireshark uses, but on multi-user machines it means any local user can capture packets
- The plist path is fixed (`/Library/LaunchDaemons/com.aurora.bpf-setup.plist`); `isLaunchDaemonInstalled()` checks file existence

## 5. Troubleshooting

| Symptom | Cause & fix |
|---|---|
| "effective after reboot" shown after install | launchd load timing; reboot, or `sudo launchctl kickstart -k system/com.aurora.bpf-setup` |
| BPF unavailable again after reboot | check `ls /Library/LaunchDaemons/com.aurora.bpf-setup.plist`; re-install if security software removed it |
| Password sheet keeps re-popping | `isBPFAvailable()` fails + Daemon not installed; first verify BPF works via manual `sudo chmod 666 /dev/bpf*` |
