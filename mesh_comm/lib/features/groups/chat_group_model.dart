import 'dart:typed_data';

class ChatGroup {
  final String groupId;
  final String name;
  final Uint8List leaderId;
  final List<GroupMember> members;
  final int createdAt;
  final int unreadCount;

  const ChatGroup({
    required this.groupId,
    required this.name,
    required this.leaderId,
    required this.members,
    required this.createdAt,
    this.unreadCount = 0,
  });

  int get memberCount => members.length;
  bool get isFull => memberCount >= 10;

  String get leaderHex =>
      leaderId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool isLeader(Uint8List nodeId) {
    if (nodeId.length != leaderId.length) return false;
    for (var i = 0; i < leaderId.length; i++) {
      if (leaderId[i] != nodeId[i]) return false;
    }
    return true;
  }

  bool hasMember(Uint8List nodeId) {
    return members.any((m) => _bytesEqual(m.nodeId, nodeId));
  }

  ChatGroup copyWith({
    String? name,
    Uint8List? leaderId,
    List<GroupMember>? members,
    int? unreadCount,
  }) {
    return ChatGroup(
      groupId: groupId,
      name: name ?? this.name,
      leaderId: leaderId ?? this.leaderId,
      members: members ?? this.members,
      createdAt: createdAt,
      unreadCount: unreadCount ?? this.unreadCount,
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

class GroupMember {
  final Uint8List nodeId;
  final int joinedAt;
  final int msgCount;

  const GroupMember({
    required this.nodeId,
    required this.joinedAt,
    this.msgCount = 0,
  });

  String get nodeIdHex =>
      nodeId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class GroupMessage {
  final Uint8List msgId;
  final String groupId;
  final Uint8List senderId;
  final int msgType;
  final String text;
  final int timestamp;
  final bool isRead;
  final bool isOutgoing;
  final bool isFile;
  final bool isImage;

  const GroupMessage({
    required this.msgId,
    required this.groupId,
    required this.senderId,
    required this.msgType,
    required this.text,
    required this.timestamp,
    this.isRead = false,
    this.isOutgoing = false,
    this.isFile = false,
    this.isImage = false,
  });

  String get senderHex =>
      senderId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class GroupInvite {
  final String groupId;
  final String groupName;
  final Uint8List leaderId;
  final List<Uint8List> memberIds;
  final Uint8List fromNodeId;

  const GroupInvite({
    required this.groupId,
    required this.groupName,
    required this.leaderId,
    required this.memberIds,
    required this.fromNodeId,
  });
}
