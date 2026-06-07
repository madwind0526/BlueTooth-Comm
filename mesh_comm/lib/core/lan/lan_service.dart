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
  Uint8List? _myNodeId;
  void Function(MeshPacket packet, String peerId)? _onPacketReceived;

  // nodeIdHex → Socket (활성 TCP 연결)
  final Map<String, Socket> _peers = {};

  // 연결 중인 nodeIdHex (중복 연결 방지)
  final Set<String> _connecting = {};

  // 소켓별 수신 버퍼 (부분 수신 처리)
  final Map<String, _ReceiveBuffer> _buffers = {};

  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  Timer? _beaconTimer;

  // 연결된 피어 nodeIdHex 목록 스트림
  final StreamController<List<String>> _peersController =
      StreamController<List<String>>.broadcast();

  Stream<List<String>> get connectedPeersStream => _peersController.stream;

  List<String> get connectedPeerIds => List.unmodifiable(_peers.keys);

  int get connectedCount => _peers.length;

  bool hasPeer(String nodeIdHex) => _peers.containsKey(nodeIdHex);

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
    await _startTcpServer();
    await _startUdpSocket();
    _startBeacon();
  }

  /// LAN 서비스를 중단한다. start()로 재시작 가능.
  Future<void> stop() async {
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
    final socket = _peers[peerNodeIdHex];
    if (socket == null) return false;
    try {
      final data = packet.toBytes();
      final frame = _buildFrame(data);
      socket.add(frame);
      await socket.flush();
      return true;
    } catch (e) {
      _log('sendPacket error ($peerNodeIdHex): $e');
      _removePeer(peerNodeIdHex);
      return false;
    }
  }

  /// 연결된 모든 LAN 피어에게 패킷을 브로드캐스트한다.
  Future<void> broadcastPacket(MeshPacket packet) async {
    final peerIds = List<String>.from(_peers.keys);
    await Future.wait(peerIds.map((id) => sendPacket(packet, id)));
  }

  // ── TCP 서버 ─────────────────────────────────────────────────────────────────

  Future<void> _startTcpServer() async {
    try {
      _tcpServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        LanConstants.tcpPort,
        shared: true,
      );
      _tcpServer!.listen(_handleIncomingConnection, onError: (e) {
        _log('TCP server error: $e');
      });
      _log('TCP server listening on port ${LanConstants.tcpPort}');
    } catch (e) {
      _log('TCP server start failed: $e');
    }
  }

  void _handleIncomingConnection(Socket socket) {
    _log('Incoming TCP from ${socket.remoteAddress.address}:${socket.remotePort}');
    _setupSocketListener(socket, null);
  }

  Future<void> _connectToPeer(LanPeer peer) async {
    if (_peers.containsKey(peer.nodeIdHex)) return;
    if (_connecting.contains(peer.nodeIdHex)) return;
    _connecting.add(peer.nodeIdHex);
    try {
      final socket = await Socket.connect(
        peer.address,
        peer.tcpPort,
        timeout: LanConstants.connectTimeout,
      );
      _setupSocketListener(socket, peer.nodeIdHex);
      _log('Connected to ${peer.nodeIdHex} at ${peer.address.address}');
    } catch (e) {
      _log('Connect to ${peer.nodeIdHex} failed: $e');
    } finally {
      _connecting.remove(peer.nodeIdHex);
    }
  }

  void _setupSocketListener(Socket socket, String? knownNodeIdHex) {
    final buffer = _ReceiveBuffer();
    String? resolvedId = knownNodeIdHex;

    socket.listen(
      (data) {
        buffer.append(data);
        while (true) {
          final frame = buffer.tryReadFrame();
          if (frame == null) break;
          final packet = MeshPacket.fromBytes(frame);
          if (packet == null) continue;

          // 처음 수신한 패킷의 senderId로 피어를 확인
          if (resolvedId == null) {
            resolvedId = _hexOf(packet.senderId);
            if (!_peers.containsKey(resolvedId)) {
              _peers[resolvedId!] = socket;
              _buffers[resolvedId!] = buffer;
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
        if (resolvedId != null) _removePeer(resolvedId!);
        socket.destroy();
      },
      onError: (e) {
        _log('Socket error ($resolvedId): $e');
        if (resolvedId != null) _removePeer(resolvedId!);
        socket.destroy();
      },
      cancelOnError: true,
    );

    if (knownNodeIdHex != null) {
      _peers[knownNodeIdHex] = socket;
      _buffers[knownNodeIdHex] = buffer;
      _notifyChange();
    }
  }

  void _removePeer(String nodeIdHex) {
    _peers.remove(nodeIdHex);
    _buffers.remove(nodeIdHex);
    _notifyChange();
  }

  // ── UDP 비콘 ─────────────────────────────────────────────────────────────────

  Future<void> _startUdpSocket() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        LanConstants.udpPort,
      );
      _udpSocket!.broadcastEnabled = true;

      try {
        _udpSocket!.joinMulticast(
          InternetAddress(LanConstants.multicastGroup),
        );
      } catch (_) {
        // 멀티캐스트 미지원 환경(일부 Android)에서는 브로드캐스트로 폴백
      }

      _udpSocket!.listen((event) {
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
    _sendBeacon();
    _beaconTimer = Timer.periodic(LanConstants.beaconInterval, (_) {
      _sendBeacon();
    });
  }

  void _sendBeacon() {
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

