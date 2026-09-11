# Verification

Everything below was measured on real hardware, not estimated.

**Environment:** macOS 26.6.2 (Darwin 25.6.0), Apple Silicon arm64, Swift 6.3.3.
Devices exercised: a USB condenser mic (transport `usb `), AirPods Pro 3 (`blue`),
built-in mic (`bltn`), Continuity iPhone Mic (`ccwd`), a DisplayPort monitor (`dprt`),
and three Wave Link virtual devices.

Device names and identifiers are scrubbed throughout.

---

## Resource cost

| Metric | Result | Threshold |
|---|---|---|
| `phys_footprint` | **3.9–4.2 MB** | < 8 MB |
| `vmmap` writable, `written=` | **2.8 MB** | < 4 MB |
| Idle wakeups (5 s delta sample) | **0** | 0 |
| CPU over 24 h of real use | **0.59 s** | < 5 s |
| `phys_footprint` growth over 24 h | **+224 KB** | no sustained growth |
| launchd restarts over 24 h | **0** | 0 |

RSS reads ~13.6 MB and is misleading. `libswiftCore.dylib` and `Foundation` do not exist on
disk on modern macOS — they resolve from the dyld shared cache and their text pages are shared
system-wide. `phys_footprint` is the honest number.

### The idle-wakeups measurement, and how it was first read wrong

`sudo powermetrics --samplers tasks -n 3 -i 5000` never listed micpeg at all — the task sampler
only reports the busiest processes, so this is evidence of absence, not a number. The counter
was read directly instead:

```
$ top -l 2 -s 5 -pid <PID> -stats pid,command,cpu,time,idlew
PID    COMMAND %CPU TIME     IDLEW
19340  micpeg  0.0  00:00.10 0
```

**`IDLEW` is a lifetime counter, not a per-sample rate.** Reading it as a rate produced a bogus
`FAIL` on the first 24-hour check: 58 wakeups over 24 hours is 2.4/hour, not 58/second. The two
samples showed the identical value and CPU time did not move, which is what gave it away. The
soak script's verdict logic was the defect, not the daemon.

---

## The relevance filter

A DisplayPort monitor re-registered its audio endpoint **every 11.3 seconds for 8 consecutive
hours** — 3,243 events, 94% of the log. An output-only device cannot affect which input is
default, so all of that work was waste.

| | Before | After |
|---|---|---|
| Per event | 10.1 ms | **0.070 ms** |
| Per day (3,243 events) | 32.6 s | **0.23 s** |
| Heap growth | +3.6 MB | — |

**145× reduction**, measured over a 1,000-iteration benchmark of the surviving path
(`allDevices()` plus a `deviceUID()` per device).

Day-over-day, with the filter live:

| Metric | Day 1 (before) | Day 2 (after) | Change |
|---|---|---|---|
| `phys_footprint` growth | +3,616 KB | **+224 KB** | 16× |
| CPU cumulative | 32.61 s | **0.59 s** | 55× |
| Log growth | +3,243 lines | **+18 lines** | 180× |
| Idle wakeups (24 h) | 58 | **3** | — |

The flapping cause was not fully identified. An independent observer sampling the HAL device
set once a second for 90 seconds saw **zero** changes while the monitor was the default output,
so simply using the monitor's speakers is not the trigger. The hourly distribution is the better
clue: continuous from 01:00–09:00 (319/hour), zero at 13:00, intermittent otherwise — it happens
while the machine is idle, not while it is in use. Most likely the display cycling through
low-power states re-registers its audio endpoint. Not proven.

**Side effect worth knowing:** micpeg now ignores such devices entirely, so flapping no longer
appears in the log at all. It shows up only indirectly, in CPU time.

---

## Behavioural tests

| Test | Result |
|---|---|
| Bluetooth headset connects → input stays on the USB mic, output moves | **PASS** ×3 |
| Output untouched (`DefaultOutputDevice` refs in source) | **PASS** — 0 occurrences |
| `coreaudiod` restart recovery (`'srst'`) | **PASS** |
| Flip-back defence (macOS re-takes the default after our write) | **PASS** |
| Manual selection of a non-Bluetooth device respected | **PASS** → `YIELDED` |
| Manual selection of a settled Bluetooth device respected | **PASS** → `YIELDED` |
| Target unplugged → no intervention at all | **PASS** — 0 reverts across an 8 s absence |
| Target replugged (`AudioObjectID` changes) | **PASS** — UID targeting, no ID cache |
| `'dIn '` / `'dev#'` listener liveness | **PASS** |
| `micpeg on` / `off` / SIGHUP reload | **PASS** |
| launchd `ThrottleInterval` on repeated crash | **PASS** — ~50 s restart delay |
| Malformed config → CLI refuses, file preserved, daemon keeps last good settings | **PASS** |
| Out-of-range timing values (`1e300`, `-1`, `0`) | **PASS** — clamped, adjustments logged |
| Unrecognised `blockTransports` entries | **PASS** — two-tier warning |
| 24 h soak, day 2 | **PASS** |
| Input-scope retry path (`retry N/5`) | **Never triggered** — needs a device that publishes its input scope late |

### Observations from the Bluetooth tests

- The headset's transport really is `blue`, matching the default block list.
- Its **input and output objects arrive as separate events ~16 ms apart**, and which one appears
  "new" varies between connections. On one reconnect only the output object was new.
- macOS was observed setting the default input to the headset **9 ms before its input object was
  published at all** — the HFP-lag scenario, caught live.
- Flip-back intervals across three runs: **406 ms, 436 ms, 463 ms.** macOS re-takes the default
  roughly 0.4 s after our write, consistently.
- Continuity iPhone Mic reports transport `ccwd`, not `Unknown` as originally assumed. It is not
  on the block list, so behaviour is unaffected.

### Output non-interference, confirmed

With the headset connected, `system_profiler`:

```
default output:        AirPods Pro 3
default system output: AirPods Pro 3
default input:         <USB mic>
```

---

## Open issue

On 2026-09-10 the agent reported `PINNED` while the default input actually sat on the Bluetooth
headset for approximately 1.5 hours, with **zero log lines** in that window.

Ruled out:

- **Sleep** — `pmset -g log` shows no Sleep/Wake; a keep-awake utility was active
- **`coreaudiod` restart** — running continuously since two days prior
- **Process restart** — `etime` continuous at 01-00:18
- **Work-queue deadlock** — SIGHUP responded instantly and reverted
- **Dead `'dIn '` listener** — fired correctly in a test immediately afterwards

Not explained. A dropped notification is the remaining hypothesis and cannot be confirmed.

Three paths that used to give up silently were hardened as insurance — not as a confirmed fix:

1. `defaultInputDevice()` returning nil caused a silent `return` in two places, consuming the
   event with nobody retrying → now logs and re-evaluates once after 2 s.
