// lib/core/ble/ble_constants.dart

/// BLE 통신에 사용되는 상수 정의.
///
/// GATT 서비스 UUID와 Characteristic UUID는 앱 고유값으로,
/// 일반 BLE 기기와 구분하는 필터로 사용된다.
class BleConstants {
  BleConstants._(); // 인스턴스화 방지

  // ── GATT UUID ───────────────────────────────────────────────

  /// 앱 고유 GATT 서비스 UUID.
  /// 스캔 필터 및 광고 패킷에 포함된다.
  static const String serviceUuid = '4a580001-b5a3-f393-e0a9-e50e24dcca9e';

  /// 메시지 송수신 Characteristic UUID.
  /// Central → Peripheral: write
  /// Peripheral → Central: notify
  static const String messageCharUuid = '4a580002-b5a3-f393-e0a9-e50e24dcca9e';

  /// BLE 광고의 manufacturer data에 node_id를 싣기 위한 ID.
  ///
  /// 0xFFFF는 개발용 값이다. 배포 전 Bluetooth SIG 할당 ID로 교체한다.
  static const int developmentManufacturerId = 0xffff;

  // ── 연결 제한 ───────────────────────────────────────────────

  /// 동시 BLE 연결 최대 수.
  /// Android BLE 스택은 최대 7개 동시 연결을 지원한다.
  static const int maxConnections = int.fromEnvironment(
    'MESHCOMM_DIAGNOSTIC_MAX_CONNECTIONS',
    defaultValue: 7,
  );

  // ── 타이밍 ──────────────────────────────────────────────────

  /// 스캔 지속 시간. 이후 자동 중단.
  static const Duration scanDuration = Duration(seconds: 10);

  /// Heartbeat PING 전송 간격 (R-11).
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// Heartbeat 무응답 허용 횟수 초과 시 이웃 제거 (R-11).
  static const int heartbeatMaxMissed = 2;

  // ── 패킷 기본값 ─────────────────────────────────────────────

  /// 패킷 기본 TTL (R-11).
  static const int defaultTtl = 7;

  // ── MTU ─────────────────────────────────────────────────────

  /// 연결 후 요청할 MTU 크기.
  static const int requestedMtu = 512;

  /// BLE ATT write/notify 헤더 크기. 실제 앱 데이터는 MTU보다 3 bytes 작다.
  static const int attOverhead = 3;

  /// 협상 정보가 아직 없을 때 사용하는 BLE 기본 MTU.
  static const int defaultMtu = 23;

  /// 비정상 패킷으로 과도한 메모리를 사용하지 않도록 제한한다.
  static const int maxFragmentCount = 1024;

  /// 일부 조각만 수신된 전송을 메모리에서 보관하는 시간.
  static const Duration fragmentAssemblyTimeout = Duration(seconds: 30);
}
