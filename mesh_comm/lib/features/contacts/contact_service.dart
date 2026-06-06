import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_comm/core/crypto/crypto_service.dart';
import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/identity/user_level.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';

import 'contact_model.dart';

enum TrustChangeResult { newContact, unchanged, changed }

class ContactService {
  static final ContactService _instance = ContactService._internal();
  factory ContactService() => _instance;
  ContactService._internal();

  final DatabaseService _db = DatabaseService();
  final CryptoService _crypto = CryptoService();

  final StreamController<List<Contact>> _contactsController =
      StreamController<List<Contact>>.broadcast();

  Stream<List<Contact>> get contactsStream => _contactsController.stream;

  Future<Contact> addOrUpdateContact(
    Uint8List nodeId,
    Uint8List publicKey, {
    Uint8List? encryptionPublicKey,
    String? displayName,
    String? avatarKey,
    UserLevel userLevel = UserLevel.user,
    MeshDeviceType deviceType = MeshDeviceType.unknown,
    bool savedContact = false,
  }) async {
    final fp = _crypto.fingerprint(publicKey);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final existing = await _db.getContact(nodeId);
    final firstSeen = existing?['first_seen'] as int? ?? nowMs;
    final trusted = (existing?['is_trusted'] as int? ?? 0) == 1;
    final remoteDisplayName = _trimToNull(displayName);
    final remoteAvatarKey = _trimToNull(avatarKey);
    final existingDisplayName = existing?['display_name'] as String?;
    final existingAvatarKey = existing?['avatar_key'] as String?;
    final existingSaved = (existing?['is_saved'] as int? ?? 0) == 1;
    final existingUserLevel = UserLevel.fromWire(
      existing?['user_level'] as String?,
    );
    final previousRemoteDisplayName =
        existing?['remote_display_name'] as String?;
    final previousRemoteAvatarKey = existing?['remote_avatar_key'] as String?;
    final shouldAdoptRemoteName =
        existingDisplayName == null ||
        existingDisplayName == previousRemoteDisplayName;
    final shouldAdoptRemoteAvatar =
        existingAvatarKey == null ||
        existingAvatarKey == previousRemoteAvatarKey;
    final storedDisplayName = shouldAdoptRemoteName
        ? remoteDisplayName ?? existingDisplayName
        : existingDisplayName;
    final storedAvatarKey = shouldAdoptRemoteAvatar
        ? remoteAvatarKey ?? existingAvatarKey
        : existingAvatarKey;
    final storedUserLevel = _levelFromKeyAnnounce(
      existing: existing,
      existingLevel: existingUserLevel,
      announcedLevel: userLevel,
    );

    await _removeReplaceableDuplicateContacts(
      nodeId: nodeId,
      displayName: storedDisplayName,
      avatarKey: storedAvatarKey,
      deviceType: deviceType,
    );

    await _db.upsertContact(
      nodeId,
      publicKey,
      encryptionPublicKey: encryptionPublicKey,
      displayName: storedDisplayName,
      trusted: trusted,
      fingerprint: fp,
      deviceType: deviceType.wireName,
      avatarKey: storedAvatarKey,
      remoteDisplayName: remoteDisplayName,
      remoteAvatarKey: remoteAvatarKey,
      savedContact: savedContact || existingSaved,
      userLevel: storedUserLevel.wireName,
    );

    final contact = Contact(
      nodeId: nodeId,
      publicKey: publicKey,
      encryptionPublicKey: encryptionPublicKey,
      displayName: storedDisplayName,
      isTrusted: trusted,
      fingerprint: fp,
      firstSeen: firstSeen,
      lastSeen: nowMs,
      isFavorite: (existing?['is_favorite'] as int? ?? 0) == 1,
      groupName: existing?['group_name'] as String?,
      deviceType: deviceType,
      avatarKey: storedAvatarKey,
      isSaved: savedContact || existingSaved,
      userLevel: storedUserLevel,
    );

    await _emitContacts();
    return contact;
  }

  UserLevel _levelFromKeyAnnounce({
    required Map<String, dynamic>? existing,
    required UserLevel existingLevel,
    required UserLevel announcedLevel,
  }) {
    final selfSelectable =
        announcedLevel == UserLevel.user || announcedLevel == UserLevel.server;
    if (existing == null) {
      return selfSelectable ? announcedLevel : UserLevel.user;
    }
    if (existingLevel == UserLevel.creator ||
        existingLevel == UserLevel.builder ||
        existingLevel == UserLevel.admin) {
      return existingLevel;
    }
    return selfSelectable ? announcedLevel : existingLevel;
  }

