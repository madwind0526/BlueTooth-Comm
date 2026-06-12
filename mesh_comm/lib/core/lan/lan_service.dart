// lib/core/lan/lan_service.dart
//
// LAN/Wi-Fi 전송 계층.
// UDP 멀티캐스트로 동일 네트워크 내 MeshComm 피어를 발견하고
// TCP 소켓으로 MeshPacket을 교환한다.
//
// 패킷 프레이밍: [4바이트 BE uint32 길이][MeshPacket 바이트]

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../packet/mesh_packet.dart';
import 'lan_constants.dart';

/// 발견된 LAN 피어 정보.
class LanPeer {
  final String nodeIdHex;
  final InternetAddress address;
  final int tcpPort;

  const LanPeer({
    required this.nodeIdHex,
    required this.address,
    required this.tcpPort,
  });
}

/// LAN/Wi-Fi 전송 서비스 (싱글톤).
///
/// ## 초기화
/// ```dart
/// await LanService().init(
///   myNodeId: identity.myNodeId,
///   onPacketReceived: (packet, peerId) { ... },
/// );
/// ```
class LanService {
  static final LanService _instance = LanService._internal();
  factory LanService() => _instance;
  LanService._internal();

  bool _initialized = false;
  bool _running = false;
  Uint8List? _myNodeId;
  void Function(MeshPacket packet, String peerId)? _onPacketReceived;

  // nodeIdHex → Socket (활성 TCP 연결)
  final Map<String, Socket> _peers = {};

  // 연결 중인 nodeIdHex (중복 연결 방지)
  final Set<String> _connecting = {};

  // 소켓별 수신 버퍼 (부분 수신 처리)
  final Map<String, _ReceiveBuffer> _buffers = {};

  // 마지막으로 알려진 피어 주소 캐시 (끊김 후 즉시 재연결용)
  final Map<String, LanPeer> _peerAddressCache = {};

  // 피어별 재연결 시도 횟수 (exponential backoff 계산용)
  final Map<String, int> _reconnectAttempts = {};

  // ── LAN Heartbeat ─────────────────────────────────────────────────────────
  // PING/PONG: 0xFF 매직 바이트로 MeshPacket과 구별.
  // 목적: 무음 TCP 끊김 감지 (WiFi 단절 후 onDone/onError 없이 소켓이 죽는 경우).
  static const int _hbMagic    = 0xFF;
  static const int _hbPingByte = 0x50; // 'P'
  static const int _hbPongByte = 0x51; // 'Q'
  static const int _hbIntervalSec = 8;
  static const int _hbTimeoutMs  = 20000; // PONG 20초 무응답 → 연결 해제

  // nodeIdHex → 마지막 PONG 수신 시각 (ms)
  final Map<String, int> _lastPongMs = {};
  Timer? _heartbeatTimer;
  Timer? _heartbeatWatchdog;

  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  Timer? _beaconTimer;

  // 연결된 피어 nodeIdHex 목록 스트림
  final StreamController<List<String>> _peersController =
      StreamController<List<String>>.broadcast();
  Set<String> _lastEmittedPeerIds = {};

  Stream<List<String>> get connectedPeersStream => _peersController.stream;

  List<String> get connectedPeerIds =>
      _running ? List.unmodifiable(_peers.keys) : const [];

  int get connectedCount => _running ? _peers.length : 0;

  bool hasPeer(String nodeIdHex) => _running && _peers.containsKey(nodeIdHex);

  // ── 초기화 ──────────────────────────────────────────────────────────────────

  Future<void> init({
    required Uint8List myNodeId,
    required void Function(MeshPacket packet, String peerId) onPacketReceived,
  }) async {
    if (_initialized) return;
    _myNodeId = myNodeId;
    _onPacketReceived = onPacketReceived;
    _initialized = true;
    await start();
  }

