// lib/core/storage/database_service.dart

import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Singleton service managing all local SQLite persistence.
///
/// Tables:
///   identity      — 자신의 Ed25519 키쌍 (항상 1행)
///   contacts      — 상대방 공개키 + TOFU 신뢰 상태
///   messages      — 수신/발신 메시지 (복호화된 payload)
///   seen_messages — msg_id 캐시 (R-09: 중복·루프 방지, 30분 보존)
class DatabaseService {
  // ── 싱글톤 ──────────────────────────────────────────────────────────────
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  static const String _dbFileName = 'mesh_comm.db';
  static const int _dbVersion = 11;

  Database? _db;

  // seen_messages 보존 기간: 30분 (ms)
  static const int _seenMessageTtlMs = 30 * 60 * 1000;

  // ── 초기화 ───────────────────────────────────────────────────────────────

  /// DB 파일을 열고 테이블을 생성한다.
  /// 앱 시작 시 1회 호출할 것.
  Future<void> init() async {
    if (_db != null) return;

    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, _dbFileName);

    _db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Database get _database {
    assert(_db != null, 'DatabaseService.init() 를 먼저 호출하세요.');
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE identity (
        id          INTEGER PRIMARY KEY,
        node_id     BLOB    NOT NULL,
        public_key  BLOB    NOT NULL,
        private_key BLOB    NOT NULL,
        encryption_public_key  BLOB,
        encryption_private_key BLOB
      )
    ''');

    await db.execute('''
      CREATE TABLE contacts (
        node_id      BLOB    PRIMARY KEY,
        public_key   BLOB    NOT NULL,
        encryption_public_key BLOB,
        display_name TEXT,
        is_trusted   INTEGER NOT NULL DEFAULT 0,
        fingerprint  TEXT,
        first_seen   INTEGER,
        last_seen    INTEGER,
        is_favorite  INTEGER NOT NULL DEFAULT 0,
        group_name   TEXT,
        device_type  TEXT NOT NULL DEFAULT 'unknown',
        avatar_key   TEXT,
        remote_display_name TEXT,
        remote_avatar_key   TEXT,
        is_saved     INTEGER NOT NULL DEFAULT 1,
        user_level   TEXT NOT NULL DEFAULT 'user'
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        msg_id      BLOB    NOT NULL UNIQUE,
        sender_id   BLOB    NOT NULL,
        target_id   BLOB    NOT NULL,
        msg_type    INTEGER NOT NULL,
        timestamp   INTEGER NOT NULL,
        payload     BLOB,
        is_outgoing INTEGER NOT NULL DEFAULT 0,
        is_read     INTEGER NOT NULL DEFAULT 0,
        expires_at  INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE seen_messages (
        msg_id  BLOB    PRIMARY KEY,
        seen_at INTEGER NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_messages_expires_at ON messages (expires_at)',
    );

    await db.execute(
      'CREATE INDEX idx_seen_messages_seen_at ON seen_messages (seen_at)',
    );

    await db.execute('''
      CREATE TABLE chat_groups (
        group_id   TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        leader_id  BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE group_members (
        group_id   TEXT NOT NULL,
        node_id    BLOB NOT NULL,
        joined_at  INTEGER NOT NULL,
        msg_count  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (group_id, node_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE group_messages (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        msg_id      BLOB NOT NULL UNIQUE,
        group_id    TEXT NOT NULL,
        sender_id   BLOB NOT NULL,
        msg_type    INTEGER NOT NULL,
        payload     TEXT,
        timestamp   INTEGER NOT NULL,
        is_read     INTEGER NOT NULL DEFAULT 0,
        is_outgoing INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_group_messages_group ON group_messages (group_id, timestamp)',
    );

    await db.execute('''
      CREATE TABLE notices (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        sender_name TEXT    NOT NULL,
        text        TEXT    NOT NULL,
        timestamp   INTEGER NOT NULL,
        is_long     INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE contacts ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE contacts ADD COLUMN group_name TEXT');
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE identity ADD COLUMN encryption_public_key BLOB',
      );
      await db.execute(
        'ALTER TABLE identity ADD COLUMN encryption_private_key BLOB',
      );
      await db.execute(
        'ALTER TABLE contacts ADD COLUMN encryption_public_key BLOB',
      );
    }
    if (oldVersion < 4) {
      await db.execute(
        "ALTER TABLE contacts ADD COLUMN device_type TEXT NOT NULL DEFAULT 'unknown'",
      );
      await db.execute('ALTER TABLE contacts ADD COLUMN avatar_key TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE messages ADD COLUMN expires_at INTEGER');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_expires_at ON messages (expires_at)',
      );
    }
    if (oldVersion < 6) {
      await db.execute(
        'ALTER TABLE contacts ADD COLUMN remote_display_name TEXT',
      );
      await db.execute(
        'ALTER TABLE contacts ADD COLUMN remote_avatar_key TEXT',
      );
    }
    if (oldVersion < 7) {
      await db.execute(
        'ALTER TABLE contacts ADD COLUMN is_saved INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 8) {
      await db.execute(
        "ALTER TABLE contacts ADD COLUMN user_level TEXT NOT NULL DEFAULT 'user'",
      );
    }
    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS notices (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          sender_name TEXT    NOT NULL,
          text        TEXT    NOT NULL,
          timestamp   INTEGER NOT NULL,
          is_long     INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 11) {
      await db.execute(
        'ALTER TABLE group_messages ADD COLUMN expires_at INTEGER',
      );
    }
    if (oldVersion < 10) {
      // 기존 로컬 그룹 태그 초기화 (새 ChatGroup 시스템으로 교체)
      await db.execute("UPDATE contacts SET group_name = NULL");

      await db.execute('''
        CREATE TABLE IF NOT EXISTS chat_groups (
          group_id   TEXT PRIMARY KEY,
          name       TEXT NOT NULL,
          leader_id  BLOB NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS group_members (
          group_id   TEXT NOT NULL,
          node_id    BLOB NOT NULL,
          joined_at  INTEGER NOT NULL,
          msg_count  INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (group_id, node_id)
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS group_messages (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          msg_id      BLOB NOT NULL UNIQUE,
          group_id    TEXT NOT NULL,
          sender_id   BLOB NOT NULL,
          msg_type    INTEGER NOT NULL,
          payload     TEXT,
          timestamp   INTEGER NOT NULL,
          is_read     INTEGER NOT NULL DEFAULT 0,
          is_outgoing INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_group_messages_group ON group_messages (group_id, timestamp)',
      );
    }
  }

  // ── Identity ─────────────────────────────────────────────────────────────

  /// 자신의 키쌍을 저장한다 (기존 행을 교체).
  ///
  /// [privateKey] 는 암호화된 상태로 전달되어야 한다 (crypto 레이어 책임).
  Future<void> saveIdentity(
    Uint8List nodeId,
    Uint8List publicKey,
    Uint8List privateKey,
    Uint8List encryptionPublicKey,
    Uint8List encryptionPrivateKey,
  ) async {
    await _database.insert('identity', {
      'id': 1,
      'node_id': nodeId,
      'public_key': publicKey,
      'private_key': privateKey,
      'encryption_public_key': encryptionPublicKey,
      'encryption_private_key': encryptionPrivateKey,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 기존 신원에 X25519 메시지 암호화 키쌍을 추가한다.
  Future<void> updateIdentityEncryptionKeys(
    Uint8List encryptionPublicKey,
    Uint8List encryptionPrivateKey,
  ) async {
    await _database.update('identity', {
      'encryption_public_key': encryptionPublicKey,
      'encryption_private_key': encryptionPrivateKey,
    }, where: 'id = 1');
  }

  /// DB의 개인키 seed를 0으로 덮어쓴다 (secure storage 마이그레이션 후 호출).
  Future<void> clearPrivateKeys() async {
    final zeros32 = Uint8List(32);
    await _database.update('identity', {
      'private_key': zeros32,
      'encryption_private_key': zeros32,
    }, where: 'id = 1');
  }

  /// 저장된 자신의 키쌍을 반환한다. 없으면 null.
  Future<Map<String, dynamic>?> getIdentity() async {
    final rows = await _database.query('identity', where: 'id = 1');
    if (rows.isEmpty) return null;
    return _blobRow(rows.first);
  }

  // ── Contacts ─────────────────────────────────────────────────────────────

  /// 연락처를 삽입하거나 갱신한다.
  ///
  /// [trusted] = true 이면 is_trusted = 1 (핑거프린트 직접 확인 후).
  /// [displayName], [fingerprint] 는 선택 항목.
  Future<void> upsertContact(
    Uint8List nodeId,
    Uint8List publicKey, {
    Uint8List? encryptionPublicKey,
    String? displayName,
    bool trusted = false,
    String? fingerprint,
    bool? favorite,
    String? groupName,
    String? deviceType,
    String? avatarKey,
    String? remoteDisplayName,
    String? remoteAvatarKey,
    bool? savedContact,
    String? userLevel,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // 기존 연락처가 있으면 first_seen 을 보존하고 나머지를 갱신
    final existing = await getContact(nodeId);

    await _database.insert('contacts', {
      'node_id': nodeId,
      'public_key': publicKey,
      'encryption_public_key':
          encryptionPublicKey ?? existing?['encryption_public_key'],
      'display_name': displayName ?? existing?['display_name'],
      'is_trusted': trusted ? 1 : 0,
      'fingerprint': fingerprint,
      'first_seen': existing?['first_seen'] ?? nowMs,
      'last_seen': nowMs,
      'is_favorite':
          (favorite ?? ((existing?['is_favorite'] as int? ?? 0) == 1)) ? 1 : 0,
      'group_name': groupName ?? existing?['group_name'],
      'device_type': deviceType ?? existing?['device_type'] ?? 'unknown',
      'avatar_key': avatarKey ?? existing?['avatar_key'],
      'remote_display_name':
          remoteDisplayName ?? existing?['remote_display_name'],
      'remote_avatar_key': remoteAvatarKey ?? existing?['remote_avatar_key'],
      'is_saved': (savedContact ?? ((existing?['is_saved'] as int? ?? 1) == 1))
          ? 1
          : 0,
      'user_level': userLevel ?? existing?['user_level'] ?? 'user',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 기존 연락처의 X25519 메시지 암호화 공개키만 갱신한다.
  Future<void> setContactEncryptionPublicKey(
    Uint8List nodeId,
    Uint8List encryptionPublicKey,
  ) async {
    await _database.update(
      'contacts',
      {
        'encryption_public_key': encryptionPublicKey,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  /// node_id 로 연락처를 조회한다. 없으면 null.
  Future<Map<String, dynamic>?> getContact(Uint8List nodeId) async {
    final rows = await _database.query(
      'contacts',
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
    if (rows.isEmpty) return null;
    return _blobRow(rows.first);
  }

  /// 전체 연락처 목록을 반환한다 (last_seen 내림차순).
  Future<List<Map<String, dynamic>>> getAllContacts() async {
    final rows = await _database.query(
      'contacts',
      orderBy: 'is_favorite DESC, last_seen DESC',
    );
    return rows.map(_blobRow).toList();
  }

  /// 특정 연락처의 신뢰 상태를 변경한다 (R-08 TOFU).
  Future<void> setTrusted(Uint8List nodeId, bool trusted) async {
    await _database.update(
      'contacts',
      {'is_trusted': trusted ? 1 : 0},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  Future<void> setContactSaved(Uint8List nodeId, bool saved) async {
    await _database.update(
      'contacts',
      {'is_saved': saved ? 1 : 0},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  /// 연락처에 사용자가 기억하기 쉬운 로컬 이름을 저장한다.
  Future<void> setContactDisplayName(
    Uint8List nodeId,
    String? displayName,
  ) async {
    await _database.update(
      'contacts',
      {'display_name': displayName},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  /// 연락처의 로컬 즐겨찾기 상태를 변경한다.
  Future<void> setContactFavorite(Uint8List nodeId, bool favorite) async {
    await _database.update(
      'contacts',
      {'is_favorite': favorite ? 1 : 0},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  /// 연락처에 로컬 그룹 이름을 저장한다.
  Future<void> setContactGroup(Uint8List nodeId, String? groupName) async {
    await _database.update(
      'contacts',
      {'group_name': groupName},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  Future<void> setContactDeviceType(Uint8List nodeId, String deviceType) async {
    await _database.update(
      'contacts',
      {
        'device_type': deviceType,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  Future<void> setContactAvatar(Uint8List nodeId, String? avatarKey) async {
    await _database.update(
      'contacts',
      {'avatar_key': avatarKey},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  Future<void> setContactUserLevel(Uint8List nodeId, String userLevel) async {
    await _database.update(
      'contacts',
      {'user_level': userLevel},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  /// 연락처를 로컬 목록에서 삭제한다. 메시지 기록은 보존한다.
  Future<int> deleteContact(Uint8List nodeId) {
    return _database.delete(
      'contacts',
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  Future<int> deleteMessagesForContact(
    Uint8List contactNodeId, {
    Uint8List? myNodeId,
  }) {
    if (myNodeId != null) {
      if (_bytesEqual(contactNodeId, myNodeId)) {
        return _database.delete(
          'messages',
          where: 'sender_id = ? AND target_id = ?',
          whereArgs: [myNodeId, myNodeId],
        );
      }
      return _database.delete(
        'messages',
        where:
            '(sender_id = ? AND target_id = ?) OR '
            '(sender_id = ? AND target_id = ?)',
        whereArgs: [contactNodeId, myNodeId, myNodeId, contactNodeId],
      );
    }
    return _database.delete(
      'messages',
      where: 'sender_id = ? OR target_id = ?',
      whereArgs: [contactNodeId, contactNodeId],
    );
  }

  Future<int> deleteAllMessages() async {
    await _database.delete('seen_messages');
    await _database.delete('notices');
    return _database.delete('messages');
  }

  /// 모든 메시지를 원시 행으로 반환 (export용).
  Future<List<Map<String, dynamic>>> exportAllMessagesRaw() {
    return _database.query('messages', orderBy: 'timestamp ASC');
  }

  /// 메시지를 대량 insert한다. 기존 메시지 삭제 없이 중복만 무시.
  Future<int> importMessagesRaw(List<Map<String, dynamic>> rows) async {
    var count = 0;
    final batch = _database.batch();
    for (final row in rows) {
      batch.insert(
        'messages',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      count++;
    }
    await batch.commit(noResult: true);
    return count;
  }

  /// 저장된 연락처를 모두 삭제한다.
  Future<int> deleteAllSavedContacts() async {
    return _database.delete('contacts');
  }

  Future<int> deleteExpiredMessages({int? nowMs}) {
    final effectiveNowMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return _database.delete(
      'messages',
      where: 'expires_at IS NOT NULL AND expires_at <= ?',
      whereArgs: [effectiveNowMs],
    );
  }

  Future<void> setMessageExpiresAtIfNull(Uint8List msgId, int expiresAt) async {
    await _database.update(
      'messages',
      {'expires_at': expiresAt},
      where: 'msg_id = ? AND expires_at IS NULL',
      whereArgs: [msgId],
    );
  }

  // ── Messages ──────────────────────────────────────────────────────────────

  /// 메시지를 저장한다.
  ///
  /// [payload] 는 복호화된 본문 (TEXT 메시지의 경우 UTF-8 bytes).
  /// 중복 msg_id 는 무시한다 (ConflictAlgorithm.ignore).
  Future<void> saveMessage({
    required Uint8List msgId,
    required Uint8List senderId,
    required Uint8List targetId,
    required int msgType,
    required int timestamp,
    Uint8List? payload,
    bool isOutgoing = false,
    int? expiresAt,
  }) async {
    await _database.insert('messages', {
      'msg_id': msgId,
      'sender_id': senderId,
      'target_id': targetId,
      'msg_type': msgType,
      'timestamp': timestamp,
      'payload': payload,
      'is_outgoing': isOutgoing ? 1 : 0,
      'is_read': 0,
      'expires_at': expiresAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// 특정 연락처와의 메시지 목록을 반환한다 (timestamp 오름차순, 최근 [limit]건).
  ///
  /// sender_id 또는 target_id 가 [contactNodeId] 인 행을 조회한다.
  Future<List<Map<String, dynamic>>> getMessages(
    Uint8List contactNodeId, {
    Uint8List? myNodeId,
    int limit = 50,
  }) async {
    await deleteExpiredMessages();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (myNodeId != null) {
      final isSelf = _bytesEqual(contactNodeId, myNodeId);
      final rows = await _database.rawQuery(
        isSelf
            ? '''
              SELECT * FROM messages
              WHERE sender_id = ?
                AND target_id = ?
                AND (expires_at IS NULL OR expires_at > ?)
              ORDER BY timestamp ASC
              LIMIT ?
              '''
            : '''
              SELECT * FROM messages
              WHERE (
                  (sender_id = ? AND target_id = ?)
                  OR (sender_id = ? AND target_id = ?)
                  OR (sender_id = ? AND target_id = X'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF')
                )
                AND (expires_at IS NULL OR expires_at > ?)
              ORDER BY timestamp ASC
              LIMIT ?
              ''',
        isSelf
            ? [myNodeId, myNodeId, nowMs, limit]
            : [contactNodeId, myNodeId, myNodeId, contactNodeId, contactNodeId, nowMs, limit],
      );
      return rows.map(_blobRow).toList();
    }
    final rows = await _database.rawQuery(
      '''
      SELECT * FROM messages
      WHERE (sender_id = ? OR target_id = ?)
        AND (expires_at IS NULL OR expires_at > ?)
      ORDER BY timestamp ASC
      LIMIT ?
      ''',
      [contactNodeId, contactNodeId, nowMs, limit],
    );
    return rows.map(_blobRow).toList();
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<List<Uint8List>> getContactNodeIdsWithMessages(
    Uint8List myNodeId,
  ) async {
    await deleteExpiredMessages();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows = await _database.rawQuery(
      '''
      SELECT sender_id AS node_id FROM messages
      WHERE sender_id != ? AND (expires_at IS NULL OR expires_at > ?)
      UNION
      SELECT target_id AS node_id FROM messages
      WHERE target_id != ? AND (expires_at IS NULL OR expires_at > ?)
      ''',
      [myNodeId, nowMs, myNodeId, nowMs],
    );
    return rows.map((row) => row['node_id']).whereType<Uint8List>().toList();
  }

  Future<Map<String, int>> getUnreadMessageCounts(Uint8List myNodeId) async {
    await deleteExpiredMessages();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows = await _database.rawQuery(
      '''
      SELECT sender_id AS node_id, COUNT(*) AS unread_count
      FROM messages
      WHERE target_id = ?
        AND sender_id != ?
        AND is_outgoing = 0
        AND is_read = 0
        AND (expires_at IS NULL OR expires_at > ?)
      GROUP BY sender_id
      ''',
      [myNodeId, myNodeId, nowMs],
    );
    return {
      for (final row in rows)
        _hex(row['node_id'] as Uint8List): row['unread_count'] as int,
    };
  }

  Future<int> markMessagesReadForContact(
    Uint8List contactNodeId,
    Uint8List myNodeId,
  ) {
    return _database.update(
      'messages',
      {'is_read': 1},
      where:
          'sender_id = ? AND target_id = ? AND is_outgoing = 0 AND is_read = 0',
      whereArgs: [contactNodeId, myNodeId],
    );
  }

  Future<Map<String, String>> getSettings() async {
    final rows = await _database.query('app_settings');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

  Future<void> setSettings(Map<String, String> values) async {
    final batch = _database.batch();
    for (final entry in values.entries) {
      batch.insert('app_settings', {
        'key': entry.key,
        'value': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  // ── Seen Messages (R-09) ─────────────────────────────────────────────────

  /// [msgId] 가 seen_messages 테이블에 있으면 true (중복/루프 패킷).
  Future<bool> isMessageSeen(Uint8List msgId) async {
    final rows = await _database.query(
      'seen_messages',
      where: 'msg_id = ?',
      whereArgs: [msgId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// [msgId] 를 seen_messages 에 기록한다.
  /// 이미 존재하면 seen_at 을 갱신한다.
  Future<void> markMessageSeen(Uint8List msgId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _database.insert('seen_messages', {
      'msg_id': msgId,
      'seen_at': nowMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 30분(1,800,000 ms) 이전 seen_messages 항목을 삭제한다 (R-09).
  /// 앱 시작 시 또는 주기적으로 호출하여 DB 크기를 관리한다.
  Future<void> cleanOldSeenMessages() async {
    final cutoffMs = DateTime.now().millisecondsSinceEpoch - _seenMessageTtlMs;
    await _database.delete(
      'seen_messages',
      where: 'seen_at < ?',
      whereArgs: [cutoffMs],
    );
    await _database.rawDelete('''
      DELETE FROM seen_messages
      WHERE msg_id NOT IN (
        SELECT msg_id
        FROM seen_messages
        ORDER BY seen_at DESC
        LIMIT 10000
      )
    ''');
  }

  // ── Notices ───────────────────────────────────────────────────────────────

  Future<void> saveNotice({
    required String senderName,
    required String text,
    required int timestamp,
    required bool isLong,
  }) async {
    await _database.insert('notices', {
      'sender_name': senderName,
      'text': text,
      'timestamp': timestamp,
      'is_long': isLong ? 1 : 0,
    });
  }

  Future<List<Map<String, dynamic>>> loadNotices() async {
    return _database.query('notices', orderBy: 'timestamp ASC');
  }

  // ── 내부 유틸리티 ─────────────────────────────────────────────────────────

  /// sqflite 는 BLOB 컬럼을 Uint8List 로 반환하지만,
  /// `Map<String, dynamic>` 의 값 타입을 명시적으로 맞춰 두기 위해
  /// 변환 없이 그대로 반환한다. (sqflite >= 2.0 에서 BLOB → Uint8List 자동 변환)
  Map<String, dynamic> _blobRow(Map<String, dynamic> row) => Map.of(row);

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ── ChatGroup ─────────────────────────────────────────────────────────────

  Future<void> upsertChatGroup({
    required String groupId,
    required String name,
    required Uint8List leaderId,
    required int createdAt,
  }) async {
    await _database.insert('chat_groups', {
      'group_id': groupId,
      'name': name,
      'leader_id': leaderId,
      'created_at': createdAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getChatGroup(String groupId) async {
    final rows = await _database.query(
      'chat_groups',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    if (rows.isEmpty) return null;
    return Map.of(rows.first);
  }

  Future<List<Map<String, dynamic>>> getAllChatGroups() async {
    return _database.query('chat_groups', orderBy: 'created_at ASC');
  }

  Future<void> deleteChatGroup(String groupId) async {
    await _database.delete('chat_groups', where: 'group_id = ?', whereArgs: [groupId]);
    await _database.delete('group_members', where: 'group_id = ?', whereArgs: [groupId]);
    await _database.delete('group_messages', where: 'group_id = ?', whereArgs: [groupId]);
  }

  Future<void> updateChatGroupName(String groupId, String name) async {
    await _database.update('chat_groups', {'name': name},
        where: 'group_id = ?', whereArgs: [groupId]);
  }

  Future<void> updateChatGroupLeader(String groupId, Uint8List leaderId) async {
    await _database.update('chat_groups', {'leader_id': leaderId},
        where: 'group_id = ?', whereArgs: [groupId]);
  }

  // ── GroupMember ──────────────────────────────────────────────────────────

  Future<void> upsertGroupMember({
    required String groupId,
    required Uint8List nodeId,
    required int joinedAt,
  }) async {
    final existing = await _database.query(
      'group_members',
      where: 'group_id = ? AND node_id = ?',
      whereArgs: [groupId, nodeId],
    );
    if (existing.isEmpty) {
      await _database.insert('group_members', {
        'group_id': groupId,
        'node_id': nodeId,
        'joined_at': joinedAt,
        'msg_count': 0,
      });
    }
  }

  Future<void> removeGroupMember(String groupId, Uint8List nodeId) async {
    await _database.delete(
      'group_members',
      where: 'group_id = ? AND node_id = ?',
      whereArgs: [groupId, nodeId],
    );
  }

  Future<List<Map<String, dynamic>>> getGroupMembers(String groupId) async {
    final rows = await _database.query(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'msg_count DESC, joined_at ASC',
    );
    return rows.map(Map.of).toList();
  }

  Future<void> incrementGroupMemberMsgCount(String groupId, Uint8List nodeId) async {
    await _database.rawUpdate(
      'UPDATE group_members SET msg_count = msg_count + 1 WHERE group_id = ? AND node_id = ?',
      [groupId, nodeId],
    );
  }

  // ── GroupMessage ─────────────────────────────────────────────────────────

  Future<void> saveGroupMessage({
    required Uint8List msgId,
    required String groupId,
    required Uint8List senderId,
    required int msgType,
    required String payload,
    required int timestamp,
    bool isOutgoing = false,
    int? expiresAt,
  }) async {
    await _database.insert('group_messages', {
      'msg_id': msgId,
      'group_id': groupId,
      'sender_id': senderId,
      'msg_type': msgType,
      'payload': payload,
      'timestamp': timestamp,
      'is_read': 0,
      'is_outgoing': isOutgoing ? 1 : 0,
      'expires_at': expiresAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> getGroupMessages(
    String groupId, {
    int limit = 100,
  }) async {
    await deleteExpiredGroupMessages();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows = await _database.rawQuery(
      '''
      SELECT * FROM group_messages
      WHERE group_id = ?
        AND (expires_at IS NULL OR expires_at > ?)
      ORDER BY timestamp ASC
      LIMIT ?
      ''',
      [groupId, nowMs, limit],
    );
    return rows.map(Map.of).toList();
  }

  Future<int> deleteExpiredGroupMessages({int? nowMs}) {
    final effectiveNowMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return _database.delete(
      'group_messages',
      where: 'expires_at IS NOT NULL AND expires_at <= ?',
      whereArgs: [effectiveNowMs],
    );
  }

  Future<int> getGroupUnreadCount(String groupId) async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS cnt FROM group_messages WHERE group_id = ? AND is_read = 0 AND is_outgoing = 0',
      [groupId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['cnt'] as int?) ?? 0;
  }

  Future<void> markGroupMessagesRead(String groupId) async {
    await _database.update(
      'group_messages',
      {'is_read': 1},
      where: 'group_id = ? AND is_outgoing = 0',
      whereArgs: [groupId],
    );
  }

  // ── 리소스 해제 (테스트 또는 앱 종료 시) ──────────────────────────────────

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
