# Patterns

## Phase-1 portrait app shell

- Windows runner opens at `430 x 800` so the desktop layout follows the phone layout.
- Home uses a fixed top system menu, left filter rail, content area, and bottom navigation.
- LAN and Wi-Fi are visible placeholders until transports are implemented. BLE is functional.
- Contact and group ordering is favorites first, then case-insensitive name ascending.
- Groups are currently derived from local `contacts.group_name` metadata. Group transport
  packets and group chat are Phase-2 work.
- SCAN exposes Tree, SCAN START, and depth input as the stable entry screen.
  N-depth topology packets and force-directed rendering are Phase-2 work.
- GPS/Map is excluded from the product scope for now.
- Shout messages use `MessagePolicy.shoutMaxLength == 50` and
  `MessagePolicy.shoutCooldown == 1 day`.

> 검증된 코드 패턴. 복붙 바로 가능한 형태로 유지.

---

## 싱글톤 서비스 패턴

**사용 시점:** DatabaseService, BleService 등 앱 전역 단일 인스턴스가 필요한 서비스

```dart
class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _db;

  Future<void> init() async {
    if (_db != null) return; // 멱등 보장
    final path = join(await getDatabasesPath(), 'mesh_comm.db');
    _db = await openDatabase(path, version: 1, onCreate: _onCreate);
  }
}
```

---

## sqflite BLOB 바인딩

**사용 시점:** Uint8List(node_id, public_key 등)를 SQLite에 저장/조회

```dart
// 저장
await db.insert('contacts', {
  'node_id': nodeId,  // Uint8List 그대로 바인딩
  'public_key': publicKey,
});

// 조회
final rows = await db.query(
  'contacts',
  where: 'node_id = ?',
  whereArgs: [nodeId],  // Uint8List 그대로 사용
);
// sqflite >= 2.0: 자동으로 Uint8List로 반환
```

---

## upsertContact 패턴 (first_seen 보존)

**사용 시점:** 연락처 추가/업데이트 시 최초 발견 시각 유지

```dart
Future<void> upsertContact(Uint8List nodeId, Uint8List publicKey, ...) async {
  final existing = await getContact(nodeId);
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.insert('contacts', {
    'node_id': nodeId,
    'public_key': publicKey,
    'first_seen': existing?['first_seen'] ?? now,  // 기존값 보존
    'last_seen': now,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}
```

---

## seen_messages TTL 정리

**사용 시점:** 30분마다 또는 앱 시작 시 오래된 msg_id 캐시 정리

```dart
Future<void> cleanOldSeenMessages() async {
  final cutoff = DateTime.now().millisecondsSinceEpoch - 1800000; // 30분
  await db.delete(
    'seen_messages',
    where: 'seen_at < ?',
    whereArgs: [cutoff],
  );
}
// 인덱스: CREATE INDEX idx_seen_messages_seen_at ON seen_messages(seen_at)
```

---

## MeshPacket 직렬화 레이아웃

**사용 시점:** 패킷 직렬화/역직렬화 오프셋 참조

```
toSignableBytes() = 59 bytes 헤더(signature 제외) + payload
toBytes()         = 123 bytes 헤더(signature 포함) + payload

오프셋:
  0  ~ 15 : msg_id      (16 bytes)
  16 ~ 31 : sender_id   (16 bytes)
  32 ~ 47 : target_id   (16 bytes)
  48      : msg_type    (1 byte)
  49      : ttl         (1 byte)
  50      : hop_count   (1 byte)
  51 ~ 58 : timestamp   (8 bytes, big-endian int64)
  59 ~122 : signature   (64 bytes)
  123~    : payload     (가변, 최대 330 bytes)
```

---

## UUID v4 생성 (외부 패키지 없음)

**사용 시점:** msg_id 생성

```dart
static Uint8List generateMsgId() {
  final random = Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) bytes[i] = random.nextInt(256);
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122
  return bytes;
}
```

---

## AES-GCM 직렬화 레이아웃

**사용 시점:** encrypt/decrypt 시 바이트 배열 구조

```dart
// 암호화 결과: nonce(12) + ciphertext(가변) + mac(16)
final encrypted = Uint8List(12 + cipherText.length + 16);
encrypted.setRange(0, 12, nonce);
encrypted.setRange(12, 12 + cipherText.length, cipherText);
encrypted.setRange(12 + cipherText.length, encrypted.length, mac);

// 복호화
final nonce = ciphertext.sublist(0, 12);
final mac   = ciphertext.sublist(ciphertext.length - 16);
final body  = ciphertext.sublist(12, ciphertext.length - 16);
```

