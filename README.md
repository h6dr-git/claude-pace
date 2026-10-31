# claude-pace — AI 사용량 메뉴바 게이지

[![build](https://github.com/h6dr-git/claude-pace/actions/workflows/build.yml/badge.svg)](https://github.com/h6dr-git/claude-pace/actions/workflows/build.yml)

Claude·Codex 구독 한도(5시간·주간)를 지금 얼마나 썼는지, 언제 리셋되는지, 이 속도면 리셋 전에 바닥나는지를 macOS 메뉴바의 링 하나로 보여 주는 앱.

> 비공식 개인 프로젝트 — Anthropic·OpenAI와 관계없음. 공식 CLI 명령(`claude -p "/usage"`, `codex app-server`)만 쓰고, 비공식 API·세션 쿠키·OAuth 토큰 직접 호출은 하지 않음.

## 보여 주는 것
- **메뉴바 링**: 고른 공급자의 공식 조회값만 표시. Claude는 5시간 창 우선, `/usage`가 주간만 내면 주간 창으로 대체.
- **클릭(드롭다운)**: 주간·5시간 한도와 리셋 시각, 모델별 주간 버킷, 수집 기록 요약.
- **페이스**: 지금 속도가 이어지면 리셋 때 몇 %가 될지(`사용률 ÷ 경과 비율`). 90% 미만 여유 · 90~110% 적정 · 110% 초과 과속. 창의 처음 5%는 판단 보류.
- **갱신**: 공식 조회 180초, 화면 다시 그리기 10초. `지금 갱신`(⌘R)으로 즉시 조회. 잠자기에서 깨면 네트워크가 돌아올 8초 뒤 바로 조회하고(Claude는 결과가 정상이 아니면 30초 뒤 한 번 더, 마지막 값이 180초 안이면 건너뜀), 메뉴를 열면 바로 다시 그린 뒤 조회할 때가 됐으면 조회. 열려 있는 메뉴는 포인터 아래서 다시 만들지 않고 닫힐 때 갱신.

## 설계에서 정한 것
- **틀린 숫자보다 빈칸**: 읽을 값이 없으면 링 대신 `?`. 0%로 그리지 않음. 퍼센트·리셋이 없거나 범위를 벗어난 값도 "읽을 값 없음"으로 처리.
- **멈추면 이유를 표시**: 로그아웃·한도 줄 없음·해석 실패·시간 초과 같은 사유를 메뉴에 그대로 띄움. `claude` 호출은 한 번에 60초까지만 기다려서, CLI가 멈춰도 다음 조회는 돎. 마지막 값이 24시간 안이면 「⚠ 수집 중단」 구획과 함께 보여 줘서, 멈춘 숫자가 현재값처럼 읽히지 않게 함.
- **조회가 안 돌아도 표시**: 실패가 아니라 조회 자체가 없을 때(맥이 잠들어 있었거나 조회가 멈춤)는 사유가 남지 않으므로 값의 나이로 판단. 마지막 값이 10분(180초 조회 세 번)을 넘으면 메뉴의 Claude 제목 바로 아래에 「⚠ 갱신 멈춤」과 그 값의 시각·마지막 조회 시도를 띄우고 메뉴바 링을 흐리게 그림. 조회 중이면 「↻ 다시 조회하는 중」, 조회 하나가 깨어 있는 시간으로 5분을 넘기면 「⚠ 조회가 멈춤」. 다른 공급자 모드의 「Claude · 전환 보조」 구획에는 값의 나이와 그 모드에선 조회하지 않는다는 점만 표시.
- **리셋이 지난 창은 0%로 굴리지 않음**: 마지막 값을 읽은 뒤 리셋 시각이 지난 창은 그 퍼센트를 버리고 "○시에 창 끝남 · 새 값은 다음 조회 때"로 표시. 다음 5시간 창은 다음 메시지 때 열려서 리셋 시각을 앱이 알 수 없고, 그동안 쓴 양도 모름. 리셋 뒤 조회에도 새 창이 없으면(`/usage`는 창 사이에 5시간 줄을 생략) "지금 열린 창 없음". 링은 주간 창으로 대체하고, 쓸 창이 하나도 없으면 `?`. 조회기도 같은 원칙: 퍼센트는 있는데 리셋을 못 읽은 줄은 이미 지난 리셋을 물려받지 않고 리셋을 비움.
- **로그인 여부 선확인**: 로그아웃 상태의 `/usage`는 오류 없이 한도 줄만 빠진 출력을 냄. 그래서 조회 전에 `claude auth status`를 먼저 확인해 "출력 형식이 바뀐 것"으로 오진하지 않음.
- **공급자 게이트**: 환경 변수 하나(`AI_USAGE_PRIMARY_PROVIDER`)가 정한 공급자만 수집. 값이 없거나 오타면 아무것도 수집하지 않음(fail-closed). 공급자를 바꿔도 이전 공급자의 폴링이 되살아나지 않음.
- **기록은 지우지 않음**: 사용량 원장이 50MiB를 넘거나 월이 바뀌면 통째로 보관 폴더로 옮김. 옮기기 전에 모든 줄이 JSON인지 검사하고, 하나라도 깨져 있으면 회전 거부. 보관본은 수정·압축·삭제하지 않음.

## 요구 사항
- macOS 13 이상, Swift 도구(Xcode 명령어 라인 도구)
- Claude 모드: 로그인된 Claude Code CLI(`claude`) · Codex 모드: Codex CLI(`codex`)

수집기가 전부 앱 실행 파일 안에 있어서 `jq`·`python3`는 필요 없음(테스트에만 씀).

## 빌드 & 실행
어디에 클론해도 됨. 빌드된 실행 파일 하나(`.build/release/ClaudePace`)로 돌아가므로 원하는 곳에 복사해 써도 됨.

```sh
git clone https://github.com/h6dr-git/claude-pace
cd claude-pace
swift build -c release
AI_USAGE_PRIMARY_PROVIDER=claude .build/release/ClaudePace   # Codex는 codex
```

`claude`는 `PATH` → `/opt/homebrew/bin` → `~/.local/bin`(네이티브 설치) 순으로 찾음.

| `AI_USAGE_PRIMARY_PROVIDER` | 메뉴바 링 | 수집 |
|---|---|---|
| `claude` | Claude 5시간·주간 한도 | `claude -p "/usage"` 180초마다 · `~/.claude/projects` 세션 기록 60초(처음 한 번은 30일치) |
| `codex` | Codex 계정 한도 | `codex app-server` 조회 180초 · `~/.codex/sessions` 기록 60초 |
| 그 밖의 값 · 없음 | `?` (확인 불가) | 없음 |

### 로그인 때 자동 실행 (선택)
`~/Library/LaunchAgents/local.claude-pace.plist`로 저장하고 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.claude-pace.plist`. 경로는 빌드(또는 복사)한 `ClaudePace` 실행 파일의 전체 경로로.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.claude-pace</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/<사용자명>/claude-pace/.build/release/ClaudePace</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>AI_USAGE_PRIMARY_PROVIDER</key>
        <string>claude</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
```

## 데이터 위치
`~/Library/Application Support/ClaudePace/` 아래:
- `snapshot.json` — Claude 스냅샷. 모델별 주간 버킷은 `modelWindows`에 이름 그대로 들어가서 모델명이 바뀌어도 코드 수정 불필요
- `codex-snapshot.json` — Codex 스냅샷
- `claude-collector-state.json` — 마지막 수집 결과(`ok` · `signed-out` · `no-limits` · `cli-missing` · `empty-output` · `parse-failed` · `timed-out`). 스키마가 다르거나 모르는 값이면 성공이 아니라 수집 차단으로 읽음
- `usage-log.jsonl` — 사용량 원장(`usage.v1`). 회전된 세그먼트와 색인(`.summary.json`)은 `archive/`
- `usage-history-summary.json` — 60초마다 갱신되는 경량 요약(보관본은 다시 훑지 않고 색인만 합산)
- `.claude-session-offsets/` · `.claude-session-seen` · `.claude-session-backfill-done` — Claude 세션 기록 수집의 파일별 읽은 위치·넣은 이벤트 id·첫 30일치 수집 완료 표시(Codex는 `.codex-offsets/` · `.codex-usage-seen`)
- `.debug/last-input.json` — statusLine이 마지막으로 받은 입력 원문(등록한 경우에만)

### statusLine — 지금은 등록할 필요 없음
예전엔 Claude Code `statusLine`으로 한도가 들어왔지만, 2.1.x부터 statusLine 입력에 `rate_limits`가 없고 데스크톱 앱은 statusLine을 렌더하지 않음(2026-08-20 실측). 한도는 `/usage` 조회가 담당. 등록해 둬도 한도가 없는 입력으로는 `snapshot.json`을 건드리지 않고 기록(원장·디버그 덤프)만 남김. Claude Code가 다시 `rate_limits`를 보내면 그때부터 스냅샷도 갱신.

## 구조
- `Sources/ClaudePace/` — AppKit 메뉴바 앱, 서드파티 의존성 0
- `Sources/ClaudePace/Collectors/` — 수집기. 예전 `tools/`·`bridge/` 스크립트를 Swift로 옮긴 것으로, 앱 안에서 직접 돌고 하위 명령으로도 실행 가능

| 하위 명령 (`ClaudePace <명령>`) | 하는 일 | 예전 스크립트 |
|---|---|---|
| `statusline` | Claude Code `statusLine` 명령(표준 입력 JSON) | `bridge/statusline.sh` |
| `poll-usage` | `claude -p "/usage"`로 한도를 읽어 스냅샷·수집 상태 기록(`CLAUDE_BIN`으로 실행 파일, `CLAUDE_USAGE_TIMEOUT`으로 호출당 제한 시간(초, 기본 60) 지정 가능) | `tools/poll-usage.sh` |
| `poll-codex-usage` | `codex app-server`를 잠깐 띄워 읽기 요청 2개만 보내고 바로 종료(모델 턴 없음) | `tools/poll-codex-usage.py` |
| `ingest-codex-sessions` · `ingest-claude-sessions` | `~/.codex/sessions`·`~/.claude/projects` 세션 기록의 토큰 사용량을 원장 형식으로 정규화 | `tools/ingest-*-sessions.sh` |
| `usage-log-rotate` · `usage-log-segment-summary` · `usage-history-summary` | 원장 회전·세그먼트 색인·경량 요약 | `tools/usage-log-*.sh` · `tools/usage-history-summary.sh` |
| `usage-daily-deltas` · `usage-monthly-summary` | 일별·월별 보고서 | `tools/usage-daily-deltas.sh` · `tools/usage-monthly-summary.sh` |

인자·환경 변수·출력·종료 코드는 예전 스크립트와 같음(더해진 것: 위 시간 제한). 모르는 명령이면 앱을 띄우지 않고 사용법을 출력한 뒤 64로 끝남. 목록은 `ClaudePace help`.

### 스크립트 버전에서 넘어올 때
- `git pull` 후 `swift build -c release`로 다시 빌드. LaunchAgent는 실행 파일 경로만 맞으면 그대로 씀
- statusLine을 등록해 뒀다면 명령을 `…/ClaudePace statusline`으로 바꾸거나 `~/.claude/settings.json`에서 뺌(`bridge/statusline.sh`는 없어짐). 지금은 등록할 필요 없음(위 「statusLine」 참고)
- 원장·오프셋·처리 기록은 그대로 이어 씀. 이벤트 id·파일 경로 규칙이 예전과 같아서 이미 넣은 기록을 다시 넣지 않음

## 겪은 문제
- **조회마다 뜨는 권한 팝업**: launchd처럼 작업 디렉터리 없이 `claude`를 실행하면 Claude Code가 `$HOME`을 프로젝트 루트로 보고 훑다가 `~/Library/Application Support/*` 같은 보호 영역에 닿아, 조회할 때마다 "claude를 허용하시겠습니까?" 팝업이 뜸 → 빈 디렉터리(`~/.claudepace/cwd`)에서 실행하고, MCP 서버·크롬 브리지를 끈 채(`--strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-chrome`) 조회.
- **로그인돼 있는데 로그아웃으로 보고**: `USER` 환경 변수가 없으면 CLI가 키체인의 로그인 정보를 못 읽음. launchd는 환경을 거의 안 넘겨서, 앱이 `HOME`·`USER`·`PATH`를 직접 넘김.
- **세션 목록이 조회 찌꺼기로 뒤덮임**: 180초마다 조회하니 이틀 만에 빈 세션 파일이 314개 쌓여 실제 세션 목록이 묻힘 → `--no-session-persistence`.

팝업 재발 확인(zsh 내장 `log`와 겹치므로 전체 경로로):
```sh
/usr/bin/log show --last 30m --info --debug --predicate 'subsystem == "com.apple.TCC"' | grep AUTHREQ_PROMPTING
```

## 테스트
먼저 `swift build -c release`. 가짜 `claude`·`codex`를 PATH에 올려 실계정을 건드리지 않고 검증(테스트에는 `jq`·`python3` 필요). GitHub Actions(macOS)에서 커밋마다 전부 돌림.
```sh
tests/test-cli.sh                        # 하위 명령 분기, 모르는 명령이면 앱을 띄우지 않고 64로 종료
tests/test-claude-usage-poll.sh          # /usage 출력 형태별 동작, 로그아웃·빈 출력·CLI 부재·시간 초과·한도 없는 statusLine에서 스냅샷 보존
tests/test-session-ingest.sh             # 쓰는 중이던 세션 줄을 다음 실행에서 빠짐없이, 한 번만 수집
tests/test-usage-provider-selection.sh   # 공급자별 fail-closed, 0% 대신 "읽을 값 없음"
tests/test-usage-log-rotation.sh         # 임계·월 경계 회전, 바이트·행 보존, 깨진 JSON 회전 거부
tests/test-parity.sh                     # 예전 스크립트(git 이력)와 Swift 수집기를 같은 입력으로 돌려 결과 파일 대조(일부러 바꾼 동작은 tests/parity/apply-intended-changes.py에 명시)
```

## 제거
```sh
launchctl bootout "gui/$(id -u)/local.claude-pace" 2>/dev/null
rm -f ~/Library/LaunchAgents/local.claude-pace.plist
# 기록까지 지우려면 ~/Library/Application Support/ClaudePace 폴더 삭제
# statusLine을 등록했다면 ~/.claude/settings.json의 "statusLine" 항목 삭제
```

## 한계
- Codex app-server 스키마는 설치된 Codex CLI 버전에 따라 달라질 수 있음. 조회가 실패하면 마지막 정상 스냅샷 유지.
- 토큰 통계는 공식 응답이 주는 범위만 표시하고 비용·청구액으로 환산하지 않음.
- 구독이 끝나 조회가 실패하면 마지막 값은 보존되지만, 24시간이 지나면 메뉴에서 숨김.

## 만든 방식
기능·설계 결정과 실측 검증은 직접, 코드는 AI 코딩 도구(Claude Code)로 작성.

## 라이선스
[MIT](LICENSE)
