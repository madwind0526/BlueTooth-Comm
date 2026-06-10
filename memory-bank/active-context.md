# Active Context

## Latest 2026-06-09 (v1.0.X — BLE 크래시 수정 + LAN 안정화)

- **빌드**: `v1.0.X / 2026-06-09` (pubspec `1.0.27+27`)
- **BLE 크래시 수정**: `setWriteRequestCallback`에 try-catch 추가. `main.dart`에 `runZonedGuarded` + `FlutterError.onError`. `handleIncomingPacket` Future에 `.catchError()` 추가 (BLE·LAN 양쪽). 근본 원인: async Future가 동기 native callback에서 await 없이 호출되어 unhandled exception → Android "앱에 버그" 다이얼로그
- **LAN 안정화**: LAN TCP 연결 후 즉시 `keyAnnounce` 브로드캐스트 (수신 측 피어 등록 유발). 30초 keepalive 타이머 (idle TCP drop 방지). PONG을 `_sendPacketToNodeId`로 라우팅 (LAN 우선)
- **파일 전송 경로 수정**: LAN 피어 등록 지연 문제 해결로 LAN+BLE 동시 환경에서 LAN 우선 경로 정상 작동. LAN only / LAN+BLE 간 파일 전송 확인됨
- **SCAN BLE 의존성 제거**: BLE 꺼져 있어도 LAN 연결 있으면 SCAN 동작. BLE startScan은 BLE 켜진 경우에만 실행
- **깜박이는 점 theme-aware**: dark mode = 흰색, light mode = 검은색. 크기 8px → 16px
- **버전 표시 수정**: `--dart-define=MESHCOMM_VERSION` 없이 빌드하면 항상 기본값 `1.0.Q` 표시되던 문제 → 이후 빌드 시 항상 dart-define 명시 필요
- **현재 상태**: Android LAN↔LAN, LAN+BLE↔LAN+BLE 파일 전송 확인. BLE only↔BLE only 전송은 추가 조사 필요

## Latest 2026-06-05

