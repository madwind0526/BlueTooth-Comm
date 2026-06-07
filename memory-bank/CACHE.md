# Cache

> 임시 발견사항 저장소. Wave 완료 후 knowledge/ 로 flush하고 이 섹션을 비울 것.

## Active Findings (2026-06-07 v2)

| 유형 | 발견사항 | 이동 대상 |
|------|----------|-----------|
| 버그수정 | fileHeader/fileChunk/fileAck 수신 시 targetId 확인 없이 처리 → 3기기 환경에서 S26이 S21 대상 파일 패킷도 처리해 spurious ACK 전송, 동시 _sendNextChunk 호출 race condition → 청크 누락으로 전송 0%에 멈춤. 수정: _handleIncomingPacket switch에서 _bytesEqual(packet.targetId, myNodeId) 체크 추가 | trouble-shooting.md |
| 패턴 | TEXT는 _handleTextPacket 내부에서 isForMe 체크. 파일 패킷도 동일 패턴 적용 필요 (relay node는 step5에서 relay만 해야 함) | PATTERNS.md |

---

## Active Findings (2026-06-07)

| 유형 | 발견사항 | 이동 대상 |
|------|----------|-----------|
| 설계변경 | TransportKind.wifi 제거 — BLE 아닌 모든 전송 = LAN. Wi-Fi는 같은 공유기 망, LAN은 유선/LTE/위성. LAN 단일 계층으로 통합 | RULES.md |
| 패턴 | LanService.start()/stop() — init() 후 toggle 가능. stop()은 소켓/타이머/피어 모두 닫고 stream은 유지. start()는 재소켓 바인딩. dispose()는 stop() + stream 닫기 | PATTERNS.md |
| 패턴 | 홈 _toggleLan() — _lanEnabled bool + _transports copyWith(enabled) + MessagingService().startLan()/stopLan() 위임 | PATTERNS.md |
| 규칙 | 수정 사항은 항상 memory-bank MD 파일 업데이트할 것 (active-context + STATE + CACHE) | RULES.md |
| 규칙 | 버전 번호는 사소한 수정에서 올리지 않음 — 새 기능·배포 시에만 | RULES.md |
| 버그수정 | home_screen.dart Tooltip 한국어 `吏???덉젙` 인코딩 깨짐 — PowerShell로 regex 교체, Edit tool 매칭 실패 (파일 인코딩 손상) | trouble-shooting.md |

---

## Previous Active Findings

