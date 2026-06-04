// lib/core/packet/mesh_packet.dart

import 'dart:math';
import 'dart:typed_data';

import 'msg_type.dart';

/// BLE 메시 네트워크를 통해 전달되는 기본 패킷 단위.
///
/// ## 이진 레이아웃 (헤더 124 bytes + 가변 payload)
///
/// ```
/// 오프셋   크기    필드
/// ──────   ────   ─────────────────────────────────────────
///  0        1     protocol_version
///  1       16     msg_id      (UUID v4)
/// 17       16     sender_id   (SHA-256(공개키) 앞 16 bytes)
/// 33       16     target_id   (수신자 node_id; 브로드캐스트=0xFF×16)
/// 49        1     msg_type    (MsgType.value)
/// 50        1     ttl         (남은 홉 수, 기본 7)
/// 51        1     hop_count   (경유 홉 수, 0에서 시작)
/// 52        8     timestamp   (Unix ms, big-endian int64)
/// 60       64     signature   (Ed25519, 64 bytes)
/// 124      var    payload     (암호화된 본문, 최대 4096 bytes)
/// ──────
/// 총       124 + payload.length bytes
/// ```
class MeshPacket {
  // ── 필드 ────────────────────────────────────────────────

  /// 패킷 프로토콜 버전. 버전이 다르면 파싱 단계에서 폐기한다.
  final int protocolVersion;

  /// 패킷 고유 ID (UUID v4, 16 bytes). 중복 감지 및 루프 방지에 사용.
  final Uint8List msgId; // 16 bytes

  /// 발신자 node_id (SHA-256(공개키) 앞 16 bytes).
  final Uint8List senderId; // 16 bytes

  /// 수신자 node_id (16 bytes). 브로드캐스트이면 [broadcast].
  final Uint8List targetId; // 16 bytes

  /// 메시지 유형.
  final MsgType msgType; // 1 byte

  /// 남은 홉 수 (기본 7). 릴레이할 때마다 1 감소. 0이 되면 폐기.
  int ttl; // 1 byte

  /// 경유 홉 수 (0에서 시작). 릴레이할 때마다 1 증가.
  int hopCount; // 1 byte

  /// 발신 Unix timestamp (밀리초). UI 표시용.
  final int timestamp; // 8 bytes (int64)

  /// Ed25519 발신자 서명 (64 bytes).
  /// 서명 대상은 [toSignableBytes] 의 반환값.
  Uint8List signature; // 64 bytes

  /// 암호화된 메시지 본문 (가변, 최대 4096 bytes).
  final Uint8List payload;

  // ── 상수 ────────────────────────────────────────────────

  /// 현재 지원하는 패킷 프로토콜 버전.
  static const int currentProtocolVersion = 2;

  /// 브로드캐스트용 target_id (0xFF × 16).
  static final Uint8List broadcast = Uint8List.fromList(List.filled(16, 0xFF));

  /// 기본 TTL.
  static const int defaultTtl = 7;

  /// 헤더 크기 (bytes). signature 포함.
  static const int headerSize = 124;

  /// payload 최대 크기 (bytes). BLE 전송 시 작은 조각으로 나눈다.
  static const int maxPayloadSize = 4096;

  // ── 오프셋 상수 ──────────────────────────────────────────
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

  // ── 생성자 ───────────────────────────────────────────────

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

  // ── 팩토리 ───────────────────────────────────────────────

  /// 새 패킷을 생성한다. [msgId]와 [timestamp]는 자동 생성.
  /// [signature]는 초기값으로 64 bytes 0으로 채워진다 (서명 전 상태).
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
      signature: Uint8List(64), // 서명 전 placeholder
      payload: payload,
    );
  }

  // ── 직렬화 ───────────────────────────────────────────────

  /// 서명 대상 바이트열을 반환한다.
  ///
  /// **ttl과 hop_count는 서명 대상에서 제외한다.**
  /// 릴레이 노드가 ttl/hop_count를 변경해도 서명이 유효하게 유지되어야 하기 때문이다.
  /// 서명 생성/검증 양쪽에서 이 메서드를 동일하게 사용한다.
  ///
  /// 레이아웃:
  /// ```
  ///  0      protocol_version
  ///  1-16   msg_id
  /// 17-32   sender_id
  /// 33-48   target_id
  /// 49      msg_type
  /// 50-57   timestamp (big-endian int64)  ← ttl/hopCount 건너뜀
  /// 58-...  payload
  /// ```
  Uint8List toSignableBytes() {
    // version(1) + msg_id(16) + sender_id(16) + target_id(16) + msg_type(1) + timestamp(8) + payload
    // ttl(1)과 hop_count(1)는 릴레이 중 변경되므로 서명 대상에서 제외
    const signableHeaderSize = 58; // 1+16+16+16+1+8
    final buf = Uint8List(signableHeaderSize + payload.length);
    final bd = ByteData.sublistView(buf);

    bd.setUint8(0, protocolVersion);
    buf.setRange(1, 17, msgId);
    buf.setRange(17, 33, senderId);
    buf.setRange(33, 49, targetId);
    bd.setUint8(49, msgType.value);
    bd.setInt64(50, timestamp, Endian.big); // ttl·hopCount 건너뜀
    buf.setRange(
      signableHeaderSize,
      signableHeaderSize + payload.length,
      payload,
    );

    return buf;
  }

  /// 전체 패킷을 바이트열로 직렬화한다 (signature 포함).
  ///
  /// 전송 직전에 호출한다. signature가 설정되어 있어야 한다.
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

  // ── 역직렬화 ─────────────────────────────────────────────

  /// 바이트열에서 [MeshPacket]을 복원한다.
  ///
  /// 파싱에 실패하면 null을 반환한다 (예외를 던지지 않음).
  /// 실패 조건:
  /// - 길이가 headerSize(124) bytes 미만
  /// - payload 길이가 maxPayloadSize(4096) bytes 초과
  /// - 지원하지 않는 protocol_version
  /// - 알 수 없는 msg_type 값
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

  // ── 유틸 ────────────────────────────────────────────────

  /// UUID v4 형식의 16 bytes msg_id를 생성한다.
  ///
  /// RFC 4122 Section 4.4 준수:
  /// - byte[6] 상위 4 bits = 0100 (version 4)
  /// - byte[8] 상위 2 bits = 10   (variant 1)
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

  /// 이 패킷이 브로드캐스트 패킷인지 확인한다.
  bool get isBroadcast {
    for (var i = 0; i < 16; i++) {
      if (targetId[i] != 0xFF) return false;
    }
    return true;
  }

  // ── 디버그 ───────────────────────────────────────────────

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
