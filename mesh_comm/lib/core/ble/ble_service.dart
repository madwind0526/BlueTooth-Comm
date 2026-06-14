// lib/core/ble/ble_service.dart

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart' as peripheral;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../packet/mesh_packet.dart';
import '../diagnostics/diagnostic_config.dart';
import 'ble_constants.dart';
import 'ble_fragment_codec.dart';

/// Data class for BLE scan results.
class BleScanResult {
  /// BLE address (device ID) of the discovered device.
  final String deviceId;

  /// node_id parsed from ScanResponse (null if absent).
  final Uint8List? nodeId;

  /// Received signal strength (dBm).
  final int rssi;

  const BleScanResult({
    required this.deviceId,
    required this.nodeId,
    required this.rssi,
  });
}

/// BLE mesh network service (singleton).
///
/// ## Roles
/// - **Android**: Peripheral (advertising + accepting connections) + Central (scanning + requesting connections)
/// - **Windows**: Central only (flutter_blue_plus does not support Windows Peripheral)
///
/// ## Usage flow
/// ```dart
/// await BleService().init(
///   myNodeId: nodeId,
///   onPacketReceived: (packet, deviceId) { ... },
/// );
/// await BleService().startScan();
/// ```
class BleService {
  // ── Singleton ───────────────────────────────────────────────────────────────
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  // ── Initialization state ─────────────────────────────────────────────────────
  bool _initialized = false;
  Uint8List? _myNodeId;
  void Function(MeshPacket packet, String deviceId)? _onPacketReceived;

  // ── Connection management ─────────────────────────────────────────────────────
  /// deviceId → BluetoothDevice mapping
  final Map<String, BluetoothDevice> _connectedDevices = {};

  /// deviceId → connection state subscription cancellation
  final Map<String, StreamSubscription> _connectionSubscriptions = {};

  /// deviceId → cached message characteristic found during discovery.
  final Map<String, BluetoothCharacteristic> _messageCharacteristics = {};

  /// deviceId → notify subscription cancellation.
  final Map<String, StreamSubscription> _notificationSubscriptions = {};

  /// Processes BLE sends per device in order so notify/write do not overlap.
  final Map<String, Future<void>> _sendQueues = {};
  final Map<String, DateTime> _lastSendFailureAt = {};
  final Map<String, int> _sendFailureCounts = {};

  /// Device IDs currently being connected. Prevents duplicate connections from repeated scan results.
  final Set<String> _connectingDevices = {};

  /// Central device IDs connected to the Android Peripheral GATT server.
  final Set<String> _peripheralConnectedDevices = {};

  /// Negotiated MTU per Android peripheral connection.
  final Map<String, int> _peripheralMtuByDevice = {};

  final BleFragmentReassembler _fragmentReassembler = BleFragmentReassembler();

  bool _peripheralInitialized = false;

  // ── Stream controllers ───────────────────────────────────────────────────────
  final StreamController<List<String>> _connectedDevicesController =
      StreamController<List<String>>.broadcast();

  final StreamController<BleScanResult> _scanResultController =
      StreamController<BleScanResult>.broadcast();

  // ── Scan subscriptions ───────────────────────────────────────────────────────
  StreamSubscription? _scanSubscription;
  Timer? _scanTimer;
  Timer? _rescanTimer;
  bool _scanRequested = false;
  bool _scanStarting = false;

  // ── Heartbeat ────────────────────────────────────────────────
  Timer? _heartbeatTimer;

  /// deviceId → consecutive missed heartbeat count
  final Map<String, int> _heartbeatMissed = {};
  bool _heartbeatInProgress = false;

  // ── Public streams ────────────────────────────────────────────────────────────

  /// Stream of changes to the connected device ID list.
  Stream<List<String>> get connectedDevicesStream =>
      _connectedDevicesController.stream;

  /// Stream of devices discovered by scanning.
  Stream<BleScanResult> get scanResultStream => _scanResultController.stream;

  // ── Initialization ────────────────────────────────────────────────────────────