- Latest build: `v1.0.M / 20260606-125804`
- Identity Backup/Restore verified on S26 after uninstall/reinstall.
- DB v6: message `expires_at`, contact `remote_display_name`, `remote_avatar_key`.
- Chat modes: normal, timed, notice S, notice L.
- Notice policy: 50 chars, level-based cooldowns. Creator unlimited; Builder S/L 1h/2h; Admin 2h/4h; User 6h/24h; Server cannot send.
- DB v8: contact `user_level`; app setting `user_level`; unread message counts and read marking added.
- Message UX: incoming alert can be Sound/Vibration/Silent, per-contact unread badge, per-contact message delete, Settings delete-all-messages. Sound uses the platform alert sound; vibration uses platform haptic vibration.
- Home contact list includes this device as a saved self contact pinned at the top. Self profile identity values (name/avatar/level) sync with Settings; local contact metadata (favorite/group/messages) uses the same contact DB path as other contacts.
- Level policy: Settings only lets regular User/Server choose User or Server for self. Contact `... > Level` is only for Admin/Builder/Creator. Admin can assign User/Admin; Builder can assign User/Admin/Builder; Creator can assign User/Admin/Builder/Creator.
- Level sync: QR and KEY_ANNOUNCE now include `userLevel`; contacts update their stored remote level from the peer. Contact level changes are allowed only when the contact's level is lower than my level.
- Server is self-selected only by regular User/Server in Settings. Admin/Builder/Creator cannot assign or remove Server; Server contacts are displayed distinctly but not externally editable.
- SCAN map now hides stale unsaved discovered nodes unless they were seen within the last 3 minutes, and scan start runs stale-contact cleanup. Settings dialog clamps text scaling to prevent Android large-font wrapping. Contact import opens the file picker without a restrictive extension filter.
- Android back now stays inside the app: Back from SCAN/Search/Home-root returns Home/All, and returning from Chat/QR also resets to Home/All. App exit is intended through the Power button or Android Home/Recents.
- Chat is disabled when either side is Server: local Server mode cannot open chats, Server contacts cannot be opened from Home/Search/SCAN, and ChatScreen defensively exits if reached through another route.
- Contact and SCAN role colors are unified: Me orange, Server gray, Creator/Builder/Admin red, regular User theme default. Self contact menu keeps rename/favorite/group/avatar/level/delete-messages, forces trust true, and blocks self deletion.
- Unsaved nodes in the SCAN map pulse continuously until added to contacts.
- Message history is now scoped to the actual pair `(me, contact)`. Self chat only shows messages where sender and target are both my node ID, so messages sent to another device no longer leak into self chat.
- Android incoming alerts now use a native MethodChannel: notification tone for Sound and `Vibrator` for Vibration, with Flutter fallback.
- Windows/Main PC now forces self level to Creator at startup; Android devices keep their Settings-selected level.
- S26 current local setting restored to `display_name=madwind`, `user_level=user`.
- Contact rows are two-line again: name only, then `[Group] · Level · 신뢰O/X · BLE · seen time`.
- Relay stability pass: BLE sends retry once after clearing stale GATT characteristic cache, broadcasts send to neighbors in parallel, relays use the same retry path, heartbeat runs non-overlapping, hop overflow is dropped, fragment collisions reset assembly, and seen_messages is capped at 10,000 rows after TTL cleanup.
- Current local roles: Windows/Main PC forces Creator at startup; Android devices keep Settings-selected roles. S26 Ultra `madwind` should remain User unless changed in Settings.
- Chat filter and chat screen periodically refresh so expired instant messages disappear.
- Safe duplicate cleanup only removes untrusted, non-favorite, no-group, no-message temporary contacts with matching announced metadata.
- SCAN START button is now single-line safe under larger phone font scaling by using a custom fitted button; bottom navigation selection remains icon-color only.
- SCAN topology packet exchange backend has started: `TOPOLOGY_REQUEST`/`TOPOLOGY_RESPONSE` packets ask reachable nodes for their 1-hop neighbor summary and expose responses through `MessagingService.topologyStream`. A larger 5-depth virtual mesh DEMO is available on the SCAN screen and uses the same topology graph merge/layout path for visual verification without extra physical devices.
- SCAN demo mode is now an in-card checkbox beside Depth instead of a separate top button; checked shows the 5-depth virtual mesh and unchecked returns to real scan data. Topology edges now carry transport kind so LAN is drawn as a thick solid line, Wi-Fi as a solid line, and BLE as a dashed line.
- Added a pure Dart `VirtualMeshSimulator` for parallel real-device and virtual-network testing. The simulator uses the demo topology as a real-like mesh with PC/Phone nodes, LAN/Wi-Fi/BLE links, transport latency, relay-only Server behavior, normal/timed messages, NoticeS contact-only reach, NoticeL reachable-node broadcast, notice cooldowns by user level, and timed-message expiry. Future LAN/Wi-Fi/BLE, NoticeS/NoticeL, normal/timed message tests should be paired with both physical-device cases and virtual mesh cases.
- Demo mode is now a global Settings switch below Dark mode. SCAN follows Settings demo mode instead of showing a Demo checkbox. The former SCAN checkbox is now `Node`; it defaults off and only controls whether node connection counts are shown beside PC/Phone icons.
- Attachment transfer is documented but not fully implemented; full files need a multi-chunk protocol.
- Identity backup is now encrypted-only. Backup asks for a password, writes `*.enc.json`, and restore requires the same password. Old plaintext identity backups are intentionally rejected. The app does not store the backup password; restoring the node ID means restoring the full identity keypair, not only the short code.

## Latest 2026-06-08 (Export/Import 기본 폴더 설정)

- **`_meshCommDocumentsDir()` 헬퍼 추가**: `Documents/Mesh-comm/` 반환, 없으면 자동 생성
  - Windows: `C:\Users\<user>\Documents\Mesh-comm\`
  - Android: `getDownloadsDirectory().parent/Documents/Mesh-comm/`
- **적용 범위**: 연락처/대화 Export(`_saveJsonFile`), Import(`openFile`), Identity Backup/Restore(`getSaveLocation`, `openFile`) — 모두 `initialDirectory` 지정
- **폴백**: getSaveLocation 실패 시도 `_meshCommDocumentsDir()`에 직접 저장

## Latest 2026-06-08 (채팅 기록 Documents 자동 저장)

- **채팅창 닫을 때 자동 저장**: `dispose()` → `_autoExportChatHistory()` (unawaited)
- **저장 경로**: `Documents/Mesh-comm/<연락처이름>/chat_history.txt` (매번 덮어씀)
- **Windows**: `C:\Users\<user>\Documents\Mesh-comm\<name>\`
- **Android**: `getDownloadsDirectory().parent/Documents/Mesh-comm/<name>/`  = `/storage/emulated/0/Documents/Mesh-comm/<name>/`
- **파일 형식**: 텍스트. 메시지+파일전송 합쳐 타임스탬프 정렬. `[2026-06-08 14:00] 나: ...`
- 연락처 이름 파일시스템 unsafe 문자 `<>:"/\|?*` → `_` 치환

