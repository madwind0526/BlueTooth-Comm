// lib/core/packet/mesh_packet.dart

import 'dart:math';
import 'dart:typed_data';

import 'msg_type.dart';

/// The basic packet unit transmitted over the BLE mesh network.
///
/// ## Binary layout (124-byte header + variable payload)
///
/// ```
/// Offset   Size   Field
/// ──────   ────   ─────────────────────────────────────────
///  0        1     protocol_version
///  1       16     msg_id      (UUID v4)
/// 17       16     sender_id   (first 16 bytes of SHA-256(public key))
/// 33       16     target_id   (recipient node_id; broadcast=0xFF×16)
/// 49        1     msg_type    (MsgType.value)
/// 50        1     ttl         (remaining hops, default 7)
/// 51        1     hop_count   (hops traversed, starts at 0)
/// 52        8     timestamp   (Unix ms, big-endian int64)
/// 60       64     signature   (Ed25519, 64 bytes)
/// 124      var    payload     (encrypted body, max 4096 bytes)
/// ──────
/// Total    124 + payload.length bytes
/// ```
class MeshPacket {
  // ── Fields ──────────────────────────────────────────────

  /// Packet protocol version. Packets with a different version are discarded during parsing.
  final int protocolVersion;

  /// Unique packet ID (UUID v4, 16 bytes). Used for duplicate detection and loop prevention.
  final Uint8List msgId; // 16 bytes

  /// Sender node_id (first 16 bytes of SHA-256(public key)).
  final Uint8List senderId; // 16 bytes

  /// Recipient node_id (16 bytes). [broadcast] if this is a broadcast packet.
  final Uint8List targetId; // 16 bytes

  /// Message type.
  final MsgType msgType; // 1 byte

  /// Remaining hop count (default 7). Decremented on each relay. Discarded when 0.
  int ttl; // 1 byte

  /// Hops traversed (starts at 0). Incremented on each relay.
  int hopCount; // 1 byte

  /// Send Unix timestamp (milliseconds). Used for UI display.
  final int timestamp; // 8 bytes (int64)

  /// Ed25519 sender signature (64 bytes).
  /// The signed data is the return value of [toSignableBytes].
  Uint8List signature; // 64 bytes

  /// Encrypted message body (variable, max 4096 bytes).
  final Uint8List payload;

  // ── Constants ────────────────────────────────────────────

  /// Currently supported packet protocol version.
  static const int currentProtocolVersion = 2;

  /// target_id for broadcast (0xFF × 16).
  static final Uint8List broadcast = Uint8List.fromList(List.filled(16, 0xFF));

  /// Default TTL.
  static const int defaultTtl = 7;

  /// Header size (bytes), including signature.
  static const int headerSize = 124;

  /// Maximum payload size (bytes). Split into smaller fragments for BLE transmission.
  static const int maxPayloadSize = 4096;

  // ── Offset constants ─────────────────────────────────────
  static const int _offProtocolVersion = 0;
  static const int _offMsgId = 1;
  static const int _offSenderId = 17;
  static const int _offTargetId = 33;
  static const int _offMsgType = 49;
  static const int _offTtl = 50;
  static const int _offHopCount = 51;
  static const int _offTimestamp = 52;
  static const int _offSignature = 60;
  static const int _offPayload = 124;

  // ── Constructor ──────────────────────────────────────────

  MeshPacket({
    this.protocolVersion = currentProtocolVersion,
    required this.msgId,
    required this.senderId,
    required this.targetId,
    required this.msgType,
    required this.ttl,
    required this.hopCount,
    required this.timestamp,
    required this.signature,
    required this.payload,
  }) : assert(
         protocolVersion == currentProtocolVersion,
         'unsupported protocol version',
       ),
       assert(msgId.length == 16, 'msgId must be 16 bytes'),
       assert(senderId.length == 16, 'senderId must be 16 bytes'),
       assert(targetId.length == 16, 'targetId must be 16 bytes'),
       assert(ttl >= 0 && ttl <= 255, 'ttl must be 0-255'),
       assert(hopCount >= 0 && hopCount <= 255, 'hopCount must be 0-255'),
       assert(signature.length == 64, 'signature must be 64 bytes'),
       assert(
         payload.length <= maxPayloadSize,
         'payload exceeds max size ($maxPayloadSize bytes)',
       );

  // ── Factory ───────────────────────────────────────────────

  /// Creates a new packet. [msgId] and [timestamp] are generated automatically.
  /// [signature] is initially filled with 64 zero bytes (pre-signing placeholder).
  factory MeshPacket.create({
    required Uint8List senderId,
    required Uint8List targetId,
    required MsgType msgType,
    required Uint8List payload,
    int ttl = defaultTtl,
  }) {
    return MeshPacket(
      msgId: generateMsgId(),
      senderId: senderId,
      targetId: targetId,
      msgType: msgType,
      ttl: ttl,
      hopCount: 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      signature: Uint8List(64), // pre-signing placeholder
      payload: payload,
    );
  }

  // ── Serialization ────────────────────────────────────────

