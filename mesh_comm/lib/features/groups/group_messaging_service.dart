import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:mesh_comm/core/packet/mesh_packet.dart';
import 'package:mesh_comm/core/packet/msg_type.dart';
import 'package:mesh_comm/features/groups/chat_group_model.dart';
import 'package:mesh_comm/features/groups/group_service.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';

/// 그룹 채팅 패킷 프로토콜 서비스 (싱글톤).
/// MessagingService가 수신한 그룹 패킷을 여기로 위임한다.
/// 그룹 패킷 전송은 MessagingService.sendGroupControlPacket()을 호출한다.
class GroupMessagingService {
  static final GroupMessagingService _instance =
      GroupMessagingService._internal();
  factory GroupMessagingService() => _instance;
  GroupMessagingService._internal();

  final _groupService = GroupService();

  // ── Streams ───────────────────────────────────────────────────────────────

  final _inviteController =
      StreamController<GroupInvite>.broadcast();
  final _messageController =
      StreamController<GroupMessage>.broadcast();
  final _updateController =
      StreamController<ChatGroup>.broadcast();

  /// 수신된 그룹 초대
  Stream<GroupInvite> get inviteStream => _inviteController.stream;

  /// 수신된 그룹 메시지
  Stream<GroupMessage> get messageStream => _messageController.stream;

  /// 그룹 멤버/상태 변경 (가입/탈퇴/방장 변경)
  Stream<ChatGroup> get updateStream => _updateController.stream;

  // ── Packet sending (delegated to MessagingService) ────────────────────────

  /// MessagingService.sendGroupControlPacket에 대한 함수 주입.
  /// main.dart 또는 MessagingService.init()에서 설정된다.
  Future<bool> Function(
    Uint8List targetNodeId,
    MsgType type,
    String jsonPayload,
  )? _sendFn;

  void setSendFunction(
    Future<bool> Function(Uint8List, MsgType, String) fn,
  ) {
    _sendFn = fn;
  }

  Future<bool> _send(
    Uint8List targetNodeId,
    MsgType type,
    Map<String, dynamic> payload,
  ) async {
    final fn = _sendFn;
    if (fn == null) return false;
    try {
      return await fn(targetNodeId, type, jsonEncode(payload));
    } catch (e) {
      debugPrint('[GroupMsg] _send error: $e');
      return false;
    }
  }

  // ── Outgoing actions ──────────────────────────────────────────────────────

  /// 특정 연락처에게 그룹 초대를 전송한다.
  Future<bool> sendInvite({
    required ChatGroup group,
    required Uint8List targetNodeId,
  }) async {
    return _send(targetNodeId, MsgType.groupInvite, {
      'gid': group.groupId,
      'name': group.name,
      'lid': group.leaderHex,
      'members': group.members.map((m) => m.nodeIdHex).toList(),
    });
  }

  /// 초대 응답 전송 (accept=true: 수락, false: 거절).
  Future<bool> sendInviteResponse({
    required String groupId,
    required Uint8List toNodeId,
    required bool accepted,
  }) async {
    return _send(toNodeId, MsgType.groupInviteResp, {
      'gid': groupId,
      'ok': accepted,
    });
  }

  /// 그룹 메시지를 모든 멤버에게 전송한다.
  /// 직접 연결 여부 무관: relay가 비연결 멤버까지 전달한다.
  Future<int> sendGroupMessage({
    required ChatGroup group,
    required String text,
    String? filePrefix, // '__FILE__' or '__IMAGE__'
  }) async {
    final myNodeId = IdentityService().myNodeId;
    final myHex = _hex(myNodeId);
    final payload = filePrefix != null ? '$filePrefix$text' : text;
    var sent = 0;
    for (final member in group.members) {
      if (member.nodeIdHex == myHex) continue;
      // 직접 연결 체크 제거: broadcast + relay로 비연결 멤버에도 전달
      final ok = await _send(member.nodeId, MsgType.groupMessage, {
        'gid': group.groupId,
        'sid': myHex,
        'text': payload,
      });
      if (ok) sent++;
    }

    // 로컬 저장 (발신 메시지는 전달 성공 여부와 관계없이 항상 저장)
    final msgId = MeshPacket.generateMsgId();
    await _groupService.saveMessage(
      msgId: msgId,
      groupId: group.groupId,
      senderId: myNodeId,
      msgType: MsgType.groupMessage.value,
      payload: payload,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isOutgoing: true,
    );
    return sent;
  }

  /// 멤버 추가/제거/방장 변경 공지를 모든 멤버에게 전송 (relay로 비연결 멤버도 수신).
  Future<void> broadcastMemberUpdate({
    required ChatGroup group,
    required String action, // 'add' | 'remove' | 'leader'
    required Uint8List targetNodeId,
    Uint8List? newLeaderId,
  }) async {
    final myHex = _hex(IdentityService().myNodeId);
    final payload = {
      'gid': group.groupId,
      'act': action,
      'tid': _hex(targetNodeId),
      if (newLeaderId != null) 'nlid': _hex(newLeaderId),
    };
    for (final member in group.members) {
      if (member.nodeIdHex == myHex) continue;
      await _send(member.nodeId, MsgType.groupMemberUpdate, payload);
    }
  }

