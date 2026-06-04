import 'dart:typed_data';

import 'package:mesh_comm/features/identity/user_level.dart';

enum MeshDeviceType {
  unknown,
  phone,
  pc;

  static MeshDeviceType fromWire(String? value) {
    return switch (value) {
      'phone' => MeshDeviceType.phone,
      'pc' => MeshDeviceType.pc,
      _ => MeshDeviceType.unknown,
    };
  }

  String get wireName {
    return switch (this) {
      MeshDeviceType.phone => 'phone',
      MeshDeviceType.pc => 'pc',
      MeshDeviceType.unknown => 'unknown',
    };
  }
}

class Contact {
  final Uint8List nodeId;
  final Uint8List publicKey;
  final Uint8List? encryptionPublicKey;
  final String? displayName;
  final bool isTrusted;
  final String fingerprint;
  final int firstSeen;
  final int lastSeen;
  final bool isFavorite;
  final String? groupName;
  final MeshDeviceType deviceType;
  final String? avatarKey;
  final bool isSaved;
  final UserLevel userLevel;

  const Contact({
    required this.nodeId,
    required this.publicKey,
    this.encryptionPublicKey,
    this.displayName,
    required this.isTrusted,
    required this.fingerprint,
    required this.firstSeen,
    required this.lastSeen,
    this.isFavorite = false,
    this.groupName,
    this.deviceType = MeshDeviceType.unknown,
    this.avatarKey,
    this.isSaved = true,
    this.userLevel = UserLevel.user,
  });

  String get trustLabel => isTrusted ? 'trusted' : 'unconfirmed';

  factory Contact.fromMap(Map<String, dynamic> map) {
    return Contact(
      nodeId: map['node_id'] as Uint8List,
      publicKey: map['public_key'] as Uint8List,
      encryptionPublicKey: map['encryption_public_key'] as Uint8List?,
      displayName: map['display_name'] as String?,
      isTrusted: (map['is_trusted'] as int) == 1,
      fingerprint: map['fingerprint'] as String? ?? '',
      firstSeen: map['first_seen'] as int? ?? 0,
      lastSeen: map['last_seen'] as int? ?? 0,
      isFavorite: (map['is_favorite'] as int? ?? 0) == 1,
      groupName: map['group_name'] as String?,
      deviceType: MeshDeviceType.fromWire(map['device_type'] as String?),
      avatarKey: map['avatar_key'] as String?,
      isSaved: (map['is_saved'] as int? ?? 1) == 1,
      userLevel: UserLevel.fromWire(map['user_level'] as String?),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'node_id': nodeId,
      'public_key': publicKey,
      'encryption_public_key': encryptionPublicKey,
      'display_name': displayName,
      'is_trusted': isTrusted ? 1 : 0,
      'fingerprint': fingerprint,
      'first_seen': firstSeen,
      'last_seen': lastSeen,
      'is_favorite': isFavorite ? 1 : 0,
      'group_name': groupName,
      'device_type': deviceType.wireName,
      'avatar_key': avatarKey,
      'is_saved': isSaved ? 1 : 0,
      'user_level': userLevel.wireName,
    };
  }

  Contact copyWith({
    Uint8List? nodeId,
    Uint8List? publicKey,
    Uint8List? encryptionPublicKey,
    String? displayName,
    bool? isTrusted,
    String? fingerprint,
    int? firstSeen,
    int? lastSeen,
    bool? isFavorite,
    String? groupName,
    MeshDeviceType? deviceType,
    String? avatarKey,
    bool? isSaved,
    UserLevel? userLevel,
  }) {
    return Contact(
      nodeId: nodeId ?? this.nodeId,
      publicKey: publicKey ?? this.publicKey,
      encryptionPublicKey: encryptionPublicKey ?? this.encryptionPublicKey,
      displayName: displayName ?? this.displayName,
      isTrusted: isTrusted ?? this.isTrusted,
      fingerprint: fingerprint ?? this.fingerprint,
      firstSeen: firstSeen ?? this.firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
      isFavorite: isFavorite ?? this.isFavorite,
      groupName: groupName ?? this.groupName,
      deviceType: deviceType ?? this.deviceType,
      avatarKey: avatarKey ?? this.avatarKey,
      isSaved: isSaved ?? this.isSaved,
      userLevel: userLevel ?? this.userLevel,
    );
  }

  @override
  String toString() {
    return 'Contact(displayName: $displayName, fingerprint: $fingerprint, '
        'isTrusted: $isTrusted, isFavorite: $isFavorite, '
        'groupName: $groupName, deviceType: $deviceType, isSaved: $isSaved, '
        'userLevel: $userLevel, '
        'lastSeen: $lastSeen)';
  }
}
