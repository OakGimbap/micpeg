<!-- Engineering log, written in Korean during development.
     English summaries: ../design.md (architecture) and ../verification.md (measurements). -->

> **이 문서는 개발 과정의 원본 기록입니다.** 설계 근거, 도중에 발견해 고친 결함, 실기기 검증
> 로그가 시간순으로 남아 있습니다. 결론만 필요하면 [`../design.md`](../design.md)(영문 설계)와
> [`../verification.md`](../verification.md)(영문 실측치)를 보세요.
>
> 기기 식별자(USB 시리얼, Bluetooth MAC, 디스플레이 UID)는 플레이스홀더로 치환했습니다.

# micpin — macOS 기본 오디오 입력 고정 데몬

## 1. Context — 왜 이걸 만드는가

**문제.** macOS는 새 오디오 장치가 연결되면 기본 **입력**과 **출력**을 둘 다 그 장치로 옮긴다.
AirPods Pro 3가 연결되는 순간 기본 입력이 AirPods 마이크로 넘어간다. 사용자는 Elgato Wave:1 USB
마이크를 상시 사용하는데, Claude Code voice mode가 OS 기본 입력을 쓰고 마이크 선택 UI가 없어서
의도치 않게 AirPods 마이크로 녹음된다.

**원하는 결과.** Elgato Wave:1이 연결돼 있는 동안 기본 입력이 항상 Elgato에 남는다.
출력은 평소대로 AirPods가 가져간다. 사용자가 직접 다른 마이크를 고른 경우에는 그 선택을 존중한다.

**사용자가 명시한 제약 (우선순위 순).**
1. **입력만 건드린다.** 출력은 읽지도 쓰지도 않으며, "출력 고정" 옵션도 설계에 넣지 않는다.
2. **최적화가 최우선.** 메모리·CPU·전력 과부하나 다른 OS 동작과의 간섭이 없어야 한다. 기능보다 우선.
3. **수동 선택 존중.** 사용자가 시스템 설정에서 직접 다른 입력을 고르면 되돌리지 않는다.

**환경.** macOS 26.6.2 (Darwin 25.6.0), Apple Silicon arm64, Xcode 26 / swiftc Apple Swift 6.3.3.
Elgato Wave Link 설치됨(미실행, 가상 장치 3개는 HAL 드라이버로 상시 존재). 오디오 관련 LaunchAgent 0건.

## 2. 검토로 확정된 사실

리서치 에이전트 3대가 SDK 헤더·실기기·실제 프로젝트 소스로 검증한 결과. **초안의 결함 2개가 발견됐다.**