| 유형 | 발견사항 | 이동 대상 |
|------|----------|-----------|
| TODO | private_key seed DB 저장 현재 평문 — Phase 2에서 AES-GCM 암호화 저장으로 교체 필요 | trouble-shooting.md |
| 구현 | BleService 연결 시 message characteristic 캐싱, disconnect 시 notify subscription 정리 | trouble-shooting.md |
| 구현 | ui/home/home_screen.dart 생성 — StatefulWidget + StreamBuilder 패턴, ContactService/BleService 싱글톤 직접 참조 | PATTERNS.md |
| 구현 | ui/chat/chat_screen.dart 완성 — StatefulWidget, 버블 UI, 160자 제한(R-13), 신뢰배너, MessagingService TODO 주석 처리 | PATTERNS.md |
| 구현 | ui/qr/qr_screen.dart stub 생성 — 내 QR 화면, 실제 구현 예정 | — |
| 패턴 | _formatRelativeTime(int ms) 헬퍼 함수 — lastSeen 상대 시각 포맷 (방금 전/N분 전/N시간 전/N일 전) | PATTERNS.md |
| 패턴 | _ContactDisplayName: displayName ?? nodeId hex 앞 8자리 | PATTERNS.md |
| 주의 | HomeScreen._isScanning 타이머 — BleConstants.scanDuration 미노출로 임시 10초 하드코딩. 실제 상수 연동 필요 | trouble-shooting.md |
| 주의 | contactsStream 초기값 없음 — 앱 시작 시 getAllContacts()로 초기 로드 필요 (현재 StreamBuilder waiting 상태 처리만 있음) | trouble-shooting.md |
| 패턴 | ChatScreen 낙관적 업데이트 — sendTextMessage 호출 후 즉시 _messages에 추가, MessagingService 없이도 UI 동작 | PATTERNS.md |
| 패턴 | ValueListenableBuilder로 전송 버튼 활성화 제어 — TextEditingController.text.trim().isNotEmpty 조건 | PATTERNS.md |
| TODO | MessagingService 완성 후 chat_screen.dart 의 TODO 주석 4곳 해제 필요: _loadHistory, _subscribeToStream, _sendMessage, import | trouble-shooting.md |
| 구현 | ui/qr/qr_screen.dart 완성 — TabBar 2탭(내 QR / QR 스캔), QrImageView, MobileScanner, 핑거프린트 확인 다이얼로그 | PATTERNS.md |
| 의존성 | qr_flutter: ^4.1.0 pubspec.yaml에 추가 (mobile_scanner는 이미 존재) | — |
| 패턴 | QrScreen._scanned 플래그 — MobileScanner onDetect 중복 처리 방지. 처리 후 resetScanner()로 재활성화 | PATTERNS.md |
| 패턴 | _ScanQrTab: addOrUpdateContact(nodeId, publicKey) 호출 후 confirmTrust(nodeId, fingerprint) 다이얼로그 결과로 분기 | PATTERNS.md |
| 주의 | MobileScanner: AppLifecycleObserver로 pause/resume 시 start()/stop() 수동 관리 필요 (controller 자동 관리 미지원) | trouble-shooting.md |
| 구현 | main.dart 완전 교체 — StatefulWidget 기반 _MeshCommAppState, 비동기 서비스 초기화 순서 확정 | PATTERNS.md |
| 패턴 | main.dart 초기화 순서: DB → Identity → ContactService() → BleService.init() → startScan() → startAdvertising(Android) → MessagingService(TODO) | PATTERNS.md |
| 패턴 | main.dart 로딩화면: 검정 배경 + "MeshComm" 보라 텍스트(0xFF7C6AF7) + CircularProgressIndicator, 완료 후 HomeScreen 전환 | PATTERNS.md |
| 패턴 | main.dart 에러화면: error_outline 아이콘 + 에러 메시지, 앱 크래시 방지 | trouble-shooting.md |
| TODO | MessagingService 구현 완료 후 main.dart의 주석 2곳 해제: import + MessagingService().init() 호출 | trouble-shooting.md |
| 버그수정 | MessagingService 릴레이 재서명 누락 — ttl·hopCount 변경 후 packet.signature를 재계산하지 않으면 다음 홉 서명 검증 실패. _identity.myPrivateKeySeed로 재서명 코드 추가 | trouble-shooting.md |
| 구현추가 | ReceivedMessage.isOutgoing 필드 추가 (spec 요구사항) + getMessageHistory에서 DB row['is_outgoing'] 반영 | PATTERNS.md |
| 패턴 | TEXT sharedSecret: 내 X25519 개인키 seed + 최종 상대 X25519 공개키로 ECDH 계산. 공개 node ID 기반 MVP 키 제거 | PATTERNS.md |
| 구현 | features/messaging/messaging_service.dart 완성 (Wave 3) — 수신 파이프라인·전송·KEY_ANNOUNCE·PING/PONG·히스토리 조회 전부 구현 | — |
| 구현 | Android Peripheral 광고 전용 `flutter_ble_peripheral` 제거, GATT 서버 지원 `ble_peripheral: ^2.4.0`으로 교체 | PATTERNS.md |
| 구현 | S21+에 Service `4a580001...`, write+notify Characteristic `4a580002...`, CCCD 등록 확인 | PATTERNS.md |
| 구현 | 광고 manufacturer data에 node_id 16 bytes 포함. 현재 manufacturer ID `0xFFFF`는 개발용 | PATTERNS.md |
| 버그수정 | 반복 scan result가 동일 기기에 connect()를 중복 호출하던 경쟁 조건 — `_connectingDevices` Set으로 방어 | trouble-shooting.md |
| 버그수정 | notify 구독 직후 빈 `lastValueStream` 값이 invalid packet 로그를 만들던 문제 — 빈 bytes 무시 | trouble-shooting.md |
| 검증 | Windows debug 앱 → S21+ 광고 발견, GATT 연결, MTU 517 협상, CCCD notify 구독 확인 | trouble-shooting.md |
| 검증 | Windows→S21+ central write, S21+→Windows peripheral notify로 암호화 TEXT 양방향 수신 확인 | trouble-shooting.md |
| 버그수정 | 앱 시작 직후 연결 전 `KEY_ANNOUNCE`가 유실되던 문제 — 연결 이벤트 후 3초 뒤 재공지 + 홈 화면 수동 키 재전송 버튼 | trouble-shooting.md |
| 버그수정 | 릴레이된 자체 패킷 echo가 자기 연락처를 생성할 수 있던 문제 — sender_id가 내 node_id면 조기 drop | trouble-shooting.md |
| 패턴 | `--dart-define=MESHCOMM_DIAGNOSTIC_MESSAGE=...` 빌드는 첫 연락처 발견 1초 후 진단 TEXT를 한 번 자동 전송 | PATTERNS.md |
| 구현 | DB v2: contacts에 `is_favorite`, `group_name` 추가. 기존 DB는 `onUpgrade`에서 ALTER TABLE | PATTERNS.md |
| 구현 | 연락처 `...` 메뉴: 삭제, Group 추가/변경, 즐겨찾기, 로컬 이름 변경 | PATTERNS.md |
| 버그수정 | 이전 진단 실행에서 남은 자기 연락처 — 앱 시작 시 내 node ID 연락처를 삭제. Windows DB에서 self count 0 확인 | trouble-shooting.md |
| 버그수정 | Android 이름/Group 저장 후 빨간 화면 — dialog pop 직후 `TextEditingController.dispose()` 제거, `TextFormField.initialValue` + closure 값으로 교체 | trouble-shooting.md |
| 주의 | Android SQLite 복사 시 `adb exec-out ... > file` 금지. PowerShell이 바이너리를 텍스트 변환할 수 있으므로 `adb pull` 사용 | trouble-shooting.md |
| 설계 | SCAN `Tree`는 계층 목록 대신 `C:\Claude\Connection-map` 참고 인터랙티브 네트워크 맵으로 구현. COSE force layout, 줌/팬, 노드 상세, BFS 경로 강조 | design-document.md |
| 구현 | MTU 23 대응 packet fragmentation/reassembly, Android peripheral notify 직렬화 | trouble-shooting.md |
| 구현 | DB v3 X25519 키 저장 + TEXT ECDH 적용. relay는 target 불일치 TEXT를 복호화·저장하지 않음 | trouble-shooting.md |
| 검증 | Windows MTU 23 KEY 40조각, TEXT 23조각 전송 및 Windows↔S21+ 복호화 성공 | trouble-shooting.md |
| 구현 | heartbeat 실제 시작, 서명 검증된 PONG만 카운터 초기화 | trouble-shooting.md |
| TODO | A ↔ PC ↔ B ↔ C 물리 기기 3홉 릴레이 E2E 검증 | trouble-shooting.md |
| TODO | 배포 전 개발용 manufacturer ID `0xFFFF`를 Bluetooth SIG 할당 ID로 교체 | trouble-shooting.md |
| 주의 | `ble_peripheral`은 Android Peripheral 연결을 강제로 끊는 Dart API를 제공하지 않음. heartbeat timeout 시 논리 이웃 제거만 가능 | trouble-shooting.md |
| 주의 | Flutter 3.44 Android 빌드 시 `ble_peripheral`, `mobile_scanner` Built-in Kotlin 마이그레이션 경고 발생 | trouble-shooting.md |

