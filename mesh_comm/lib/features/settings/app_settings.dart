import 'package:mesh_comm/features/identity/user_level.dart';

class AppSettings {
  final bool darkMode;
  final String displayName;
  final String avatarKey;
  final UserLevel userLevel;
  final int scanDefaultDepth;
  final int lastShortNoticeAt;
  final int lastLongNoticeAt;

  const AppSettings({
    this.darkMode = true,
    this.displayName = 'Me',
    this.avatarKey = 'animal_monkey',
    this.userLevel = UserLevel.user,
    this.scanDefaultDepth = 3,
    this.lastShortNoticeAt = 0,
    this.lastLongNoticeAt = 0,
  });

  AppSettings copyWith({
    bool? darkMode,
    String? displayName,
    String? avatarKey,
    UserLevel? userLevel,
    int? scanDefaultDepth,
    int? lastShortNoticeAt,
    int? lastLongNoticeAt,
  }) {
    return AppSettings(
      darkMode: darkMode ?? this.darkMode,
      displayName: displayName ?? this.displayName,
      avatarKey: avatarKey ?? this.avatarKey,
      userLevel: userLevel ?? this.userLevel,
      scanDefaultDepth: scanDefaultDepth ?? this.scanDefaultDepth,
      lastShortNoticeAt: lastShortNoticeAt ?? this.lastShortNoticeAt,
      lastLongNoticeAt: lastLongNoticeAt ?? this.lastLongNoticeAt,
    );
  }

  static AppSettings fromMap(Map<String, String> values) {
    final depth = int.tryParse(values['scan_default_depth'] ?? '') ?? 3;
    return AppSettings(
      darkMode: values['dark_mode'] != 'false',
      displayName: _cleanText(values['display_name']) ?? 'Me',
      avatarKey: _cleanText(values['avatar_key']) ?? 'animal_monkey',
      userLevel: UserLevel.fromWire(values['user_level']),
      scanDefaultDepth: depth < -1 ? 3 : depth,
      lastShortNoticeAt:
          int.tryParse(values['last_short_notice_at'] ?? '') ?? 0,
      lastLongNoticeAt:
          int.tryParse(values['last_long_notice_at'] ?? '') ?? 0,
    );
  }

  Map<String, String> toMap() {
    return {
      'dark_mode': darkMode ? 'true' : 'false',
      'display_name': displayName.trim().isEmpty ? 'Me' : displayName.trim(),
      'avatar_key': avatarKey,
      'user_level': userLevel.wireName,
      'scan_default_depth': scanDefaultDepth.toString(),
      'last_short_notice_at': lastShortNoticeAt.toString(),
      'last_long_notice_at': lastLongNoticeAt.toString(),
    };
  }

  static String? _cleanText(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