  /// 그룹 나가기 패킷을 모든 멤버에게 전송 (relay로 비연결 멤버도 수신).
  Future<void> broadcastLeave({
    required ChatGroup group,
    Uint8List? newLeaderId,
  }) async {
    final myHex = _hex(IdentityService().myNodeId);
    final payload = {
      'gid': group.groupId,
      if (newLeaderId != null) 'nlid': _hex(newLeaderId),
    };
    for (final member in group.members) {
      if (member.nodeIdHex == myHex) continue;
      await _send(member.nodeId, MsgType.groupLeave, payload);
    }
  }

  // ── Incoming packet handler ───────────────────────────────────────────────

  Future<void> handleIncomingPacket(
    MeshPacket packet,
    Uint8List senderNodeId,
    String decryptedPayload,
  ) async {
    try {
      final json = jsonDecode(decryptedPayload) as Map<String, dynamic>;
      switch (packet.msgType) {
        case MsgType.groupInvite:
          await _handleInvite(json, senderNodeId);
        case MsgType.groupInviteResp:
          await _handleInviteResp(json, senderNodeId);
        case MsgType.groupMessage:
          await _handleGroupMessage(json, senderNodeId, packet);
        case MsgType.groupMemberUpdate:
          await _handleMemberUpdate(json);
        case MsgType.groupLeave:
          await _handleLeave(json, senderNodeId);
        default:
          break;
      }
    } catch (e) {
      debugPrint('[GroupMsg] handleIncomingPacket error: $e');
    }
  }

  Future<void> _handleInvite(
    Map<String, dynamic> json,
    Uint8List senderNodeId,
  ) async {
    final groupId = json['gid'] as String;
    final groupName = json['name'] as String;
    final leaderHex = json['lid'] as String;
    final memberHexList = (json['members'] as List).cast<String>();

    final leaderId = _fromHex(leaderHex);
    final memberIds = memberHexList.map(_fromHex).toList();

    final invite = GroupInvite(
      groupId: groupId,
      groupName: groupName,
      leaderId: leaderId,
      memberIds: memberIds,
      fromNodeId: senderNodeId,
    );
    _inviteController.add(invite);
  }

  Future<void> _handleInviteResp(
    Map<String, dynamic> json,
    Uint8List senderNodeId,
  ) async {
    final groupId = json['gid'] as String;
    final accepted = json['ok'] as bool;
    if (!accepted) return;

    final group = await _groupService.getGroup(groupId);
    if (group == null) return;

    // 신규 멤버 DB 추가
    await _groupService.addMember(groupId, senderNodeId);

    // 기존 멤버들에게 신규 멤버 가입 공지 (relay 통해 비연결 멤버도 수신)
    final myHex = _hex(IdentityService().myNodeId);
    final newMemberHex = _hex(senderNodeId);
    final updatePayload = {
      'gid': groupId,
      'act': 'add',
      'tid': newMemberHex,
    };
    for (final member in group.members) {
      if (member.nodeIdHex == myHex) continue;
      if (member.nodeIdHex == newMemberHex) continue; // 본인에게는 불필요
      await _send(member.nodeId, MsgType.groupMemberUpdate, updatePayload);
    }

    final updated = await _groupService.getGroup(groupId);
    if (updated != null) _updateController.add(updated);
  }

  Future<void> _handleGroupMessage(
    Map<String, dynamic> json,
    Uint8List senderNodeId,
    MeshPacket packet,
  ) async {
    final groupId = json['gid'] as String;
    final text = json['text'] as String? ?? '';

    final group = await _groupService.getGroup(groupId);
    if (group == null) return;

    await _groupService.saveMessage(
      msgId: packet.msgId,
      groupId: groupId,
      senderId: senderNodeId,
      msgType: MsgType.groupMessage.value,
      payload: text,
      timestamp: packet.timestamp,
      isOutgoing: false,
    );

    final msg = GroupMessage(
      msgId: packet.msgId,
      groupId: groupId,
      senderId: senderNodeId,
      msgType: MsgType.groupMessage.value,
      text: text,
      timestamp: packet.timestamp,
      isOutgoing: false,
      isFile: text.startsWith('__FILE__'),
      isImage: text.startsWith('__IMAGE__'),
    );
    _messageController.add(msg);
  }

  Future<void> _handleMemberUpdate(Map<String, dynamic> json) async {
    final groupId = json['gid'] as String;
    final action = json['act'] as String;
    final targetHex = json['tid'] as String;
    final targetId = _fromHex(targetHex);

    final group = await _groupService.getGroup(groupId);
    if (group == null) return;

    switch (action) {
      case 'add':
        await _groupService.addMember(groupId, targetId);
      case 'remove':
        await _groupService.removeMember(groupId, targetId);
      case 'leader':
        await _groupService.setLeader(groupId, targetId);
    }

    final updated = await _groupService.getGroup(groupId);
    if (updated != null) _updateController.add(updated);
  }

  Future<void> _handleLeave(
    Map<String, dynamic> json,
    Uint8List senderNodeId,
  ) async {
    final groupId = json['gid'] as String;
    await _groupService.removeMember(groupId, senderNodeId);

    if (json.containsKey('nlid')) {
      final newLeaderId = _fromHex(json['nlid'] as String);
      await _groupService.setLeader(groupId, newLeaderId);
    }

    final updated = await _groupService.getGroup(groupId);
    if (updated != null) _updateController.add(updated);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  void dispose() {
    _inviteController.close();
    _messageController.close();
    _updateController.close();
  }
}
