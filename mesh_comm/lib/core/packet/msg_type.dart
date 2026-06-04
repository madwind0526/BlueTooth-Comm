// lib/core/packet/msg_type.dart

/// MeshPacket 메시지 유형 열거형.
///
/// 1 byte (0x01 ~ 0x06) 로 직렬화된다.
/// 알 수 없는 값은 [MsgType.fromValue]가 FormatException을 던진다.
enum MsgType {
  /// 일반 텍스트 메시지 (E2E 암호화 payload)
  text(0x01),

  /// 공개키 브로드캐스트 공지 (앱 시작 + 5분 주기 재전송, 서명 필수)
  keyAnnounce(0x02),

  /// 관리자 서명 공지 (Phase 3)
  adminNotice(0x03),

  /// 수신 확인 (Phase 2 구현 예정)
  ack(0x04),

  /// Heartbeat 요청 (30초 주기)
  ping(0x05),

  /// Heartbeat 응답
  pong(0x06);

  final int value;
  const MsgType(this.value);

  /// [v]에 해당하는 [MsgType]을 반환한다.
  ///
  /// 정의되지 않은 값이면 [FormatException]을 던진다.
  static MsgType fromValue(int v) {
    for (final type in MsgType.values) {
      if (type.value == v) return type;
    }
    throw FormatException(
      'Unknown MsgType value: 0x${v.toRadixString(16).padLeft(2, '0')}',
    );
  }
}
