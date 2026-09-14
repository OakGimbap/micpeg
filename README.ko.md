# micpeg

**AirPods를 연결해도 USB 마이크가 macOS 기본 입력으로 남아 있게 합니다.**

[English README](README.md)

---

## 문제

블루투스 헤드셋을 연결하면 macOS는 기본 출력**과** 기본 **입력**을 둘 다 그쪽으로 옮깁니다.
출력은 대개 그게 맞지만 입력은 거의 항상 틀립니다 — 소리를 들으려고 AirPods를 연결한 것이지
마이크 품질을 낮추려고 연결한 게 아니니까요.

특히 **OS 기본 입력을 그대로 쓰면서 마이크 선택 UI가 없는 앱**에서 문제가 됩니다.
Claude Code의 voice mode가 그렇습니다 — push-to-talk을 누르는 그 순간에 장치를 결정하기 때문에,
마이크가 조용히 이어버드로 넘어가 있으면 **아무 표시 없이** 더 나쁜 녹음이 만들어집니다.

이 동작을 끄는 1st-party 설정은 없습니다. `com.apple.coreaudio`와
`com.apple.audio.AudioMIDISetup`은 preference 도메인 자체가 존재하지 않고,
`defaults domains` 전수 조사에도 억제 키가 없습니다.

## micpeg이 하는 일

CoreAudio의 기본 입력 속성을 감시하다가 macOS가 그것을 블루투스 장치로 넘기면 되돌리는
약 4MB짜리 launchd 에이전트입니다.

- **입력만 건드립니다.** 백그라운드 에이전트의 소스에는 `DefaultOutputDevice` /
  `DefaultSystemOutputDevice` 문자열이 없고, CI가 이를 검사합니다. 설정 앱은 기본 출력을
  표시하려고 읽기만 할 뿐 CoreAudio에 아무것도 쓰지 않습니다. 출력은 원래대로 AirPods가 가져갑니다.
- **직접 고른 선택은 존중합니다.** 사용자가 다른 마이크를 고르면 물러납니다.
  시스템이 한 것으로 판단되는 전환만 되돌립니다.
- **사실상 공짜입니다.** idle wakeup 0회, `phys_footprint` 약 4MB, 실사용 24시간 동안 CPU 0.59초.
  타이머도 폴링도 없이 `CFRunLoopRun()`에 파킹해 있다가 CoreAudio 알림이 올 때만 깨어납니다.
  → [docs/verification.md](docs/verification.md)
- **에이전트는 마이크를 열지 않습니다.** 라우팅 설정을 바꿀 뿐 캡처하지 않으므로 주황색 녹음
  표시도, TCC 권한 요청도 없고, 지금 마이크를 쓰고 있는 앱을 방해하지도 않습니다. 설정 앱은
  입력 테스트를 돌리는 동안에만 마이크를 열고, 그때 처음 한 번 권한을 요청합니다.

## 두 부분

- **`micpeg`** — launchd 에이전트와 그 커맨드라인. 이 프로젝트의 본체이고, 완성돼 있습니다.
  아래 설치·명령어 항목은 전부 이쪽 이야기입니다.
- **`Micpeg.app`** — 마이크를 고르고, 에이전트가 동작 중인지 확인하고, 입력 테스트를 돌리는
  작은 SwiftUI 설정 앱입니다. 만들어 두고 검증도 했지만 **아직 배포하지 않습니다.** 서명된
  다운로드가 없고, `./scripts/bundle.sh`는 가지고 있는 개발 인증서로 서명할 뿐이라 직접 쓰기에는
  충분해도 남에게 건네기에는 부족합니다. Developer ID 빌드가 다음 작업입니다.

## 요구 사항

- macOS 14 (Sonoma) 이상
- Swift 5.9 이상 툴체인 (Xcode 또는 Swift 커맨드라인 도구)

에이전트 자체는 둘 다 필요 없습니다 — CoreAudio와 Foundation만 링크하므로 훨씬 낮은 버전에서도
돕니다. 하한은 설정 앱에서 옵니다(`@Observable`이 macOS 14 전용). SwiftPM의 `platforms:`는
패키지 전체에 적용되므로 에이전트가 그 하한을 물려받습니다.