  /// Returns the bytes to be signed.
  ///
  /// **ttl and hop_count are excluded from the signed data.**
  /// The signature must remain valid even when relay nodes modify ttl/hop_count.
  /// This method is used identically for both signing and verification.
  ///
  /// Layout:
  /// ```
  ///  0      protocol_version
  ///  1-16   msg_id
  /// 17-32   sender_id
  /// 33-48   target_id
  /// 49      msg_type
  /// 50-57   timestamp (big-endian int64)  ← ttl/hopCount skipped
  /// 58-...  payload
  /// ```
  Uint8List toSignableBytes() {
    // version(1) + msg_id(16) + sender_id(16) + target_id(16) + msg_type(1) + timestamp(8) + payload
    // ttl(1) and hop_count(1) are excluded because they change during relay
    const signableHeaderSize = 58; // 1+16+16+16+1+8
    final buf = Uint8List(signableHeaderSize + payload.length);
    final bd = ByteData.sublistView(buf);

    bd.setUint8(0, protocolVersion);
    buf.setRange(1, 17, msgId);
    buf.setRange(17, 33, senderId);
    buf.setRange(33, 49, targetId);
    bd.setUint8(49, msgType.value);
    bd.setInt64(50, timestamp, Endian.big); // ttl·hopCount skipped
    buf.setRange(
      signableHeaderSize,
      signableHeaderSize + payload.length,
      payload,
    );

    return buf;
  }

  /// Serializes the entire packet to bytes (including signature).
  ///
  /// Call this immediately before sending. The signature must already be set.
  Uint8List toBytes() {
    final buf = Uint8List(headerSize + payload.length);
    final bd = ByteData.sublistView(buf);

    bd.setUint8(_offProtocolVersion, protocolVersion);
    buf.setRange(_offMsgId, _offMsgId + 16, msgId);
    buf.setRange(_offSenderId, _offSenderId + 16, senderId);
    buf.setRange(_offTargetId, _offTargetId + 16, targetId);
    bd.setUint8(_offMsgType, msgType.value);
    bd.setUint8(_offTtl, ttl);
    bd.setUint8(_offHopCount, hopCount);
    bd.setInt64(_offTimestamp, timestamp, Endian.big);
    buf.setRange(_offSignature, _offSignature + 64, signature);
    buf.setRange(_offPayload, _offPayload + payload.length, payload);

    return buf;
  }

  // ── Deserialization ──────────────────────────────────────

  /// Restores a [MeshPacket] from bytes.
  ///
  /// Returns null on parse failure (does not throw exceptions).
  /// Failure conditions:
  /// - length less than headerSize (124) bytes
  /// - payload length exceeds maxPayloadSize (4096) bytes
  /// - unsupported protocol_version
  /// - unknown msg_type value
  static MeshPacket? fromBytes(Uint8List bytes) {
    if (bytes.length < headerSize) return null;

    final payloadLen = bytes.length - headerSize;
    if (payloadLen > maxPayloadSize) return null;

    final bd = ByteData.sublistView(bytes);
    final protocolVersion = bd.getUint8(_offProtocolVersion);
    if (protocolVersion != currentProtocolVersion) return null;

    final MsgType msgType;
    try {
      msgType = MsgType.fromValue(bd.getUint8(_offMsgType));
    } on FormatException {
      return null;
    }

    final int ttl = bd.getUint8(_offTtl);
    final int hopCount = bd.getUint8(_offHopCount);
    final int timestamp = bd.getInt64(_offTimestamp, Endian.big);

    return MeshPacket(
      protocolVersion: protocolVersion,
      msgId: Uint8List.fromList(bytes.sublist(_offMsgId, _offMsgId + 16)),
      senderId: Uint8List.fromList(
        bytes.sublist(_offSenderId, _offSenderId + 16),
      ),
      targetId: Uint8List.fromList(
        bytes.sublist(_offTargetId, _offTargetId + 16),
      ),
      msgType: msgType,
      ttl: ttl,
      hopCount: hopCount,
      timestamp: timestamp,
      signature: Uint8List.fromList(
        bytes.sublist(_offSignature, _offSignature + 64),
      ),
      payload: Uint8List.fromList(
        bytes.sublist(_offPayload, _offPayload + payloadLen),
      ),
    );
  }

  // ── Utilities ───────────────────────────────────────────

  /// Generates a 16-byte UUID v4 msg_id.
  ///
  /// Compliant with RFC 4122 Section 4.4:
  /// - byte[6] upper 4 bits = 0100 (version 4)
  /// - byte[8] upper 2 bits = 10   (variant 1)
  static Uint8List generateMsgId() {
    final rng = Random.secure();
    final id = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      id[i] = rng.nextInt(256);
    }
    // version 4: 0100xxxx
    id[6] = (id[6] & 0x0F) | 0x40;
    // variant 1: 10xxxxxx
    id[8] = (id[8] & 0x3F) | 0x80;
    return id;
  }

  /// Returns whether this packet is a broadcast packet.
  bool get isBroadcast {
    for (var i = 0; i < 16; i++) {
      if (targetId[i] != 0xFF) return false;
    }
    return true;
  }

  // ── Debug ────────────────────────────────────────────────

  @override
  String toString() {
    final msgIdHex = msgId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final senderHex = senderId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'MeshPacket('
        'version=$protocolVersion, '
        'msgId=$msgIdHex, '
        'sender=$senderHex, '
        'type=$msgType, '
        'ttl=$ttl, '
        'hop=$hopCount, '
        'ts=$timestamp, '
        'payloadLen=${payload.length}'
        ')';
  }
}