2. The debounce had no upper bound; notifications arriving faster than `debounceMs` could defer
   `evaluate()` indefinitely → now forces evaluation 1 s after the first notification.
3. A single re-evaluation 5 s after any revert, giving a second look while evidence is still
   inside the arrival window.

All three are one-shot and self-cancelling, so idle timers stay at zero (`idlew` = 1 confirmed
after deployment).

**Practical impact is limited but real.** `cpal` resolves the device when push-to-talk is
pressed, so a gap with no recording in it costs nothing. The failure mode is *the first
recording after such a gap*. `micpeg status` detects it — `state: PINNED` with a `default input`
that is not the target — and `micpeg on` fixes it immediately.

The soak script now fails on exactly that mismatch. A once-daily sample is a weak net for a
1.5-hour event, but it costs nothing.

---

## Reproducing these checks

```sh
L="gui/$(id -u)/com.micpeg.agent"
P=$(launchctl print "$L" | awk '/pid = /{print $3; exit}')

footprint -p "$P" | tail -3                       # phys_footprint
vmmap -summary "$P" | grep -E "Physical footprint|Writable regions"
top -l 2 -s 5 -pid "$P" -stats pid,command,cpu,time,idlew   # idle wakeups (2nd sample)
sudo fs_usage -w -f filesys | grep micpeg         # expect zero syscalls while idle
```

Listener liveness cannot be checked at rest — an idle daemon with dead listeners looks exactly
like a healthy one. Provoke an event: unplug and reconnect the mic, or select a different input
in System Settings, and watch `~/Library/Logs/micpeg.log` for a transition line.

24-hour soak: see [`../scripts/leakcheck.sh`](../scripts/leakcheck.sh) for the arming command.

---

## The settings app

Recorded stage by stage as the build order in [`app-design.md`](app-design.md) is worked
through. Same rule as everything above: measured on this machine, not taken from documentation.

### Stage 1 — the `MicpegAudio` extraction and the three CLI changes

The extraction moves twelve read-only helpers out of `main.swift`. Its risk is not that the
code stops compiling but that the daemon goes *quiet*: `addr()` now comes from another module,
and an agent whose listeners never registered is indistinguishable from one with nothing to do.
So all three listeners were provoked rather than assumed.

| Test | Result |
|---|---|
| `micpeg list` and `micpeg status`, before vs. after the extraction | **PASS** — byte-identical |
| Dynamic dependencies (`otool -L`), before vs. after | **PASS** — unchanged; the library links statically |
| Universal build and deployment target | **PASS** — x86_64 + arm64, `minos 12.0` unchanged |
| `'dIn '` liveness — default input moved to the built-in mic | **PASS** → `YIELDED`; `micpeg on` reverted it |
| `'dev#'` liveness — Bluetooth headset connected | **PASS** — arrival logged, reverted 11 ms later |
| `'srst'` liveness — `sudo killall coreaudiod` | **PASS** — re-registered in process |
| `micpeg pick <uid>` round trip against the live daemon | **PASS** — applied in both directions |
| `pick` refusals: unresolvable UID, two output-only devices | **PASS** — config left untouched |
| Bundle guard on `install` / `uninstall` | **PASS** — refused from inside a bundle *and* through a PATH symlink |
| Read-only commands from inside a bundle | **PASS** — `status` and `list` unaffected |
| `micpeg link`: regular file, `--force`, re-link, dangling link, directory | **PASS** ×5 — a directory is refused even with `--force` |
| `scripts/invariants.sh` with each violation injected in turn | **PASS** — all four checks fail when they should |

Observations worth keeping:

- The headset published its output and input objects **3 ms apart** here, against ~16 ms
  measured earlier. Output still came first; the gap is not a constant, which is another reason
  the classification does not rest on timing.
- Killing `coreaudiod` produced `PINNED -> ABSENT` for **3.4 s** — while the HAL is down the
  target genuinely does not resolve — and `'srst'` then recovered it. **The daemon's pid did not
  change**, so that was in-process recovery, not a launchd relaunch.
- `micpeg link` replaced the very path launchd runs the agent from, while the agent was running,
  with no restart and no missed event: the running process holds its inode, and launchd re-reads
  the path only when it starts the program again.

### Two findings that change the app's design

**1. `Bundle.main` cannot answer "am I inside an app bundle?" once the CLI is on `PATH`.**

| How the helper was run | `Bundle.main.bundlePath` | `Bundle.main.executableURL` |
|---|---|---|
| `…/Fake.app/Contents/MacOS/micpeg`, directly | `…/Fake.app` | the helper itself |
| through a symlink in `~/.local/bin` | **the symlink's directory** | **the symlink** |
| `…/Fake.app/Contents/Helpers/micpeg`, directly | `…/Contents/Helpers` | the helper itself |

A bundle check that skips symlink resolution therefore misses exactly the case the guard exists
for — a user with the bundled CLI on their `PATH` running `micpeg install`. Resolving first
(`resolvingSymlinksInPath()`) gives the real path in every case above, and `_NSGetExecutablePath`
agreed with `Bundle.main.executableURL` throughout, so no lower-level call is needed.

Note also that `Bundle.main.bundlePath` is the *enclosing* bundle only for a helper in
`Contents/MacOS`; one in `Contents/Helpers` reports its own directory. Neither is a reliable
"which app am I in" answer.

**2. `Contents/MacOS/Micpeg` and `Contents/MacOS/micpeg` are one file on a stock Mac.**

The boot volume is case-insensitive APFS, which is the macOS default. Creating both names in one
directory yields a single entry:

```
115619559  Contents/MacOS/micpeg
115619559  Contents/MacOS/Micpeg     ← same inode; the directory holds one file
```

So the bundle layout in `app-design.md` cannot be assembled as written: whichever executable is
copied second silently overwrites the first, and the app bundle ends up with the wrong program
as its main executable. The names have to differ by more than case. Not yet decided — it belongs
to stage 2.

**Not tested, and still open:** `HOME` cannot be used to redirect the CLI's paths for testing —
`NSHomeDirectory()` resolves through `getpwuid`, so `~/.config/micpeg` and `~/.local/bin` always
mean the real ones. Any future test that writes there has to back up and restore instead.

### Stage 2 — the bundle, `SMAppService`, and the agent plist

Built with `scripts/bundle.sh`, signed with an Apple Development certificate (agents need a
signature; only LaunchDaemons need notarization — `SMAppService.h`), copied to
`/Applications`, and exercised from there rather than from a build directory.

