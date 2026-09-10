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

