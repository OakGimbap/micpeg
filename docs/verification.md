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