| Check | Result |
|---|---|
| Both executables are universal, `minos 14.0` | PASS — `x86_64 arm64` for `MicpegApp` and `micpeg` |
| `Contents/MacOS` holds two distinct files | PASS — the collision guard in `bundle.sh` |
| `codesign --verify --strict` | PASS — "valid on disk", "satisfies its Designated Requirement" |
| The app carries `com.apple.security.device.audio-input` | PASS |
| The daemon carries **no** entitlements | PASS — `codesign -d --entitlements -` returns nothing |
| `spctl --assess` | rejected, as expected for a development certificate. Stage 5 concern |
| `BundleProgram` resolves | PASS — see below |
| The agent runs from inside the bundle and pins | PASS — `PINNED`, `state.json` written, pid from `Contents/MacOS/micpeg` |
| Registration survives replacing the app in place | PASS — see below |
| Registration survives moving the app | **FAIL** — a Finder move deletes the BTM records outright |
| Deleting the app tears the agent down | partly — the records go, the launchd job and the running daemon stay |
| A legacy agent under the same label makes the conflict loud | **FAIL** — it is completely silent |
| The daemon still logs | fixed during this stage — see below |
| `.requiresApproval` is reachable | **yes**, and it is **not** recoverable in code — see below |
| The app or the daemon ever needs an administrator password | **never** — see below |

`BundleProgram` itself works exactly as documented. With the app at `/Applications`,
`launchctl print gui/$UID/com.micpeg.agent` reports:

```
path = (submitted by smd.35003)
type = Submitted
managed_by = com.apple.xpc.ServiceManagement
program identifier = Contents/MacOS/micpeg (mode: 2)
parent bundle identifier = com.micpeg.app
arguments = { micpeg, daemon }
```

`ProgramArguments[0]` is not used as a path — `micpeg`, `anything` and a path naming a file
that does not exist all produced a running daemon. It is argv[0] and nothing more.

**`EX_CONFIG` (exit 78) is launchd's answer whenever it cannot realise the job**, and it came
up in three unrelated ways during this stage: a `StandardErrorPath` it could not open, a
bundle-relative program whose bundle had moved, and one whose bundle had been deleted. It
is worth recognising on sight; nothing else in this project produces it.

Replacing the app in place is fine. `ditto build/Micpeg.app /Applications/Micpeg.app` over a
registered, running agent, followed by a restart, brought the daemon back from the new copy
with no `register()` call — `PINNED`, fresh `state.json`. `SMAppService.h` recommends
re-registering after an update anyway, and stage 3 will, but the failure it warns about did
not occur here.

Note for any future test: `ThrottleInterval 60` means `launchctl print` reports `minimum
runtime = 60`, and a daemon killed before it has run a minute will sit at `spawn scheduled`
for the remainder. Two tests in this stage first looked like failures for that reason.

#### 1. The shared label does not make the conflict loud. It makes it silent.

`app-design.md` argued that reusing `com.micpeg.agent` is safe because "launchd refuses the
second bootstrap and the conflict is loud instead of silent". Measured, with the legacy
hand-written agent bootstrapped and running:

```
status before: enabled          ← nothing had ever been registered from the bundle
register(): returned without throwing
status after:  enabled
launchd:  path = /Users/…/Library/LaunchAgents/com.micpeg.agent.plist
          program = /Users/…/.local/bin/micpeg
          pid = 21738           ← unchanged; the legacy daemon, from the legacy path
btm:      Generation: 12        ← unchanged; the registration recorded nothing
```

No error, no exception, no change. Worse than silent: `status` reports `.enabled` **about the
legacy agent**, because Background Task Management keys its record on the label
(`8.com.micpeg.agent`), not on the bundle. An app that trusts `register()` and `status` would
tell the user the agent is running while what is running is the old binary at the old path —
and would keep saying so after an uninstall of the app.

The conclusion is not that the shared label is wrong; it still prevents two daemons fighting.
It is that **the conflict has to be detected by the app, on disk, before registering.**
`SMAppService.statusForLegacyPlist(at:)` exists for exactly this and takes a
`~/Library/LaunchAgents` URL. Migration is therefore not a convenience — it is the only thing
standing between an upgrading user and an app that lies to them.

It also means **`SMAppService.status` is not a liveness check.** The honest check is the one
the app already has a reason to do: watch `state.json` and confirm its `updated` timestamp
moves after registration. That is an end-to-end proof that the agent ran; the registry lookup
is not.

#### 2. Moving the bundle destroys the registration, and moving it back does not restore it

`SMAppService.h` says `BundleProgram` "allows apps to support a user relocating the app bundle
after installation". It does not, in either kind of move.

**Shell `mv`.** The registration survives but is pinned to the path it was made at:

```
mv /Applications/Micpeg.app ~/Applications/Micpeg.app
pkill -x micpeg
→ 120 s later:  state = spawn scheduled,  last exit code = 78: EX_CONFIG,  job state = spawn failed
```

Moving the bundle back and restarting recovered it with no `register()` call.

**Finder move** — the one a user actually performs — is worse. Dragging
`/Applications/Micpeg.app` to `~/Downloads` in Finder **deleted both Background Task
Management records**:

```
sfltool dumpbtm | grep -ci micpeg      → 0        (97 records for other apps, so the tool is fine)
SMAppService.status                    → notFound
```

Nothing then appears in System Settings → Login Items & Extensions, which is how this was
found: there was no Micpeg row to switch off. Moving the bundle back to `/Applications` and
waiting restored **nothing** — still 0 records, still `.notFound`.

**And the launchd job outlives the records.** After the purge, `launchctl print` still showed
the job `running` on its old process, carrying a `BTM uuid` that no longer existed anywhere.
A plain `register()` from that state created a fresh BTM record but left the broken job in
place, so the next spawn failed with `EX_CONFIG` and the machine had no daemon at all. The
sequence that actually repairs it:

```
unregister()      → the launchd job disappears (verify: launchctl print returns nothing)
register()        → new job, BTM uuid matching the new record, daemon running
```

The first `unregister()` attempt, made while `status` was `.notFound`, did nothing — there was
no record for it to act on. It only worked after a `register()` had recreated one. **Any
recovery path has to check `launchctl print`, not the return value of `unregister()`.**

#### 3. Deleting the app: the teardown is real, but it is not immediate

The Trash test earlier in this stage looked like the record survived deletion:

```
Finder → move /Applications/Micpeg.app to the Trash
  daemon still running after 30 s          (it holds its own inode)
  pkill -x micpeg
  → state = spawn scheduled, last exit code = 78: EX_CONFIG
  → BTM record still present, still enabled, Generation unchanged
```

The Finder-move result above supersedes that reading. Background Task Management **does** drop
its records once the bundle is no longer at the path it registered from — the 30-second
observation was simply too early. What remains true, and matters:

- The running daemon is not killed. It keeps going on its own inode until something stops it.
- The **launchd job is not removed with the records**, so a stale, unspawnable job is left
  behind. That orphan is what `app-design.md` credited `SMAppService` with preventing.

#### A note on what BTM records

`Executable Path` in the BTM entry is exactly the plist's `BundleProgram`, verbatim
(`Contents/MacOS/micpeg`). An earlier dump in this session read `MacOS/micpeg`; that was left
over from a deliberately wrong variant used while narrowing down the spawn failure, not a
normalisation the system performs.