> **정직한 범위 고지:** macOS 14+로 빌드되지만 **실기기 검증은 macOS 26(26.6)에서만** 했습니다.
> 특히 `kAudioHardwarePropertyServiceRestarted`(HAL 재시작 복구 훅)가 macOS 14·15에서 실제로
> 발화하는지는 미검증입니다. 발화하지 않으면 리스너가 안 불릴 뿐 해롭지는 않습니다.

## 설치

고정하려는 마이크를 연결하고 기본 입력으로 선택한 다음:

```sh
git clone https://github.com/OakGimbap/micpeg.git
cd micpeg
./scripts/install.sh
```

빌드 → `~/.local/bin/micpeg` 복사 → `~/Library/LaunchAgents/com.micpeg.agent.plist` 작성 →
**현재** 기본 입력으로 설정 초기화 → 에이전트 시작까지 한 번에 합니다. `sudo`가 필요 없습니다 —
전부 홈 디렉터리 안에서 끝납니다.

이 스크립트가 설치하는 것은 에이전트이고 앱이 아닙니다. 이미 `Micpeg.app`이 에이전트를 관리하고
있으면 스크립트가 거부합니다 — 하나의 launchd 레이블이 두 개의 등록 경로를 가질 수는 없습니다.

유니버설(Apple Silicon + Intel) 바이너리: `MICPEG_UNIVERSAL=1 ./scripts/install.sh`

`~/.local/bin`이 `PATH`에 있는지 확인한 뒤:

```sh
micpeg status
```

```
enabled:       true
default input: Elgato Wave:1 [usb ]
target[0]:     Elgato Wave:1  — present
state:         PINNED  (default input is the target)
updated:       2026-09-10 16:12:05.732
daemon:        pid = 20138
```

### 업데이트

```sh
git pull
./scripts/install.sh
```

스크립트가 새로 빌드한 바이너리를 직접 배치한 뒤 에이전트를 다시 부트스트랩하므로
업데이트가 실제로 반영됩니다.

## 명령어

| 명령 | 동작 |
|---|---|
| `micpeg status` | 현재 상태, 고정 대상, 실제 기본 입력, 데몬 생존 여부 |
| `micpeg list` | 입력 장치 전체를 transport type·UID와 함께 나열 |
| `micpeg pick` | 현재 기본 입력을 고정 대상으로 지정 (이전 대상은 대체됨) |
| `micpeg on` / `off` | 고정 재개 / 일시 중지 (yield도 함께 해제) |
| `micpeg install` | 설정 + LaunchAgent 작성 후 에이전트 부트스트랩 |
| `micpeg uninstall` | 에이전트 bootout + LaunchAgent 제거 |
| `micpeg daemon` | 포그라운드 실행 (launchd 전용) |

고정 대상을 바꾸려면 시스템 설정에서 그 마이크를 고른 뒤 `micpeg pick`을 실행하세요.

## 설정

`~/.config/micpeg/config.json` — [`config.example.json`](config.example.json) 참고.
재시작 없이 재적용하려면 `launchctl kill SIGHUP gui/$(id -u)/com.micpeg.agent`,
아니면 그냥 `micpeg on`.

| 키 | 기본값 | 의미 |
|---|---|---|
| `enabled` | `true` | 마스터 스위치. `micpeg off`가 이 값을 씁니다. |
| `input.priority` | *(설치 시 자동)* | `{uid, name}` 순서 목록. 연결돼 있는 첫 항목이 대상. UID를 우선 매칭하고 `name`은 폴백입니다. `micpeg pick`은 항목 하나로 덮어씁니다. 여러 항목은 직접 편집할 때만 생깁니다. |
| `blockTransports` | `["bluetooth", "bluetoothle"]` | 되돌릴 transport. 나머지는 전부 의도적 선택으로 봅니다. |
| `arrivalWindowSeconds` | `15` | 차단 대상 장치가 이 시간 내에 도착했다면 자동 전환이지 사용자 결정이 아닙니다. |
| `debounceMs` | `300` | 알림 폭주를 합칩니다. |
| `reverifyDelaySeconds` | `1.0` | 쓰기가 삼켜졌을 경우를 대비해 1회 재확인합니다. |
| `postWriteGraceSeconds` | `3.0` | micpeg이 쓴 직후 이만큼 안에 기본값이 옮겨졌다면 macOS의 flip-back이지 사람이 한 게 아닙니다. |

