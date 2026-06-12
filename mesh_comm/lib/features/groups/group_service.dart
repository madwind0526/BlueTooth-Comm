import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/groups/chat_group_model.dart';

class GroupService {
  static final GroupService _instance = GroupService._internal();
  factory GroupService() => _instance;
  GroupService._internal();

  final _db = DatabaseService();

  // ── UUID 생성 ─────────────────────────────────────────────────────────────

  static String generateGroupId() {
    final rng = Random.secure();
    final bytes = List.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  // ── Group CRUD ────────────────────────────────────────────────────────────

  Future<ChatGroup> createGroup({
    required String name,
    required Uint8List myNodeId,
  }) async {
    final groupId = generateGroupId();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertChatGroup(
      groupId: groupId,
      name: name,
      leaderId: myNodeId,
      createdAt: now,
    );
    await _db.upsertGroupMember(
      groupId: groupId,
      nodeId: myNodeId,
      joinedAt: now,
    );
    return ChatGroup(
      groupId: groupId,
      name: name,
      leaderId: myNodeId,
      members: [GroupMember(nodeId: myNodeId, joinedAt: now)],
      createdAt: now,
    );
  }

  Future<ChatGroup?> getGroup(String groupId) async {
    final row = await _db.getChatGroup(groupId);
    if (row == null) return null;
    final memberRows = await _db.getGroupMembers(groupId);
    final unread = await _db.getGroupUnreadCount(groupId);
    return _rowToGroup(row, memberRows, unread);
  }

  Future<List<ChatGroup>> getAllGroups() async {
    final rows = await _db.getAllChatGroups();
    final groups = <ChatGroup>[];
    for (final row in rows) {
      final gid = row['group_id'] as String;
      final memberRows = await _db.getGroupMembers(gid);
      final unread = await _db.getGroupUnreadCount(gid);
      groups.add(_rowToGroup(row, memberRows, unread));
    }
    return groups;
  }

  // ── Backup / Restore ──────────────────────────────────────────────────────

  /// 모든 그룹을 JSON 문자열로 직렬화한다.
  Future<String> exportAllGroupsToJson() async {
    final groups = await getAllGroups();
    return jsonEncode({
      'version': 1,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'groups': groups
          .map((g) => {
                'groupId': g.groupId,
                'name': g.name,
                'leaderHex': g.leaderHex,
                'members': g.members.map((m) => m.nodeIdHex).toList(),
                'createdAt': g.createdAt,
              })
          .toList(),
    });
  }

  /// JSON 문자열에서 그룹을 복원한다. 반환값: 복원된 그룹 수.
  Future<int> importGroupsFromJson(String jsonStr) async {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final list = (data['groups'] as List).cast<Map<String, dynamic>>();
    var count = 0;
    for (final g in list) {
      final gid = g['groupId'] as String;
      if (await _db.getChatGroup(gid) != null) continue; // 이미 존재하면 스킵
      final leaderHex = g['leaderHex'] as String;
      final leaderId = _fromHex(leaderHex);
      final createdAt = g['createdAt'] as int;
      await _db.upsertChatGroup(
        groupId: gid,
        name: g['name'] as String,
        leaderId: leaderId,
        createdAt: createdAt,
      );
      for (final hex in (g['members'] as List).cast<String>()) {
        await _db.upsertGroupMember(
          groupId: gid,
          nodeId: _fromHex(hex),
          joinedAt: createdAt,
        );
      }
      count++;
    }
    return count;
  }

  static Uint8List _fromHex(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  Future<void> deleteGroup(String groupId) async {
    await _db.deleteChatGroup(groupId);
  }

  Future<void> renameGroup(String groupId, String name) async {
    await _db.updateChatGroupName(groupId, name);
  }

  Future<void> setLeader(String groupId, Uint8List leaderId) async {
    await _db.updateChatGroupLeader(groupId, leaderId);
  }

  // ── Member management ─────────────────────────────────────────────────────

  Future<void> addMember(String groupId, Uint8List nodeId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertGroupMember(
      groupId: groupId,
      nodeId: nodeId,
      joinedAt: now,
    );
  }

  Future<void> removeMember(String groupId, Uint8List nodeId) async {
    await _db.removeGroupMember(groupId, nodeId);
  }

  /// 방장 나갈 때 후임 방장 결정: msgCount 많은 순, 동률이면 joinedAt 빠른 순.
  Future<Uint8List?> getNextLeader(
    String groupId,
    Uint8List excludeNodeId,
  ) async {
    final members = await _db.getGroupMembers(groupId);
    final candidates = members
        .where((m) => !_bytesEqual(m['node_id'] as Uint8List, excludeNodeId))
        .toList();
    if (candidates.isEmpty) return null;
    return candidates.first['node_id'] as Uint8List;
  }

  Future<void> incrementMsgCount(String groupId, Uint8List nodeId) async {
    await _db.incrementGroupMemberMsgCount(groupId, nodeId);
  }

  // ── Message storage ──────────────────────────────────────────────────────

  Future<void> saveMessage({
    required Uint8List msgId,
    required String groupId,
    required Uint8List senderId,
    required int msgType,
    required String payload,
    required int timestamp,
    bool isOutgoing = false,
    int? expiresAt,
  }) async {
    await _db.saveGroupMessage(
      msgId: msgId,
      groupId: groupId,
      senderId: senderId,
      msgType: msgType,
      payload: payload,
      timestamp: timestamp,
      isOutgoing: isOutgoing,
      expiresAt: expiresAt,
    );
    if (!isOutgoing) {
      await _db.incrementGroupMemberMsgCount(groupId, senderId);
    }
  }

  Future<List<GroupMessage>> getMessages(
    String groupId, {
    int limit = 100,
  }) async {
    final rows = await _db.getGroupMessages(groupId, limit: limit);
    return rows.map(_rowToMessage).toList();
  }

  Future<void> markMessagesRead(String groupId) async {
    await _db.markGroupMessagesRead(groupId);
  }

  // ── Receive group invite/update ──────────────────────────────────────────

  /// 수락된 초대: 그룹 생성 + 멤버 전체 추가
  Future<ChatGroup> acceptInvite(GroupInvite invite) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertChatGroup(
      groupId: invite.groupId,
      name: invite.groupName,
      leaderId: invite.leaderId,
      createdAt: now,
    );
    for (final memberId in invite.memberIds) {
      await _db.upsertGroupMember(
        groupId: invite.groupId,
        nodeId: memberId,
        joinedAt: now,
      );
    }
    final memberRows = await _db.getGroupMembers(invite.groupId);
    return _rowToGroup(
      {
        'group_id': invite.groupId,
        'name': invite.groupName,
        'leader_id': invite.leaderId,
        'created_at': now,
      },
      memberRows,
      0,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  ChatGroup _rowToGroup(
    Map<String, dynamic> row,
    List<Map<String, dynamic>> memberRows,
    int unread,
  ) {
    return ChatGroup(
      groupId: row['group_id'] as String,
      name: row['name'] as String,
      leaderId: row['leader_id'] as Uint8List,
      members: memberRows.map((m) => GroupMember(
            nodeId: m['node_id'] as Uint8List,
            joinedAt: m['joined_at'] as int,
            msgCount: m['msg_count'] as int? ?? 0,
          )).toList(),
      createdAt: row['created_at'] as int,
      unreadCount: unread,
    );
  }

  GroupMessage _rowToMessage(Map<String, dynamic> row) {
    final payload = row['payload'] as String? ?? '';
    final msgType = row['msg_type'] as int;
    return GroupMessage(
      msgId: row['msg_id'] as Uint8List,
      groupId: row['group_id'] as String,
      senderId: row['sender_id'] as Uint8List,
      msgType: msgType,
      text: payload,
      timestamp: row['timestamp'] as int,
      isRead: (row['is_read'] as int? ?? 0) == 1,
      isOutgoing: (row['is_outgoing'] as int? ?? 0) == 1,
      isFile: msgType == 0x0F && payload.startsWith('__FILE__'),
      isImage: msgType == 0x0F && payload.startsWith('__IMAGE__'),
    );
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
