// lib/core/lan/lan_service.dart
//
// LAN/Wi-Fi transport layer.
// Discovers MeshComm peers on the same network via UDP multicast and
// exchanges MeshPackets over TCP sockets.
//
// Packet framing: [4-byte BE uint32 length][MeshPacket bytes]

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../packet/mesh_packet.dart';
import 'lan_constants.dart';

/// Discovered LAN peer information.
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

/// LAN/Wi-Fi transport service (singleton).
///
/// ## Initialization
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

  // nodeIdHex → Socket (active TCP connections)
  final Map<String, Socket> _peers = {};

  // nodeIdHex values currently connecting (prevents duplicate connections)
  final Set<String> _connecting = {};

  // Per-socket receive buffers (handles partial receives)
  final Map<String, _ReceiveBuffer> _buffers = {};

  // Cache of last known peer addresses (for immediate reconnect after disconnect)
  final Map<String, LanPeer> _peerAddressCache = {};

  // Per-peer reconnect attempt count (used for exponential backoff)
  final Map<String, int> _reconnectAttempts = {};

  // ── LAN Heartbeat ─────────────────────────────────────────────────────────
  // PING/PONG: distinguished from MeshPacket by 0xFF magic byte.
  // Purpose: detect silent TCP disconnects (socket dying after WiFi loss with no onDone/onError).
  static const int _hbMagic    = 0xFF;
  static const int _hbPingByte = 0x50; // 'P'
  static const int _hbPongByte = 0x51; // 'Q'
  static const int _hbIntervalSec = 8;
  static const int _hbTimeoutMs  = 20000; // PONG 20초 무응답 → 연결 해제

  // nodeIdHex → last PONG received timestamp (ms)
  final Map<String, int> _lastPongMs = {};
  Timer? _heartbeatTimer;
  Timer? _heartbeatWatchdog;

  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  Timer? _beaconTimer;

  // Stream of connected peer nodeIdHex list
  final StreamController<List<String>> _peersController =
      StreamController<List<String>>.broadcast();
  Set<String> _lastEmittedPeerIds = {};

  Stream<List<String>> get connectedPeersStream => _peersController.stream;

  List<String> get connectedPeerIds =>
      _running ? List.unmodifiable(_peers.keys) : const [];

  int get connectedCount => _running ? _peers.length : 0;

  bool get isRunning => _running;

  bool hasPeer(String nodeIdHex) => _running && _peers.containsKey(nodeIdHex);

  // ── Initialization ────────────────────────────────────────────────────────

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

  /// Starts (or restarts) the LAN service. Only valid after init().
  Future<void> start() async {
    if (_myNodeId == null) return;
    if (_running) return;
    _running = true;
    // Windows: binding immediately after stop() may fail if the port is still releasing.
    // Wait briefly before binding.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!_running) return;
    await _startTcpServer();
    if (!_running) return;
    await _startUdpSocket();
    if (!_running) return;
    _startBeacon();
    _startHeartbeat();
    // Immediately attempt to reconnect to previously known peers (WiFi toggle recovery)
    _reconnectCachedPeers();
  }

  /// Stops the LAN service. Can be restarted via start().
  /// Address cache (_peerAddressCache) is preserved for immediate reconnect after start().
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
    _reconnectAttempts.clear(); // reset on stop so start() retries from scratch
    // _peerAddressCache is intentionally preserved — used for reconnect after start()
    _notifyChange();
  }

  Future<void> dispose() async {
    await stop();
    if (!_peersController.isClosed) {
      await _peersController.close();
    }
    _initialized = false;
  }

  // ── Packet sending ────────────────────────────────────────────────────────

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

  /// Broadcasts a packet to all connected LAN peers.
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
    _peerAddressCache[peer.nodeIdHex] = peer; // update address cache
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

          // ── LAN Heartbeat: handle first ───────────────────────────────────
          // Distinguish PING/PONG from MeshPacket by 0xFF magic byte before parsing.
          if (frame.length >= 2 && frame[0] == _hbMagic) {
            if (frame[1] == _hbPingByte) {
              // PING received → respond with PONG (includes current connection count)
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
              // PONG received → confirm peer is alive
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

          // Register peer from the first DIRECT (hopCount==0) packet only.
          // Relay packets (hopCount>0) have senderId = original sender, not the direct TCP peer,
          // so using them would map the wrong nodeHex to this socket and corrupt dedup logic.
          if (resolvedId == null) {
            if (packet.hopCount > 0) {
              // Forward relay packet without registering; wait for a direct packet.
              _onPacketReceived?.call(packet, '');
              continue;
            }
            resolvedId = _hexOf(packet.senderId);
            if (!_running) {
              socket.destroy();
              return;
            }
            if (!_peers.containsKey(resolvedId)) {
              _peers[resolvedId!] = socket;
              _buffers[resolvedId!] = buffer;
              _reconnectAttempts.remove(resolvedId);
              _lastPongMs[resolvedId!] = DateTime.now().millisecondsSinceEpoch;
              _notifyChange();
              _log('Peer registered via incoming: $resolvedId');
            } else {
              // Simultaneous-open: both nodes connected to each other at the same time.
              // Tie-break deterministically: the node with the HIGHER nodeId hex
              // closes its own outgoing and accepts the remote's incoming instead.
              // The LOWER nodeId node keeps its own outgoing (handled in outgoing path).
              final myHex = _myNodeId != null ? _hexOf(_myNodeId!) : '';
              if (myHex.compareTo(resolvedId!) > 0) {
                // I have higher nodeId → close my existing outgoing, accept this incoming
                final existing = _peers.remove(resolvedId!)!;
                _buffers.remove(resolvedId!);
                existing.destroy(); // onDone fires but _peers[resolvedId] is already replaced
                _peers[resolvedId!] = socket;
                _buffers[resolvedId!] = buffer;
                _reconnectAttempts.remove(resolvedId);
                _lastPongMs[resolvedId!] = DateTime.now().millisecondsSinceEpoch;
                _notifyChange();
                _log('Simultaneous open: I yield (higher nodeId) — swapped to incoming from $resolvedId');
              } else {
                // I have lower nodeId → keep my outgoing, reject this incoming
                _log('Simultaneous open: I keep outgoing (lower nodeId) — rejecting incoming from $resolvedId');
                socket.destroy();
                return;
              }
            }
          }

          _onPacketReceived?.call(packet, resolvedId!);
        }
      },
      onDone: () {
        // Only remove peer if this socket is still the registered one.
        // Destroyed duplicate sockets also fire onDone; this check prevents
        // them from removing the valid peer that replaced them.
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
      if (_peers.containsKey(knownNodeIdHex)) {
        // Simultaneous-open: the incoming path registered the peer before our
        // outgoing connection completed. Apply the SAME nodeId tie-break that
        // the incoming path uses, so both sides reach the same decision.
        //
        // Lower nodeId keeps its OWN outgoing — replace the registered incoming.
        // Higher nodeId yields — discard this outgoing, keep the incoming.
        //
        // Without this, both sockets get destroyed: A (lower) discards its
        // outgoing, B (higher) yields by destroying B's outgoing which is the
        // socket A registered, so A fires removePeer and both connections die.
        final myHex = _myNodeId != null ? _hexOf(_myNodeId!) : '';
        if (myHex.compareTo(knownNodeIdHex) < 0) {
          // Lower nodeId wins: replace the registered incoming with our outgoing.
          final old = _peers[knownNodeIdHex]!;
          _peers[knownNodeIdHex] = socket;
          _buffers[knownNodeIdHex] = buffer;
          old.destroy();
          _log('Simultaneous open (outgoing late): lower nodeId wins → replaced incoming: $knownNodeIdHex');
          // Fall through to update heartbeat/notify below.
        } else {
          // Higher nodeId yields: keep the incoming, discard this outgoing.
          _log('Simultaneous open (outgoing late): higher nodeId yields → discarding outgoing: $knownNodeIdHex');
          socket.destroy();
          return;
        }
      } else {
        _peers[knownNodeIdHex] = socket;
        _buffers[knownNodeIdHex] = buffer;
      }
      _reconnectAttempts.remove(knownNodeIdHex);
      _lastPongMs[knownNodeIdHex] = DateTime.now().millisecondsSinceEpoch;
      _notifyChange();
    }
  }

  /// Immediately retries all cached peers that are not yet connected.
  /// Called from notifyWakeup when the LAN service is already running.
  void tryReconnectCached() => _reconnectCachedPeers();

  /// Immediately tries to connect to a specific cached peer by nodeId hex.
  /// No-op if already connected, already connecting, or peer not in cache.
  void tryConnectCached(String nodeIdHex) {
    if (!_running) return;
    if (_peers.containsKey(nodeIdHex) || _connecting.contains(nodeIdHex)) return;
    final peer = _peerAddressCache[nodeIdHex];
    if (peer != null) _connectToPeer(peer);
  }

  /// Immediately attempts to reconnect peers in the address cache (called after start()).
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
    // Reconnect with exponential backoff after cached peer disconnects.
    final cached = _peerAddressCache[nodeIdHex];
    if (cached != null) {
      final attempt = _reconnectAttempts[nodeIdHex] ?? 0;
      // 1s → 2s → 4s → 8s → 16s → 32s → 60s cap
      final delaySec = attempt < 6 ? (1 << attempt) : 60;
      _reconnectAttempts[nodeIdHex] = attempt + 1;
      // Add node-ID-derived jitter (0–1999 ms) so that two nodes coming back
      // from the same network disruption don't reconnect simultaneously and
      // trigger the simultaneous-open race condition.
      final jitterMs = _myNodeId != null
          ? ((_myNodeId![_myNodeId!.length - 2] << 8 |
                      _myNodeId![_myNodeId!.length - 1]) %
                  2000)
          : Random().nextInt(2000);
      _log('Reconnect $nodeIdHex in ${delaySec}s + ${jitterMs}ms jitter (attempt ${attempt + 1})');
      Future<void>.delayed(
        Duration(milliseconds: delaySec * 1000 + jitterMs),
        () {
          if (_running &&
              !_peers.containsKey(nodeIdHex) &&
              !_connecting.contains(nodeIdHex)) {
            _connectToPeer(cached);
          }
        },
      );
    }
  }

  // ── UDP beacon ───────────────────────────────────────────────────────────────

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

      // Join multicast on all network interfaces.
      // Windows: when both Ethernet and WiFi are active, joining only one interface fails to receive.
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLinkLocal: false,
        );
        if (interfaces.isEmpty) {
          // Fallback join when interface list cannot be retrieved
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

  /// LAN TCP Heartbeat — periodically sends PING and removes unresponsive peers.
  void _startHeartbeat() {
    if (!_running) return;
    final pingFrame = _buildFrame(Uint8List.fromList([_hbMagic, _hbPingByte]));

    // PING send: periodically to all connected peers
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

    // Watchdog: disconnect if _hbTimeoutMs has elapsed since last PONG
    _heartbeatWatchdog = Timer.periodic(
      const Duration(seconds: _hbIntervalSec),
      (_) {
        if (!_running) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final peerId in List<String>.from(_peers.keys)) {
          final lastPong = _lastPongMs[peerId];
          if (lastPong != null && now - lastPong > _hbTimeoutMs) {
            _log('[HB] $peerId no response (${now - lastPong}ms) → disconnecting');
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

    // Multicast
    try {
      _udpSocket!.send(
        bytes,
        InternetAddress(LanConstants.multicastGroup),
        LanConstants.udpPort,
      );
    } catch (_) {}

    // Broadcast (255.255.255.255)
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

      // Ignore own beacon
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

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Builds a frame with 4-byte BE length prefix + data
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

// ── Receive buffer ────────────────────────────────────────────────────────────

/// Reassembles [4-byte length][data] frames from a TCP stream.
class _ReceiveBuffer {
  final _buf = <int>[];

  void append(List<int> data) => _buf.addAll(data);

  /// Returns a completed frame if available, or null.
  Uint8List? tryReadFrame() {
    if (_buf.length < 4) return null;
    final length =
        (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];
    if (length <= 0 || length > 4 * 1024 * 1024) {
      // Abnormal length — clear the buffer
      _buf.clear();
      return null;
    }
    if (_buf.length < 4 + length) return null;
    final frame = Uint8List.fromList(_buf.sublist(4, 4 + length));
    _buf.removeRange(0, 4 + length);
    return frame;
  }
}