  /// Initializes BleService.
  ///
  /// [myNodeId]: 16-byte node_id to include in advertisement packets.
  /// [onPacketReceived]: callback invoked on packet receipt, along with the sender device ID.
  ///
  /// Idempotent: returns immediately if already initialized.
  Future<void> init({
    required Uint8List myNodeId,
    required void Function(MeshPacket packet, String deviceId) onPacketReceived,
  }) async {
    if (_initialized) return;

    _myNodeId = myNodeId;
    _onPacketReceived = onPacketReceived;
    _initialized = true;

    _log('BleService initialized. platform=${Platform.operatingSystem}');
  }

  // ── Peripheral (Android only) ────────────────────────────────────────────────

  /// Starts BLE advertising. **Android only**.
  ///
  /// Includes [serviceUuid] in the advertisement packet and
  /// [_myNodeId] in the manufacturer data.
  Future<void> startAdvertising() async {
    if (!Platform.isAndroid) return;
    if (_myNodeId == null) {
      _log('startAdvertising: not initialized');
      return;
    }
    try {
      await _initializePeripheral();
      await peripheral.BlePeripheral.startAdvertising(
        services: [BleConstants.serviceUuid],
        localName: 'MeshComm',
        manufacturerData: peripheral.ManufacturerData(
          manufacturerId: BleConstants.developmentManufacturerId,
          data: Uint8List.fromList(_myNodeId!),
        ),
        addManufacturerDataInScanResponse: true,
      );
      _log(
        'Advertising started with GATT server '
        '(serviceUuid: ${BleConstants.serviceUuid})',
      );
    } catch (e) {
      _log('startAdvertising error: $e');
    }
  }

  /// Stops BLE advertising. **Android only**.
  Future<void> stopAdvertising() async {
    if (!Platform.isAndroid) return;
    try {
      await peripheral.BlePeripheral.stopAdvertising();
      _log('Advertising stopped');
    } catch (e) {
      _log('stopAdvertising error: $e');
    }
  }

  // ── Central scan ─────────────────────────────────────────────────────────────

