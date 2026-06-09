# State

## Current Wave

- **Wave:** 3 — Android 실기기 테스트 + 버그 수정 계속
- **Status:** Active
- **Cache Status:** DIRTY (2026-06-09 수정 반영 필요)
- **Last Checkpoint:** v1.0.X — BLE 크래시 수정 + LAN 안정화 + SCAN LAN 지원 (2026-06-09)

## Wave History

| Wave | 작업 내용 | 상태 | 날짜 |
|------|-----------|------|------|
| 1 | 아키텍처 설계 + 2회 독립 리뷰 | ✅ 완료 | 2026-06-01 |
| 2 | MVP 구현 (Android + Windows) | ✅ 완료 | 2026-06-01 |
| 3 | 실기기 테스트 + 버그 수정 | 진행 중 | 2026-06-02 |

## Wave 3 진행 상황

### 2026-06-03 Phase-1 UI shell
- [x] Windows initial window changed to portrait ratio (`430 x 800`)
- [x] Top system menu: LAN, Wi-Fi, BLE status buttons and Settings / Power actions
- [x] BLE toggle controls scan, advertising, and active BLE connections
- [x] Home left rail: All, Group, favorites filters
- [x] Contacts and local groups sorted with favorites first, then name ascending
- [x] Bottom navigation: Home, Search, SCAN, QR
- [x] Search view for local contacts and groups
- [x] SCAN entry screen with Tree, SCAN START, and N-depth input
- [x] GPS/Map removed from planned scope
- [x] Shout policy set to 50 chars and 1 day cooldown
- [x] Group rows derived from local contact metadata with rename, favorite, delete menus
- [x] Phase-1 sort/group unit tests added

### 2026-06-03 physical BLE verification
- [x] Galaxy S26 Ultra APK install and Android BLE runtime permission handling
- [x] PC <-> S26 direct TEXT: PC -> S26 hop=0
- [x] S21+ <-> S26 Ultra direct TEXT: S21+ -> S26 hop=0
- [x] S21+ <-> PC <-> S26 Ultra relay TEXT: S21+ -> S26 hop=1
- [x] S21+ <-> S26 Ultra <-> PC relay TEXT: S21+ -> PC hop=1
- [x] PC <-> S21+ <-> S26 Ultra relay TEXT: PC -> S26 hop=1
- [x] Samsung peer scan compatibility: request location permission with Bluetooth permissions

### 완료
- [x] Android APK 빌드 + Galaxy S21+ 설치 성공
- [x] Android BLE 광고 + Peripheral GATT 서버 구현 (`ble_peripheral`)
- [x] 코드 리뷰 Critical 3개 수정 (릴레이 재서명, DoS, R-14)
- [x] 초기화 순서 Race Condition 수정 (W-3)
- [x] QR 코드 → 연락처 등록 테스트 ✅
- [x] 홈 화면 UI 정상 동작 확인 ✅
- [x] Windows에서 S21+ `MeshComm` 광고 발견 ✅
- [x] Windows Central → S21+ GATT 연결 + CCCD notify 구독 ✅
- [x] 중복 scan result 연결 경쟁 조건 수정 (`_connectingDevices`) ✅
- [x] 연결 후 `KEY_ANNOUNCE` 자동 재전송 + 수동 재전송 UI ✅
- [x] Windows → S21+ central write 암호화 TEXT 수신 ✅
- [x] S21+ → Windows peripheral notify 암호화 TEXT 수신 ✅
- [x] 릴레이된 자체 패킷 echo 조기 drop ✅
- [x] DB v2 마이그레이션 (`is_favorite`, `group_name`) ✅
- [x] 연락처 `...` 메뉴: 삭제, Group 추가/변경, 즐겨찾기, 로컬 이름 변경 ✅
- [x] 자기 연락처 자동 정리, Windows DB `SELF_CONTACT_COUNT=0` 확인 ✅
- [x] Android 이름 변경 후 빨간 오류 화면 수정 (`TextFormField.initialValue`) ✅
- [x] DB v3 마이그레이션: identity/contact에 X25519 메시지 암호화 키 저장 ✅
- [x] TEXT 공개 node ID 기반 임시 키 제거, X25519 ECDH + AES-GCM 적용 ✅
- [x] BLE 저 MTU fragmentation/reassembly 구현, Windows MTU 23 실기기 검증 ✅
- [x] GATT characteristic 캐싱 + notify 구독 정리 ✅
- [x] 서명된 heartbeat PING/PONG 활성화, 30초 주기 실기기 검증 ✅
- [x] KEY_ANNOUNCE 상호 응답 및 반복 응답 제한 ✅
- [x] Windows ↔ S21+ Phase-0 TEXT 양방향 복호화 수신 확인 ✅