  Future<void> _removeReplaceableDuplicateContacts({
    required Uint8List nodeId,
    required String? displayName,
    required String? avatarKey,
    required MeshDeviceType deviceType,
  }) async {
    final normalizedName = _normalizeName(displayName);
    if (normalizedName == null) return;

    final messageNodeIds = (await _db.getContactNodeIdsWithMessages(
      IdentityService().myNodeId,
    )).map(_hex).toSet();
    final rows = await _db.getAllContacts();

    for (final row in rows) {
      final candidateNodeId = row['node_id'] as Uint8List;
      if (_bytesEqual(candidateNodeId, nodeId)) continue;

      final candidateName = _normalizeName(row['display_name'] as String?);
      if (candidateName != normalizedName) continue;

      final candidateDeviceType = MeshDeviceType.fromWire(
        row['device_type'] as String?,
      );
      if (candidateDeviceType != deviceType) continue;

      final candidateAvatarKey = _trimToNull(row['avatar_key'] as String?);
      if (avatarKey != null &&
          candidateAvatarKey != null &&
          candidateAvatarKey != avatarKey) {
        continue;
      }

      final hasMessages = messageNodeIds.contains(_hex(candidateNodeId));
      final hasGroup =
          _trimToNull(row['group_name'] as String?)?.isNotEmpty ?? false;
      final isTrusted = (row['is_trusted'] as int? ?? 0) == 1;
      final isFavorite = (row['is_favorite'] as int? ?? 0) == 1;
      final replaceable =
          !isTrusted && !isFavorite && !hasGroup && !hasMessages;

      if (!replaceable) continue;
      await _db.deleteContact(candidateNodeId);
    }
  }

  Future<bool> confirmTrust(Uint8List nodeId, String scannedFingerprint) async {
    final row = await _db.getContact(nodeId);
    if (row == null) return false;

    final storedFp = row['fingerprint'] as String? ?? '';
    if (storedFp.toUpperCase() != scannedFingerprint.toUpperCase()) {
      return false;
    }

    await _db.setTrusted(nodeId, true);
    await _emitContacts();
    return true;
  }

  Future<void> setTrusted(Uint8List nodeId, bool trusted) async {
    await _db.setTrusted(nodeId, trusted);
    await _emitContacts();
  }

  Future<Contact> ensureSelfContact({
    required Uint8List nodeId,
    required Uint8List publicKey,
    Uint8List? encryptionPublicKey,
    required String displayName,
    required String avatarKey,
    required UserLevel userLevel,
    required MeshDeviceType deviceType,
  }) async {
    final fp = _crypto.fingerprint(publicKey);
    await _db.upsertContact(
      nodeId,
      publicKey,
      encryptionPublicKey: encryptionPublicKey,
      displayName: _trimToNull(displayName) ?? 'Me',
      trusted: true,
      fingerprint: fp,
      deviceType: deviceType.wireName,
      avatarKey: _trimToNull(avatarKey),
      remoteDisplayName: _trimToNull(displayName) ?? 'Me',
      remoteAvatarKey: _trimToNull(avatarKey),
      savedContact: true,
      userLevel: userLevel.wireName,
    );

    final row = await _db.getContact(nodeId);
    final contact = Contact.fromMap(row!);
    await _emitContacts();
    return contact;
  }

  Future<bool> setSaved(Uint8List nodeId, bool saved) async {
    if (saved) {
      final existing = await _db.getContact(nodeId);
      final alreadySaved = (existing?['is_saved'] as int? ?? 0) == 1;
      final limit = AppSettingsService().current.userLevel.savedContactLimit;
      if (!alreadySaved && limit != null) {
        final savedCount = (await getAllContacts())
            .where(
              (contact) =>
                  contact.isSaved &&
                  !_bytesEqual(contact.nodeId, IdentityService().myNodeId),
            )
            .length;
        if (savedCount >= limit) return false;
      }
    }
    await _db.setContactSaved(nodeId, saved);
    await _emitContacts();
    return true;
  }

  Future<TrustChangeResult> checkPublicKeyChange(
    Uint8List nodeId,
    Uint8List newPublicKey,
    Uint8List? newEncryptionPublicKey,
  ) async {
    final row = await _db.getContact(nodeId);

    if (row == null) {
      return TrustChangeResult.newContact;
    }

    final storedKey = row['public_key'] as Uint8List;
    if (_bytesEqual(storedKey, newPublicKey)) {
      final storedEncryptionKey = row['encryption_public_key'] as Uint8List?;
      if (newEncryptionPublicKey != null &&
          (storedEncryptionKey == null ||
              !_bytesEqual(storedEncryptionKey, newEncryptionPublicKey))) {
        await _db.setContactEncryptionPublicKey(nodeId, newEncryptionPublicKey);
        await _emitContacts();
      }
      return TrustChangeResult.unchanged;
    }

    final newFp = _crypto.fingerprint(newPublicKey);
    await _db.upsertContact(
      nodeId,
      newPublicKey,
      encryptionPublicKey: newEncryptionPublicKey,
      displayName: row['display_name'] as String?,
      trusted: false,
      fingerprint: newFp,
      favorite: (row['is_favorite'] as int? ?? 0) == 1,
      groupName: row['group_name'] as String?,
      deviceType: row['device_type'] as String? ?? 'unknown',
      avatarKey: row['avatar_key'] as String?,
      savedContact: (row['is_saved'] as int? ?? 1) == 1,
      remoteDisplayName: row['remote_display_name'] as String?,
      remoteAvatarKey: row['remote_avatar_key'] as String?,
    );

    await _emitContacts();
    return TrustChangeResult.changed;
  }

