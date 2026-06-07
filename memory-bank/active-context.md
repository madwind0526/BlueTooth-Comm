# Active Context

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