---

## Wave 2 코드 리뷰 발견사항 (2026-06-01 — Sub-Agent Audit)

### Critical

| 파일 | 줄 | 문제 | 수정 방법 |
|------|-----|------|-----------|
| messaging_service.dart | 319~341 | 릴레이 재서명 로직 오류: Step 4(처리)가 Step 5(릴레이) 전에 실행되므로 자신을 대상으로 한 패킷(TEXT)도 ttl-1 후 릴레이됨. 그러나 더 큰 문제는 릴레이 노드가 자신의 개인키로 재서명하면 수신자가 "발신자 서명"을 검증할 때 실제 발신자의 서명이 아닌 릴레이 노드 서명을 검증하게 됨. 즉 서명 체인이 깨져 다음 홉에서 서명 검증 실패 가능. | 릴레이 시 signature 필드를 변경하지 말거나, 별도 relay_signature 필드를 도입해야 함. 또는 서명 검증을 "발신자의 원본 서명은 불변"으로 유지하고 ttl/hopCount만 변경 후 재서명 없이 전달 |
| messaging_service.dart | 284~290 | 서명 검증 전 markMessageSeen() 호출(Step 2): 서명 위조 패킷을 먼저 seen으로 기록하면, 이후 정상 패킷이 도착해도 "중복"으로 drop됨. 공격자가 같은 msg_id로 위조 패킷을 먼저 보내면 정상 패킷을 영구 차단 가능 | markMessageSeen()을 서명 검증 성공 후에 호출할 것 |
| messaging_service.dart | ~185-191 | R-14 E2E 암호화 미충족: sharedSecret = SHA-256(nodeIdA||nodeIdB) 사용. node_id는 브로드캐스트되는 공개 정보이므로 누구나 동일 sharedSecret을 계산 가능. 릴레이 노드도 payload 열람 가능 → R-14 위반 | Phase 2에서 X25519 ECDH 교체 필요. 현재 TODO 주석이 있으나 릴레이 노드 열람 불가 요건이 완전히 위반됨을 명확히 표시할 것 |