**전제 검증 — 이 접근이 실제로 통한다.**
Claude Code의 음성 캡처는 Rust `cpal` + `coreaudio-rs` → CoreAudio AUHAL 직접 호출이다
(`~/.local/share/claude/versions/2.1.263`에서 문자열 확인). 브라우저/Electron 레이어가 없어
`getUserMedia`류 개입 여지가 없고, `cpal`의 `default_input_device()`가
`kAudioHardwarePropertyDefaultInputDevice`를 그대로 읽는다. 마이크 선택 수단은 없다
([공식 문서](https://code.claude.com/docs/en/voice-dictation)의 트러블슈팅도 "시스템 설정에서 기본 입력을
확인하라"가 전부). **자동 전환을 끄는 1st-party 설정도 없다** — `com.apple.coreaudio`,
`com.apple.audio.AudioMIDISetup` 모두 *Domain does not exist*, `defaults domains` 전수 grep에도 억제 키 없음.

**결함 ①  `dispatchMain()`은 리스너를 통째로 죽인다.**
초안은 "`CFRunLoopRun()`보다 가볍다"며 `dispatchMain()`을 골랐는데, 이는 기능을 무력화하는 경로였다.
`AudioHardwareDeprecated.h:193-197`이 HAL은 알림 핸들러를 `CFRunLoopGetMain()`에 붙인다고 명시하고,
`dispatchMain()`은 메인 스레드를 park 하지 않고 **`pthread_exit()`한다**
([Quinn, DevForums 794775](https://developer.apple.com/forums/thread/794775)). 런루프 객체는 남고 아무도
서비스하지 않는다. 자체 큐를 `AudioObjectAddPropertyListenerBlock`에 줘도 소용없다 — HAL이 mach 알림을
먼저 자기 런루프에서 받아야 내 큐로 재디스패치한다. **`'srst'` 복구 리스너도 같이 죽는다** ⇒ 깨끗하게
등록되고 "listening"을 로깅하고 CPU를 안 쓰면서 아무것도 강제하지 않는 데몬이 된다.
*두 에이전트가 독립적으로 같은 수정에 도달: `CFRunLoopRun()`을 쓰고 `kAudioHardwarePropertyRunLoop`는
건드리지 않는다.* NULL 쓰기는 덫이다 — 그 상수는 Deprecated 헤더(`:218`)에 있으면서
`API_DEPRECATED` 어노테이션이 없어(이웃 `kAudioHardwarePropertyProcessIsMaster`는 있음) 컴파일러 경고가
전혀 없는데, "pre-10.6 동작으로 회귀" 서술은 16년 된 문장이고 macOS 26에서 유효한지 미검증이다.

**결함 ②  `coreaudiod`는 일상 중 재시작하고, 리스너는 조용히 죽는다.**
이 머신에서 실증: 부팅 후 **16일**인데 `coreaudiod`는 **2시간 13분 전 재부팅 없이 재시작**했다
(`/Library/Preferences/Audio/com.apple.audio.DeviceSettings.plist` mtime이 같은 분으로 교차 확인).
초안의 "리스너 소멸을 알리는 콜백은 없다"는 전제가 틀렸다 — `kAudioHardwarePropertyServiceRestarted`
(`'srst'`, `AudioHardware.h:573-577, 631`)가 정확히 그 용도다:
*"any state the client has, such as cached data or **added listeners**, must be re-established by the client."*
미처리 시 [BackgroundMusic #126](https://github.com/kyleneideck/BackgroundMusic/issues/126) 양상 →
`kAudioHardwareBadObjectError`(560947818). AppKit 웨이크 훅을 뺀 건 옳았지만 이유가 달랐다 —
`NSWorkspace.didWakeNotification`은 저 10:03 재시작을 못 막았을 것이다. `'srst'` 하나가 재시작과
웨이크 파손을 동시에 덮는다.

**결함 ③  타이밍 기반 자동/수동 판별이 AirPods에서 실패한다.**
AirPods는 **A2DP(출력)가 먼저 붙고 HFP(입력)가 수 초 뒤 완료**된다. 초안의 5초 grace window는 그 사이
만료돼 자동 전환을 "사용자 선택"으로 오판하고 되돌리지 않는다 — 데몬의 존재 이유가 실패한다.
⇒ 1차 판정을 `kAudioDevicePropertyTransportType`으로 옮긴다.
**초기자를 알려주는 신호는 없음이 확정**됐다: `log stream --predicate 'subsystem == "com.apple.coreaudio"'`
6초 → 0줄, `log show --last 30m` → 0줄, 콜백 시그니처에도 initiator 필드 없음. 휴리스틱은 불가피하다.

**기존 도구로는 안 된다.**
`cli-fix-my-mic`는 복귀 대상이 **내장 마이크로 하드코딩**(요구사항과 정반대)이고, `shouldBlockAsInput()`에
`Virtual` 케이스가 없어 `default: true`로 떨어져 **Wave Link 가상 장치 3개와 Continuity iPhone Mic까지
차단**한다. Hammerspoon은 기본 15–25MB에
[수 GB 증가 이슈](https://github.com/Hammerspoon/hammerspoon/issues/3614)가 다수라 제약 2와 충돌.
SoundSource 6은 $49 + HAL 드라이버 설치로 과잉.
**SoundAnchor는 검토 후 기각(사용자 결정)** — 소스 비공개에 공식 사이트 403이라 "출력 목록을 비우면
출력을 안 건드리는가"를 문서로 확정할 수 없고, 메뉴바 상주 앱이라 5–10MB 데몬보다 무겁다. 결정적으로
**`coreaudiod` 재시작 복구를 처리하는지 확인할 방법이 없다** — 검토한 레퍼런스 구현 전부가 그것을 빠뜨렸다.

**상주 데몬이 맞다 (이벤트 트리거 기각).**
`com.apple.iokit.matching`으로 Wave:1 USB 부착을 잡는 건 가능하다(IORegistry에서 `idVendor 4057`/
`idProduct 110` 확인). 그러나 실익이 없다: ① IOKit 매칭은 서비스 publication에만 발화하고 "기본 입력이
바뀌었다"에는 발화하지 않으며, 오디오 장치 변경용 `notify(3)` 이름도 없다(`strings /usr/sbin/coreaudiod`
확인). ② 프로세스 기동 수십 ms로는 이미 끝난 전환을 못 막는다 — 어차피 사후 보정이다.
③ **HAL 리셋 시 실행 중이 아니면 `'srst'`를 소비할 주체가 없다.** 블루투스 스트림
(`com.apple.bluetooth.connections`) 구독은 `xpc_events(3)` 미문서화에 소비자가 전부 Apple 데몬이라,
비특권 에이전트가 선언하면 에러 없이 조용히 못 받을 가능성이 높다.

**기각된 대안:** HAL 플러그인은 가상 장치를 publish할 뿐 시스템 기본값에 관여권이 없다(관리자 설치 필요,
이득 없음). Aggregate device는 모든 앱의 선택기와 `cpal` 열거에서 마이크의 정체 자체를 바꿔버려 **유해**하다.

## 3. 아키텍처

Swift 단일 바이너리 `micpin` — launchd 상주 LaunchAgent와 CLI를 겸한다.
링크 대상은 **CoreAudio + Foundation뿐. AppKit 없음.**

**메인 스레드는 `CFRunLoopRun()`으로 파킹한다.** 타이머도 예약 소스도 없는 CFRunLoop는 포트 셋에서
타임아웃 없이 `mach_msg`에 블록되므로 스핀·폴링·틱이 없다. `DispatchSource.makeSignalSource`(SIGHUP)와
리스너 큐는 libdispatch 워커가 서비스하므로 런루프 의존성이 없다.

`kAudioObjectSystemObject`에 `AudioObjectAddPropertyListenerBlock` **3개** 등록 (전용 serial queue):

| 셀렉터 | 용도 |
|---|---|
| `kAudioHardwarePropertyDevices` (`'dev#'`) | 장치 도착/이탈 기록, 핀 재적용 |
| `kAudioHardwarePropertyDefaultInputDevice` (`'dIn '`) | 판정 및 되돌리기 |
| `kAudioHardwarePropertyServiceRestarted` (`'srst'`) | **전체 재등록 + 캐시 폐기** |

*macOS 26 SDK의 AudioSystemObject 셀렉터 29개(`AudioHardware.h:606-637`)를 전수 검토한 결과 이보다
구체적인 property는 없다. `'livn'`은 per-device로 죽어가는 하드웨어를 알리고,
`kAudioObjectPropertyOwnedObjects`는 `'dev#'`보다 순수하게 시끄럽기만 하다.*

**구현 시 반드시 지킬 API 세부사항:**
- `kAudioObjectPropertyElementMain` 사용 (`Master` 아님) — `AudioHardwareBase.h:208`
- UID→ID 해석은 열거하지 말고 `kAudioHardwarePropertyTranslateUIDToDevice`(`'uidd'`,
  `AudioHardware.h:483-489`) 한 번으로
- **`AudioDeviceID`를 절대 캐시하지 않는다** (초안의 캐시 최적화 폐기 — `'uidd'`가 충분히 싸다)
- CFString getter마다 `takeRetainedValue()` — 호출자가 참조를 소유한다 (`AudioHardwareBase.h:650`)
- set은 **비동기로 취급**한다
- 리스너 콜백에서 set을 호출해도 데드락은 아니다 (`AudioHardware.h:382-389`: IO context 속성인
  `kAudioDevicePropertyDeviceIsRunning`·`kAudioDeviceProcessorOverload`만 동기 디스패치).
  **단 큐 호핑은 필요하다** — set이 `'dIn '`을 재발화시키므로.

### 3.1 범위 — 입력 전용

| 속성 | 취급 |
|---|---|
| `kAudioHardwarePropertyDefaultInputDevice` | 읽기 + 쓰기 (유일한 쓰기 대상) |
| `kAudioHardwarePropertyDefaultOutputDevice` | **코드에 등장하지 않음** |
| `kAudioHardwarePropertyDefaultSystemOutputDevice` | **코드에 등장하지 않음** |
| 볼륨 / 뮤트 / 앱별 장치 지정 | 코드에 등장하지 않음 |

출력 관련 키를 config 스키마에 넣지 않는다 — 스키마에 없으면 실수로 켜질 수 없다.
추가 비목표: **Elgato 미연결 시 무동작** (내장 마이크로 강제 전환하는 fallback 없음).

### 3.2 판정 로직

**1차 — transport type (타이밍 아님).** macOS가 자발적으로 기본 입력을 가져가는 경로는 Bluetooth뿐이다.
- 새 기본 입력이 `kAudioDeviceTransportTypeBluetooth` / `...BluetoothLE` → 되돌림 후보
- 그 외 전부(USB / **Virtual** / **Unknown** / BuiltIn) → 사용자 선택으로 간주, 즉시 `YIELDED`
- `Virtual`(Wave Link)과 `Unknown`(Continuity iPhone Mic)은 **차단 목록에서 반드시 제외.**
  [Elgato가 MicrophoneFX 사용 시 가상 장치를 기본 입력으로 지정하라고 안내](https://help.elgato.com/hc/en-us/articles/14611247199757)하므로
  차단하면 정면충돌한다.

**2차 — 타이밍 (BT 전환이 자동인지 사용자 의도인지만 가른다).**
- 해당 BT 장치의 도착 이벤트가 **최근 15초 내** → 자동 전환/HFP flip-back → 조용히 되돌림, yield 미카운트
- 최근 도착 이벤트 **없음** (이미 안정된 AirPods를 사용자가 시스템 설정에서 선택) → `YIELDED`

**되돌리기 타이밍: 300ms 디바운스 → 되돌림 → 1.0초에 1회 재확인, 안 붙었으면 재적용.**
초안의 0.3/1.5/4s 3발도, `cli-fix-my-mic`의 0.5s×10틱도 쓰지 않는다. 근거 — **늦게 도착하는 HFP는
그 자체가 `'dev#'`/`'dIn '` 변경이므로 리스너가 알아서 다시 발화한다.** 폴링 사다리는 *알림 없는*
재덮어쓰기(HAL 계약 위반)나 디바운스에 삼켜진 경우에만 값어치가 있고, 후자만 실재하는 구멍이라
1.0초 재확인으로 닫는다. `cpal`이 push-to-talk 키 누름 시점에 장치를 정하므로 늦은 되돌리기도 여전히
유효해서 지연 압박이 없다. *검증 5·6번에서 flip-back이 살아남으면 그때 2.5s·4s 틱을 추가한다.*

**필수 구현 규칙 2개** (`cli-fix-my-mic`의 실제 버그에서 도출):
1. **수동 판정은 `'dIn '` 리스너에서만 발생시킨다.** `'dev#'` 리스너는 도착 시각 기록과 핀 재적용만
   담당하고 yield 판정에 관여하지 않는다. *(그 도구는 `stabilize()`를 두 리스너 모두에서 불러서,
   보정 후 10초 내 장치 목록 변경이 일어나면 사용자가 아무것도 안 했는데 "수동 재전환"으로 오판하고
   1시간 보호를 껐다.)*
2. **self-write를 명시적으로 태깅한다.** 쓰기 직전 기대 장치 ID를 기록하고 **정확히 그 콜백 하나만
   삼킨다.** 불리언 안정화 창으로 뭉개지 않는다.

**다중 장치 동시 도착**(웨이크 / `coreaudiod` 재시작 / 빠른 사용자 전환)은 목록 전체가 재구축돼 모든
장치가 "신규"로 보인다 → 도착 창을 열지 말고 **핀만 1회 재적용**.

| 상태 | 조건 | 동작 |
|---|---|---|
| `ABSENT` | Elgato 미연결 | 완전 무동작 |
| `PINNED` | Elgato 연결, 감시 중 | BT 전환만 되돌림 |
| `YIELDED` | 사용자가 비-BT 선택, 또는 안정된 BT를 수동 선택 | 무동작 |
| `PAUSED` | `micpin off` | 무동작 |
| `BACKOFF` | 5초 내 3회 되돌림 | 60초 무동작 + **경고 로그 (반드시 가시화)** |

`BACKOFF`를 눈에 띄게 로깅해야 하는 이유: [FB15113809](https://developer.apple.com/forums/thread/763583)에
따르면 Continuity로 오염된 HAL은 `noErr`을 반환하면서 무한히 되돌려 가드를 조용히 소진시킨다.

`YIELDED` 해제: Elgato 재연결 / `micpin on` / 재로그인.

### 3.3 오작동 시나리오 검토 결과

| 시나리오 | 판정 |
|---|---|
| AirPods HFP 협상 지연 | 초안을 깨뜨림 → transport 1차 판정으로 해결 |
| HFP flip-back 반복 | 1.0초 재확인으로 해결 (리스너 자체 재발화가 주 방어) |
| Continuity iPhone Mic 자발적 등장 (`Unknown`) | `Unknown` 차단 제외로 해결 |
| 다중 장치 동시 도착 | 창 미개방 + 핀 1회 재적용 |
| Elgato 언플러그–리플러그 (`AudioObjectID` 변경) | UID 타깃 + ID 미캐시로 해결 |
| Wave Link 앱 실행/종료 | **오작동 없음** — 앱 미실행에도 가상 장치 3개 상시 존재(HAL 드라이버가 앱과 독립) |
| Zoom / Teams / Discord 통화 시작 | **오작동 없음** — 전부 자체 선택기, 시스템 기본값 미변경 |
| Wispr Flow / Aqua Voice | **오작동 없음** — 앱 내부 선택만 (Tiro는 미확인, 실사용 관찰) |
| 자기 쓰기가 리스너 재발화 | 명시적 태깅으로 해결 |

## 4. 생성할 파일

```
~/.local/bin/micpin                          # Swift 단일 바이너리 (데몬 + CLI)
~/.config/micpin/config.json
~/Library/LaunchAgents/com.micpin.agent.plist
~/Library/Logs/micpin.log                    # StandardErrorPath, 시작 시 256KB 초과면 truncate
```

```json
{
  "enabled": true,
  "input": {
    "priority": [
      { "uid": "AppleUSBAudioEngine:Elgato Systems:Elgato Wave:1:XXXXXXXXXXXX:2,1",
        "name": "Elgato Wave:1" }
    ]
  },
  "blockTransports": ["bluetooth", "bluetoothle"],
  "arrivalWindowSeconds": 15,
  "debounceMs": 300,
  "reverifyDelaySeconds": 1.0
}
```

**UID는 이 머신에서 실제로 읽은 값**이다. USB 시리얼 `XXXXXXXXXXXX`이 박혀 있어 **포트/허브를 바꿔도
불변**이며, `AudioHardwareBase.h:645`가 UID는 부팅 간 유지된다고 명시한다. `priority`가 배열인 것은
MicLock의 Primary→Fallback 체인 패턴 차용 — Elgato 부재 시 행선지가 명시되면 런타임 판정이 줄어든다.
이름 매칭은 fallback으로만 둔다 (`system_profiler` 출력에 직선/곡선 어포스트로피가 섞여 있다).

**CLI**

| 명령 | 동작 |
|---|---|
| `micpin status` | 상태 기계 위치, 현재 기본 입력, 고정 대상 |
| `micpin off` / `on` | `PAUSED` 진입/해제 (`YIELDED`도 함께 해제) |
| `micpin pick` | 현재 기본 입력을 UID째로 1순위에 기록 |
| `micpin daemon` | launchd 전용 모드 |
| `micpin uninstall` | `launchctl bootout` + 파일 제거 |

**launchd** (`com.micpin.agent.plist`)

```
RunAtLoad          true
KeepAlive          true            # {SuccessfulExit:false} 아님
ThrottleInterval   60
ProcessType        Background      # 미지정 시 시스템이 임의의 light resource limit을 적용
StandardErrorPath  ~/Library/Logs/micpin.log     # + setvbuf(stderr, nil, _IOLBF, 0)
```

설치/제거는 `launchctl bootstrap gui/$UID <plist>` / `launchctl bootout gui/$UID/com.micpin.agent`.
`launchctl load|unload`는 macOS 26에서 **legacy**다 (로컬 `man 1 launchctl`의 `LEGACY SUBCOMMANDS` 항목).

## 5. 구현 순서

1. `micpin.swift` — 장치 열거/해석(`'uidd'`), transport type 조회, 입력 채널 확인
   (input scope `kAudioDevicePropertyStreams`에 `AudioObjectGetPropertyDataSize` → `dataSize > 0`,
   할당 없음. Wave:1이 입력 1ch/출력 2ch 겸용이라 scope 구분이 결과를 가른다)
2. 리스너 3개 등록 + `CFRunLoopRun()` 파킹. **여기서 검증 5·6번을 먼저 통과시킨다** —
   이후 로직은 리스너가 살아 있어야 의미가 있다
3. 상태 기계 + self-write 태깅 + 루프 가드
4. `'srst'` 복구 경로 (전체 재등록, 캐시 폐기, UID 재해석, 재평가)
5. config 로딩(이벤트 시 lazy read) + SIGHUP dispatch source
6. CLI 서브커맨드
7. plist 작성 및 `bootstrap`
8. 검증 전체 수행

## 6. 검증 계획

세션당 한 번:
```bash
L=gui/$(id -u)/com.micpin.agent
P=$(launchctl print $L | awk '/pid = /{print $3; exit}')
```

| # | 명령 | 통과 기준 |
|---|---|---|
| 1 | `sudo powermetrics --samplers tasks -n 3 -i 5000 \| grep -E "micpin\|^Name"` | `Wakeups (Intr, Pkg idle)` = `0.00`, 3샘플 전부 |
| 2 | `footprint -p $P \| tail -3` | `phys_footprint` < 8 MB |
| 3 | `vmmap -summary $P \| grep -E "Physical footprint\|Writable regions"` | `written=` < 4 MB |
| 4 | `ps -o pid,rss,time,etime -p $P` (24시간 후) | `TIME` < 00:00:02, RSS가 1시간 시점 대비 10% 이내 |
| 5 | **리스너 생존 — 장치 이벤트.** `tail -f ~/Library/Logs/micpin.log` 하며 Wave를 물리적 분리 후 재연결 | 재연결 2초 내 전이 로그 |
| 6 | **리스너 생존 — 장치 변경 없는 default-input 이벤트.** 시스템 설정 → 사운드 → 입력에서 MacBook Pro Microphone 선택 | 1.5초 내 Wave:1로 복원 + 전이 로그 |
| 7 | **`dispatchMain()` 회귀 게이트.** `dispatchMain()` 파킹 변종을 빌드해 5·6번 반복 | 하나라도 실패하면 `CFRunLoopRun()` 선택이 load-bearing임이 입증. **어느 쪽이든 `CFRunLoopRun()`으로 출시** |
| 8 | **`'srst'` 복구.** `sudo killall coreaudiod; sleep 8; launchctl print $L \| grep "pid = "` 후 6번 재실행 | PID가 `$P`와 동일(크래시 아님), `'srst'` 재등록 로그, 6번 통과 |
| 9 | `launchctl kill SIGSEGV $L` ×6 후 `log show --last 5m --predicate 'process == "launchd"' \| grep micpin` | 재기동 간격 ≥ 60초, 깨끗한 `exit(0)` |
| 10 | `sudo fs_usage -w -f filesys 2>/dev/null \| grep micpin` (유휴 60초) | syscall 0건 |
| 11 | `sudo powermetrics ... \| grep coreaudiod` — 에이전트 로드 vs `launchctl bootout $L` 비교 | `CPU ms/s`·wakeups에 측정 가능한 차이 없음 |
| 12 | config 편집 후 `launchctl kill SIGHUP $L` | 재로드 성공, 동일 PID 유지 |

**5·6·8번이 핵심이다.** 유휴 상태에서 죽은 리스너와 산 리스너는 구별되지 않으며,
그것이 `dispatchMain()` 버그가 그대로 출시될 뻔한 이유다.

**기능 시나리오** (수동 확인):
- AirPods 연결 → 입력은 Elgato 유지, **출력만** AirPods로 이동
- AirPods 연결 15초 경과 후 수동으로 AirPods 마이크 선택 → 되돌려지지 않음 (`YIELDED`)
- Elgato USB 분리 → 개입 없이 macOS 기본 동작 (`ABSENT`)
- 슬립 → 웨이크 후 5·6번 재실행
- Wave Link MicrophoneFX 활성화 후 가상 장치를 기본 입력으로 지정 → 되돌리지 않음

## 7. 예상 풋프린트 및 알려진 한계

| 항목 | 값 |
|---|---|
| RSS | 5–10 MB |
| `phys_footprint` | 3–6 MB |
| idle wakeups | **0** — HAL 알림은 MIG 채널의 push-only 빈 본문 mach 메시지, 주기 트래픽 없음 |

*RSS가 부풀려지는 것은 실증됐다 — `/usr/lib/swift/libswiftCore.dylib`와 `Foundation`은 디스크에 존재하지
않고 dyld 공유 캐시에서만 해석되며 텍스트 페이지가 시스템 전역 공유다. `phys_footprint`가 정직한 수치다.*

**한계.** AirPods 연결 후 ~15초 안에 수동으로 AirPods 마이크를 고르면 한 번 되돌려진다.
`micpin off`를 쓰거나 잠시 뒤 다시 고르면 존중된다. 초기자 신호가 존재하지 않으므로
(§2의 `log stream` 0줄) 이보다 정확히 가를 방법은 없다.

**비간섭 근거.** 마이크를 열지 않으므로(라우팅 설정일 뿐 캡처가 아님) 주황색 인디케이터·TCC 프롬프트가
없고 다른 앱의 장치 점유를 방해하지 않는다. *단 이는 Apple 문서에 명시된 바가 아니라 정황 증거다 —
SoundAnchor가 Mac App Store에 있고(⇒ 강제 샌드박스), InputGuard는 미서명 배포인데 설치 주의사항이
Gatekeeper 우클릭뿐이다.* 이미 스트림을 연 앱은 자기 장치를 유지하므로 녹음 중인 앱을 끊지 않고,
자체 선택기를 쓰는 앱(Wave Link, OBS, Zoom)은 기본값을 경유하지 않는다. 출력 경로는 무접촉이다.

---

# 구현 결과 (2026-09-08)

구현 완료, 설치 및 부트스트랩됨. 소스는 `~/.local/src/micpin/micpin.swift` (739줄, `swiftc -O`로 226KB).

## 실측 결과

| # | 항목 | 결과 |
|---|---|---|
| 2 | `phys_footprint` | **3.9–4.2 MB** ✅ (기준 < 8MB, 예측 3–6MB 적중) |
| 3 | `vmmap written=` | **2.8 MB** ✅ (기준 < 4MB) |
| — | RSS | **13.6 MB** ⚠️ 예측 5–10MB 초과. 공유 dyld 캐시 페이지 때문이며 의미 있는 수치는 `phys_footprint` |
| — | 유휴 CPU 누적 | 90초간 `0:00.06` → `0:00.06` **무변화** ✅ (0-wakeup 간접 증거) |
| 6 | `'dIn '` 리스너 생존 | ✅ 내장 마이크 선택 시 즉시 전이 로그 |
| 9 | `ThrottleInterval` | ✅ 연속 kill 시 ~50초 지연 후 재기동 |
| 12 | SIGHUP 재로드 | ✅ yield 해제 후 26ms 만에 복원 |

## 플랜 대비 정정 사항

1. **검증 6번의 통과 기준이 틀렸다.** 플랜은 "내장 마이크 선택 → 1.5초 내 Wave:1로 복원"이었으나,
   내장 마이크는 transport `bltn`으로 차단 목록에 없으므로 **설계상 되돌리지 않고 `YIELDED`로 존중하는 것이
   정답**이다. 6번은 transport 기반 판정이 확정되기 전에 작성된 항목이다. 리스너 생존이라는 본래 목적은
   **전이 로그 출현**으로 검증하며, 그것으로 통과했다.
2. **Continuity iPhone Mic의 transport는 `Unknown`이 아니라 `ccwd`**다 (실측). 차단 목록에 없으므로
   동작 영향은 없다. `ccwl`(wireless) 변종도 마찬가지다.
3. **검증 9번의 "영속 카운터"는 구현하지 않았다.** 설계에는 in-process 루프 가드만 있고 크래시 카운터는
   없다. 재기동 간격은 launchd `ThrottleInterval`이 담당하며 실측으로 확인했다.
4. **`ThrottleInterval`은 직전 spawn 시점부터 계산한다.** 1회 kill로는 스로틀이 걸리지 않는다
   (데몬이 이미 60초 이상 실행 중이었으므로 즉시 재기동). 연속 2회 kill이 실제 테스트다.

## 구현 중 발견해 고친 버그

`micpin on`이 `enabled: true`를 쓰고도 `status`가 계속 `PAUSED`를 보고했다. 원인은 SIGHUP 핸들러가
`state`를 직접 대입해 `transition()`을 우회한 것과, `transition()`이 상태가 같으면 조기 반환해
상태 파일을 쓰지 않은 것. 수정: `transition()`은 로그만 변경 시 남기고 **상태 파일은 항상 갱신**하며,
SIGHUP은 상태를 추측하지 않고 중립값 `.absent`로 리셋해 `applyPin()`이 실제 결과를 판정·기록하게 했다.

## 남은 검증 — 사용자 실행 필요

sudo 또는 물리적 조작이 필요해 미수행:

| # | 명령 / 조작 | 확인 대상 |
|---|---|---|
| 1 | `sudo powermetrics --samplers tasks -n 3 -i 5000 \| grep -E "micpin\|^Name"` | idle wakeups = 0.00 (확정적 검증) |
| 8 | `sudo killall coreaudiod` → 8초 후 `micpin status` + 로그 | **`'srst'` 복구 — 최대 리스크** |
| 10 | `sudo fs_usage -w -f filesys \| grep micpin` (유휴 60초) | syscall 0건 |
| 5 | Elgato USB 물리적 분리 후 재연결 | `'dev#'` 리스너 생존, `ABSENT`↔`PINNED` |
| — | **AirPods 연결** | 입력은 Elgato 유지 + 출력만 AirPods 이동. AirPods의 실제 transport가 `blue`인지 확인 — 아니면 차단 목록 조정 필요 |

## AirPods 실측에서 발견한 결함 (2026-09-08 14:48)

첫 AirPods 테스트는 **결과적으로 통과**했으나(기본 입력이 Elgato 유지), 로그가 잘못된 경로를 드러냈다:

```
14:48:02.722 EVENT dev# — bulk arrival (2); arrival windows not opened
14:48:02.731 REVERT -> Elgato Wave:1 (dev#)
```

**AirPods는 장치 2개(입력 객체 + 출력 객체)로 동시에 등장한다.** 구현이 `added.count > 1`을
"대량 재구축"으로 판정해 도착 창을 기록하지 않았다. 이번엔 macOS가 기본 입력을 장치 등장과 거의 동시에
(9ms 차) 바꿨고 `'dev#'` 경로의 `applyPin`이 잡아서 결과가 맞았다 — `applyPin`은 도착 창을 보지 않는다.

**그러나 HFP가 늦게 완료되면 실패한다.** 전환이 `'dIn '`으로 도착하면 `evaluate()`가 AirPods UID의
도착 기록을 찾지 못해 `YIELDED`로 물러난다 — 데몬이 일해야 할 바로 그 순간에. §2 결함 ③이 다른 문에서
재발한 것이다.

**원인: 구현이 플랜의 근거보다 넓었다.** 플랜은 "목록 전체가 재구축돼 **모든 장치가** 신규로 보인다"였는데
`added.count > 1`로 구현했다. 7개 중 2개는 전체 재구축이 아니다.

**수정:** 재구축 판정을 `added.count == current.count`(아무것도 살아남지 않음)로 좁혔다. 여러 객체를
동시에 publish하는 장치는 재구축이 아니므로 도착 창을 정상 기록한다. 사라진 장치의 도착 기록도 함께 정리한다.

**추가:** 장치 도착 시 이름·transport·입력 유무·차단 여부를 로깅하도록 했다. AirPods의 실제 transport
코드를 확인할 유일한 지점이며(되돌리기가 `dev#` 경로로 일어나면 transport가 검사되지 않아 가려진다),
차단 목록을 실제와 대조할 수 있다.

## 2차 AirPods 실측 — 도착 창 방식 자체의 취약점 (2026-09-08 14:52)

```
14:52:19.437 ARRIVED AirPods Pro 3 [blue] output-only BLOCKED
14:52:19.455 REVERT -> Elgato Wave:1 (dev#)
```

**확정:** AirPods의 transport는 `blue`이며 차단 목록과 일치한다(`BLOCKED`). §3.2의 1차 판정은 옳다.

**그런데 이번엔 장치가 1개, `output-only`로만 등장했다.** 첫 테스트에서는 2개였다. 즉 AirPods의
입력/출력 객체가 등장하는 시점이 연결마다 다르고, 재연결 시 입력 객체는 "신규"로 보이지 않을 수 있다.
그럼에도 18ms 뒤 되돌리기가 일어났다는 것은 **macOS가 입력 스트림조차 publish되지 않은 장치를 기본
입력으로 지정했다**는 뜻이다 — HFP 지연 시나리오가 실물로 관측된 것이며, `'dev#'`/`applyPin`이
간신히 먼저 잡았다.

**결과적으로 UID 단위 도착 창은 신뢰할 수 없다.** 전환이 조금만 늦게 `'dIn '`으로 도착하면
해당 UID의 도착 기록이 없어 `YIELDED`로 물러난다.

**수정:** `lastBlockedArrival`을 추가해 **차단 transport 장치가 방금 도착했다는 사실 자체**를 증거로
쓴다. `evaluate()`는 해당 UID의 도착 기록 **또는** 최근 차단 장치 도착 중 하나라도 창 안이면 되돌린다.
HAL 리셋 시 함께 폐기한다.

**추가:** 되돌리기 로그에 밀려난 장치의 이름·transport를 넣었다
(`REVERT -> Elgato Wave:1 (dev#, displacing AirPods Pro 3 [blue])`).
"무엇을 밀어냈는가"를 몰라 테스트 한 라운드를 더 써야 했던 문제를 없앤다.

## 3차 AirPods 실측 — 시나리오 검증 완료 (2026-09-08 14:55)

```
.417  ARRIVED AirPods Pro 3 [blue] output-only BLOCKED
.424  REVERT -> Elgato Wave:1 (dev#, displacing AirPods Pro 3 [blue])
.433  ARRIVED AirPods Pro 3 [blue] input BLOCKED
```

밀려난 장치가 AirPods로 확인됨 — 데몬이 의도한 일을 정확히 수행했다.

**관측된 사실 2가지:**
1. AirPods의 출력 객체와 입력 객체는 **약 16ms 간격으로 별개 도착**한다. 1차 테스트에서 "2개"로 보인 것은
   둘이 한 샘플에 잡혔기 때문이고, 2·3차에서는 별개 이벤트로 갈렸다.
2. `.424` 시점에 macOS는 **입력 객체가 존재하기도 전에**(`.433` 도착) 기본 입력을 AirPods로 옮겼다.
   §2 결함 ③의 HFP 지연이 실물로 관측된 것이다.

**출력 불가침 검증 완료** (AirPods 연결 상태에서 `system_profiler`):
```
default output:        AirPods Pro 3
default system output: AirPods Pro 3
default input:         Elgato Wave:1
```
소스 내 `DefaultOutputDevice` / `DefaultSystemOutputDevice` 참조 **0건**(grep 확인).
제약 1(입력만 건드린다)과 프로젝트의 원래 목표가 모두 충족됐다.

**정직한 한계:** 3회 연결 모두 `'dev#'`/`applyPin` 경로가 7–18ms 안에 잡았다. 즉 §3.2의 2차 판정
(도착 창 타이밍)은 자동 전환 방향으로 **한 번도 실제 실행된 적이 없다.** 그 코드는 아직 관측되지 않은
경로에 대한 보험이며, 검증된 것은 1차 판정(transport)과 `'dev#'` 경로다.

## `'srst'` 실측 — 재구축 가드가 데몬을 실패시켰다 (2026-09-08 14:57)

`sudo killall coreaudiod` 결과. **데몬이 목적을 달성하지 못했고 마이크가 AirPods에 남았다.**

```
14:57:56.226 PINNED -> ABSENT: no configured input device present   ← 장치 전멸
14:57:59.162 EVENT srst — coreaudiod restarted; rebuilding all state
14:57:59.162 EVENT dev# — full list rebuild (6 devices); arrival windows not opened
14:57:59.163 ABSENT -> PINNED: dev#
14:57:59.165 listeners registered: dev# dIn  srst
14:58:03.966 PINNED -> YIELDED: user chose settled Bluetooth device AirPods — respecting
```

**`'srst'` 복구 경로 자체는 정상 동작했다** (리스너 재등록 완료). 무너진 것은 재구축 가드다.

`coreaudiod`가 죽으면 장치 6개가 전멸 후 전부 복귀하므로 `added.count == current.count`가 성립해
"전체 재구축"으로 판정되고 도착 창을 기록하지 않았다. 4.8초 뒤 macOS가 기본 입력을 AirPods로 옮겼을 때
`evaluate()`에 증거가 전무했고(`arrivals` 비어 있음, `lastBlockedArrival` nil) "사용자가 안정된
블루투스 장치를 골랐다"고 오판해 물러났다.

**가드의 손익이 애초에 맞지 않았다.** 지키려던 것은 "잠들기 전 고른 BT 마이크를 웨이크 때 뒤집지 않기"인데,
대가는 **웨이크마다 마이크가 조용히 AirPods로 넘어가 굳는 것**이다. `YIELDED`는 끈적해서 Elgato
재연결이나 `micpin on` 없이는 풀리지 않는다. `coreaudiod` 재시작은 16일에 한 번이지만 웨이크는 매일이다.

**수정 3건:**
1. **도착 기록은 재구축 여부와 무관하게 항상 한다.** `isRebuild`는 이제 도착 기록을 막지 않는다.
2. **`isRebuild`는 yield 해제만 게이팅한다.** 타깃의 진짜 재연결(물리적 재삽입)은 yield를 풀지만,
   목록 재구축은 풀지 않는다 — 그래야 웨이크가 의도적 선택을 지우지 않는다. 이것이 가드의 원래 취지에
   부합하는 유일한 용도다.
3. **`yieldedTo`를 추적해 yield가 만료되게 했다.** 사용자가 고른 장치가 사라지면 yield는 지킬 대상이
   없으므로 해제하고 핀을 복원한다. 이전에는 yield가 무한히 끈적해서 오판 한 번이 영구 실패가 됐다.

재배포 후 즉시 AirPods를 밀어내고 Elgato로 복귀함을 확인:
`REVERT -> Elgato Wave:1 (startup, displacing AirPods Pro 3 [blue])`

## 2차 `'srst'` 실측 — 복구가 증거를 지웠다, 그리고 flip-back 실물 관측 (2026-09-08 15:00)

도착 기록은 정상적으로 남았는데도 4.6초 뒤 물러났다:
```
.162  ARRIVED AirPods Pro 3 [blue] input BLOCKED    ← 증거 기록됨
.165  ABSENT -> PINNED: dev#
.166  listeners registered                              ← srst 복구 블록
.761  PINNED -> YIELDED (+4.6초)
```

**`'srst'` 복구 블록이 `arrivals.removeAll()` / `lastBlockedArrival = nil`로 방금 기록된 증거를 지웠다.**
`q.async` 지연이 "dev# 먼저, 복구 나중" 순서를 보장해버려 이 파괴가 확정적으로 일어났다.
근본 오류: 플랜의 "캐시 폐기"를 너무 넓게 해석했다. 폐기 대상은 **`AudioDeviceID` 캐시**이고
그건 애초에 캐시하지 않으므로 폐기할 것이 없다. 도착 타임스탬프는 HAL 리셋과 무관하게 유효하다.

**수정:** 복구는 리스너 재등록 + `expectedSelfWrite` 무효화 + 핀 재적용만 한다.
`snapshotDevices()`도 제거했다 — 반대 순서로 실행되면 dev#가 보기 전에 도착을 삭제해버린다.
그리고 **리셋 자체가 창을 연다**: 리셋 직후 수 초간 macOS는 모든 기본값을 처음부터 재결정하므로
그 구간의 기본 입력 변경은 시스템의 결정이지 사용자의 선택이 아니다 → `lastBlockedArrival = Date()`.

### flip-back 실물 관측 — 판정 기준을 근본적으로 개선

재배포 직후 로그가 flip-back을 처음으로 포착했다:
```
.142  REVERT -> Elgato Wave:1 (startup, displacing AirPods [blue])
.548  PINNED -> YIELDED: user chose settled Bluetooth device AirPods   ← 406ms 뒤
```
**macOS가 우리 쓰기 406ms 뒤에 AirPods로 되돌렸다.** 판정 로직은 증거가 없어(AirPods가 데몬 시작
시점에 이미 존재했으므로 도착 기록 없음) 이를 "사용자 선택"으로 읽었다. 플랜이 "디바운스에 삼켜진
재덮어쓰기"를 유일한 실재 구멍으로 보고 1.0초 재확인으로 닫으려 했으나, `evaluate()`가 먼저
`YIELDED`로 넘어가 재확인의 `guard state == .pinned`가 무력화됐다.

**수정 — `postWriteGraceSeconds`(기본 3.0) 도입.** 우리가 타깃을 쓴 직후 기본 입력이 옮겨졌다면
**구조적으로 flip-back이다** — 사람이 400ms 만에 장치를 다시 고르지 않는다. 도착 이력이 전혀 필요 없고
우리 자신의 쓰기 시각만으로 성립하므로, 도착 창보다 강한 증거다. 폭주는 기존 루프 가드(5초 내 3회 →
60초 백오프)가 막는다.

**검증 완료 — 두 경로가 깨끗하게 갈린다:**

| 시퀀스 | 결과 |
|---|---|
| 안정된 AirPods를 의도적 선택 (마지막 쓰기 후 4초) | `YIELDED` — 존중 ✅ |
| 우리 쓰기 직후 AirPods가 재탈취 (grace 내) | `REVERT ... (flip-back to AirPods Pro 3)` ✅ |

참고: AirPods 입력 객체 UID는 `AA-BB-CC-DD-EE-FF:input` (MAC 기반, 장치별 안정).

### 판정 로직 설계 회고

도착 창(arrival window) 방식은 3회 연속 실패했다 — AirPods가 객체를 나눠 publish하고(1차),
재구축이 창을 막고(2차), 복구가 증거를 지우고(3차). 매번 "증거를 어떻게 보존할까"로 대응했으나
근본 문제는 **증거의 종류가 잘못됐다**는 것이었다. `postWriteGraceSeconds`는 외부 장치 이력에
의존하지 않고 자기 행동만 참조하므로 이 실패 계열 전체에 면역이다. 도착 창은 이제 보조 증거로 남는다.

## 3차 `'srst'` 실측 — 통과 (2026-09-08 15:05)

```
.500  EVENT dev# — full list rebuild (6 devices)
.501  ARRIVED AirPods Pro 3 [blue] input BLOCKED     ← 증거 기록됨(복구가 더 이상 지우지 않음)
.504  ABSENT -> PINNED: dev#                              ← 이미 Elgato, 쓰기 없음 ⇒ lastWriteAt 없음
.506  listeners registered
42.819  REVERT -> Elgato Wave:1 (auto-switch to AirPods)  ← +4.3초, 도착 창이 잡음
43.255  REVERT -> Elgato Wave:1 (flip-back to AirPods)    ← +436ms, post-write grace가 잡음
```
최종: `PINNED`, `default input: Elgato Wave:1` ✅

**두 기제가 모두 필요함이 증명됐다.** `.504`에서 쓰기가 없었으므로 `lastWriteAt`이 없었고, 4.3초 뒤의
첫 탈취는 **도착 창만** 잡을 수 있었다. 그 되돌리기 436ms 뒤의 재탈취는 **post-write grace만** 잡을 수
있었다. 어느 하나만으로는 실패한다.

flip-back 간격이 406ms → 436ms로 일관된다. macOS는 리셋 직후 구간에서 우리 쓰기 약 0.4초 뒤에
안정적으로 재탈취한다. 루프 가드는 5초 내 2회로 발동하지 않았다 — 임계값 3이 적절하다.

## 최종 검증 현황

| 검증 | 상태 |
|---|---|
| AirPods 연결 시나리오 (본래 목표) | ✅ 3회 |
| 출력 불가침 | ✅ 소스에 출력 property 참조 0건, AirPods로 정상 이동 |
| `'srst'` / `coreaudiod` 재시작 복구 | ✅ |
| flip-back 방어 | ✅ |
| 수동 선택 존중 (비-BT / 안정된 BT) | ✅ |
| `'dIn '` / `'dev#'` 리스너 생존 | ✅ |
| `on` / `off` / SIGHUP | ✅ |
| 메모리 `phys_footprint` 3.9–4.2MB, written 2.8MB | ✅ |
| 재기동 스로틀 | ✅ |
| 유휴 CPU 90초 무변화 | ✅ |
| **0-wakeup 확정** | ✅ `top` 델타 모드에서 `IDLEW 0` 직접 측정 (아래 참조) |
| **Elgato 물리적 착탈** | ✅ 통과 (아래 참조) |
| **24시간 누수 확인** | ⏳ 미수행 |

## 0-wakeup 확정 (2026-09-08 15:09)

`sudo powermetrics --samplers tasks -n 3 -i 5000`에서 **micpin이 3개 샘플 어디에도 나타나지 않았다**
— task 샘플러는 활동량 상위만 보고하므로 보고 임계값 아래라는 뜻이다. 다만 이는 부재의 증거이지
수치가 아니므로, `top`으로 카운터를 직접 읽었다 (sudo 불필요):

```
$ top -l 2 -s 5 -pid <PID> -stats pid,command,cpu,time,idlew
PID    COMMAND %CPU TIME     IDLEW
19340  micpin  0.0  00:00.10 0
```

델타 모드 두 번째 샘플이므로 **5초 구간의 idle wakeup이 0개**다. CPU 시간도 20초 브래킷에서
`0:00.10` → `0:00.10` 무변화. 제약 2(저자원)의 핵심 주장이 수치로 확정됐다.

설계 근거가 실측으로 뒷받침된 것이다 — 타이머도 예약 소스도 없는 `CFRunLoopRun()`은 타임아웃 없이
`mach_msg`에 블록된다. 기각한 폴링 방식(`StartInterval 5`)이라면 하루 17,280번의 spawn이 여기 잡혔다.

## Elgato 물리적 착탈 (2026-09-08 15:09) — 통과

AirPods 연결 상태에서 USB 분리 → 8초 → 재연결:
```
15:09:42.525  PINNED -> ABSENT: no configured input device present
              (8초간 로그 없음 — REVERT 0건)
15:09:50.520  ARRIVED Elgato Wave:1 [usb ] input
15:09:50.520  ABSENT -> PINNED: dev#
```
최종 상태 이유: `default input is the target`

**두 가지가 확인됐다:**
1. **`ABSENT` 구간 무개입.** AirPods가 연결돼 있었으므로 macOS는 그 사이 기본 입력을 옮겼을 것이나
   데몬은 `REVERT`를 한 줄도 내지 않았다. §3.1의 비목표("Elgato 미연결 시 무동작")가 지켜졌다.
2. **재연결 시에도 쓰기 없음.** macOS가 새로 도착한 USB 마이크를 스스로 기본값으로 선택했고 micpin은
   확인만 했다(`default input is the target`). 불필요한 개입이 0이다.

---

# 코드 리뷰 대응 (2026-09-08 15:25, `/code-review xhigh`)

15건 + 부록 3건. 실제 코드에 대조한 결과 대부분이 실재하는 결함이었다. 소스 1126줄로 재작성.
이전 버전은 `micpin.swift.bak`에 보관.

## 수정 (14 + 부록 2)

| # | 결함 | 수정 |
|---|---|---|
| 1 | `Config.load()`가 "없음"과 "깨짐"을 모두 `.fallback`으로 뭉갰고, CLI가 그걸 되써서 **핀 목록을 영구 파괴** | `ConfigLoad {missing, ok, corrupt}` 도입. CLI는 corrupt면 거부하고 종료, 데몬은 **메모리에 있던 설정을 유지**. 키가 존재하면 반드시 디코드돼야 하도록 변경(빠진 키만 기본값) |
| 2 | 시작 시 churn grace가 없어 로그인 시 이미 연결된 BT가 몇 초 뒤 입력을 가져가면 "사용자 선택"으로 오판 | `systemChurnUntil` 도입. 시작과 HAL 리셋 **양쪽**에서 무장. srst의 `lastBlockedArrival = Date()` 특수 케이스 제거 |
| 3 | 백오프 만료 시 아무도 핀을 재적용하지 않고, SIGHUP이 `backoffUntil`을 못 지워 `micpin on`이 무효 | 만료 웨이크 타이머 + SIGHUP이 백오프·yield·pause 전부 해제 |
| 4 | `cmdInstall`이 존재하지 않는 바이너리 경로를 plist에 박고 성공 보고 → launchd 무한 크래시 루프 | 실행 중인 바이너리를 찾아 복사, 없으면 명시적 실패. bootout→bootstrap 경쟁도 5회 재시도 |
| 5 | 리스너 등록 실패를 "FATAL"로 찍고 **계속 실행** → 영구히 귀먹은 데몬 | `exit(1)` — KeepAlive가 복구한다 |
| 6 | `hasInput()`이 일시적으로 false면 `ABSENT`로 확정되고 재시도 없음 | 1초 간격 **최대 5회** 재시도. 무한 폴링이 되면 0-wakeup이 깨지므로 반드시 유계 |
| 7 | `removeAllListeners()`를 리스너 배달 큐와 **같은 큐**에서 호출 (데드락 형태) | HAL 배달 큐(`hal`)와 작업 큐(`work`) 분리. 조사했던 레퍼런스 구현들이 모두 쓰는 패턴 |
| 8 | `writeState()`가 디렉터리를 안 만들고 오류를 `try?`로 삼킴 | 디렉터리 생성 + 실패 시 1회 경고 로그 |
| 9 | `Config.save()`/`writeState()` 비원자적 쓰기 | `options: .atomic` (plist는 이미 그랬음) |
| 10 | 재확인 쓰기가 `lastWriteAt`을 갱신하지 않아 flip-back 창이 낡은 쓰기 기준으로 계산됨 | 갱신 + `RE-VERIFY ->` 로그. `reverifyDelaySeconds < postWriteGraceSeconds` 암묵적 의존 제거 |
| 11 | 타이밍 값 검증 없음 (`debounceMs: 0`이면 코얼레싱 소멸, `postWriteGraceSeconds: 0`이면 flip-back 탐지 소멸) | 범위 클램핑 + NaN 처리 + 조정 내역 로깅 |
| 12 | `blockTransports` 오타를 `compactMap`이 조용히 버려 **차단 목록이 비면 데몬이 무의미해짐** | 인식 못 한 이름 경고 + 결과가 비면 별도 경고 |
| 13 | `install`/`pick`이 차단 transport 장치를 타깃으로 잡을 수 있음 (강제 불가능한 설정) | 경고 출력 |
| 14 | `expectedSelfWrite`에 만료가 없어 낡은 기대가 진짜 사용자 변경을 삼킬 수 있음 | 타임스탬프 부착, `postWriteGraceSeconds` 경과 시 폐기 |
| 부록 | `allDevices()`가 반환 바이트 수를 무시 | 실제 기록량으로 트림 + 0 필터 |
| 부록 | plist가 경로를 XML 이스케이프 없이 보간 | `xmlEscaped()` |

## 부분 수정 (1)

**15. `transition()`/`writeState()`의 중복 작업과 `currentInput` staleness.**
`resolveTarget()` 안의 `allDevices()`를 루프 밖으로 호이스트했다. `transition()` 시그니처 변경과
`applyPin`/`evaluate` 프롤로그 통합은 하지 않았다 — idle wakeup이 0이고 하루 수 회만 동작하는 데몬에서
성능 이득이 없는 반면, 여러 라운드의 실측으로 검증한 판정 로직을 건드리는 위험이 실재한다.
staleness는 실측했으나 재현되지 않았다(쓰기가 2ms 내 반영, `state.json`의 `currentInput`이 정확).
`reason` 필드에 밀려난 장치가 남으므로 기록이 모호해지지도 않는다. **알려진 채로 수용.**

## 기각 (1)

**부록: "`arrivals`가 `lastBlockedArrival`과 거의 중복".** 중복이 아니라 **정밀도가 다른 두 신호**다.
`arrivals[uid]`는 해당 장치 자신의 도착이라는 좁고 정확한 증거이고, `lastBlockedArrival`은 AirPods가
입력/출력 객체를 16ms 간격으로 따로 publish하는 실측 사실에 대응하는 넓은 폴백이다. 3차 `'srst'`
테스트에서 둘이 각각 다른 순간을 잡아 **양쪽 모두 필요함이 증명됐다.** 의도된 설계다.

## 검증

| 항목 | 결과 |
|---|---|
| 깨진 JSON / `input` 타입 불일치 → CLI 거부, 파일 보존 | ✅ |
| 타이밍 클램핑 (`1e300`, `-1`, `0`) | ✅ 조정 내역 로깅됨 |
| 차단 목록 오타 경고 | ✅ 2단 경고 |
| 시작 시 churn 창 무장 | ✅ `system churn window armed for 15s (daemon start)` |
| churn 창 내 BT 탈취 → 되돌림 | ✅ `REVERT ... (system churn to AirPods)` |
| churn 창 종료 후 의도적 BT 선택 → 존중 | ✅ `YIELDED` |
| `micpin on` → yield 해제 | ✅ |
| post-write grace 내 flip-back → 되돌림 | ✅ |
| idle wakeups | ✅ **0** (`IDLEW 0`) |
| `phys_footprint` | ✅ 4065 KB (재작성 전과 동일) |
| CPU 20초 무변화 | ✅ |

## 새로 생긴 알려진 한계

`systemChurnUntil` 때문에 **데몬 시작 또는 HAL 리셋 후 15초 동안은 의도적인 블루투스 마이크 선택도
되돌려진다.** 기존의 "AirPods 연결 후 15초" 한계와 같은 성격이며, 안전한 방향(데몬의 목적 우선)이다.
회피는 `micpin off` 또는 15초 후 재선택.

## 재작성 후 실기기 재검증 (2026-09-08 15:33–15:35) — 3/3 통과

재작성으로 세 리스너 전부와 큐 구조가 바뀌었으므로 실제 장치 경로를 다시 돌렸다
(직전 회귀는 `setinput`을 써서 `'dIn '`만 건드렸다).

**① AirPods 재연결** — `'dev#'` 리스너가 큐 분리 후에도 정상 발화:
```
.631 ARRIVED AirPods [blue] output-only BLOCKED
.645 REVERT -> Elgato Wave:1 (dev#, displacing AirPods [blue])
.653 ARRIVED AirPods [blue] input BLOCKED
```

**② Elgato 물리적 착탈** — `ABSENT` 7.8초 구간에 `REVERT` 0건, 재연결 시 macOS가 스스로 선택해
쓰기조차 불필요(`default input is the target`). `retry N/5`는 나오지 않았다 — 장치가 즉시 입력
스코프를 내놓았다는 뜻. **입력 스코프 재시도 경로는 여전히 실기기로 검증되지 않았다.**

**③ `sudo killall coreaudiod`** — 통과, 그리고 순서 의존성 해소가 증명됨:
```
15:35:25.930 EVENT srst — re-registering listeners
15:35:25.930 system churn window armed for 15s (HAL reset)
15:35:25.934 EVENT dev# — full list rebuild (7 devices)
15:35:25.935 ARRIVED AirPods [blue] input BLOCKED          ← 증거 보존
15:35:30.195 REVERT (system churn to AirPods)     ← +4.3초
15:35:30.658 REVERT (flip-back to AirPods)        ← +463ms
```

**이번 실행에서 `'srst'`가 `'dev#'`보다 먼저 실행됐다**(.930 vs .934) — 이전 실패 때와 정반대 순서다
(`q.async` 지연 제거의 결과). 복구가 `snapshotDevices()`를 더 이상 호출하지 않으므로 뒤이은 `'dev#'`가
7개를 전부 신규로 보고 도착을 정상 기록했다. **예전에 치명적이었던 순서가 실제로 발생했는데 무해했다** —
그 수정의 목적이 우연히 재현되며 증명된 셈이다.

flip-back 간격 3회 관측: 406ms → 436ms → 463ms. 일관적이다.

## 남은 검증

| 항목 | 상태 |
|---|---|
| 24시간 누수 확인 | ⏳ 내일 |
| 입력 스코프 재시도 경로 (`retry N/5`) | 실기기 미검증 — 입력 스코프를 늦게 publish하는 장치가 있어야 발동 |

---

# 24시간 점검 결과 및 후속 수정 (2026-09-09 15:44)

## 1일차 결과 — 스크립트가 `FAIL`을 냈으나 판정 자체가 틀렸다

```
phys_footprint : 7873 KB   (기준 4257 KB, 통과 < 8192)
CPU TIME       : 0:32.61   (통과 < 00:00:02)
idle wakeups   : 58        (통과 0)
판정: FAIL (idle wakeup 발생)
```

**`idlew` 오독.** `top -l 2`의 `IDLEW`는 5초 델타가 아니라 **프로세스 수명 누적 카운터**다.
두 샘플이 정확히 같은 `58`을 보이고 CPU TIME도 변하지 않는 것으로 확인했다. 24시간에 58회는
시간당 2.4회이며 실패가 아니다. 어제 `0`이 나온 것은 프로세스가 20분밖에 안 됐고 이벤트가 없었기 때문.
**내 검사 스크립트의 판정 로직 결함이다.**

**누수도 아니다.** 유휴 30초 동안 CPU·로그·`phys_footprint`(7857 KB) 전부 무변화.
RSS 2768 KB 대 `phys_footprint` 7857 KB — 약 5MB가 압축된 상태이며, 힙 high-water이지
진행 중인 누수가 아니다.

## 진짜 문제 — 출력 전용 장치로 인한 낭비

로그 3443줄 중 **3243줄(94%)이 `ARRIVED LG ULTRAFINE [dprt] output-only`**.
01시–09시 시간당 319회, 즉 **11.3초 간격으로 8시간 연속**. 10시 이후 간헐적.

| 지표 | 값 |
|---|---|
| 이벤트 수 | 3243 |
| 이벤트당 CPU | 10.1 ms |
| 이벤트당 메모리 | 1.12 KB |
| 총 대가 | CPU 32.6초, 힙 +3.6MB (peak 9265 KB) |

**출력 전용 장치가 오고 가는 것은 어떤 입력이 기본값인지에 영향을 줄 수 없다.** 즉 이 일은
전부 불필요했다. 기능은 정상이었다 — REVERT 27회 모두 AirPods 관련 정상 판정.

## 수정 4건

1. **관련 없는 장치 목록 변경을 조기 반환.** 도착한 장치에 입력 스코프가 있거나, 타깃이거나,
   **차단 transport이거나**, 떠난 장치가 입력 가능했거나 타깃이었을 때만 처리한다.
   `inputCapableUIDs`를 유지하는 이유는 이미 떠난 장치는 조회할 수 없기 때문이다.
2. **차단 transport 도착은 출력 전용이어도 관련 있음으로 처리.** ①만 적용하면 회귀가 생긴다 —
   AirPods는 출력 객체를 입력 객체보다 약 16ms 먼저 publish하고, 실측 로그에서
   **그 출력 객체 이벤트가 되돌리기를 촉발했다**(macOS가 입력 객체 publish 전에 이미 기본 입력을
   옮겼다). 2차 재연결에서는 출력 객체만 신규로 등록됐다. LG는 `dprt`로 차단 목록에 없으므로 계속 걸러진다.
3. **상태 파일 중복 쓰기 제거.** `transition()`이 무조건 쓰던 것을 상태 또는 이유가 바뀔 때만
   쓰도록 변경. 이전의 stale-hold 버그 수정은 유지된다 — `micpin on`은 항상 새 이유를 들고 온다.
   상태 전이 시 로그 로테이션(256KB)도 함께 수행한다.
4. **검사 스크립트 판정 로직 수정.** `idlew`를 누적값으로 표기하고 시간당 비율로 환산(참고용),
   CPU 임계값을 5초로 현실화, 장치별 `ARRIVED` 횟수를 출력해 플래핑 재발을 바로 볼 수 있게 했다.

회귀 확인: 비차단 transport 수동 선택 존중 → `micpin on` 복귀 통과. 1일차 결과는
`leakcheck-result-day1.txt`에 보존.

## 2일차 점검 예약

기준 4209 KB / CPU 0:00.06 / 로그 3453줄 → **2026-09-10 15:51** 실행.

## LG 플래핑 원인 추적 및 수정 효과 실측 (2026-09-09 16:11)

사용자 가설: "LG 모니터 스피커를 사용한 것이 원인." **부분적으로만 맞다.**

- LG는 실제로 기본 출력이었다(`system_profiler`에서 `Default Output Device: Yes` 확인).
- **그러나 스피커 선택 자체가 트리거는 아니다.** micpin과 독립적인 관찰기로 90초간
  HAL 장치 집합을 1초 간격 샘플링한 결과 **변화 0건** — LG가 기본 출력인 상태에서도 플래핑이 없다.
- 시간대 분포가 더 그럴듯한 설명을 준다: 01–09시 연속(시간당 319회), **13시 0회**,
  10·11·12·14시 간헐적. **작업 중에는 발생하지 않고 유휴 구간에 발생한다** —
  디스플레이가 저전력 상태를 오갈 때 오디오 엔드포인트가 재등록되는 것으로 보인다. 확증은 못 했다.
- LG UID: `<display-uid>`

### 수정 효과 실측 (1000회 벤치마크)

걸러지는 이벤트의 남은 비용은 `allDevices()` + 장치당 `deviceUID()` 뿐이다:

| | 수정 전 | 수정 후 |
|---|---|---|
| 이벤트 1건당 | 10.1 ms | **0.070 ms** |
| 3243건/일 환산 | 32.6 초 | **0.23 초** |

**145배 감소.** 밤새 플래핑이 계속돼도 무의미한 수준이므로 추가 최적화는 하지 않는다.
(검토했으나 기각: `AudioDeviceID`→UID 캐시로 장치당 조회를 없애는 방안. 0.23초를 더 줄이려고
"ID를 캐시하지 않는다"는 원칙을 깨고 ID 재사용 경합 위험을 들이는 것은 손익이 맞지 않는다.)

### 부수 효과 — 진단 정보 손실

micpin이 LG를 완전히 무시하므로 **앞으로 로그에 `ARRIVED LG`가 아예 남지 않는다.**
플래핑 재발 여부는 로그로 알 수 없고, CPU 수치(0.070ms × N)에만 간접적으로 반영된다.
직접 확인하려면 독립 관찰기가 필요하다. 데몬의 일이 디스플레이 감시는 아니므로 이 교환은 타당하다.

---

# 2일차 점검 (2026-09-10 15:53) — PASS, 그러나 미해결 사건 1건

## 수정 효과 확정

| 지표 | 1일차 (수정 전) | 2일차 (수정 후) | 개선 |
|---|---|---|---|
| `phys_footprint` 증가 | +3616 KB | **+224 KB** | 16배 |
| CPU 누적 | 32.61초 | **0.59초** | 55배 |
| 로그 증가 | +3243줄 | **+18줄** | 180배 |
| idle wakeups | 58 (24h) | **3 (24h)** | — |
| `ARRIVED LG` 신규 | 3243 | **0** | 필터 작동 |

프로세스는 24시간(`01-00:02:56`) 연속 실행, 크래시 재기동 없음. 판정 **PASS**.
실사용도 정상 — AirPods 되돌리기가 13:42·14:35 등에서 작동했다.

## 미해결 — 상태 불일치 1건

점검 직후 확인한 실제 상태:
```
default input: AirPods Pro 3 [blue]   ← 실제
target[0]:     Elgato Wave:1  — present     ← 연결돼 있음
state:         PINNED (14:35:20 기준)        ← 데몬은 고정됐다고 믿는 중
```
**14:35:20.938의 `REVERT` 이후 16:08까지 약 1.5시간, 로그가 한 줄도 없다.**
되돌리기도 `YIELDED`도 없이 기본 입력이 AirPods에 머물렀다.

**배제한 원인:**
- 잠자기 — `pmset -g log`에 Sleep/Wake 없음, Amphetamine이 잠자기 차단 중이었음
- `coreaudiod` 재시작 — 9/8 15:35(수동 kill) 이후 계속 실행 (`etime 02-00:34`)
- 프로세스 재기동 — micpin `etime 01-00:18` 연속
- work 큐 교착 — SIGHUP이 즉시 작동해 되돌림
- `'dIn '` 리스너 사망 — 직후 시험에서 정상 발화, 올바르게 `YIELDED`

**원인 규명 실패.** 남은 가장 그럴듯한 설명은 알림 유실이지만 확증 불가.

## 대응 — 알림을 놓치면 조용히 포기하던 경로 3곳 수정

원인이 아닐 수도 있으나 그 자체로 결함이다.

1. **`defaultInputDevice()`가 nil이면 조용히 return**하던 두 곳(`evaluate`, `applyPin`).
   그 이벤트를 소비하고 아무도 재시도하지 않았다 → 로그 + 2초 뒤 1회 재판정.
2. **디바운스 리셋에 상한이 없었다.** 알림이 `debounceMs`보다 빠르게 연속 도착하면
   `evaluate()`가 무한정 밀린다 → 첫 알림으로부터 1초가 지나면 즉시 판정.
3. **되돌리기 후 5초 시점에 1회 재판정**(`scheduleReconcile`). 보험이지 수정이 아니다 —
   알림이 유실됐다면 증거가 아직 도착 창 안에 있을 때 한 번 더 판단할 기회를 준다.
   전부 일회성·자동 해제라 유휴 타이머는 0을 유지한다(배포 후 `idlew` 1 확인).

## 점검 스크립트에 상태 일치 검사 추가

`state=PINNED`인데 실제 기본 입력이 타깃과 다르면 `FAIL`. 하루 1회 샘플이라 1.5시간짜리
사건을 잡을 확률은 낮지만 비용이 없다.

## 3일차 예약

기준 4209 KB / CPU 0:00.07 / 로그 3489줄 → **2026-09-11 16:12**.

---