  /// LAN 서비스를 시작(재시작)한다. init() 이후에만 유효.
  Future<void> start() async {
    if (_myNodeId == null) return;
    if (_running) return;
    _running = true;
    // Windows: stop() 직후 즉시 bind 하면 포트가 아직 해제 중일 수 있어 실패.
    // 짧은 대기 후 bind 시도.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!_running) return;
    await _startTcpServer();
    if (!_running) return;
    await _startUdpSocket();
    if (!_running) return;
    _startBeacon();
    _startHeartbeat();
    // 이전에 알고 있던 피어에 즉시 재연결 시도 (WiFi 토글 복구)
    _reconnectCachedPeers();
  }

  /// LAN 서비스를 중단한다. start()로 재시작 가능.
  /// 주소 캐시(_peerAddressCache)는 보존 — start() 후 즉시 재연결에 사용.
  Future<void> stop() async {
    _running = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
    await _tcpServer?.close();
    _tcpServer = null;
    for (final socket in List<Socket>.from(_peers.values)) {
      socket.destroy();
    }
    _peers.clear();
    _buffers.clear();
    _connecting.clear();
    _lastPongMs.clear();
    _reconnectAttempts.clear(); // stop 후 start 시 처음부터 재시도
    // _peerAddressCache 는 의도적으로 유지 — start() 재연결용
    _notifyChange();
  }

  Future<void> dispose() async {
    await stop();
    if (!_peersController.isClosed) {
      await _peersController.close();
    }
    _initialized = false;
  }

  // ── 패킷 전송 ───────────────────────────────────────────────────────────────

  Future<bool> sendPacket(MeshPacket packet, String peerNodeIdHex) async {
    if (!_running) return false;
    final socket = _peers[peerNodeIdHex];
    if (socket == null) return false;
    try {
      final data = packet.toBytes();
      final frame = _buildFrame(data);
      socket.add(frame);
      await socket.flush().timeout(const Duration(seconds: 5));
      return true;
    } catch (e) {
      _log('sendPacket error ($peerNodeIdHex): $e');
      _removePeer(peerNodeIdHex);
      return false;
    }
  }

  /// 연결된 모든 LAN 피어에게 패킷을 브로드캐스트한다.
  Future<int> broadcastPacket(MeshPacket packet) async {
    if (!_running) return 0;
    final peerIds = List<String>.from(_peers.keys);
    if (peerIds.isEmpty) return 0;
    final results = await Future.wait(peerIds.map((id) => sendPacket(packet, id)));
    return results.where((sent) => sent).length;
  }

  // ── TCP 서버 ─────────────────────────────────────────────────────────────────