장치 UID는 재부팅과 USB 포트 변경을 견딥니다(USB 마이크의 UID에는 시리얼 번호가 박혀 있습니다).
micpeg이 이름이나 device ID가 아니라 UID를 대상으로 삼는 이유입니다.

**`virtual`이나 `unknown`을 `blockTransports`에 넣지 마세요.** Elgato는 MicrophoneFX 사용 시
Wave Link *가상* 장치를 기본 입력으로 지정하라고 안내하고, Continuity iPhone Mic은 `ccwd`로
보고됩니다. 이것들을 차단하면 사용자와 정면으로 충돌합니다.

## 동작 원리

시스템 객체에 `AudioObjectAddPropertyListenerBlock` 리스너 3개 — 장치 목록(`dev#`),
기본 입력(`dIn `), HAL 재시작(`srst`) — 를 걸고 5-상태 기계
(`ABSENT` / `PINNED` / `YIELDED` / `PAUSED` / `BACKOFF`)로 판정합니다.

자동인지 의도적인지는 **타이밍이 아니라 transport type**으로 1차 판정합니다. macOS가 스스로
기본 입력을 가져가는 경로는 블루투스뿐이기 때문입니다. 타이밍은 보조 신호이고,
가장 강한 증거는 micpeg 자신의 쓰기 시각입니다 — micpeg이 쓴 400ms 뒤에 기본값이 옮겨졌다면
그건 사람이 한 일이 아닙니다.

출시 전 발견해 고친 설계 결함 3건을 포함한 전체 근거는 **[docs/design.md](docs/design.md)**(영문),
개발 당시의 원본 기록은 [docs/ko/engineering-log.md](docs/ko/engineering-log.md)에 있습니다.

## 의도적으로 하지 않는 것

- 기본 출력·시스템 출력을 건드리는 것 — **옵션으로도 제공하지 않습니다.** 설정 스키마에 없으므로
  실수로 켜질 수가 없습니다.
- 대상 마이크가 빠졌을 때 다른 마이크로 강제 전환하는 것. 대상이 없으면 `ABSENT`가 되어 아무것도
  하지 않고, macOS가 평소대로 동작합니다.
- 폴링 루프. `StartInterval 5` 방식이었다면 하루 17,280번 깨어납니다.

## 알려진 한계

- **블루투스 마이크를 연결 후 약 15초 안에 직접 고르면 한 번 되돌려집니다.**
  CoreAudio 어디에도 "누가 이 변경을 시작했는가"를 알려주는 신호가 없어서
  (`log stream --predicate 'subsystem == "com.apple.coreaudio"'`가 이 전환에 대해 0줄을 냅니다)
  휴리스틱이 불가피합니다. 잠시 뒤 다시 고르거나 `micpeg off`를 쓰세요.
- 로그인 직후와 `coreaudiod` 재시작 직후 약 15초도 마찬가지입니다.
- 설치 경로가 `~/.local/bin`으로 고정돼 있습니다.
- **미해결 사건 1건:** 2026-09-10에 에이전트가 `PINNED`를 보고하는 동안 실제 기본 입력이
  약 1.5시간 블루투스 헤드셋에 머물렀고 그동안 로그가 0줄이었습니다. 잠자기, `coreaudiod` 재시작,
  프로세스 재기동, 큐 교착, 리스너 사망은 모두 배제했고 알림 유실이 남은 가설입니다.
  조용히 포기하던 경로 3곳을 보험으로 보강했습니다. `micpeg status`로 탐지되고 `micpeg on`으로
  즉시 복구됩니다.

## 제거

```sh
micpeg uninstall
rm -rf ~/.config/micpeg ~/Library/Logs/micpeg.log ~/.local/bin/micpeg
```

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
