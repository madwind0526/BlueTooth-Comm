import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/contacts/contact_service.dart';
import 'package:mesh_comm/features/identity/user_level.dart';

class ContactFileService {
  ContactFileService({DatabaseService? database, ContactService? contacts})
    : _db = database ?? DatabaseService(),
      _contacts = contacts ?? ContactService();

  final DatabaseService _db;
  final ContactService _contacts;

  Future<String> exportToJson() async {
    final contacts = await _contacts.getAllContacts();
    return exportBackupToJson(contacts: contacts, includeConversations: false);
  }

  Future<int> importFromJson(String rawJson) async {
    return importContactsFromBackupJson(rawJson);
  }

  /// 선택된 연락처 및/또는 대화를 하나의 backup JSON으로 export.
  Future<String> exportBackupToJson({
    required List<Contact> contacts,
    required bool includeConversations,
  }) async {
    final payload = <String, dynamic>{
      'format': 'mesh_comm_backup',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
    };
    if (contacts.isNotEmpty) {
      payload['contacts'] = contacts.map(_contactToJson).toList();
    }
    if (includeConversations) {
      final rows = await _db.exportAllMessagesRaw();
      payload['conversations'] = {
        'version': 1,
        'messages': rows.map(_messageRowToJson).toList(),
      };
    }
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// contacts 섹션을 import (기존 연락처에 merge, 중복 skip).
  Future<int> importContactsFromBackupJson(String rawJson) async {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid backup file.');
    }
    final contacts = decoded['contacts'];
    if (contacts is! List) {
      throw const FormatException('No contacts data found in file.');
    }
    return _importContactsList(contacts);
  }

  /// conversations 섹션을 import (기존 메시지 전부 삭제 후 교체).
  Future<int> importConversationsFromJson(String rawJson) async {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid backup file.');
    }
    final convoSection = decoded['conversations'] as Map<String, dynamic>?;
    final messages = convoSection?['messages'] as List?;
    if (messages == null) {
      throw const FormatException('No conversations data found in file.');
    }
    final rows = messages
        .whereType<Map<String, dynamic>>()
        .map(_jsonToMessageRow)
        .whereType<Map<String, dynamic>>()
        .toList();
    await _db.deleteAllMessages();
    return _db.importMessagesRaw(rows);
  }

  Future<int> _importContactsList(List<dynamic> contacts) async {
    var imported = 0;
    for (final item in contacts) {
      if (item is! Map<String, dynamic>) continue;
      final nodeId = _hexToBytes(item['nodeId'] as String?);
      final publicKey = _hexToBytes(item['publicKey'] as String?);
      if (nodeId == null || nodeId.length != 16 || publicKey == null || publicKey.length != 32) {
        continue;
      }
      final encryptionPublicKey = _hexToBytes(item['encryptionPublicKey'] as String?);
      final favorite = item['isFavorite'] as bool? ?? false;
      final trusted = item['isTrusted'] as bool? ?? false;
      final deviceType = MeshDeviceType.fromWire(item['deviceType'] as String?);
      final userLevel = _safeImportedUserLevel(item['userLevel']);
      await _db.upsertContact(
        nodeId, publicKey,
        encryptionPublicKey: encryptionPublicKey,
        displayName: _cleanText(item['displayName'] as String?),
        trusted: trusted,
        fingerprint: _cleanText(item['fingerprint'] as String?),
        favorite: favorite,
        groupName: _cleanText(item['groupName'] as String?),
        deviceType: deviceType.wireName,
        avatarKey: _cleanText(item['avatarKey'] as String?),
        savedContact: true,
        userLevel: userLevel.wireName,
      );
      imported++;
    }
    await _contacts.refresh();
    return imported;
  }

  Map<String, dynamic> _messageRowToJson(Map<String, dynamic> row) {
    return {
      'msgId': _blobToHex(row['msg_id']),
      'senderId': _blobToHex(row['sender_id']),
      'targetId': _blobToHex(row['target_id']),
      'msgType': row['msg_type'] as int? ?? 0,
      'timestamp': row['timestamp'] as int? ?? 0,
      'payload': row['payload'] == null
          ? null
          : base64Encode(row['payload'] as Uint8List),
      'isOutgoing': (row['is_outgoing'] as int? ?? 0) == 1,
      'expiresAt': row['expires_at'] as int?,
    };
  }

  Map<String, dynamic>? _jsonToMessageRow(Map<String, dynamic> json) {
    final msgId = _hexToBytes(json['msgId'] as String?);
    final senderId = _hexToBytes(json['senderId'] as String?);
    final targetId = _hexToBytes(json['targetId'] as String?);
    if (msgId == null || senderId == null || targetId == null) return null;
    Uint8List? payload;
    final payloadStr = json['payload'] as String?;
    if (payloadStr != null) {
      try { payload = base64Decode(payloadStr); } catch (_) {}
    }
    return {
      'msg_id': msgId,
      'sender_id': senderId,
      'target_id': targetId,
      'msg_type': json['msgType'] as int? ?? 0,
      'timestamp': json['timestamp'] as int? ?? 0,
      'payload': payload,
      'is_outgoing': (json['isOutgoing'] as bool? ?? false) ? 1 : 0,
      'is_read': 0,
      'expires_at': json['expiresAt'] as int?,
    };
  }

  String _blobToHex(dynamic blob) {
    if (blob is Uint8List) return _bytesToHex(blob);
    return '';
  }

  Map<String, dynamic> _contactToJson(Contact contact) {
    return {
      'nodeId': _bytesToHex(contact.nodeId),
      'publicKey': _bytesToHex(contact.publicKey),
      'encryptionPublicKey': contact.encryptionPublicKey == null
          ? null
          : _bytesToHex(contact.encryptionPublicKey!),
      'displayName': contact.displayName,
      'isTrusted': contact.isTrusted,
      'fingerprint': contact.fingerprint,
      'isFavorite': contact.isFavorite,
      'groupName': contact.groupName,
      'deviceType': contact.deviceType.wireName,
      'avatarKey': contact.avatarKey,
      'userLevel': contact.userLevel.wireName,
    };
  }

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List? _hexToBytes(String? hex) {
    if (hex == null || hex.length.isOdd) return null;
    try {
      return Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    } catch (_) {
      return null;
    }
  }

  String? _cleanText(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  UserLevel _safeImportedUserLevel(Object? value) {
    final level = UserLevel.fromWire(value is String ? value : null);
    return level == UserLevel.server ? UserLevel.server : UserLevel.user;
  }
}