  Future<Contact?> getContact(Uint8List nodeId) async {
    final row = await _db.getContact(nodeId);
    if (row == null) return null;
    return Contact.fromMap(row);
  }

  Future<List<Contact>> getAllContacts() async {
    final rows = await _db.getAllContacts();
    return rows.map(Contact.fromMap).toList();
  }

  Future<List<Contact>> getTrustedContacts() async {
    final all = await getAllContacts();
    return all.where((contact) => contact.isTrusted).toList();
  }

  Future<List<Contact>> getUntrustedContacts() async {
    final all = await getAllContacts();
    return all.where((contact) => !contact.isTrusted).toList();
  }

  Future<void> refresh() => _emitContacts();

  Future<void> deleteContact(Uint8List nodeId) async {
    await _db.deleteMessagesForContact(
      nodeId,
      myNodeId: IdentityService().myNodeId,
    );
    await _db.deleteContact(nodeId);
    await _emitContacts();
  }

  Future<int> cleanupStaleContacts({
    Duration staleAfter = const Duration(minutes: 10),
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoffMs = nowMs - staleAfter.inMilliseconds;
    final messageNodeIds = (await _db.getContactNodeIdsWithMessages(
      IdentityService().myNodeId,
    )).map(_hex).toSet();
    final contacts = await getAllContacts();
    var removed = 0;

    for (final contact in contacts) {
      final hasMessages = messageNodeIds.contains(_hex(contact.nodeId));
      final hasGroup = contact.groupName?.trim().isNotEmpty ?? false;
      final shouldRemove =
          !contact.isTrusted &&
          !contact.isFavorite &&
          !hasGroup &&
          !hasMessages &&
          contact.lastSeen > 0 &&
          contact.lastSeen < cutoffMs;

      if (!shouldRemove) continue;
      await _db.deleteMessagesForContact(
        contact.nodeId,
        myNodeId: IdentityService().myNodeId,
      );
      await _db.deleteContact(contact.nodeId);
      removed++;
    }

    if (removed > 0) {
      await _emitContacts();
    }
    return removed;
  }

  Future<void> renameContact(Uint8List nodeId, String? displayName) async {
    await _db.setContactDisplayName(nodeId, _trimToNull(displayName));
    await _emitContacts();
  }

  Future<void> setFavorite(Uint8List nodeId, bool favorite) async {
    await _db.setContactFavorite(nodeId, favorite);
    await _emitContacts();
  }

  Future<void> setGroup(Uint8List nodeId, String? groupName) async {
    await _db.setContactGroup(nodeId, _trimToNull(groupName));
    await _emitContacts();
  }

  Future<void> setDeviceType(
    Uint8List nodeId,
    MeshDeviceType deviceType,
  ) async {
    await _db.setContactDeviceType(nodeId, deviceType.wireName);
    await _emitContacts();
  }

  Future<void> setAvatar(Uint8List nodeId, String? avatarKey) async {
    await _db.setContactAvatar(nodeId, _trimToNull(avatarKey));
    await _emitContacts();
  }

  Future<void> setUserLevel(Uint8List nodeId, UserLevel level) async {
    final row = await _db.getContact(nodeId);
    final currentLevel = UserLevel.fromWire(row?['user_level'] as String?);
    final myLevel = AppSettingsService().current.userLevel;
    final isSelf = _bytesEqual(nodeId, IdentityService().myNodeId);
    final allowed = isSelf
        ? myLevel.selfSelectableLevels.contains(level)
        : myLevel.canChangeContactLevel(currentLevel) &&
              myLevel.contactAssignableLevels.contains(level);
    if (!allowed) {
      throw StateError('Not authorized to change contact level.');
    }
    await _db.setContactUserLevel(nodeId, level.wireName);
    await _emitContacts();
  }

  Future<Uint8List?> getPublicKey(Uint8List nodeId) async {
    final row = await _db.getContact(nodeId);
    if (row == null) return null;
    return row['public_key'] as Uint8List;
  }

  Future<Uint8List?> getEncryptionPublicKey(Uint8List nodeId) async {
    final row = await _db.getContact(nodeId);
    if (row == null) return null;
    return row['encryption_public_key'] as Uint8List?;
  }

  void dispose() {
    _contactsController.close();
  }

  Future<void> _emitContacts() async {
    if (_contactsController.isClosed) return;
    final contacts = await getAllContacts();
    _contactsController.add(contacts);
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String? _trimToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String? _normalizeName(String? value) => _trimToNull(value)?.toLowerCase();

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
