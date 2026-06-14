// lib/core/packet/msg_type.dart

/// MeshPacket message type enum.
///
/// Serialized as 1 byte (0x01 ~ 0x06).
/// [MsgType.fromValue] throws FormatException for unknown values.
enum MsgType {
  /// Plain text message (E2E encrypted payload)
  text(0x01),

  /// Public key broadcast announcement (on app start + re-sent every 5 minutes, signature required)
  keyAnnounce(0x02),

  /// Admin-signed notice (Phase 3)
  adminNotice(0x03),

  /// Delivery acknowledgment (Phase 2, planned)
  ack(0x04),

  /// Heartbeat request (every 30 seconds)
  ping(0x05),

  /// Heartbeat response
  pong(0x06),

  /// SCAN topology request. Receivers respond with their 1-hop view.
  topologyRequest(0x07),

  /// SCAN topology response containing one node's direct neighbor summary.
  topologyResponse(0x08),

  /// File/image transfer start metadata (name, size, chunk count, transfer ID).
  fileHeader(0x09),

  /// File/image chunk data (transfer ID + chunk index + binary).
  fileChunk(0x0A),

  /// File/image chunk acknowledgment (transfer ID + chunk index + success flag).
  fileAck(0x0B),

  /// File transfer cancellation (transfer ID). Can be sent by either sender or receiver.
  fileCancel(0x0C),

  /// Group chat invitation (inviter → target)
  groupInvite(0x0D),

  /// Group invitation response (target → inviter): accept/reject
  groupInviteResp(0x0E),

  /// Group message (sender → each member individually)
  groupMessage(0x0F),

  /// Group member change announcement (leader → all members): add/remove/leader_change
  groupMemberUpdate(0x10),

  /// Leave group (member → all members)
  groupLeave(0x11),

  /// File receipt confirmation (receiver → original sender): tid + groupId
  fileReceipt(0x12);

  final int value;
  const MsgType(this.value);

  /// Returns the [MsgType] for value [v].
  ///
  /// Throws [FormatException] for undefined values.
  static MsgType fromValue(int v) {
    for (final type in MsgType.values) {
      if (type.value == v) return type;
    }
    throw FormatException(
      'Unknown MsgType value: 0x${v.toRadixString(16).padLeft(2, '0')}',
    );
  }
}
