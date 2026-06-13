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

/// BLE 스캔 결과 데이터 클래스.
class BleScanResult {
  /// 발견된 기기의 BLE 주소 (device ID).
  final String deviceId;

  /// ScanResponse에서 파싱한 node_id (없으면 null).
  final Uint8List? nodeId;

  /// 수신 신호 강도 (dBm).
  final int rssi;

  const BleScanResult({
    required this.deviceId,
    required this.nodeId,
    required this.rssi,
  });
}

/// BLE 메시 네트워크 서비스 (싱글톤).
///
/// ## 역할
/// - **Android**: Peripheral(광고·연결 수락) + Central(스캔·연결 요청) 동시 운용
/// - **Windows**: Central 전용 (flutter_blue_plus 가 Windows Peripheral 미지원)
///
/// ## 사용 흐름
/// ```dart
/// await BleService().init(
///   myNodeId: nodeId,
///   onPacketReceived: (packet, deviceId) { ... },
/// );
/// await BleService().startScan();
/// ```
class BleService {
  // ── 싱글톤 ───────────────────────────────────────────────────
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  // ── 초기화 상태 ──────────────────────────────────────────────
  bool _initialized = false;
  Uint8List? _myNodeId;
  void Function(MeshPacket packet, String deviceId)? _onPacketReceived;

  // ── 연결 관리 ────────────────────────────────────────────────
  /// deviceId → BluetoothDevice 매핑
  final Map<String, BluetoothDevice> _connectedDevices = {};

  /// deviceId → 연결 상태 구독 취소
  final Map<String, StreamSubscription> _connectionSubscriptions = {};

  /// deviceId → 발견한 메시지 characteristic 캐시.
  final Map<String, BluetoothCharacteristic> _messageCharacteristics = {};

  /// deviceId → notify 구독 취소.
  final Map<String, StreamSubscription> _notificationSubscriptions = {};

  /// device별 BLE 전송을 순서대로 처리하여 notify/write가 겹치지 않게 한다.
  final Map<String, Future<void>> _sendQueues = {};
  final Map<String, DateTime> _lastSendFailureAt = {};
  final Map<String, int> _sendFailureCounts = {};

  /// 연결 협상 중인 device ID. 반복 scan result로 인한 중복 연결을 막는다.
  final Set<String> _connectingDevices = {};

  /// Android Peripheral GATT 서버에 연결된 Central device ID.
  final Set<String> _peripheralConnectedDevices = {};

  /// Android peripheral 연결별 협상 MTU.
  final Map<String, int> _peripheralMtuByDevice = {};

  final BleFragmentReassembler _fragmentReassembler = BleFragmentReassembler();

  bool _peripheralInitialized = false;

  // ── Stream 컨트롤러 ──────────────────────────────────────────
  final StreamController<List<String>> _connectedDevicesController =
      StreamController<List<String>>.broadcast();

  final StreamController<BleScanResult> _scanResultController =
      StreamController<BleScanResult>.broadcast();

  // ── 스캔 구독 ────────────────────────────────────────────────
  StreamSubscription? _scanSubscription;
  Timer? _scanTimer;
  Timer? _rescanTimer;
  bool _scanRequested = false;
  bool _scanStarting = false;

  // ── Heartbeat ────────────────────────────────────────────────
  Timer? _heartbeatTimer;

  /// deviceId → 연속 무응답 횟수
  final Map<String, int> _heartbeatMissed = {};
  bool _heartbeatInProgress = false;

  // ── 공개 Stream ──────────────────────────────────────────────

  /// 연결된 기기 ID 목록 변화 스트림.
  Stream<List<String>> get connectedDevicesStream =>
      _connectedDevicesController.stream;

  /// 스캔으로 발견된 기기 스트림.
  Stream<BleScanResult> get scanResultStream => _scanResultController.stream;

  // ── 초기화 ───────────────────────────────────────────────────

  /// BleService를 초기화한다.
  ///
  /// [myNodeId]: 광고 패킷에 포함될 16 bytes node_id.
  /// [onPacketReceived]: 패킷 수신 콜백. 발신 기기 ID와 함께 전달.
  ///
  /// 멱등(idempotent): 이미 초기화된 경우 즉시 반환.
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

  // ── Peripheral (Android 전용) ────────────────────────────────

  /// BLE 광고를 시작한다. **Android 전용**.
  ///
  /// 광고 패킷에 [serviceUuid]를 포함하며,
  /// manufacturer data에 [_myNodeId]를 포함한다.
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

  /// BLE 광고를 중지한다. **Android 전용**.
  Future<void> stopAdvertising() async {
    if (!Platform.isAndroid) return;
    try {
      await peripheral.BlePeripheral.stopAdvertising();
      _log('Advertising stopped');
    } catch (e) {
      _log('stopAdvertising error: $e');
    }
  }