#### 4. The bundled agent has no log at all

The daemon writes its log with `fputs(…, stderr)` and nothing else (`main.swift:31`). The file
at `~/Library/Logs/micpeg.log` exists only because the hand-written LaunchAgent sets
`StandardErrorPath`. A plist that ships inside the bundle cannot do that, because it is built
before the user exists:

| `StandardErrorPath` | Result |
|---|---|
| `~/Library/Logs/micpeg-tildeprobe.log` | `stderr path = ~/Library/…` kept literally; **exit 78 `EX_CONFIG`, the job never runs** |
| `/Users/<user>/Library/Logs/micpeg-tildeprobe.log` | exit 0, the file is written |

launchd does not expand `~`, and it does not fail softly about it — the whole job is refused.
With the key omitted, the agent runs and its diagnostics go nowhere:

```
$ lsof -p <daemon> -a -d 0,1,2
micpeg  …  0r  CHR  3,2  /dev/null
micpeg  …  1u  CHR  3,2  /dev/null
micpeg  …  2u  CHR  3,2  0t324  /dev/null     ← 324 bytes of startup log, discarded
```

`~/Library/Logs/micpeg.log` keeps the timestamp of the last legacy run. The project's rule is
that a quiet log proves nothing; here there is no log to be quiet. The stage 4 "recent
activity" panel would have nothing to read, and `tail -f ~/Library/Logs/micpeg.log` — which
`CLAUDE.md` and the README both tell people to run — would show a file frozen at the moment
they installed the app.

**Resolved by making the daemon open its own log.** `redirectStderrToLogIfDiscarded()` runs at
the top of `cmdDaemon()` and re-points fd 2 at `~/Library/Logs/micpeg.log` — but only when fd 2
is *literally* `/dev/null`, tested by comparing `fstat(2)`'s `st_rdev` against `stat("/dev/null")`
rather than by `isatty()`. `isatty()` would have been wrong twice over: it also reports false
for a pipe and for a file the user redirected to, and stealing either of those would break the
debugging path that found the CoreAudio traps in the first place.

Verified on all three inputs:

| fd 2 at start | Log went to | `~/Library/Logs/micpeg.log` touched |
|---|---|---|
| a pty | the pty | no |
| a file, from `micpeg daemon 2>somewhere` | that file | no |
| `/dev/null` | `~/Library/Logs/micpeg.log` | **yes** |

The redirected case announces itself in the file it just opened, which is the only place the
notice could be read from:

```
22:13:03.580 stderr was /dev/null — logging to /Users/…/Library/Logs/micpeg.log
22:13:03.638 listeners registered: dev# dIn  srst
22:13:03.639 ABSENT -> PINNED: startup
```

The file is opened `O_APPEND` so that `truncateLogIfLarge()` cannot leave the descriptor
writing past a hole. This is the only change made to the daemon during stage 2.

#### 5. `.requiresApproval` is reachable, and code cannot get out of it

Switching Micpeg off under System Settings → General → Login Items & Extensions → Allow in the
Background:

```
SMAppService.status                              → requiresApproval
launchctl print gui/$UID/com.micpeg.agent        → nothing; the job is gone
micpeg status                                    → daemon: not loaded
launchctl print-disabled gui/$UID                → "com.micpeg.agent" => enabled   ← misleading
```

Note the last line: launchd's own disabled list still says `enabled`, so it is not a usable
check for this state either.

`register()` from there throws, and an `unregister()` first does not help:

```
register()                    → SMAppServiceErrorDomain code=1, "Operation not permitted"
unregister(); register()      → notRegistered, then the same throw, then requiresApproval again
```

So the user's decision is sticky and only reversible where they made it. The app's only correct
response is to say so and offer `SMAppService.openSystemSettingsLoginItems()`. Note also that
code 1 is **not** in `SMErrors.h`, whose enum starts at `kSMErrorInternalFailure = 2`, and the
domain is `SMAppServiceErrorDomain`, which is macOS 15+. Do not present either to a user.

#### 5b. Re-enabling the item in System Settings restores everything

Switching Micpeg back on under Login Items:

```
SMAppService.status                → enabled
launchctl print                    → state = running, program identifier = Contents/MacOS/micpeg (mode: 2)
lsof -p <daemon> -a -d 2           → /Users/…/Library/Logs/micpeg.log      ← the daemon's own redirect
```

And the agent is not merely loaded — the listeners are alive under `SMAppService`, proved by
provoking a real event rather than reading a quiet log. Moving the default input to the
built-in microphone behind the daemon's back, then `micpeg on`:

```
22:18:05.317 ABSENT -> PINNED: startup
22:18:38.572 PINNED -> YIELDED: user chose MacBook Pro Microphone [bltn] — respecting
22:18:45.982 SIGHUP — reloading config
22:18:45.998 REVERT -> Elgato Wave:1 (SIGHUP, displacing MacBook Pro Microphone [bltn])
22:18:45.998 ABSENT -> PINNED: SIGHUP, displacing MacBook Pro Microphone [bltn]
```

`'dIn '` fires, the state machine judges, the CLI inside the bundle reaches the daemon over
SIGHUP, and the revert lands — all of it recorded in a log file that only exists because the
daemon opens it itself.

#### 6. Nothing micpeg ships ever needs an administrator password

Worth stating because this stage produced a great many password prompts, and none of them came
from micpeg. Every authorization request in a two-hour window, by client:

| Right | Client | Times |
|---|---|---|
| `system.privilege.admin` | `/usr/bin/sfltool` | 26 |
| `system.privilege.admin` | `backgroundtaskmanagementd`, on sfltool's behalf | 26 |
| `com.apple.ServiceManagement.daemons.modify` | `/usr/libexec/mdmclient` | 16, uid 0, no prompt |

`micpeg`, `MicpegApp` and `smd` appear **zero** times. Registering a LaunchAgent through
`SMAppService` is a per-user operation and needs no authorization at all; only LaunchDaemons
would, which is one more reason this project registers an agent.

The 26 prompts were all `sfltool dumpbtm`, run as a diagnostic while narrowing down the
findings above. It requests `system.privilege.admin` **once per invocation** — the credential is
not cached between runs, so 26 invocations produced 26 dialogs. It is not part of the product
and must not be part of a routine workflow.

Unprivileged substitutes cover everything it was used for:

| Question | Unprivileged answer |
|---|---|
| Is the agent registered, and to what? | `launchctl print gui/$UID/com.micpeg.agent` — program identifier, pid, exit code, BTM uuid |
| What does ServiceManagement think? | `MicpegApp status` — this is the one that reported `notFound` when `launchctl` still showed a stale job |
| Is the daemon actually doing its job? | `micpeg status`, and the `updated` timestamp in `state.json` |

Reach for `sfltool dumpbtm` only when the record's own contents are the question — its
`Disposition`, `Generation`, or the path it recorded — and expect a password each time.