  /// Starts BLE scanning.
  ///
  /// Discovers only mesh app devices via the [serviceUuid] filter.
  /// Automatically attempts to connect to discovered devices when
  /// [connectedDeviceIds] is below [maxConnections].
  ///
  /// Automatically stops after [scanDuration].
  Future<void> startScan() async {
    _scanRequested = true;
    if (_scanStarting) return;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _scanStarting = true;
    try {
      // Clean up the previous scan
      await stopScan(keepAutoRestart: true);
      if (!_scanRequested) return;

      // Check BLE adapter state
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (!_scanRequested) return;
      if (adapterState != BluetoothAdapterState.on) {
        _log('BLE adapter is off: $adapterState — scan aborted');
        return;
      }

      // Windows: check already-known BLE devices first via systemDevices
      if (Platform.isWindows) {
        try {
          final knownDevices = await FlutterBluePlus.systemDevices([]);
          _log('Windows known devices: ${knownDevices.length}');
          for (final d in knownDevices) {
            _log('  known device: ${d.remoteId.str} name=${d.platformName}');
            // Log only. Actual connections are made from MeshComm-filtered
            // scan results so unrelated paired BLE devices are ignored.
          }
        } catch (e) {
          _log('systemDevices error: $e');
        }
      }

      // Use onScanResults (more stable on Windows WinRT)
      if (!_scanRequested) return;
      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          _handleScanResult(result);
        }
      }, onError: (e) => _log('scanResults error: $e'));

      // Windows: withServices filter may not work depending on WinRT BLE ad format
      // → scan without filter, then identify MeshComm devices in _handleScanResult.
      // Android: use serviceUuid filter to quickly discover only MeshComm devices.
      await FlutterBluePlus.startScan(
        timeout: BleConstants.scanDuration,
        withServices: Platform.isWindows ? [] : [Guid(BleConstants.serviceUuid)],
        androidScanMode: AndroidScanMode.lowPower,
      );
      if (!_scanRequested) {
        await FlutterBluePlus.stopScan();
        return;
      }

      // Auto-rescan after timeout (repeats periodically to maintain connections)
      _scanTimer = Timer(BleConstants.scanDuration, () {
        _scanSubscription?.cancel();
        _scanSubscription = null;
        _log('Scan completed — rescan in 15s');
        // Rescan in 15s if connected devices are below maxConnections
        if (!_scanRequested) return;
        final shouldRescan =
            connectedDeviceIds.length < BleConstants.maxConnections;
        if (!shouldRescan) return;
        _rescanTimer?.cancel();
        _rescanTimer = Timer(const Duration(seconds: 15), () {
          if (!_scanRequested) return;
          final stillNeedsScan =
              connectedDeviceIds.length < BleConstants.maxConnections;
          if (stillNeedsScan) {
            unawaited(startScan());
          }
        });
      });

      _log('Scan started');
    } catch (e) {
      _log('startScan error: $e');
    } finally {
      _scanStarting = false;
    }
  }

  /// Stops the current scan in progress.
  Future<void> stopScan({bool keepAutoRestart = false}) async {
    if (!keepAutoRestart) {
      _scanRequested = false;
      _rescanTimer?.cancel();
      _rescanTimer = null;
    }
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;

    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      _log('stopScan error: $e');
    }
  }

  // ── Packet sending ────────────────────────────────────────────────────────────

  /// Sends [packet] to a specific device.
  ///
  /// Returns: whether the send succeeded.
  Future<bool> sendPacket(MeshPacket packet, String deviceId) async {
    final previous = _sendQueues[deviceId] ?? Future.value();
    var success = false;
    late final Future<void> current;
    current = previous.catchError((_) {}).then((_) async {
      success = await _sendPacketNow(packet, deviceId);
    });
    _sendQueues[deviceId] = current;
    await current;
    if (identical(_sendQueues[deviceId], current)) {
      _sendQueues.remove(deviceId);
    }
    return success;
  }

  Future<bool> _sendPacketNow(MeshPacket packet, String deviceId) async {
    const maxAttempts = 2;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final lastFailureAt = _lastSendFailureAt[deviceId];
      if (attempt > 0 &&
          lastFailureAt != null &&
          DateTime.now().difference(lastFailureAt) <
              const Duration(milliseconds: 120)) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      final success = await _sendPacketAttempt(packet, deviceId);
      if (success) {
        _lastSendFailureAt.remove(deviceId);
        _sendFailureCounts.remove(deviceId);
        return true;
      }
      _messageCharacteristics.remove(deviceId);
      _lastSendFailureAt[deviceId] = DateTime.now();
      if (attempt < maxAttempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    await _recordSendFailure(deviceId);
    return false;
  }

  Future<void> _recordSendFailure(String deviceId) async {
    final failures = (_sendFailureCounts[deviceId] ?? 0) + 1;
    _sendFailureCounts[deviceId] = failures;
    if (failures < 3 || !isConnected(deviceId)) return;

    _log(
      'sendPacket: removing stale connection $deviceId after $failures failures',
    );
    await disconnect(deviceId);
  }

  Future<bool> _sendPacketAttempt(MeshPacket packet, String deviceId) async {
    final device = _connectedDevices[deviceId];
    if (device == null && !_peripheralConnectedDevices.contains(deviceId)) {
      _log('sendPacket: device $deviceId not connected');
      return false;
    }

    try {
      final bytes = packet.toBytes();
      if (device != null) {
        final characteristic =
            _messageCharacteristics[deviceId] ??
            await _findMessageCharacteristic(device);
        if (characteristic == null) {
          _log('sendPacket: messageChar not found on $deviceId');
          return false;
        }
        _messageCharacteristics[deviceId] = characteristic;
        // Android GATT hard-caps characteristic values at 512 bytes regardless
        // of negotiated MTU. With mtu=517 the codec produces 514-byte frames
        // which fail with PlatformException(dataLen: 514 > max: 512).
        // Cap at 515 so the frame size (mtu-3) never exceeds 512.
        final effectiveMtu = device.mtuNow.clamp(
          BleConstants.defaultMtu,
          515,
        );
        final frames = BleFragmentCodec.fragment(bytes, mtu: effectiveMtu);
        for (final frame in frames) {
          await characteristic.write(frame, withoutResponse: true);
        }
        _log(
          'sendPacket: ${bytes.length} bytes / ${frames.length} fragments '
          '→ $deviceId (central write, mtu=${device.mtuNow}→$effectiveMtu)',
        );
      } else {
        final rawMtu =
            _peripheralMtuByDevice[deviceId] ?? BleConstants.defaultMtu;
        final mtu = rawMtu.clamp(BleConstants.defaultMtu, 515);
        final frames = BleFragmentCodec.fragment(bytes, mtu: mtu);
        for (final frame in frames) {
          await peripheral.BlePeripheral.updateCharacteristic(
            characteristicId: BleConstants.messageCharUuid,
            value: frame,
            deviceId: deviceId,
          );
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        _log(
          'sendPacket: ${bytes.length} bytes / ${frames.length} fragments '
          '→ $deviceId (peripheral notify, mtu=$rawMtu→$mtu)',
        );
      }
      return true;
    } catch (e) {
      _log('sendPacket error ($deviceId): $e');
      return false;
    }
  }

  /// Sends [packet] to all connected devices (Flooding).
  ///
  /// [excludeDeviceId]: skips this device (Reverse Path Filtering, R-09).
  Future<int> broadcastPacket(
    MeshPacket packet, {
    String? excludeDeviceId,
  }) async {
    final targets = connectedDeviceIds
        .where((deviceId) => deviceId != excludeDeviceId)
        .toList(growable: false);
    if (targets.isEmpty) return 0;

    final results = await Future.wait([
      for (final deviceId in targets) sendPacket(packet, deviceId),
    ]);
    return results.where((sent) => sent).length;
  }

  // ── Connection management ─────────────────────────────────────────────────────

  /// List of currently connected device IDs.
  List<String> get connectedDeviceIds => List.unmodifiable({
    ..._connectedDevices.keys,
    ..._peripheralConnectedDevices,
  });

  /// Returns whether [deviceId] is currently connected.
  bool isConnected(String deviceId) =>
      _connectedDevices.containsKey(deviceId) ||
      _peripheralConnectedDevices.contains(deviceId);

  /// Disconnects from [deviceId].
  Future<void> disconnect(String deviceId) async {
    final device = _connectedDevices[deviceId];
    if (device == null) {
      // ble_peripheral does not provide an API to forcibly disconnect an
      // Android GATT server connection. Remove the neighbor only from the heartbeat perspective.
      if (_peripheralConnectedDevices.remove(deviceId)) {
        _heartbeatMissed.remove(deviceId);
        _peripheralMtuByDevice.remove(deviceId);
        _sendQueues.remove(deviceId);
        _lastSendFailureAt.remove(deviceId);
        _sendFailureCounts.remove(deviceId);
        _fragmentReassembler.removeDevice(deviceId);
        _notifyConnectionChange();
      }
      return;
    }

    try {
      await device.disconnect();
    } catch (e) {
      _log('disconnect error ($deviceId): $e');
    }
    // Actual removal is handled in the connectionState listener
  }

  // ── Internal helpers ──────────────────────────────────────────────────────────

  /// Processes a scan result and attempts connection if needed.
  void _handleScanResult(ScanResult result) {
    final deviceId = result.device.remoteId.str;
    final rssi = result.rssi;

    // Parse node_id: extract from manufacturerData
    Uint8List? nodeId;
    try {
      final mData = result.advertisementData.manufacturerData;
      final bytes = mData[BleConstants.developmentManufacturerId];
      if (bytes != null) {
        if (bytes.length == 16) {
          nodeId = Uint8List.fromList(bytes);
        }
      }
    } catch (_) {
      // nodeId = null on parse failure
    }

    // Identify MeshComm devices: by serviceUuid or localName
    final serviceUuids = result.advertisementData.serviceUuids
        .map((g) => g.str128.toLowerCase())
        .toList();
    final localName = result.advertisementData.advName;
    final hasMeshService = serviceUuids.any(
      (u) => u == BleConstants.serviceUuid.toLowerCase(),
    );
    final hasMeshName = localName == 'MeshComm';
    final hasMeshNodeId = nodeId != null;

    // [DIAG-BLE] Windows에서 광고 데이터 상세 로그
    if (Platform.isWindows && (hasMeshService || hasMeshName || hasMeshNodeId || localName.isNotEmpty)) {
      _log('[DIAG-BLE-WIN] device=$deviceId name="$localName" '
          'svcUuids=$serviceUuids hasSvc=$hasMeshService hasName=$hasMeshName hasNodeId=$hasMeshNodeId');
    }

    if (!hasMeshService && !hasMeshName && !hasMeshNodeId) {
      return; // Ignore non-MeshComm devices
    }
    _log('MeshComm device found: $deviceId (rssi: $rssi, name: $localName)');

    // Skip already connected devices
    if (_connectedDevices.containsKey(deviceId) ||
        _connectingDevices.contains(deviceId)) {
      return;
    }

    // Stop connection attempt when max connections reached
    if (connectedDeviceIds.length >= BleConstants.maxConnections) return;

    // Attempt connection in background (only log on error)
    _connectToDevice(result.device);
  }

  /// Connects to [device] and sets up GATT services.
  Future<void> _connectToDevice(BluetoothDevice device) async {
    final deviceId = device.remoteId.str;
    if (_connectedDevices.containsKey(deviceId) ||
        !_connectingDevices.add(deviceId)) {
      return;
    }
    _log('Connecting to $deviceId ...');

    try {
      // Windows BLE stack may take several seconds for connect/discoverServices, so timeout is required.
      await device
          .connect(license: License.nonprofit, autoConnect: false)
          .timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          _log('connect timeout: $deviceId');
          throw TimeoutException('BLE connect timeout');
        },
      );

      // MTU negotiation (Android only; Windows handles it automatically)
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(BleConstants.requestedMtu);
        } catch (e) {
          _log('MTU request failed ($deviceId): $e');
        }
      }

      // Service discovery
      final services = await device.discoverServices().timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          _log('discoverServices timeout: $deviceId');
          throw TimeoutException('BLE discoverServices timeout');
        },
      );
      final targetService = services.cast<BluetoothService?>().firstWhere(
        (s) => s?.serviceUuid == Guid(BleConstants.serviceUuid),
        orElse: () => null,
      );

      if (targetService == null) {
        _log('Service not found on $deviceId, disconnecting');
        await device.disconnect();
        return;
      }

      // Find Characteristic and subscribe to notify
      final messageChar = targetService.characteristics
          .cast<BluetoothCharacteristic?>()
          .firstWhere(
            (c) => c?.characteristicUuid == Guid(BleConstants.messageCharUuid),
            orElse: () => null,
          );

      if (messageChar == null) {
        _log('MessageChar not found on $deviceId, disconnecting');
        await device.disconnect();
        return;
      }

      // Subscribe to notify
      await messageChar.setNotifyValue(true).timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          _log('setNotifyValue timeout: $deviceId');
          throw TimeoutException('setNotifyValue timeout');
        },
      );
      _messageCharacteristics[deviceId] = messageChar;
      _notificationSubscriptions[deviceId] = messageChar.lastValueStream.listen(
        (bytes) {
          if (bytes.isEmpty) return;
          _handleIncomingBytes(Uint8List.fromList(bytes), deviceId);
        },
        onError: (e) => _log('notify error ($deviceId): $e'),
      );

      // Register connection
      _connectedDevices[deviceId] = device;
      _heartbeatMissed[deviceId] = 0;
      _notifyConnectionChange();

      // Detect disconnection
      final sub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDeviceDisconnected(deviceId);
        }
      });
      _connectionSubscriptions[deviceId] = sub;

      _log('Connected to $deviceId');
    } catch (e) {
      _log('_connectToDevice error ($deviceId): $e');
      // Return GATT slot — if disconnect is not called on catch, the OS slot remains occupied
      try { await device.disconnect(); } catch (_) {}
    } finally {
      _connectingDevices.remove(deviceId);
    }
  }

  /// Reassembles BLE fragments, parses them as a [MeshPacket], and invokes the callback.
  void _handleIncomingBytes(Uint8List bytes, String deviceId) {
    Uint8List? packetBytes;
    if (BleFragmentCodec.isFragment(bytes)) {
      packetBytes = _fragmentReassembler.add(deviceId, bytes);
      if (packetBytes == null) return;
    } else {
      // Also parse raw packets during protocol transition to clearly log errors.
      packetBytes = bytes;
    }

    final packet = MeshPacket.fromBytes(packetBytes);
    if (packet == null) {
      _log(
        '_handleIncomingBytes: invalid packet from $deviceId '
        '(${packetBytes.length} bytes)',
      );
      return;
    }
    _onPacketReceived?.call(packet, deviceId);
  }

  /// Handles device disconnection.
  void _onDeviceDisconnected(String deviceId) {
    _log('Device disconnected: $deviceId');
    _connectedDevices.remove(deviceId);
    _heartbeatMissed.remove(deviceId);
    _messageCharacteristics.remove(deviceId);
    _sendQueues.remove(deviceId);
    _lastSendFailureAt.remove(deviceId);
    _sendFailureCounts.remove(deviceId);
    _notificationSubscriptions[deviceId]?.cancel();
    _notificationSubscriptions.remove(deviceId);
    _fragmentReassembler.removeDevice(deviceId);
    _connectionSubscriptions[deviceId]?.cancel();
    _connectionSubscriptions.remove(deviceId);
    _notifyConnectionChange();

    // Trigger rescan immediately on disconnect instead of waiting for scanTimer/rescanTimer expiry.
    if (_scanRequested) {
      _rescanTimer?.cancel();
      _rescanTimer = Timer(const Duration(seconds: 3), () {
        if (_scanRequested) unawaited(startScan());
      });
    }
  }

  /// Registers the Android Peripheral GATT server and message characteristic.
  Future<void> _initializePeripheral() async {
    if (_peripheralInitialized) return;

    await peripheral.BlePeripheral.initialize();
    if (!await peripheral.BlePeripheral.isSupported()) {
      throw StateError('BLE peripheral mode is not supported on this device');
    }

    peripheral.BlePeripheral.setAdvertisingStatusUpdateCallback((
      advertising,
      error,
    ) {
      _log(
        'Peripheral advertising=$advertising'
        '${error == null ? '' : ' error=$error'}',
      );
    });
    peripheral.BlePeripheral.setConnectionStateChangeCallback((
      deviceId,
      connected,
    ) {
      if (connected) {
        _peripheralConnectedDevices.add(deviceId);
        _heartbeatMissed[deviceId] = 0;
        _peripheralMtuByDevice[deviceId] = BleConstants.defaultMtu;
        _log('Peripheral central connected: $deviceId');
        if (DiagnosticConfig.stopAdvertisingAfterPeripheralConnect) {
          unawaited(stopAdvertising());
        }
      } else {
        _peripheralConnectedDevices.remove(deviceId);
        _heartbeatMissed.remove(deviceId);
        _peripheralMtuByDevice.remove(deviceId);
        _sendQueues.remove(deviceId);
        _lastSendFailureAt.remove(deviceId);
        _sendFailureCounts.remove(deviceId);
        _fragmentReassembler.removeDevice(deviceId);
        _log('Peripheral central disconnected: $deviceId');
      }
      _notifyConnectionChange();
    });
    peripheral.BlePeripheral.setMtuChangeCallback((deviceId, mtu) {
      _peripheralMtuByDevice[deviceId] = mtu;
      _log('Peripheral MTU changed: device=$deviceId mtu=$mtu');
    });
    peripheral.BlePeripheral.setWriteRequestCallback((
      deviceId,
      characteristicId,
      offset,
      value,
    ) {
      if (characteristicId.toLowerCase() !=
          BleConstants.messageCharUuid.toLowerCase()) {
        return null;
      }
      if (offset != 0 || value == null) {
        _log(
          'Peripheral write ignored: device=$deviceId '
          'offset=$offset bytes=${value?.length ?? 0}',
        );
        return peripheral.WriteRequestResult(status: 7);
      }

      try {
        _handleIncomingBytes(Uint8List.fromList(value), deviceId);
      } catch (e, st) {
        _log('setWriteRequestCallback error: $e\n$st');
      }
      return null;
    });

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

    _peripheralInitialized = true;
    _log('Peripheral GATT server initialized');
  }

  /// Finds and returns the messageChar for the connected device.
  /// Returns from cache (_messageCharacteristics) immediately without re-discovering GATT.
  Future<BluetoothCharacteristic?> _findMessageCharacteristic(
    BluetoothDevice device,
  ) async {
    final deviceId = device.remoteId.str;
    // Return from cache first — prevents duplicate discoverServices calls
    final cached = _messageCharacteristics[deviceId];
    if (cached != null) return cached;

    try {
      final services = await device.discoverServices().timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          _log('_findMessageCharacteristic discoverServices timeout: $deviceId');
          throw TimeoutException('discoverServices timeout');
        },
      );
      for (final service in services) {
        if (service.serviceUuid == Guid(BleConstants.serviceUuid)) {
          for (final char in service.characteristics) {
            if (char.characteristicUuid == Guid(BleConstants.messageCharUuid)) {
              return char;
            }
          }
        }
      }
    } catch (e) {
      _log('_findMessageCharacteristic error: $e');
    }
    return null;
  }

  /// Emits the latest device list to connectedDevicesStream.
  void _notifyConnectionChange() {
    if (!_connectedDevicesController.isClosed) {
      _connectedDevicesController.add(connectedDeviceIds);
    }
  }

  // ── Heartbeat ────────────────────────────────────────────────

  /// Starts the heartbeat timer.
  ///
  /// Sends a PING every [BleConstants.heartbeatInterval] and removes a device
  /// after [BleConstants.heartbeatMaxMissed] consecutive missed responses.
  void startHeartbeat(Future<MeshPacket> Function() pingPacketFactory) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(BleConstants.heartbeatInterval, (_) async {
      if (_heartbeatInProgress) return;
      _heartbeatInProgress = true;
      try {
        final deviceIds = connectedDeviceIds;
        for (final deviceId in deviceIds) {
          // Increment missed count, then send
          _heartbeatMissed[deviceId] = (_heartbeatMissed[deviceId] ?? 0) + 1;

          if (_heartbeatMissed[deviceId]! > BleConstants.heartbeatMaxMissed) {
            _log('Heartbeat timeout: removing $deviceId');
            await disconnect(deviceId);
            continue;
          }

          final ping = await pingPacketFactory();
          await sendPacket(ping, deviceId);
        }
      } finally {
        _heartbeatInProgress = false;
      }
    });
  }

  /// Stops the heartbeat timer.
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Resets the heartbeat counter when a signature-verified PONG is received.
  void markHeartbeatResponse(String deviceId) {
    if (isConnected(deviceId)) {
      _heartbeatMissed[deviceId] = 0;
    }
  }

  // ── Cleanup ──────────────────────────────────────────────────

  /// Disconnects all connections and releases resources.
  Future<void> dispose() async {
    stopHeartbeat();
    await stopScan();
    _rescanTimer?.cancel();
    _rescanTimer = null;

    if (Platform.isAndroid) {
      await stopAdvertising();
      if (_peripheralInitialized) {
        await peripheral.BlePeripheral.clearServices();
      }
    }

    for (final deviceId in List<String>.from(_connectedDevices.keys)) {
      await disconnect(deviceId);
    }
    _peripheralConnectedDevices.clear();
    _connectingDevices.clear();
    _heartbeatMissed.clear();
    _peripheralMtuByDevice.clear();
    _messageCharacteristics.clear();
    _sendQueues.clear();
    _lastSendFailureAt.clear();
    _sendFailureCounts.clear();
    _fragmentReassembler.clear();

    for (final sub in _connectionSubscriptions.values) {
      await sub.cancel();
    }
    _connectionSubscriptions.clear();

    for (final sub in _notificationSubscriptions.values) {
      await sub.cancel();
    }
    _notificationSubscriptions.clear();

    if (!_connectedDevicesController.isClosed) {
      await _connectedDevicesController.close();
    }
    if (!_scanResultController.isClosed) {
      await _scanResultController.close();
    }

    _initialized = false;
    _peripheralInitialized = false;
    _log('BleService disposed');
  }

  // ── Logging ──────────────────────────────────────────────────

  void _log(String message) {
    // ignore: avoid_print
    print('[BleService] $message');
  }
}
