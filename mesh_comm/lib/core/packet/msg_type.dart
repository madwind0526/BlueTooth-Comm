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
  pong(0x06),

  /// SCAN topology request. Receivers respond with their 1-hop view.
  topologyRequest(0x07),

  /// SCAN topology response containing one node's direct neighbor summary.
  topologyResponse(0x08),

  /// 파일/이미지 전송 시작 메타데이터 (이름·크기·청크 수·전송 ID).
  fileHeader(0x09),

  /// 파일/이미지 청크 데이터 (전송 ID + 청크 인덱스 + 바이너리).
  fileChunk(0x0A),

  /// 파일/이미지 청크 수신 확인 (전송 ID + 청크 인덱스 + 성공 여부).
  fileAck(0x0B),

  /// 파일 전송 취소 (전송 ID). 송신·수신 양쪽 모두 보낼 수 있다.
  fileCancel(0x0C),

  /// 그룹 채팅 초대 (inviter → target)
  groupInvite(0x0D),

  /// 그룹 초대 응답 (target → inviter): accept/reject
  groupInviteResp(0x0E),

  /// 그룹 메시지 (sender → each member individually)
  groupMessage(0x0F),

  /// 그룹 멤버 변경 공지 (leader → all members): add/remove/leader_change
  groupMemberUpdate(0x10),

  /// 그룹 나가기 (member → all members)
  groupLeave(0x11);

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