#### One failure that could not be reproduced

The first `register()` after removing the legacy install failed with `EX_CONFIG`, and so did
the next attempt; a third `unregister()` + `register()` cycle succeeded, and the same shipping
plist has worked on every attempt since. Re-creating the legacy install and repeating the
sequence did **not** reproduce it — by then a ServiceManagement-owned BTM record existed,
where the first time there was only a `Type: legacy agent` record left over from the
hand-written plist. Forcing the machine back to that state means `sfltool resetbtm`, which
wipes every background item for every app on the system, so it was not run.

Treat it as: **the first registration after a legacy uninstall may fail, and an
`unregister()` + `register()` cycle clears it.** Stage 3 should do that cycle unconditionally
and verify through `state.json` rather than through the return value.

---

### Stage 3 — migration from the legacy install

Exercised on macOS 26 (Darwin 25.6.0) with the app at `/Applications/Micpeg.app`, signed with
an Apple Development certificate. Two states were built on purpose and then measured: a
genuine legacy-only machine (the hand-written LaunchAgent bootstrapped, running
`~/.local/bin/micpeg`, no app registration anywhere) and a moved-bundle machine. The commands
are the ones the app itself runs — `MicpegApp survey | migrate | repair | link` — so every
line below is reproducible without clicking anything.

| Check | Result |
|---|---|
| The app detects a legacy LaunchAgent on disk | PASS — from the file, not from the API |
| `SMAppService.status` can be trusted to tell the app apart from a legacy agent | **FAIL** — it reported `.enabled` for an app that had never registered |
| `statusForLegacyPlist(at:)` answers about the legacy plist | **FAIL** — it answers about the label. It reported `enabled` for a plist launchd was ignoring |
| Teardown before registration works | PASS — `bootout` status 0, plist removed, job gone, then a new pid from the bundle |
| The pinned device survives the upgrade | PASS — `config.json` byte-identical, and enforced by a CI check |
| `proc_pidpath` alone can detect a moved bundle | **FAIL** — a shell `mv` carries the inode, so the survey read HEALTHY while the registration was broken |
| The app's own record detects a moved bundle | PASS — the same state now reads `MOVED`, in both directions |
| `repair()` recovers a job that is `spawn failed` with `EX_CONFIG` | PASS |
| launchd repairs a broken registration on its own | **no** — 70 s of `spawn failed`, no recovery |
| Writing the legacy plist can resurrect an unregistered agent | **yes** — with no `launchctl bootstrap` at all |
| `micpeg install`/`uninstall` are refused through the PATH symlink | PASS |

#### 7. `statusForLegacyPlist(at:)` answers about the label, not about the plist

`app-design.md` said this API "exists for this". It does not. `SMAppService.h`:

> This API is intended for apps that are **unable to adopt** the new daemon and agent packaging
> guidelines but still want to know when a user disables its legacy daemons or agents.