### Warning

| 파일 | 줄 | 문제 | 수정 방법 |
|------|-----|------|-----------|
| main.dart | 57-73 | 초기화 순서 문제: MessagingService().init()이 BleService().init() 이후에 호출되지만 MessagingService.init() 내부에서 즉시 broadcastKeyAnnounce()를 호출함. 이때 BLE 연결이 아직 없으면 무해하지만, startScan()/startAdvertising()이 MessagingService().init() 이전에 실행되어 패킷이 수신될 수 있음 → MessagingService가 초기화 전에 handleIncomingPacket이 호출될 가능성 있음 | BleService.init()의 onPacketReceived 콜백을 MessagingService().init() 완료 후 등록하거나, MessagingService를 먼저 init한 후 BLE 시작 |
| ble_service.dart | 368 | messageChar.lastValueStream 구독 후 StreamSubscription을 저장하지 않음: notify 구독 취소 방법 없음. 기기 disconnect 시 BleService._onDeviceDisconnected()에서 _connectionSubscriptions만 취소하고 messageChar subscription은 누수됨 | lastValueStream.listen()의 반환 StreamSubscription을 deviceId 키로 별도 맵에 보관하고 disconnect 시 취소 |
| ble_service.dart | 322-389 | _connectToDevice()에서 connect() 성공 후 discoverServices() 실패 또는 messageChar not found 시 disconnect() 호출 후 return하지만, _connectedDevices에는 아직 추가되지 않았으므로 _onDeviceDisconnected는 호출되지 않음. 그러나 connectionState 리스너(sub)가 등록되지 않은 상태에서 device.disconnect()를 호출하면 연결 상태 변화를 감지 못할 수 있음 | disconnect() 전에 연결 상태 리스너를 먼저 등록하거나, connect() 성공 즉시 connectionState 구독 |
| ble_service.dart | 419-436 | _findMessageCharacteristic()에서 매번 discoverServices() 재호출: sendPacket()이 호출될 때마다 GATT discover 재실행 → 지연 및 배터리 소모. CACHE.md에 TODO로 기록된 기존 이슈 | BluetoothCharacteristic을 _connectToDevice() 시점에 deviceId→char 맵에 캐싱 |
| identity_service.dart | 59 | private_key seed 평문 DB 저장: TODO 주석 있음. 재난 상황에서 기기 탈취 시 개인키 노출 → 모든 과거 메시지(MVP 단순 sharedSecret 기반) 복호화 가능 | Phase 2에서 AES-GCM 암호화 저장 구현. 현재는 허용 가능하나 보안상 심각한 취약점으로 표시 필요 |
| messaging_service.dart | 444-449 | KEY_ANNOUNCE checkPublicKeyChange 후 addOrUpdateContact 호출 로직 버그 가능성: changeResult == changed인 경우 checkPublicKeyChange 내부에서 이미 upsertContact를 호출하고(trusted=false), 이후 addOrUpdateContact()도 다시 호출됨(trusted=false). 중복 upsert는 기능상 무해하나 불필요한 DB 쓰기 및 emit 2회 발생 | changeResult == newContact인 경우에만 addOrUpdateContact 호출, changed인 경우는 checkPublicKeyChange 내부에서 이미 처리됨 |
| ble_service.dart | 451-469 | startHeartbeat()가 MessagingService 또는 main.dart에서 호출되지 않음: R-11 Heartbeat 30초 구현이 BleService에 메서드로 존재하지만 실제로 시작되지 않음. PING 전송 및 이웃 제거 동작 없음 | MessagingService.init()에서 BleService().startHeartbeat(() => pingPacket) 호출 추가 |
| qr_screen.dart | 267-281 | _showFingerprintDialog()에서 nodeId 타입이 dynamic으로 선언됨: confirmTrust(nodeId, fingerprint) 호출 시 타입 안전성 없음. Uint8List가 아닌 타입이 전달되면 런타임 에러 | nodeId 파라미터 타입을 Uint8List로 명시적 선언 |