---

## Ed25519 키 복원 (seed 기반)

**사용 시점:** 저장된 32 bytes seed에서 키쌍 복원

```dart
// 저장: seed (32 bytes) 만 보관
final keyPair = await Ed25519().newKeyPair();
final seed = await (keyPair as SimpleKeyPairData).extractPrivateKeyBytes();

// 복원
final restored = await Ed25519().newKeyPairFromSeed(seed);
```

---

## Android Peripheral GATT 서버 등록

**사용 시점:** Android 폰이 Windows 또는 다른 폰의 Central 연결을 수락할 때

```dart
await peripheral.BlePeripheral.initialize();
await peripheral.BlePeripheral.clearServices();
await peripheral.BlePeripheral.addService(
  peripheral.BleService(
    uuid: BleConstants.serviceUuid,
    primary: true,
    characteristics: [
      peripheral.BleCharacteristic(
        uuid: BleConstants.messageCharUuid,
        properties: [
          peripheral.CharacteristicProperties.write.index,
          peripheral.CharacteristicProperties.writeWithoutResponse.index,
          peripheral.CharacteristicProperties.notify.index,
        ],
        permissions: [peripheral.AttributePermissions.writeable.index],
      ),
    ],
  ),
);
```

- Central → Peripheral: `setWriteRequestCallback()`에서 패킷 파싱
- Peripheral → Central: `updateCharacteristic()`으로 notify
- 연결 협상 중 device ID는 `_connectingDevices`에 보관하여 중복 `connect()` 방지

---

## 연결 직후 KEY_ANNOUNCE 재전송

**사용 시점:** 앱 초기화 시점에는 BLE 이웃이 없어 최초 `KEY_ANNOUNCE`가 전달되지 않는 경우

- `connectedDevicesStream`에서 새 device ID를 감지한다.
- Android peripheral 연결 콜백은 CCCD notify 구독보다 먼저 올 수 있으므로 3초 뒤 재전송한다.
- 홈 화면 키 아이콘으로 수동 재전송도 가능하다.
- 릴레이되어 돌아온 자체 패킷은 `sender_id == myNodeId`이면 처리 전에 drop한다.

진단 빌드는 첫 연락처 발견 1초 후 TEXT를 한 번 자동 전송한다.

```powershell
flutter build apk --debug --dart-define=MESHCOMM_DIAGNOSTIC_MESSAGE=S21_TO_WINDOWS
flutter build windows --debug --dart-define=MESHCOMM_DIAGNOSTIC_MESSAGE=WINDOWS_TO_S21
```

---

## 연락처 로컬 메타데이터

**사용 시점:** 사용자가 BLE 연락처를 기억하기 쉽게 정리할 때

- DB v2에서 `contacts.is_favorite`, `contacts.group_name` 컬럼을 추가한다.
- `display_name`, 즐겨찾기, 그룹은 로컬 DB에만 저장하며 BLE 패킷으로 전송하지 않는다.
- `upsertContact()`는 새 KEY_ANNOUNCE를 받아도 기존 로컬 메타데이터를 보존한다.
- 즐겨찾기 연락처는 목록 상단에 정렬한다.
- 삭제는 연락처 레코드만 제거하고 채팅 기록은 보존한다.
- 삭제한 기기가 다시 KEY_ANNOUNCE를 보내면 연락처가 다시 추가될 수 있다.

---

## Phase-0 메시지 전송

- DB v3에서 identity에 X25519 공개키/개인키 seed를 저장하고 contact에 X25519 공개키를 저장한다.
- 기존 DB v2 사용자는 Ed25519 신원을 유지한 채 X25519 키쌍만 자동 생성한다.
- TEXT는 최종 수신자의 X25519 공개키와 내 X25519 개인키로 shared secret을 계산한다.
- target이 내가 아닌 TEXT는 복호화하거나 DB에 저장하지 않고 릴레이만 한다.
- BLE 패킷은 MTU와 관계없이 조각 프레임으로 전송하고, 수신 후 패킷 단위로 복원한다.
- Android peripheral notify는 device별 큐에서 순차 전송한다.
- 연결 시 발견한 message characteristic과 notify subscription을 device ID별로 보관한다.
- KEY_ANNOUNCE를 받은 node에는 내 KEY를 한 번 응답하여 양쪽 메시지 키 준비를 끝낸다.
- PING/PONG은 서명 검증 후 heartbeat 카운터를 초기화한다.