### 남은 검증
- [ ] `flutter_blue_plus_winrt`가 실패하는 별도 PC 환경이 확인되면 `win_ble` 교체 재검토

### 다음 단계
- [ ] 두 번째 Android 폰 확보 후 폰↔폰 BLE 메시지 전송 테스트
- [ ] A ↔ PC ↔ B ↔ C 물리 기기로 3홉 릴레이 E2E 검증
- [ ] 로컬 개인키 seed 암호화 저장

## Session Notes

- 2026-06-07: PC BLE 페어링 제약 확인. 코드 문제 아님 — Windows Bluetooth 어댑터 수준에서 핸드폰 수동 페어링(Windows 설정) 필요. S21+, S26 Ultra 페어링 후 BLE 발견·연결 정상. 함의: PC는 거점 릴레이, 재난 즉석 메시 핵심은 Android 폰. README/trouble-shooting/CACHE/active-context 모두 반영.
- 2026-06-07: 파일 전송 targetId 버그 수정. fileHeader/fileChunk/fileAck 수신 처리 시 targetId 확인 없어서 3기기 환경에서 비대상 기기도 파일 패킷 처리 → race condition → 청크 누락 → 0% stuck. _handleIncomingPacket switch 3곳에 _bytesEqual(targetId, myNodeId) 체크 추가. 사용자 스크린샷으로 "전송 중 0% 두 줄" 현상 확인됨. 버전 유지(1.0.U), S21/S26 재배포.
- 2026-06-07: LAN/Wi-Fi 전송 재구조화. `TransportKind.wifi` 삭제, BLE 아닌 모든 전송 = LAN으로 통합. `LanService.start()/stop()` 추가로 LAN 토글 기능 구현. `MessagingService.startLan()/stopLan()` 추가. 홈 LAN 버튼 `onPressed: _toggleLan` 연결. 초기 LAN 상태 enabled=true. SCAN 그래프 및 Demo Mode Wi-Fi 엣지 → LAN. 가상 메시 시뮬레이터 Wi-Fi 라우팅 → LAN. widget_test.dart wifi 관련 케이스 제거/통합. Tooltip 한국어 인코딩 버그 수정. v1.0.U 빌드, S21/S26/PC 배포 완료. flutter analyze clean, flutter test 20개 통과.