### Info

| 파일 | 내용 |
|------|------|
| ble_service.dart | R-12 배터리 효율: SCAN_MODE_LOW_POWER 설정 코드 없음. FlutterBluePlus.startScan()에 androidScanMode 파라미터 미전달 → 기본값 사용. R-12 미구현 상태 |
| ble_service.dart | notify 구독 후 연결 등록(_connectedDevices[deviceId] = device) 순서: notify 구독 성공 후 등록하는 현재 순서는 올바름. 단 notify 구독 실패 시 device.disconnect() 없이 return하는 경로가 없으므로 messageChar.setNotifyValue(true) 실패 시 연결이 남아있을 수 있음 |
| messaging_service.dart | SHA-256 구현 중복: CryptoService._syncSha256와 MessagingService._sha256First32가 동일 코드를 복제. CryptoService에 public static 메서드로 노출하면 중복 제거 가능 |
| database_service.dart | seen_messages 10,000개 FIFO 제한이 미구현: R-09 요구사항에는 최대 10,000개 FIFO 제거가 있으나 cleanOldSeenMessages()는 TTL(30분)만 처리하고 개수 제한 없음. DB가 계속 커질 수 있음 |
| ble_service.dart | _scanTimer와 FlutterBluePlus 내부 timeout이 중복: FlutterBluePlus.startScan(timeout: scanDuration)과 별도 Timer(_scanDuration)를 모두 사용. FlutterBluePlus의 timeout 완료 이벤트를 수신하거나 하나만 사용할 것 |
| chat_screen.dart | _subscribeToStream()의 senderNodeId 비교 로직이 복잡한 List.generate+every() 패턴 사용. MessagingService._bytesEqual과 동일한 로직을 UI에서 인라인 구현. 별도 유틸 함수로 분리 권장 |
| identity_service.dart | parseKeyAnnouncePacket() 주석에 "서명이 이미 검증되었다고 가정"이라고 명시되어 있으나, 이 메서드가 호출자 없이 단독 호출될 경우 서명 검증 없이 공개키를 신뢰하는 버그 가능. 메서드명 또는 파라미터에 "pre-verified" 조건을 강제할 것 |
| main.dart | R-03 준수: 외부 서버 호출 없음. 확인 완료 |
| database_service.dart | R-08 TOFU: is_trusted 컬럼 + setTrusted() 구현. 미확인/신뢰 구분 정상 |

---

## Wave 2B Flush 기록 (2026-06-01)

| 항목 | 반영된 파일 |
|------|------------|
| parseKeyAnnouncePacket() 서명검증 분리 패턴 | PATTERNS.md |
| confirmTrust() 대소문자 정규화 패턴 | PATTERNS.md |
| checkPublicKeyChange() 원자적 처리 패턴 | PATTERNS.md |
| StreamController.broadcast() isClosed 방어 패턴 | PATTERNS.md |
| computeSharedSecret X25519 전용 규칙 | RULES.md |
| QR/KEY_ANNOUNCE 파싱 시 nodeId 재계산 규칙 (R-06) | RULES.md |
| timestamp Big-endian int64 규칙 | RULES.md |
| getPublicKey() 신뢰 판단 상위 레이어 책임 규칙 | RULES.md |
| core/ble, features/identity, features/contacts 구현 완료 | — |