  Future<void> _startTcpServer() async {
    try {
      _tcpServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        LanConstants.tcpPort,
        shared: true,
      );
      if (!_running) {
        await _tcpServer?.close();
        _tcpServer = null;
        return;
      }
      _tcpServer!.listen(_handleIncomingConnection, onError: (e) {
        _log('TCP server error: $e');
      });
      _log('TCP server listening on port ${LanConstants.tcpPort}');
    } catch (e) {
      _log('TCP server start failed: $e');
    }
  }

  void _handleIncomingConnection(Socket socket) {
    if (!_running) {
      socket.destroy();
      return;
    }
    _log('Incoming TCP from ${socket.remoteAddress.address}:${socket.remotePort}');
    _setupSocketListener(socket, null);
  }

  Future<void> _connectToPeer(LanPeer peer) async {
    if (!_running) return;
    if (_peers.containsKey(peer.nodeIdHex)) return;
    if (_connecting.contains(peer.nodeIdHex)) return;
    _connecting.add(peer.nodeIdHex);
    _peerAddressCache[peer.nodeIdHex] = peer; // 주소 캐시 업데이트
    try {
      final socket = await Socket.connect(
        peer.address,
        peer.tcpPort,
        timeout: LanConstants.connectTimeout,
      );
      if (!_running) {
        socket.destroy();
        return;
      }
      _setupSocketListener(socket, peer.nodeIdHex);
      _log('Connected to ${peer.nodeIdHex} at ${peer.address.address}');
    } catch (e) {
      _log('Connect to ${peer.nodeIdHex} failed: $e');
    } finally {
      _connecting.remove(peer.nodeIdHex);
    }
  }

  void _setupSocketListener(Socket socket, String? knownNodeIdHex) {
    if (!_running) {
      socket.destroy();
      return;
    }
    final buffer = _ReceiveBuffer();
    String? resolvedId = knownNodeIdHex;

    socket.listen(
      (data) {
        if (!_running) {
          socket.destroy();
          return;
        }
        buffer.append(data);
        while (true) {
          final frame = buffer.tryReadFrame();
          if (frame == null) break;

          // ── LAN Heartbeat 우선 처리 ────────────────────────────────────────
          // MsgPacket 파싱 전에 0xFF 매직 바이트로 PING/PONG 구별.
          if (frame.length >= 2 && frame[0] == _hbMagic) {
            if (frame[1] == _hbPingByte) {
              // PING 수신 → PONG 응답 (현재 연결 수 포함)
              if (resolvedId != null) {
                _log('[HB] PING ← $resolvedId');
              }
              final pong = _buildFrame(Uint8List.fromList(
                [_hbMagic, _hbPongByte, _peers.length & 0xFF],
              ));
              try {
                socket.add(pong);
                unawaited(socket.flush().timeout(const Duration(seconds: 3)));
              } catch (_) {}
            } else if (frame[1] == _hbPongByte) {
              // PONG 수신 → 생존 확인
              if (resolvedId != null) {
                final connCount = frame.length > 2 ? frame[2] : 0;
                _lastPongMs[resolvedId!] = DateTime.now().millisecondsSinceEpoch;
                _log('[HB] PONG ← $resolvedId (peer connCount=$connCount)');
              }
            }
            continue; // MeshPacket 파싱 스킵
          }

          final packet = MeshPacket.fromBytes(frame);
          if (packet == null) continue;

          // 처음 수신한 패킷의 senderId로 피어를 확인
          if (resolvedId == null) {
            resolvedId = _hexOf(packet.senderId);
            if (!_running) {
              socket.destroy();
              return;
            }
            if (!_peers.containsKey(resolvedId)) {
              _peers[resolvedId!] = socket;
              _buffers[resolvedId!] = buffer;
              _reconnectAttempts.remove(resolvedId); // 연결 성공 → backoff 카운터 리셋
              _lastPongMs[resolvedId!] = DateTime.now().millisecondsSinceEpoch; // 초기 생존 시각
              _notifyChange();
              _log('Peer registered via incoming: $resolvedId');
            } else {
              socket.destroy();
              return;
            }
          }

          _onPacketReceived?.call(packet, resolvedId!);
        }
      },
      onDone: () {
        // 이 소켓이 _peers에 등록된 소켓과 같을 때만 제거
        // (중복 연결 감지로 파괴된 소켓의 onDone이 valid 피어를 지우는 race 방지)
        if (resolvedId != null && _peers[resolvedId] == socket) {
          _log('[DIAG-LAN] onDone → removePeer: $resolvedId');
          _removePeer(resolvedId!);
        } else if (resolvedId != null) {
          _log('[DIAG-LAN] onDone SKIPPED (stale socket): $resolvedId');
        }
        socket.destroy();
      },
      onError: (e) {
        _log('[DIAG-LAN] Socket error ($resolvedId): $e');
        if (resolvedId != null && _peers[resolvedId] == socket) {
          _removePeer(resolvedId!);
        }
        socket.destroy();
      },
      cancelOnError: true,
    );

    if (knownNodeIdHex != null) {
      if (!_running) {
        socket.destroy();
        return;
      }
      // 동시 오픈 레이스: incoming이 이미 등록됐으면 outgoing을 버린다.
      if (_peers.containsKey(knownNodeIdHex)) {
        _log('[DIAG-LAN] Outgoing duplicate discarded (incoming already registered): $knownNodeIdHex');
        socket.destroy();
        return;
      }
      _peers[knownNodeIdHex] = socket;
      _buffers[knownNodeIdHex] = buffer;
      _reconnectAttempts.remove(knownNodeIdHex); // 연결 성공 → backoff 카운터 리셋
      _lastPongMs[knownNodeIdHex] = DateTime.now().millisecondsSinceEpoch; // 초기 생존 시각
      _notifyChange();
    }
  }

  /// 주소 캐시에 있는 피어에 즉시 재연결 시도 (start() 후 호출).
  void _reconnectCachedPeers() {
    if (!_running) return;
    for (final peer in List<LanPeer>.from(_peerAddressCache.values)) {
      if (!_peers.containsKey(peer.nodeIdHex) &&
          !_connecting.contains(peer.nodeIdHex)) {
        _connectToPeer(peer);
      }
    }
  }

  void _removePeer(String nodeIdHex) {
    _peers.remove(nodeIdHex);
    _buffers.remove(nodeIdHex);
    _lastPongMs.remove(nodeIdHex);
    _notifyChange();
    if (!_running) return;
    // 캐시에 주소가 있으면 exponential backoff 후 재연결
    final cached = _peerAddressCache[nodeIdHex];
    if (cached != null) {
      final attempt = _reconnectAttempts[nodeIdHex] ?? 0;
      // 1s → 2s → 4s → 8s → 16s → 32s → 60s 상한
      final delaySec = attempt < 6 ? (1 << attempt) : 60;
      _reconnectAttempts[nodeIdHex] = attempt + 1;
      _log('Reconnect $nodeIdHex in ${delaySec}s (attempt ${attempt + 1})');
      Future<void>.delayed(Duration(seconds: delaySec), () {
        if (_running &&
            !_peers.containsKey(nodeIdHex) &&
            !_connecting.contains(nodeIdHex)) {
          _connectToPeer(cached);
        }
      });
    }
  }

  // ── UDP 비콘 ─────────────────────────────────────────────────────────────────

  Future<void> _startUdpSocket() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        LanConstants.udpPort,
      );
      if (!_running) {
        _udpSocket?.close();
        _udpSocket = null;
        return;
      }
      _udpSocket!.broadcastEnabled = true;

      // 모든 네트워크 인터페이스에 멀티캐스트 join.
      // Windows: 이더넷+WiFi가 동시에 있을 때 한 인터페이스만 join 하면 수신 실패.
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLinkLocal: false,
        );
        if (interfaces.isEmpty) {
          // 인터페이스 목록을 못 얻은 경우 기본 join
          _udpSocket!.joinMulticast(
            InternetAddress(LanConstants.multicastGroup),
          );
        } else {
          for (final iface in interfaces) {
            try {
              _udpSocket!.joinMulticast(
                InternetAddress(LanConstants.multicastGroup),
                iface,
              );
              _log('Multicast joined on ${iface.name}');
            } catch (e) {
              _log('Multicast join failed on ${iface.name}: $e');
            }
          }
        }
      } catch (e) {
        _log('Multicast setup failed: $e');
      }

      _udpSocket!.listen((event) {
        if (!_running) return;
        if (event == RawSocketEvent.read) {
          final dg = _udpSocket!.receive();
          if (dg != null) _handleBeacon(dg);
        }
      });
      _log('UDP socket bound on port ${LanConstants.udpPort}');
    } catch (e) {
      _log('UDP socket start failed: $e');
    }
  }

  void _startBeacon() {
    if (!_running) return;
    _sendBeacon();
    _beaconTimer = Timer.periodic(LanConstants.beaconInterval, (_) {
      _sendBeacon();
    });
  }

  /// LAN TCP Heartbeat — PING을 주기적으로 전송하고 무응답 피어를 제거한다.
  void _startHeartbeat() {
    if (!_running) return;
    final pingFrame = _buildFrame(Uint8List.fromList([_hbMagic, _hbPingByte]));

    // PING 전송: 연결된 모든 피어에 주기적으로
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: _hbIntervalSec),
      (_) {
        if (!_running) return;
        for (final entry in Map<String, Socket>.from(_peers).entries) {
          try {
            entry.value.add(pingFrame);
            unawaited(entry.value.flush().timeout(const Duration(seconds: 3)));
            _log('[HB] PING → ${entry.key}');
          } catch (_) {}
        }
      },
    );

    // Watchdog: 마지막 PONG으로부터 _hbTimeoutMs 초과 시 연결 해제
    _heartbeatWatchdog = Timer.periodic(
      const Duration(seconds: _hbIntervalSec),
      (_) {
        if (!_running) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final peerId in List<String>.from(_peers.keys)) {
          final lastPong = _lastPongMs[peerId];
          if (lastPong != null && now - lastPong > _hbTimeoutMs) {
            _log('[HB] $peerId 응답 없음 (${now - lastPong}ms) → 연결 해제');
            _peers[peerId]?.destroy();
            _removePeer(peerId);
          }
        }
      },
    );
  }

  void _sendBeacon() {
    if (!_running) return;
    if (_udpSocket == null || _myNodeId == null) return;
    final payload = jsonEncode({
      'magic': LanConstants.beaconMagic,
      'nodeId': _hexOf(_myNodeId!),
      'tcpPort': LanConstants.tcpPort,
    });
    final bytes = utf8.encode(payload);

    // 멀티캐스트
    try {
      _udpSocket!.send(
        bytes,
        InternetAddress(LanConstants.multicastGroup),
        LanConstants.udpPort,
      );
    } catch (_) {}

    // 브로드캐스트 (255.255.255.255)
    try {
      _udpSocket!.send(
        bytes,
        InternetAddress('255.255.255.255'),
        LanConstants.udpPort,
      );
    } catch (_) {}
  }

  void _handleBeacon(Datagram dg) {
    if (!_running) return;
    try {
      final raw = utf8.decode(dg.data);
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['magic'] != LanConstants.beaconMagic) return;

      final nodeIdHex = map['nodeId'] as String?;
      final tcpPort = map['tcpPort'] as int?;
      if (nodeIdHex == null || tcpPort == null) return;

      // 자기 자신 비콘 무시
      if (_myNodeId != null && nodeIdHex == _hexOf(_myNodeId!)) return;

      if (!_peers.containsKey(nodeIdHex) && !_connecting.contains(nodeIdHex)) {
        final peer = LanPeer(
          nodeIdHex: nodeIdHex,
          address: dg.address,
          tcpPort: tcpPort,
        );
        _connectToPeer(peer);
      }
    } catch (_) {}
  }

  // ── 유틸 ─────────────────────────────────────────────────────────────────────

  /// 4바이트 BE 길이 + 데이터 프레임 생성
  static Uint8List _buildFrame(Uint8List data) {
    final frame = Uint8List(4 + data.length);
    final bd = ByteData.sublistView(frame);
    bd.setUint32(0, data.length, Endian.big);
    frame.setRange(4, frame.length, data);
    return frame;
  }

  void _notifyChange() {
    final current = _peers.keys.toSet();
    if (current.length == _lastEmittedPeerIds.length &&
        current.containsAll(_lastEmittedPeerIds)) {
      return;
    }
    _lastEmittedPeerIds = current;
    if (!_peersController.isClosed) {
      _peersController.add(List.unmodifiable(_peers.keys));
    }
  }

  void _log(String msg) => debugPrint('[LanService] $msg');

  static String _hexOf(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ── 수신 버퍼 ──────────────────────────────────────────────────────────────────

/// TCP 스트림에서 [4-byte length][data] 프레임을 재조립한다.
class _ReceiveBuffer {
  final _buf = <int>[];

  void append(List<int> data) => _buf.addAll(data);

  /// 완성된 프레임이 있으면 반환, 없으면 null.
  Uint8List? tryReadFrame() {
    if (_buf.length < 4) return null;
    final length =
        (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];
    if (length <= 0 || length > 4 * 1024 * 1024) {
      // 비정상 길이 — 버퍼 초기화
      _buf.clear();
      return null;
    }
    if (_buf.length < 4 + length) return null;
    final frame = Uint8List.fromList(_buf.sublist(4, 4 + length));
    _buf.removeRange(0, 4 + length);
    return frame;
  }
}