  // ── Central 스캔 ─────────────────────────────────────────────

  /// BLE 스캔을 시작한다.
  ///
  /// [serviceUuid] 필터로 메시 앱 기기만 발견한다.
  /// 발견된 기기는 [connectedDeviceIds]가 [maxConnections] 미만인 경우
  /// 자동으로 연결을 시도한다.
  ///
  /// [scanDuration] 후 자동 중단된다.
  Future<void> startScan() async {
    _scanRequested = true;
    if (_scanStarting) return;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _scanStarting = true;
    try {
      // 이전 스캔 정리
      await stopScan(keepAutoRestart: true);
      if (!_scanRequested) return;

      // BLE 어댑터 상태 확인
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (!_scanRequested) return;
      if (adapterState != BluetoothAdapterState.on) {
        _log('BLE 어댑터 꺼져 있음: $adapterState — 스캔 중단');
        return;
      }

      // Windows: systemDevices로 이미 알려진 BLE 기기 먼저 확인
      if (Platform.isWindows) {
        try {
          final knownDevices = await FlutterBluePlus.systemDevices([]);
          _log('Windows 알려진 기기: ${knownDevices.length}개');
          for (final d in knownDevices) {
            _log('  알려진 기기: ${d.remoteId.str} name=${d.platformName}');
            // Log only. Actual connections are made from MeshComm-filtered
            // scan results so unrelated paired BLE devices are ignored.
          }
        } catch (e) {
          _log('systemDevices error: $e');
        }
      }

      // onScanResults 사용 (Windows winrt에서 더 안정적)
      if (!_scanRequested) return;
      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          _handleScanResult(result);
        }
      }, onError: (e) => _log('scanResults error: $e'));

      // Windows: withServices 필터가 WinRT BLE 광고 형식에 따라 동작하지 않을 수
      // 있음 → 필터 없이 전체 스캔 후 _handleScanResult에서 MeshComm 기기 식별.
      // Android: serviceUuid 필터로 MeshComm 기기만 빠르게 발견.
      await FlutterBluePlus.startScan(
        timeout: BleConstants.scanDuration,
        withServices: Platform.isWindows ? [] : [Guid(BleConstants.serviceUuid)],
        androidScanMode: AndroidScanMode.lowPower,
      );
      if (!_scanRequested) {
        await FlutterBluePlus.stopScan();
        return;
      }

      // 타임아웃 후 자동 재스캔 (연결 유지를 위해 주기적으로 반복)
      _scanTimer = Timer(BleConstants.scanDuration, () {
        _scanSubscription?.cancel();
        _scanSubscription = null;
        _log('Scan completed — 15초 후 재스캔');
        // 15초 후 재스캔 (연결된 기기가 maxConnections 미만이면)
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

  /// 진행 중인 스캔을 중지한다.
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

  // ── 패킷 전송 ────────────────────────────────────────────────

  /// 특정 기기에 [packet]을 전송한다.
  ///
  /// 반환값: 전송 성공 여부.
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

  /// 연결된 모든 기기에 [packet]을 전송한다 (Flooding).
  ///
  /// [excludeDeviceId]: 이 기기에는 전송하지 않는다 (Reverse Path Filtering, R-09).
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

  // ── 연결 관리 ────────────────────────────────────────────────

  /// 현재 연결된 기기 ID 목록.
  List<String> get connectedDeviceIds => List.unmodifiable({
    ..._connectedDevices.keys,
    ..._peripheralConnectedDevices,
  });

  /// [deviceId] 기기가 현재 연결 중인지 확인한다.
  bool isConnected(String deviceId) =>
      _connectedDevices.containsKey(deviceId) ||
      _peripheralConnectedDevices.contains(deviceId);

  /// [deviceId] 기기와의 연결을 끊는다.
  Future<void> disconnect(String deviceId) async {
    final device = _connectedDevices[deviceId];
    if (device == null) {
      // ble_peripheral은 Android GATT server 연결을 강제로 끊는 API를
      // 제공하지 않는다. heartbeat 관점에서만 이웃을 제거한다.
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
    // 실제 제거는 connectionState 리스너에서 처리됨
  }

  // ── 내부 헬퍼 ────────────────────────────────────────────────

  /// 스캔 결과를 처리하고 필요 시 연결을 시도한다.
  void _handleScanResult(ScanResult result) {
    final deviceId = result.device.remoteId.str;
    final rssi = result.rssi;

    // node_id 파싱: manufacturerData에서 추출
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
      // 파싱 실패 시 nodeId = null
    }

    // MeshComm 기기 확인: serviceUuid 또는 localName으로 식별
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
      return; // MeshComm 앱이 아닌 기기 무시
    }
    _log('MeshComm 기기 발견: $deviceId (rssi: $rssi, name: $localName)');

    // 이미 연결된 기기는 건너뜀
    if (_connectedDevices.containsKey(deviceId) ||
        _connectingDevices.contains(deviceId)) {
      return;
    }

    // 최대 연결 수 초과 시 연결 시도 중단
    if (connectedDeviceIds.length >= BleConstants.maxConnections) return;

    // 백그라운드에서 연결 시도 (오류 시 로그만 출력)
    _connectToDevice(result.device);
  }

  /// [device]에 연결하고 GATT 서비스를 설정한다.
  Future<void> _connectToDevice(BluetoothDevice device) async {
    final deviceId = device.remoteId.str;
    if (_connectedDevices.containsKey(deviceId) ||
        !_connectingDevices.add(deviceId)) {
      return;
    }
    _log('Connecting to $deviceId ...');

    try {
      // Windows BLE 스택은 connect/discoverServices 가 수초 걸릴 수 있어 타임아웃 필수.
      await device
          .connect(license: License.nonprofit, autoConnect: false)
          .timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          _log('connect timeout: $deviceId');
          throw TimeoutException('BLE connect timeout');
        },
      );

      // MTU 협상 (Android 전용, Windows는 자동)
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(BleConstants.requestedMtu);
        } catch (e) {
          _log('MTU request failed ($deviceId): $e');
        }
      }

      // 서비스 발견
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

      // Characteristic 찾기 및 notify 구독
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

      // Notify 구독
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

      // 연결 등록
      _connectedDevices[deviceId] = device;
      _heartbeatMissed[deviceId] = 0;
      _notifyConnectionChange();

      // 연결 끊김 감지
      final sub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDeviceDisconnected(deviceId);
        }
      });
      _connectionSubscriptions[deviceId] = sub;

      _log('Connected to $deviceId');
    } catch (e) {
      _log('_connectToDevice error ($deviceId): $e');
      // GATT 슬롯 반환 — catch 시 disconnect하지 않으면 OS 슬롯이 점유 상태로 남음
      try { await device.disconnect(); } catch (_) {}
    } finally {
      _connectingDevices.remove(deviceId);
    }
  }

  /// BLE 조각을 합친 뒤 [MeshPacket]으로 파싱하고 콜백을 호출한다.
  void _handleIncomingBytes(Uint8List bytes, String deviceId) {
    Uint8List? packetBytes;
    if (BleFragmentCodec.isFragment(bytes)) {
      packetBytes = _fragmentReassembler.add(deviceId, bytes);
      if (packetBytes == null) return;
    } else {
      // 프로토콜 전환 중 raw packet도 파싱하여 오류를 명확히 기록한다.
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

  /// 기기 연결 끊김을 처리한다.
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

  /// Android Peripheral GATT 서버와 메시지 characteristic을 등록한다.
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

  /// 연결된 기기의 messageChar을 찾아 반환한다.
  /// 캐시(_messageCharacteristics)가 있으면 GATT 재탐색 없이 바로 반환.
  Future<BluetoothCharacteristic?> _findMessageCharacteristic(
    BluetoothDevice device,
  ) async {
    final deviceId = device.remoteId.str;
    // 캐시 우선 반환 — 중복 discoverServices 호출 방지
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

  /// connectedDevicesStream에 최신 목록을 emit한다.
  void _notifyConnectionChange() {
    if (!_connectedDevicesController.isClosed) {
      _connectedDevicesController.add(connectedDeviceIds);
    }
  }

  // ── Heartbeat ────────────────────────────────────────────────

  /// Heartbeat 타이머를 시작한다.
  ///
  /// [BleConstants.heartbeatInterval] 마다 PING을 전송하고,
  /// [BleConstants.heartbeatMaxMissed] 회 연속 무응답 시 해당 기기를 제거한다.
  void startHeartbeat(Future<MeshPacket> Function() pingPacketFactory) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(BleConstants.heartbeatInterval, (_) async {
      if (_heartbeatInProgress) return;
      _heartbeatInProgress = true;
      try {
        final deviceIds = connectedDeviceIds;
        for (final deviceId in deviceIds) {
          // 무응답 횟수 증가 후 전송
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

  /// Heartbeat 타이머를 중지한다.
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 서명이 검증된 PONG을 수신했을 때 heartbeat 카운터를 초기화한다.
  void markHeartbeatResponse(String deviceId) {
    if (isConnected(deviceId)) {
      _heartbeatMissed[deviceId] = 0;
    }
  }

  // ── 정리 ────────────────────────────────────────────────────

  /// 모든 연결을 끊고 리소스를 해제한다.
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

  // ── 로그 ────────────────────────────────────────────────────

  void _log(String message) {
    // ignore: avoid_print
    print('[BleService] $message');
  }
}