## Latest 2026-06-08 (파일 Downloads 자동 저장)

- **TransferStorageService 재설계**: 실제 파일 → `Downloads/Mesh-comm/sent/` 또는 `received/`. 메타데이터(.json)만 appSupportDir/mesh_meta/ 에 유지
- **동일 파일명 처리**: `file.pdf` 충돌 시 `file(1).pdf`, `file(2).pdf` ... 자동 회피
- **AndroidManifest**: `WRITE_EXTERNAL_STORAGE` (maxSdkVersion=29), `READ_EXTERNAL_STORAGE` (maxSdkVersion=32) 추가
- **chat_screen._saveFile()**: Android → 저장 경로 스낵바 표시. Windows → 다른 위치에 복사 저장 다이얼로그 유지
- **Windows 경로**: `C:\Users\<user>\Downloads\Mesh-comm\sent|received\`
- **Android 경로**: `/storage/emulated/0/Downloads/Mesh-comm/sent|received/`

## Latest 2026-06-08 (공지 UI 재배치)

- **공지S/L → SCAN 하단 버튼으로 이전**: `_buildScan()` 하단에 "공지 보내기" OutlinedButton 추가 (Server 레벨 제외)
- **팝업 다이얼로그**: `_NoticeSendDialog` + `_NoticeTypeButton` 위젯 신규 추가. 반투명 회색 컨테이너(grey[850] opacity 0.96), 공지S/공지L 토글, 50자 입력, 쿨다운 표시, 발송/취소 버튼
- **채팅 화면 공지S/L 항목은 그대로 유지** (제거 요청 없음)

## Latest 2026-06-08 (보안 강화 + R-12)

- **개인키 secure storage 이전**: `flutter_secure_storage` 추가 (Android Keystore / Windows DPAPI). 기존 DB 평문 저장 → 자동 마이그레이션 후 DB 개인키 0으로 덮어쓰기. 신규 설치는 처음부터 secure storage에만 저장.
- **R-12 완료**: BLE scan mode `lowLatency` → `lowPower` (Android). 재난 시 배터리 수명 연장.
- **알려진 제한 사항 항목 해소**: 개인키 평문 저장 해결, R-12 배터리 효율 해결

## Latest 2026-06-08 (스코프 확정 + 기능 추가)

- **스코프 제거**: 음성 메시지·위성 연동 완전 제거
- **스코프 제거**: adminNotice — 공지S/L로 충분, 구현 안 함
- **스코프 보류**: 그룹 채팅 — 카톡처럼 하나의 채팅방(group_id+공유키+group_messages)이 맞는 방향이나 큰 작업이므로 설계 더 고민 후 진행
- **구현 완료**: 파일 전송 양방향 취소 (`fileCancel` 0x0C 패킷, `cancelTransfer(notify:bool)`)
- **구현 완료**: 홈 연락처 타일 전송 중 깜박이는 보라색 원 인디케이터 (`_BlinkingDot`)
- **결정**: 3홉 릴레이는 가상망으로만 검증. SCAN UI는 현재 수준으로 동결

## Latest 2026-06-07 (PC BLE 페어링 제약 확인)

- **PC BLE 동작 확인**: 코드 문제 아님 — PC 하드웨어(Bluetooth 어댑터) 수준 제약
- Windows 설정에서 핸드폰 수동 페어링 후 S21+, S26 Ultra 2대 모두 BLE 발견·연결 정상 확인
- **핵심 함의**: PC는 사전 페어링된 고정 거점 릴레이에 적합; 재난 즉석 메시는 폰 중심이 더 현실적
- README.md 및 trouble-shooting.md에 반영 완료

## Latest 2026-06-07 (v1.0.W — 버그 수정 릴리스)

- **BLE 파일 전송 0% 원인 확정**: chunk 380B + 오버헤드 134B = 514B > BLE max 512B → ble chunk = 340
- **LAN 동시 오픈 race 최종 수정**: outgoing 등록 시 incoming이 이미 있으면 outgoing 소켓 버림
- **TransferService timeout/retry**: 청크 ACK 15초 대기, 최대 3회 재시도, 실패 시 TransferFailed
- **TransferService cancelTransfer(tid)**: UI X 버튼으로 전송 취소 + 소켓 초기화
- **Android 다운로드 수정**: getDownloadsDirectory() 사용 (getSavePath 미구현 오류 해결)
- **파일 수신 후 안읽음 뱃지**: home_screen이 TransferService.transferStream 구독 → incoming 완료 시 _unreadCounts+1
- **PC BLE 0 원인 확정**: PC가 Android Peripheral에 연결 후 Android에서 send(PC)가 GATT write 실패 — Peripheral→Central notify 미구현 (별도 조사 필요)
- 빌드: v1.0.W APK 74.7MB, Windows exe 빌드 성공. 전 기기 배포 완료.

## Latest 2026-06-07 (v1.0.V)

- Current version: `v1.0.V` (--dart-define=MESHCOMM_VERSION=1.0.V)
- TransferStorageService: appSupportDir/mesh_files/<contactHex>/<tid>.bin+json 영구 저장
- MessagingService: transferStream 구독 → TransferCompleted 시 자동 저장 (채팅창 닫혀있어도)
- ChatScreen: initState에서 _loadStoredFiles() 복원 → S21(수신자) 이미지 미표시 버그 수정
- 이미지 전체화면: barrierDismissible false + 저장/삭제/닫기 버튼 (삭제=디스크+목록 제거)
- ConnectionBadge: "2 LAN / 1 BLE" / "N LAN" / "M BLE" / "0 연결" 분리 표시
- BLE chunk 380 bytes (0% 전송 멈춤 수정), Windows BLE withServices:[] (0 연결 수정)
- APK 74.5MB, Windows exe — 빌드 성공, git push 완료 (hash: 1bb2f6c)

## Latest 2026-06-07
- LAN/Wi-Fi 전송 재구조화: `TransportKind.wifi` 제거, BLE 아닌 모든 네트워크 연결 = `TransportKind.lan`
- LAN On/Off 토글 구현: `LanService.start()/stop()` 추가, 홈 LAN 버튼 클릭으로 On/Off 가능
- LAN 초기 상태 `available: true, enabled: true` (서비스 자동 시작)
- Wi-Fi 버튼 헤더에서 제거 (LAN / BLE 두 버튼만 남음)
- SCAN 토폴로지 및 가상 메시(Demo Mode) Wi-Fi 엣지 → LAN으로 통합
- Tooltip 한국어 인코딩 깨짐 버그 수정 (`吏???덉젙` → `지원 예정`)
- 규칙: 수정 사항은 항상 memory-bank MD 파일 업데이트; 사소한 수정에서는 버전 올리지 않음
- 파일 relay 차단: fileHeader/fileChunk/fileAck는 Step 5에서 return (직접 연결 전용)
- 직접 연결 추적: `hopCount==0` 패킷 수신 시 `_deviceToNodeHex[fromDeviceId] = nodeIdHex` 기록
- `isDirectlyConnected(nodeIdHex)`: BLE 직접 연결 또는 LAN peer 여부 확인
- `sendFile` 직접 연결 없으면 즉시 null 반환
- UI: 페이퍼클립 아이콘 제거, 드롭다운에 파일/이미지 항목 추가 (선택 즉시 picker 오픈)
- Export: checkbox 다이얼로그로 연락처(개별+전체선택 tristate) + 대화 병렬 선택
- Import: 연락처(merge) / 대화(replace) 라디오 선택 후 파일 picker
- Settings: "연락처 전부 지우기" 버튼 추가 (대화 기록 유지)
- DB 추가: `exportAllMessagesRaw()`, `importMessagesRaw()`, `deleteAllSavedContacts()`
- git commit + push 완료 (hash: 66b6588)

## Latest 2026-06-09 (v1.2.A — Group Chat)

- **Group Chat 시스템 전면 구현 (Wave A+B+C)**
- DB v10: `chat_groups`, `group_members`, `group_messages` 3 테이블 추가. `contacts.group_name` 리셋
- 5 MsgType 추가: `groupInvite`(0x0D) ~ `groupLeave`(0x11)
- `GroupService`: UUID v4 그룹 생성, 멤버 CRUD, 방장 승계, 메시지 저장
- `GroupMessagingService`: 그룹 패킷 프로토콜. 초대/응답/메시지/멤버변경/나가기 스트림
- `GroupChatScreen`: DB-backed. 발신자 이름 표시, 초대/추방/나가기 버튼 (방장만 추방)
- `_DemoGroupChatScreen`: 데모 그룹채팅. 각 멤버별 "(Re MemberName-Me): text" 시뮬레이션
- 연락처 팝업 "그룹 채팅에 초대" → 기존/신규 그룹 선택 다이얼로그
- 홈 Groups 탭: `_ChatGroupList`/`_ChatGroupTile` (ChatGroup 기반)
- 데모 그룹: `_demoSavedContacts`의 groupName으로 자동 생성 5종
- **BUG FIX**: 데모 1:1 채팅 파일/이미지 Reply에 Re: 접두사 누락 → `fileName: null` 수정
- 버전: `v1.2.A`, pubspec `1.2.0+50`. S21/S26/PC 배포 완료

## Current Focus

- ✅ Phase-1 portrait shell: top transport menu, left filters, bottom navigation
- ✅ Favorites-first alphabetical contact/group sorting and local group management
- ✅ Search screen and SCAN Tree-only entry screen
- ✅ GPS/Map removed from scope; shout policy reduced to 50 chars / 1 day
- ⏳ Phase-2: group messaging model and N-depth topology protocol / Tree renderer

- ✅ S26 Ultra added: PC direct, phone direct, and two-hop relay TEXT verified
- ✅ Samsung phone-to-phone BLE scan needs location permission and system location service enabled
- ✅ Wave 2 완료: Android + Windows MVP 구현
- ✅ Android 실기기 동작 확인 (S21+)
- ✅ QR 등록 → 연락처 → 채팅 UI 흐름 동작
- ✅ 코드 리뷰 Critical 3개 수정 (릴레이 재서명, DoS, R-14)
- ✅ Android Peripheral GATT 서버 구현 (`ble_peripheral`)
- ✅ Windows → S21+ BLE 광고 발견 + GATT 연결 smoke test
- ✅ 중복 BLE 연결 경쟁 조건 수정 (`_connectingDevices`)
- ✅ 연결 직후 `KEY_ANNOUNCE` 재전송 + 홈 화면 수동 키 재전송 버튼
- ✅ Windows ↔ S21+ 실제 암호화 TEXT write/notify 양방향 테스트
- ✅ 릴레이된 자체 패킷 echo 조기 drop
- ✅ DB v2 연락처 로컬 메타데이터 (`is_favorite`, `group_name`)
- ✅ 연락처 `...` 메뉴: 삭제, Group 추가/변경, 즐겨찾기, 로컬 이름 변경
- ✅ 이전 진단 과정에서 저장된 자기 연락처 앱 시작 시 자동 정리
- ✅ Android 연락처 이름/Group 변경 시 다이얼로그 controller use-after-dispose 수정
- ✅ Phase-0 프로토콜 v2 + DB v3 마이그레이션
- ✅ TEXT X25519 ECDH + AES-GCM 종단 간 암호화
- ✅ BLE fragmentation/reassembly, Windows MTU 23 실기기 검증
- ✅ GATT characteristic 캐싱 + Android notify 직렬화
- ✅ heartbeat PING/PONG 활성화, 30초 주기 실기기 검증
- ✅ KEY_ANNOUNCE 상호 응답 + 반복 응답 제한
- 🔲 A ↔ PC ↔ B ↔ C 물리 기기 3홉 릴레이 E2E 검증
- 🔲 두 번째 Android 폰으로 폰↔폰 실제 메시지 전송 테스트

<!-- 규칙: 최근 작업 10개만 유지 -->
