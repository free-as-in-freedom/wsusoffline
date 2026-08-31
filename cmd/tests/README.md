# Tests for the remote deployment tools

Covers `cmd\WsusOfflineRemote.psm1`, `cmd\Invoke-RemoteUpdate.ps1` and
`cmd\Show-RemoteUpdateGui.ps1`.

## Running them

From the repository root:

```
powershell -NoProfile -File cmd\tests\Invoke-WouTests.ps1
```

About a minute and a half, 200-odd assertions, and it prints `all suites
passed` or the failing assertions. Exit code is 0 or 1, so it drops into a hook
or a build step unchanged.

No elevation, no network, no target machine and no `wsusscn2.cab` are needed.
Nothing is installed anywhere and nothing outside `%TEMP%` is written, apart
from a harness copy of the GUI script that is created beside the original and
deleted again in the same breath — the GUI resolves its payload relative to its
own location, so testing it from anywhere else would test a layout no operator
has.

Options:

| | |
|---|---|
| `-SkipSlow` | Leaves out `GuiPool`, the slowest suite (five hosts, up to about a minute and a half on a cold DNS cache). `Config` still costs its twenty-odd seconds of deliberate timeouts. |
| `-Name Gui*` | Wildcard over suite names, minus the `.Tests.ps1` suffix. |
| `-Detail` | Every assertion, not just the failures. |

Most of the wall-clock time is suites waiting out SMB connect timeouts on
purpose, against hostnames that resolve nowhere. Timings therefore swing by a
factor of two or three between runs depending on what the negative DNS cache
still remembers; that is normal, and no assertion depends on a clock.

Each suite runs in its own `powershell.exe`. They import the module with
`-Force`, set their own preference variables, and several of them create WPF
windows and pump a dispatcher — sharing one session would let one suite's
leftovers decide the next suite's result. It also means a suite that dies
outright is reported as a failure instead of taking the run down with it.

## What each suite covers

| Suite | Covers |
|---|---|
| `Flags` | Mapping from switches to the client command line, and the scan flags. |
| `LogAndStatus` | Log line format, duration formatting, status codes. |
| `ScanResult` | Parsing `Get-ScanResult` out of the client's own output. |
| `Config` | Configuration, target-file parsing, staging rules. Drives two runs against an unresolvable name to prove the preflight refuses before it stages anything. |
| `Wrapper` | The generated `RunRemoteUpdate.cmd`, including under `NoDefaultCurrentDirectoryInExePath` and from a path containing a space. |
| `SchTasks` | `Invoke-WouSchTasks`. Pins the regression where PowerShell 5.1 turned `schtasks`' ordinary "the task does not exist" message into a terminating error, which made every run report `Failed` before staging anything. |
| `AdminShare` | The connectivity diagnosis. A refused logon, a firewall dropping TCP 445 and a machine that is switched off must not read alike, and the Win32 code sets behind those messages must stay disjoint. |
| `Gui` | The GUI script parses, builds its window, and wires its handlers. |
| `GuiScan` | Scan result plumbing through to the rows. |
| `GuiEvents` | The `Closing` handler can actually veto a close, and the `param()` form receives its arguments. |
| `GuiPool` | The worker pool end to end: the throttle is never exceeded, the timer stops, buttons come back, and no jobs are left behind. This is the GUI's chief risk and the one slow suite. |

## What they deliberately do not cover

The suites prove the logic and the failure paths. They cannot prove that a scan
returns the right updates for a real machine, because that answer comes from the
Windows Update Agent on the target evaluating `wsusscn2.cab`. Those checks need
a target, an elevated shell, and a downloaded cab:

```powershell
# 1. Can we reach it, and if not, does it say why? Needs no elevation.
Import-Module .\cmd\WsusOfflineRemote.psm1 -Force
$c = Get-Credential DESKTOP-1J55DGU\Administrator   # a local admin of the target
Test-WouTarget -ComputerName 192.168.233.128 -Credential $c | Format-List

# 2. What would a run do? Prints the payload and the targets it would run
#    against, then stops - no staging, no contact. Needs an elevated shell.
.\cmd\Invoke-RemoteUpdate.ps1 -ComputerName 192.168.233.128 -Credential $c -WhatIf

# 3. A real scan. Needs client\wsus\wsusscn2.cab, so run a download first.
.\cmd\Invoke-RemoteUpdate.ps1 -ComputerName 192.168.233.128 -Credential $c -ScanOnly

# 4. The GUI over the same target.
.\cmd\Show-RemoteUpdateGui.ps1 -TargetFile .\cmd\remote-targets.txt -Credential $c
```

A workgroup target needs `LocalAccountTokenFilterPolicy=1` as well as the
credential, or its admin share hands back a filtered token and every call is
refused. `Test-WouTarget` says so when it sees that error rather than leaving it
to be guessed at.

Two things worth confirming by eye on a real install, because no assertion here
can: `net user` on the target shows no `WOUTempAdmin` account afterwards (the
runner never emits the switches that would create one), and cancelling from the
GUI leaves no `WOUOfflineScan` task behind in `schtasks /query`.