It is a monitoring API for apps that are *staying* legacy. There are also reports of it
returning `.notFound` for installed, running services since macOS 14.5
([developer.apple.com/forums/thread/750685](https://developer.apple.com/forums/thread/750685),
no Apple reply). That specific bug did not reproduce here — but a worse one did. Measured, in
order, on one machine:

| State of `~/Library/LaunchAgents/com.micpeg.agent.plist` | `statusForLegacyPlist` |
|---|---|
| absent | `notRegistered` |
| present, genuinely bootstrapped, running `~/.local/bin/micpeg` | `enabled` |
| present, **not** bootstrapped, launchd running the *bundle* instead | `enabled` |
| removed again | `notRegistered` |

The third row is the problem. The API said `enabled` about a plist launchd was ignoring
completely. It is keyed on the label, exactly like `SMAppService.status`, and it inherits the
same lie. **`InstallSurvey` therefore detects the legacy install from the file on disk and
records the API's answer as evidence only.**

#### 8. A legacy plist appearing on disk resurrects an unregistered agent

This was found by accident, while trying to build a legacy-only machine, and it is the
sharpest thing stage 3 measured.

Starting from `unregister()` — job gone, `status` `notRegistered`, confirmed stable for 12 s —
the legacy plist was written to `~/Library/LaunchAgents` **and nothing else was done**. No
`launchctl bootstrap`, no `register()`:

```
t+0s   SMAppService=enabled   statusForLegacyPlist=notRegistered  job=none
t+1s   SMAppService=enabled   statusForLegacyPlist=enabled        job=present
       running_from=/Applications/Micpeg.app/Contents/MacOS/micpeg
```

Within a second there was a running daemon again. Not the one the plist names —
`ProgramArguments[0]` was `~/.local/bin/micpeg` — but the one inside the bundle, under
`managed_by = com.apple.xpc.ServiceManagement`, `program identifier = Contents/MacOS/micpeg`,
and the *same* `BTM uuid` the registration had before it was unregistered. Removing the plist
again left that job running.

Two consequences:

- **The BTM record is not destroyed by `unregister()`.** It keeps its uuid, and a legacy plist
  arriving under the same label is enough to switch it back on.
- **`launchctl bootstrap` of the legacy plist then fails with `Bootstrap failed: 5:
  Input/output error`** — the label is taken. This is what a user running `micpeg install`
  after installing the app would see, and it is why the CLI's bundle guard matters.

The one thing that did *not* happen is the two-daemons-one-label disaster the shared label was
chosen to prevent. On this machine it is not reachable at all: whichever way round it was
tried, exactly one daemon ran.

#### 9. The upgrade shape: `.enabled` for an app that has never registered

The genuine pre-upgrade machine, with the app freshly dragged into `/Applications` and
`register()` never called:

```
legacy plist:      PRESENT — /Users/…/Library/LaunchAgents/com.micpeg.agent.plist
  its program:     /Users/…/.local/bin/micpeg
launchd job:       present — gui/501/com.micpeg.agent
  pid:             63973
  running from:    /Users/…/.local/bin/micpeg
  managed_by:      (absent — not an SMAppService job)
SMAppService:      enabled
verdict:           LEGACY PRESENT
```

`SMAppService: enabled` for an app that has never registered anything. This is stage 2's
finding in the shape a real user would hit it. The two fields that catch it are `managed_by`,
absent for a hand-written job, and the executable path behind the pid.

#### 10. The migration, end to end

```
--- tearing down the legacy LaunchAgent ---
launchctl bootout gui/501/com.micpeg.agent → status 0
removed /Users/…/Library/LaunchAgents/com.micpeg.agent.plist
after teardown: legacy plist gone, launchd job gone, SMAppService enabled
--- registering this bundle ---
register(): returned without throwing
status after register(): enabled
confirmed after 0s: pid 64277 (was 63973) running from /Applications/Micpeg.app/Contents/MacOS/micpeg,
                    state.json written at 2026-09-10 22:55:16
verdict:           HEALTHY
```

Note `after teardown: … SMAppService enabled` — with the plist deleted and the job gone,
`status` still said `enabled`. It is never load-bearing here.

The log shows the handoff, including the legacy daemon's last run and the bundled one opening
its own log because launchd handed it `/dev/null`:

```
22:54:53.325 micpeg starting (pid 63973)          ← legacy, StandardErrorPath
22:54:53.477 ABSENT -> PINNED: startup
22:55:16.157 stderr was /dev/null — logging to /Users/…/Library/Logs/micpeg.log
22:55:16.166 micpeg starting (pid 64277)          ← bundled
22:55:16.326 ABSENT -> PINNED: startup
```

`config.json` was byte-identical before and after (`diff`, no output). The pinned Elgato Wave
survived the upgrade, which is the whole point.

**And the daemon that came out of it is not merely running.** A scratch tool changed the
default input, the way any application can:

```
22:56:08.118 PINNED -> YIELDED: user chose MacBook Pro Microphone [bltn] — respecting
22:56:17.270 REVERT -> Elgato Wave:1 (SIGHUP, displacing MacBook Pro Microphone [bltn])
22:56:17.271 ABSENT -> PINNED: SIGHUP, displacing MacBook Pro Microphone [bltn]
```

#### 11. `proc_pidpath` alone reports HEALTHY for a broken registration

The app cannot ask ServiceManagement where the registration points. `launchctl print` gives
`program identifier = Contents/MacOS/micpeg` — bundle-relative — plus `parent bundle
identifier`; `SMAppService` has no path property at all; and `sfltool dumpbtm`, which does hold
the absolute URL, demands an administrator password, which rules it out of a shipping app.

`proc_pidpath()` on the running daemon's pid is the closest available substitute. It works
across processes of the same user with no privilege and no entitlement, and `ps -o comm=` is
not a substitute for it — that prints `micpeg`, with no path.

It is still not enough. After `mv /Applications/Micpeg.app ~/Applications/Micpeg.app`, run
from the new location:

```
  pid:             64277
  running from:    /Users/…/Applications/Micpeg.app/Contents/MacOS/micpeg
  verdict:         HEALTHY
```

Wrong. The `mv` carried the inode, so the process that was already running reports the *new*
path, and the check passed on a registration that was about to fail. Only the next spawn would
have shown it.

So the app records its own bundle path at the moment it registers, in `UserDefaults` under
`com.micpeg.app`. It is one-way evidence — its absence proves nothing, so it can only take a
healthy verdict away, never grant one. The same move now reads:

```
registered from:   /Applications/Micpeg.app   — NOT where this app is now
verdict:           MOVED — this app registered from /Applications/Micpeg.app and is now at
                   /Users/…/Applications/Micpeg.app; re-register from here
```

`repair()` then fixed it in both directions, each time confirmed by a new pid running from the
current bundle and a `state.json` written after the call.

#### 12. A move sometimes survives, and the app cannot tell which case it is in

Stage 2 recorded "registration does not follow a shell `mv`". Stage 3 observed it following
one. Both are real:

| Move | Result after killing the daemon |
|---|---|
| `/Applications` → `~/Applications` | respawned in 1 s from `~/Applications` |
| `~/Applications` → `/Applications` | `last exit code = 78: EX_CONFIG`, `job state = spawn failed` |

Once broken, it stays broken: **70 seconds of `spawn failed` with the bundle sitting at the
right path and the app having been executed from there.** launchd does not go looking.

Why one direction survived was not chased down, and the answer would not change the code. What
matters is that the app cannot distinguish the two from the outside, which is exactly why the
recorded path exists and why `repair()` is unconditional. `repair()` recovers the broken state:

```
before:  pid = none, last exit code = 78: EX_CONFIG, verdict STALE
after:   pid 68820 running from /Applications/Micpeg.app/Contents/MacOS/micpeg, verdict HEALTHY
```

#### 13. The CLI symlink, and the bundle guard through it

`~/.local/bin/micpeg` was a real copy of the old binary — the legacy install. `MicpegApp link`
runs the bundled CLI's own `link --force`:

```
/Applications/Micpeg.app/Contents/MacOS/micpeg link --force → status 0
  linked /Users/…/.local/bin/micpeg -> /Applications/Micpeg.app/Contents/MacOS/micpeg
CLI on PATH is now: symlink -> /Applications/Micpeg.app/Contents/MacOS/micpeg
```

The migration only ever *offers* this. It is the user's file, and replacing a binary they
installed themselves, unasked, is how an upgrade silently breaks a working setup.

With the symlink in place, the guard added in stage 1 was testable for the first time through
the path it was written for, and it holds:

```
$ micpeg install
error: this copy of micpeg lives inside Micpeg.app, which registers the
       background agent itself. …
$ echo $?
1
```

Both `install` and `uninstall` are refused, and `~/Library/LaunchAgents` stayed empty.

#### What stage 3 did not do

`repair()` is not run automatically when the app launches. The app surveys on launch and shows
the verdict, and repairing is a button. Doing launchd surgery as a side effect of opening a
window, with no interface yet to say what happened, is a stage 4 decision and should be made
there deliberately rather than inherited from a test harness.

---

### Stage 4 — the interface

Built as `Sources/MicpegUI` (a library target, so previews can build it) plus a thin
`MicpegApp`. Verified on the running, signed app in `/Applications`, not in a build directory.

The window was inspected through the accessibility API rather than by looking at it — the same
discipline as everywhere else in this project, and it turned out to be the only way to catch
two of the defects below. `MicpegApp meter` prints the numbers behind the level meter for the
same reason.

| Check | Result |
|---|---|
| The window builds its state from real files and devices | PASS — Output/Input rows, summary sentence and activity all rendered from the live machine |
| The window updates while it is open | PASS — device change reflected in the Input row, the summary and the activity list, with no relaunch |
| A `state.json` watcher survives the daemon's atomic writes | PASS — but only by watching the directory. The file-descriptor watch went deaf after one write |
| Daemon vocabulary never reaches the window | PASS — no `PINNED`/`YIELDED`/`BACKOFF` in the accessibility tree |
| Buttons and headings carry accessible names | PASS — SwiftUI publishes them as `AXDescription`, not `AXTitle` |
| The level meter is hidden from assistive technology | PASS — absent from the tree |
| Microphone permission is requested at Start Test, never at launch | PASS — TCC created the record on the first press |
| `AVAudioEngine` recovers from a device change mid-test | PASS |
| The silence hint fires only when nothing is arriving | **FAIL, then fixed** — the first threshold called a working microphone silent |
| The device list offers only real microphones | **FAIL, then fixed** — the app's own input test conjured an aggregate device into the picker |
| The window sizes to its content | **FAIL, then fixed** — a `Form` is a scroll view |
| SwiftUI previews build against a SwiftPM library target | PASS as far as a command line can tell — see below |

#### 14. The obvious file watcher is the broken one

CLAUDE.md lists "a `state.json` watcher that dies on the first atomic write" as one of this
app's silent failures. It is real, and it was measured rather than assumed. Both watchers ran
against the same directory while five atomic writes were made:

```
atomic writes performed:         5
directory watch callbacks:       6      (one on attach, then one per write)
file-descriptor watch callbacks: 1
```

The daemon writes with `Data.write(to:options:.atomic)` — a temporary file and a rename — so a
`DispatchSource` attached to the file's descriptor keeps that descriptor open on an inode that
is no longer at the path. It reports once and then never fires again. Nothing crashes and
nothing is logged; the window simply keeps showing whatever it read at launch.

`DirectoryWatch` watches the enclosing directory, where a rename is an ordinary write, and
re-reads from the path.

#### 15. The level meter's threshold was calibrated against a working microphone, badly

`MicpegApp meter` opens the default input for a few seconds and reports what arrived:

| Device | Buffers | Peak RMS | Mean RMS |
|---|---|---|---|
| Elgato Wave, quiet room | 41 in 4 s | 0.00218 | 0.00170 |
| Elgato Wave, sound playing | 52 in 5 s | 0.00334 | 0.00208 |
| MacBook Pro Microphone, lid closed | 83 in 8 s | **0.00000** | **0.00000** |

The first threshold was `0.01`, and the window told a working microphone in a quiet room that
no sound was reaching it — the precise false alarm the hint exists to prevent. A room's noise
floor is thousandths. A device delivering nothing is exactly zero. The threshold now sits in
that gap at `0.0005`.

The third row is not a fault. With the lid shut and an external display driving the Mac, the
built-in microphone is still listed, still unmuted (`kAudioDevicePropertyMute` = 0), still
reports an input volume of 0.41 — and delivers buffers of zeros. `AVAudioApplication.shared
.isInputMuted` is `false` throughout. So the hint now names that cause first when the silent
device is the built-in one; sending the user to hunt for a mute switch would have been wrong
every time.

The meter's own curve changed with it. A cube root put a silent room a fifth of the way up the
bar; it is now the ordinary decibel mapping with a −60 dBFS floor.

#### 16. The app's own input test put a fake device in the picker

With the input test running, the device sheet offered:

```
MW's iPhone Microphone, ccwd
Elgato Wave:1, usb
MacBook Pro Microphone, bltn
CADefaultDeviceAggregate-88269-1, grup      ← not a microphone
```

The HAL publishes a transient aggregate device while any application holds the default input
open, and it has an input scope, so it passed every filter the list had. It disappeared when
the test stopped — which is why nothing showed it until the sheet and the test were open at the
same time. Any application using the microphone produces one; this is not specific to micpeg.

`kAudioDevicePropertyIsHidden` is not the discriminator: every input device on this machine
reports `0`, the aggregate included. Aggregate-transport devices are now excluded from the
window's list. That hides a deliberately built Aggregate Device too, which is the right trade
for this audience and is not a dead end — `micpeg list` still shows them and `micpeg pick <uid>`
still pins one.

#### 17. Two measurement artifacts that were not defects

Worth recording so they are not "fixed" later.

**Buttons appeared to have no accessible name.** AppleScript's `title of` returned
`missing value` for every button, which reads as a serious accessibility defect. It is not:
SwiftUI publishes a button's label as `AXDescription`. Read with the accessibility API
directly, the tree carries `Start Test`, `Change Microphone`, `Pause` and a `Recent activity`
heading. The same mistake hid the whole device sheet, whose rows are `AXOutline` → `AXRow` →
`AXCell` → `AXButton` and were simply below the depth the first dump printed.

**The window looked like it was scrolling.** Scrollbar increment and decrement buttons in the
accessibility tree are what a `Form` produces on macOS whether or not its content overflows.
The content did fit. `.scrollDisabled(true)` is still correct — app-ui.md asks for a window
fixed to its content size — but the scrollbars were not evidence of a problem.

#### 18. What the interface was measured doing

Live, on the machine, with the window open and untouched throughout:

```
                     Input row              Summary
before               Elgato Wave:1          Elgato Wave:1 stays your microphone.
another app steals   MacBook Pro Microphone You chose MacBook Pro Microphone, so Elgato
                                            Wave:1 is not being restored. Choosing Elgato
                                            Wave:1 again resumes it.
micpeg on            Elgato Wave:1          Elgato Wave:1 stays your microphone.
```

and the activity list, translated out of the daemon's vocabulary:

```
Moved your microphone back to Elgato Wave:1 from MacBook Pro Microphone.
You chose MacBook Pro Microphone, so Micpeg stepped aside.
Selected Elgato Wave:1.
```

Pause writes `enabled: false` through the CLI, the button becomes `Resume`, and the summary
becomes "Micpeg is paused. Your microphone can change freely." Resume reverses it. Stopping the
test releases the microphone; the app writes nothing to its own stderr in a whole session.

#### 19. Previews, as far as a command line can prove it

`#Preview` in the library target expands to `DeveloperToolsSupport.PreviewRegistry`
conformances carrying `fileID` and `line` — which is exactly what Xcode's canvas discovers:

```
struct $s8MicpegUI…PreviewRegistryfMu_: DeveloperToolsSupport.PreviewRegistry {
    static var fileID: String { "MicpegUI/MainWindow.swift" }
    static var line: Int { 299 }
```

Three previews registered. The canvas itself cannot be driven from a shell, so "the preview
renders" remains unverified; the structural prerequisite — a library target, not an
`executableTarget` with `@main` — is confirmed.

#### A note on Apple's guidance

`app-ui.md` requires fetching Apple's current documentation rather than implementing from
recollection. The API halves were read from the SDK Apple ships: `SwiftUI.swiftinterface` and
`SwiftUICore.swiftinterface` for `Form`, `LabeledContent`, `GroupedFormStyle`,
`windowResizability`, `scrollDisabled` and `Canvas` (`macOS 12.0`, so fine at this deployment
target), and `AVAudioEngine.h` / `AVAudioNode.h` / `AVAudioApplication.h` for the audio.

Three facts came from those headers and shaped the code:

- "the engine stops itself and issues this notification" on a configuration change — a device
  change does not merely disturb the meter, it ends the session.
- "the engine must not be deallocated from within the client's notification handler because
  the callback happens on an internal dispatch queue and can deadlock" — the handler does
  nothing but hop to the main actor.
- "Only one tap may be installed on any bus."

**The Human Interface Guidelines could not be fetched.** developer.apple.com/design renders its
prose in JavaScript and the DocC JSON endpoint returns 404, so nothing quotable was obtained;
search results for margins and spacing are all pre-2022 HIG numbers and were not used. The
exposure is contained by app-ui.md's own instruction — "Let `Form` supply the inner rhythm; do
not add manual padding between its rows" — which is followed literally: the window sets one
width and no margins or inter-row spacing anywhere.

#### 20. What a cleanup review found afterwards

Four of these were behavioural, not tidiness.

**The window could not report a failure.** `ActivityLog` classified log lines by matching a
list of hopeful prefixes, and the daemon's `REVERT FAILED`, `RE-VERIFY FAILED`, `FATAL:` and
two `WARNING:` lines matched none of them. Every one was dropped in silence, so the single most
important thing that can happen — micpeg tried to put the microphone back and could not — left
no trace in the feature built to report it. The parser now reads the log's grammar
(`<FROM> -> <TO>: <reason>`, with both sides resolved against `DaemonState.Kind`) and puts
everything that is not a transition into an explicit bucket. Measured against the real log and
against synthesised failure lines: 980 lines → 77 events, and all five failure shapes now
classify.

**A corrupt settings file showed the onboarding screen.** `PinnedConfig.ReadResult` exists to
separate "no file" from "a file that does not parse" — its own comment says the window "must
not offer to set things up as if nothing were there" — and the window then flattened both to
"unconfigured" and offered exactly that. `.settingsUnreadable` is now its own body state.

**The window told a user their microphone was not being kept before they had chosen one.** The
suppression was a guard bolted onto one condition; the other three leaked. It is now one rule
applied once.

**"The background helper isn't running" was said about a helper that was running.**
`.foreignBundle` — another copy of Micpeg holding the label — was folded in with the genuinely
broken states, so the window claimed nothing was running and offered a Reconnect button that
would have started a fight between two copies of the same app. It has its own condition and
says where the other copy is.

Three smaller things were measured rather than argued: a `DispatchSource` on `state.json`'s own
descriptor is deaf after one write (already known, now shared through one `Coalescer` instead
of two copies); the window's three debounce delays each re-derived the same measured fact and
one of them, at 0.15 s, could not merge the 400 ms pair its comment said it existed to merge;
and `MicpegApp meter` and the window's meter ran two separate copies of the AVAudioEngine
setup, which made "the diagnostic exercises the same tap" a promise rather than a fact. All
three now come from one place.

#### 21. What a correctness review found after that

Three of these could put the microphone in a state the user could not get out of.

**Two presses of Start Test could leave the microphone open with no way to close it.** The
`guard !isRunning` ran before the asynchronous permission callback, and `isRunning` is only set
inside it, so a double press — or a press while the TCC prompt is up — reached `reallyStart()`
twice. The second overwrote the engine, the observer and the 30 Hz timer with no teardown, so
`stop()` could only ever reach the second: the first engine kept its tap installed, with the
system's microphone indicator lit and the Stop button no longer connected to it. A stop issued
*during* the permission request had the mirror problem — it did nothing, and the callback
started anyway.

**Closing a second window blinded the first.** `WindowGroup` gives File ▸ New Window for free
and the model is one `@State` shared by every window, so the first `onDisappear` released the
HAL listeners and the directory watcher for all of them — and `startWatching`'s guard meant
they never came back. The surviving window kept showing what it had last read and stopped
updating, silently. The watchers are reference-counted now.

**A banner could tell someone to delete their home directory.** `.foreignBundle` was turned
into a path by stripping exactly three components, which is right for
`<App>.app/Contents/MacOS/micpeg` and wrong otherwise — and "otherwise" is reachable: remove
the legacy plist by hand without `launchctl bootout` and a daemon keeps running from
`~/.local/bin/micpeg`, which strips to `/Users/<name>`. The copy then read "The copy at
/Users/<name> … delete it and reopen this one." It walks up looking for a `.app` now, and when
there is none it is not another copy of the app at all.

Also fixed: the meter and its Stop button live only in the configured body, so removing
`config.json` mid-test took the control away while the engine ran; `runIfRequested()` treated
*any* first argument as a command and exited with status 2 before a window existed, which an
argument injected by Xcode or `open --args` would have triggered; and the launch survey forked
`launchctl` and made two ServiceManagement round trips on the main thread, blocking the first
frame.

Two invariant lessons. The audio guard grepped for `AVFoundation` while the project's capture
code imports **AVFAudio** — it would have reported ok while the daemon opened a stream. Proved
by injecting `import AVFAudio` plus an `AVAudioEngine` into the daemon: the widened pattern
fails, the old one did not. And the daemon's timestamp formatter sets no locale, so on a Mac
configured for a non-Gregorian calendar it writes a year the app's POSIX parser rejects and
"Recent activity" empties out. The one-line fix is in the daemon and the daemon is finished, so
the app parses with the current locale as a fallback instead.

#### 22. Looking at it

The screen was unlocked and the window opened: 460x483, CPU 0.3% — the 38% spin was the locked
session, which the screenshot settles for good.

**Three things only a screenshot found.**

The window was **clipping its own content**. `.scrollDisabled(true)` had been added on the
theory that a `Form` would then size the window to its content; measured, it does not — the
window stayed at 460x586 and everything past the bottom edge was simply cut off, which was
`Change Microphone` and `Pause`, the only two controls in the window. They were still in the
accessibility tree, which is exactly why the earlier pass passed them: **being in the tree is
not being on screen.** The combination that does size a window to its content is
`.fixedSize(horizontal: false, vertical: true)` *without* `scrollDisabled` — 460x483 collapsed,
growing to 460x819 with the activity list expanded, and scrolling rather than clipping if it
ever exceeds the screen.

The activity section rendered **five rows**. app-ui.md's skeleton says "activity — most recent
daemon action, expandable", which is one. Five is what pushed the controls off the bottom.

The device picker opened with **nothing selected**. Removing the "no selection means the
current input" rule from the list — correctly, it contradicted the sheet's Done button — left
the sheet with no seed of its own, so a user opening "Change Microphone" could not see which
microphone they already had. It opens on the kept device now.

**What was exercised, and what it did.** Pause: the summary became "Micpeg is paused. Your
microphone can change freely.", the button became Resume, `micpeg status` read
`enabled: false`; Resume reversed all three. A device stolen by another program moved the Input
row and the summary and added "Moved your microphone back to Elgato Wave:1 from MacBook Pro
Microphone." to the activity list, with the window open and untouched. Start Test opened the
microphone and the meter ran — three screenshots 0.7 s apart all differed, which is the only
way a still picture can show a meter is live — and Stop released it.

**File ▸ New Micpeg Window exists**, so the multi-window case in the correctness review was
real rather than theoretical: opened a second window, closed it, and the survivor still
followed a device change in both directions. Without the reference count on the watchers it
would have gone quiet.

**A note on a false alarm.** During this pass the app appeared to launch with no window and
spin at 38% CPU. The committed build did the same, which is what identified it: the screen was
locked (`CGSSessionScreenIsLocked = Yes`), and a locked session does not realise a new app's
windows. Nothing was wrong with the code. The window's appearance has not been re-checked on
screen since the cleanup for that reason; everything reachable without a window — the parser
against the real log, `survey`, `meter`, the invariants, the daemon still pinning — has.