- 2026-06-06: Added a visible SCAN DEMO mode for testing without more devices. The SCAN screen now has a `DEMO` button that loads a virtual 3-depth private mesh with mixed PC/Phone and User/Admin+/Server roles. Added `topology_graph.dart` for shared topology merge/depth calculation and `topology_demo.dart` for the virtual network. The map uses the same graph path for demo/topology responses, placing depth levels on concentric rings. Build updated to `v1.0.M / 20260606-124521` (`pubspec` semver `1.0.22`), Windows debug build relaunched, S26 installed/launched with no recent FlutterError/FATAL EXCEPTION/DatabaseException, S21 was offline in ADB so install is pending. `flutter analyze` clean and `flutter test` passed with 15 tests.
- 2026-06-06: Expanded SCAN DEMO from 3-depth/10 nodes to 5-depth/27 nodes so N-depth filtering can be visually checked. The `DEMO` button now loads the larger mesh and sets Depth to 5. Windows debug build relaunched as `v1.0.M / 20260606-125804`; `flutter analyze` clean and `flutter test` passed with 15 tests.
- 2026-06-06: Remaining work reprioritized: SCAN N-depth topology first, PC BLE latency diagnostics later, LAN/Wi-Fi and attachment transfer later. Added SCAN topology packet backend with `MsgType.topologyRequest`/`topologyResponse`, signed request broadcast with depth limiting, per-node 1-hop neighbor summary response, `MessagingService.topologyStream`, and payload round-trip tests. Added in-card Demo checkbox for the 5-depth virtual mesh and transport-specific topology edge styles: LAN thick solid, Wi-Fi solid, BLE dashed. Added `VirtualMeshSimulator` so future physical tests can be paired with virtual mesh tests for mixed LAN/Wi-Fi/BLE routes, normal/timed messages, NoticeS/NoticeL reach, Server relay-only behavior, and notice cooldown policy. Power user role color changed from gold to red. Build updated to `v1.0.L / 20260606-034232` (`pubspec` semver `1.0.21`), installed/launched on S21/S26, relaunched Windows debug build, `flutter analyze` clean, `flutter test` passed with 19 tests, and recent Android logs show no FlutterError/FATAL EXCEPTION/DatabaseException.
- 2026-06-06: Identity Backup/Restore changed to encrypted-only. Backup now requires a user password, exports `mesh_comm_identity_<timestamp>.enc.json`, encrypts the full identity payload with PBKDF2-HMAC-SHA256 + AES-GCM, and restore requires the same password. Old plaintext identity backups are intentionally rejected. The app does not store the backup password; node ID recovery is done by restoring the full identity keypair. Rebuilt `v1.0.K / 20260606-031642`, installed/launched on S21/S26, relaunched Windows debug build, `flutter analyze` clean, `flutter test` passed with 13 tests, and recent Android logs show no FlutterError/FATAL EXCEPTION/DatabaseException.
- 2026-06-06: Rebuilt current `v1.0.K / 20260606-024818` (`pubspec` semver `1.0.20`) without incrementing the version. Fixed self-chat contamination by scoping message history/deletion to the actual `(me, contact)` pair; self history now only includes `me -> me` messages. Added Android native alert MethodChannel for notification sound and vibrator, plus `VIBRATE` permission. Windows/Main PC now forces local self level to Creator at startup while Android devices keep their selected level. S26 local settings restored to `madwind / user`. Contact list rows changed to three-line metadata with `[Group]`, level, trust/BLE/seen time. `flutter analyze` clean, `flutter test` passed with 13 tests, Android APK installed/launched on S21/S26, Windows debug build relaunched, and recent Android logs show no FlutterError/FATAL EXCEPTION/DatabaseException.
- 2026-06-05: Rebuilt current `v1.0.K / 20260605-225348` (`pubspec` semver `1.0.20`) without incrementing the version for a small behavior/UI fix. Self is now retained as a saved contact DB row instead of being deleted at startup; self name/avatar/level sync with Settings, favorite/group/message-delete use the normal contact path, trust is forced true, and self deletion is blocked. Unsaved SCAN nodes now pulse continuously. `flutter analyze` clean, `flutter test` passed with 13 tests, APK installed/launched on S21+/S26, and recent Android logs show no FlutterError/FATAL EXCEPTION.
- 2026-06-05: Build updated to display `v1.0.K / 20260605-221454` (`pubspec` semver `1.0.20`). Added a virtual self contact pinned at the top of Home/Search contacts. Self chat is allowed when the local level can send and stores outgoing-only local notes without BLE send or incoming echo. Added Settings message alert mode: Sound, Vibration, Silent; incoming message stream now uses platform alert sound, platform haptic vibration, or no alert based on the setting. `flutter analyze` clean, `flutter test` passed with 13 tests, APK installed/launched on S21+/S26, Windows relaunched visibly, and recent Android logs show no FlutterError/FATAL EXCEPTION/DatabaseException.
- 2026-06-05: Build updated to display `v1.0.J / 20260605-220715` (`pubspec` semver `1.0.19`). Corrected Server chat policy fully: chats open only when both the local user level and the selected contact level can send messages. Server contacts no longer open from Home/Search/SCAN, SCAN info panels hide Chat for Server contacts, and ChatScreen still defensively exits if reached. Added a policy unit test. `flutter analyze` clean, `flutter test` passed with 12 tests, APK installed/launched on S21+/S26, Windows relaunched visibly, and recent Android logs show no FlutterError/FATAL EXCEPTION/DatabaseException.
- 2026-06-05: Build updated to display `v1.0.I / 20260605-215559` (`pubspec` semver `1.0.18`). Server mode now blocks contact chat entry and ChatScreen defensively exits if opened. Code review fixes applied for hopCount overflow, seen_messages 10,000-row cap, KEY_ANNOUNCE response-set cleanup, async mounted safety, fragment collision reset, BLE send retry with stale characteristic cache clearing, parallel broadcast, relay retry, and non-overlapping heartbeat. `flutter analyze` clean, `flutter test` passed, APK installed/launched on connected S21+, Windows relaunched visibly, and recent S21 logs show no FlutterError/FATAL EXCEPTION/DatabaseException. S26 was not connected.
- 2026-06-04: Build updated to display `v1.0.H / 20260604-214748` (`pubspec` semver `1.0.17`). Android back navigation now keeps the app open and returns to Home/All from SCAN/Search/Home-root; returning from Chat/QR also resets Home/All. Installed on S21+/S26, relaunched Windows visibly, `flutter analyze` clean, `flutter test` passed, and recent Android logs show no FlutterError/FATAL EXCEPTION/DatabaseException.
- 2026-06-04: Build updated to display `v1.0.G / 20260604-213756` (`pubspec` semver `1.0.16`). SCAN map now shows saved contacts plus recently seen unsaved nodes only, and START performs stale-contact cleanup. Settings dialog clamps text scaling to avoid Android large-font wrapping. Contact import now opens the unrestricted file picker so previously downloaded JSON/contact files can be selected again. Installed on S21+/S26, relaunched Windows, analyze/test clean, and recent Android logs show no FlutterError/FATAL EXCEPTION.
- 2026-06-04: Build updated to display `v1.0.E / 20260604-211834` (`pubspec` semver `1.0.14`). QR and KEY_ANNOUNCE now carry `userLevel`, so contacts learn the peer's level on import/discovery. Contact `... > Level` now permits changes only when the target contact level is lower than my level; e.g. PC Builder cannot change madwind Creator. Installed on S21+/S26 and relaunched Windows. `flutter analyze` clean and tests passed.
- 2026-06-04: Build updated to display `v1.0.D / 20260604-210722` (`pubspec` semver `1.0.13`). Settings self-level edit is now restricted to User/Server only; Admin/Builder/Creator show read-only self level. Contact level changes are restricted to Admin/Builder/Creator. Local DB roles set: S26 Ultra `madwind` = Creator, Windows PC `메인PC임` = Builder, S21 `홍기` = User. Installed on S21+/S26, relaunched both phones and Windows, and recent logs show no FlutterError/FATAL EXCEPTION.
- 2026-06-04: Build updated to display `v1.0.C / 20260604-210001` (`pubspec` semver `1.0.12`). Corrected level selection policy: User/Server -> User/Server, Admin -> User/Admin, Builder -> User/Admin/Builder, Creator -> User/Admin/Builder/Creator. Installed on S21+/S26 and relaunched Windows debug build.
- 2026-06-04: Build updated to display `v1.0.B / 20260604-204746` (`pubspec` semver `1.0.11`). Added incoming message sound, unread badges, per-contact/all message deletion, DB v8 `contacts.user_level`, Settings self level, contact level assignment, level-based notice cooldowns, Server send blocking, User/Server scan max depth 3, and User/Server saved contact limit 10. `flutter analyze` clean, `flutter test` passed, debug APK installed and launched on S21+/S26 with no FlutterError/FATAL EXCEPTION in recent logs.
- 2026-06-04: Build updated to display `v1.0.A / 20260604-201604` (`pubspec` stays semver `1.0.10`). Replaced SCAN START `FilledButton.icon` with a custom fitted single-line button to prevent phone font-scale wrapping. Installed on connected S21+ and launched Windows visibly; S26 was not connected.
- 2026-06-04: Build updated to `v1.0.9 / 20260604-022115`. Removed the Material NavigationBar selected pill indicator and changed selection feedback to icon-only accent purple; label text remains neutral. Installed on S21+/S26 and launched Windows visibly.
- 2026-06-04: Build updated to `v1.0.8 / 20260604-021529`. Fixed SCAN layout directions: Depth moved upper-left, Me/Known/New moved lower-left, node info moved lower-right and narrowed to 120px. Removed node status dots, colorized node icons/text as Me orange, Known light blue, New gray, and made the Depth numeric field semi-transparent black. Installed on S21+/S26 and launched Windows visibly.
- 2026-06-04: Build updated to `v1.0.7 / 20260604-020618`. SCAN START is now centered alone above the map; Depth moved into an upper-right translucent in-card box with black numeric input. Me/Known/New remains stacked on the lower-right and node info remains lower-left. Installed on S21+/S26 and launched Windows visibly.
- 2026-06-04: Build updated to `v1.0.6 / 20260604-020005`. Depth input height/centering fixed and changed to gray; map card now expands with available screen/window height; node info moved to a compact lower-left in-card panel; labels stack vertically as Me/Known/New with orange/light-blue/gray colors. Installed on S21+/S26 and launched Windows visibly.
- 2026-06-04: Build updated to `v1.0.5 / 20260604-014645` without the `+1` suffix. SCAN depth control is now a START-colored pill with number only; removed Connection Map and pinch/drag labels; compacted translucent node dialog to Type/Links/Route and centered icon actions. Windows app launched visibly, APK installed on S21+/S26, and recent logs show no Flutter overflow/crash.
- 2026-06-04: Build updated to `v1.0.4+1 / 20260604-013728`. Added DB v7 `contacts.is_saved` so BLE-discovered nodes stay separate from saved contacts until Add. Simplified SCAN map nodes to icon-only outline style, removed node box overflow, compacted node dialog typography/actions, and verified no recent Flutter overflow/crash logs on S21+/S26.
- 2026-06-04: Build updated to `v1.0.3+1 / 20260604-012310`. Removed the lower SCAN list, enlarged the map, added green/orange contact vs discovered node coloring, and added an `Add contact` action from discovered node info dialogs. Installed APK on S21+ and S26 Ultra; launched Windows debug build.
- 2026-06-04: Build updated to `v1.0.2+1 / 20260604-011611`. SCAN control label changed from `N차` to centered `Depth`; connection map now uses PC/Phone icon nodes with connection counts, node info dialogs, zoom, and panning. Installed APK on S21+ and S26 Ultra; launched Windows debug build.
- 2026-06-04: Renamed chat modes to `일반/타임/공지S/공지L`; timed messages now expire 1 minute after display. NoticeS sends encrypted messages to contacts; NoticeL broadcasts to connected nodes. Build updated to `v1.0.1+1 / 20260604-010313`.
- 2026-06-04: Added contact trust on/off in contact menu, Settings `My Code`, immediate dark/light toggle save, START scan label, centered scan controls, first-pass connection map painter, scan-time KEY_ANNOUNCE retry, and short message send retry.
- 2026-06-03: Identity Backup/Restore added and S26 uninstall/reinstall identity restore verified. Original node `f7cf606d...` changed to `55b045aa...` after reinstall, then restored back to `f7cf606d...`.
- 2026-06-03: DB v6 added message expiration and remote contact metadata. Contact deletion now removes related messages; expired instant messages are cleaned from history/chat filters.
- 2026-06-03: Chat send modes added: normal, instant, short-range shout, long-range shout. Shout messages are limited to 50 chars and one send per day per shout type.
- 2026-06-03: SCAN screen now has a first-pass Tree preview from local contacts; true N-depth topology exchange remains pending.
- 2026-06-03: Attachment transfer scope documented in `memory-bank/knowledge/attachment-transfer-plan.md`; full file transfer needs a multi-packet transfer protocol.
- 2026-06-03: Built `v1.0.0+1 / 20260603-213605`, installed on S21+ and S26 Ultra, and launched Windows debug build. `flutter analyze` clean and widget tests passed.
- 2026-06-03: Phase-1 portrait app shell, home filters, local groups, search, and SCAN entry screen implemented
- 2026-06-03: S21+, S26 Ultra, Windows PC direct and two-hop physical BLE relay cases verified
- 2026-05-31: 프로젝트 시작
- 2026-06-01: Wave 1 완료 (아키텍처)
- 2026-06-01: Wave 2 완료 (MVP 구현, 빌드 성공)
- 2026-06-01: Wave 3 시작 — 실기기 테스트, Android 정상, Windows BLE 블로커
- 2026-06-02: Android GATT 서버 구현, Windows→S21+ 광고 발견·연결·CCCD 구독 확인
- 2026-06-02: Windows↔S21+ `KEY_ANNOUNCE` 교환 및 암호화 TEXT 양방향 수신 확인
- 2026-06-02: DB v2 연락처 로컬 관리 메뉴 구현, 이전 자기 연락처 정리 확인
- 2026-06-02: Android 다이얼로그 pop 애니메이션 중 controller use-after-dispose 수정
- 2026-06-02: Phase-0 완료 — 프로토콜 v2, DB v3, X25519 ECDH, BLE fragmentation, heartbeat 활성화
- 2026-06-02: Windows MTU 23 조각 전송 및 Windows↔S21+ TEXT 양방향 복호화 실기기 확인
