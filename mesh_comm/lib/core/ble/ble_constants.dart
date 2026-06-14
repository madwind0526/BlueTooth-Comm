// lib/core/ble/ble_constants.dart

/// Constant definitions used for BLE communication.
///
/// GATT service UUID and Characteristic UUID are app-specific values
/// used as filters to distinguish from generic BLE devices.
class BleConstants {
  BleConstants._(); // prevent instantiation

  // ── GATT UUID ───────────────────────────────────────────────

  /// App-specific GATT service UUID.
  /// Included in scan filters and advertisement packets.
  static const String serviceUuid = '4a580001-b5a3-f393-e0a9-e50e24dcca9e';

  /// Message send/receive Characteristic UUID.
  /// Central → Peripheral: write
  /// Peripheral → Central: notify
  static const String messageCharUuid = '4a580002-b5a3-f393-e0a9-e50e24dcca9e';

  /// Manufacturer ID used to embed node_id in BLE advertisement manufacturer data.
  ///
  /// 0xFFFF is a development value. Replace with a Bluetooth SIG-assigned ID before release.
  static const int developmentManufacturerId = 0xffff;

  // ── Connection limits ───────────────────────────────────────────────

  /// Maximum number of simultaneous BLE connections.
  /// The Android BLE stack supports up to 7 simultaneous connections.
  static const int maxConnections = int.fromEnvironment(
    'MESHCOMM_DIAGNOSTIC_MAX_CONNECTIONS',
    defaultValue: 7,
  );

  // ── Timing ──────────────────────────────────────────────────

  /// Scan duration. Automatically stops after this period.
  static const Duration scanDuration = Duration(seconds: 10);

  /// Heartbeat PING send interval (R-11).
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// Number of consecutive missed heartbeats before removing a neighbor (R-11).
  static const int heartbeatMaxMissed = 2;

  // ── Packet defaults ─────────────────────────────────────────

  /// Default packet TTL (R-11).
  static const int defaultTtl = 7;

  // ── MTU ─────────────────────────────────────────────────────

  /// MTU size to request after connection.
  static const int requestedMtu = 512;

  /// BLE ATT write/notify header size. Actual app data is 3 bytes less than MTU.
  static const int attOverhead = 3;

  /// Default BLE MTU used when negotiation info is not yet available.
  static const int defaultMtu = 23;

  /// Limits memory usage from malformed packets.
  static const int maxFragmentCount = 1024;

  /// How long to keep a partially-received transfer in memory.
  static const Duration fragmentAssemblyTimeout = Duration(seconds: 30);
}
