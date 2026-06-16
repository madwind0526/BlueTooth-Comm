import 'package:mesh_comm/features/identity/user_level.dart';

enum MessageAlertMode {
  sound,
  vibration,
  silent;

  static MessageAlertMode fromWire(String? value) {
    return switch (value?.toLowerCase()) {
      'vibration' => MessageAlertMode.vibration,
      'silent' => MessageAlertMode.silent,
      _ => MessageAlertMode.sound,
    };
  }

  String get wireName => name;

  String get label {
    return switch (this) {
      MessageAlertMode.sound => '소리',
      MessageAlertMode.vibration => '진동',
      MessageAlertMode.silent => '무음',
    };
  }
}

class AppSettings {
  final bool darkMode;
  final bool demoMode;
  final String displayName;
  final String avatarKey;
  final UserLevel userLevel;
  final MessageAlertMode messageAlertMode;
  final int scanDefaultDepth;
  final int lastShortNoticeAt;
  final int lastLongNoticeAt;
  final int lastFullScanAt;

  const AppSettings({
    this.darkMode = true,
    this.demoMode = false,
    this.displayName = 'Me',
    this.avatarKey = 'animal_monkey',
    this.userLevel = UserLevel.user,
    this.messageAlertMode = MessageAlertMode.sound,
    this.scanDefaultDepth = 3,
    this.lastShortNoticeAt = 0,
    this.lastLongNoticeAt = 0,
    this.lastFullScanAt = 0,
  });

  AppSettings copyWith({
    bool? darkMode,
    bool? demoMode,
    String? displayName,
    String? avatarKey,
    UserLevel? userLevel,
    MessageAlertMode? messageAlertMode,
    int? scanDefaultDepth,
    int? lastShortNoticeAt,
    int? lastLongNoticeAt,
    int? lastFullScanAt,
  }) {
    return AppSettings(
      darkMode: darkMode ?? this.darkMode,
      demoMode: demoMode ?? this.demoMode,
      displayName: displayName ?? this.displayName,
      avatarKey: avatarKey ?? this.avatarKey,
      userLevel: userLevel ?? this.userLevel,
      messageAlertMode: messageAlertMode ?? this.messageAlertMode,
      scanDefaultDepth: scanDefaultDepth ?? this.scanDefaultDepth,
      lastShortNoticeAt: lastShortNoticeAt ?? this.lastShortNoticeAt,
      lastLongNoticeAt: lastLongNoticeAt ?? this.lastLongNoticeAt,
      lastFullScanAt: lastFullScanAt ?? this.lastFullScanAt,
    );
  }

  static AppSettings fromMap(Map<String, String> values) {
    final depth = int.tryParse(values['scan_default_depth'] ?? '') ?? 3;
    return AppSettings(
      darkMode: values['dark_mode'] != 'false',
      demoMode: values['demo_mode'] == 'true',
      displayName: _cleanText(values['display_name']) ?? 'Me',
      avatarKey: _cleanText(values['avatar_key']) ?? 'animal_monkey',
      userLevel: UserLevel.fromWire(values['user_level']),
      messageAlertMode: MessageAlertMode.fromWire(values['message_alert_mode']),
      scanDefaultDepth: depth < -1 ? 3 : depth,
      lastShortNoticeAt:
          int.tryParse(values['last_short_notice_at'] ?? '') ?? 0,
      lastLongNoticeAt: int.tryParse(values['last_long_notice_at'] ?? '') ?? 0,
      lastFullScanAt: int.tryParse(values['last_full_scan_at'] ?? '') ?? 0,
    );
  }

  Map<String, String> toMap() {
    return {
      'dark_mode': darkMode ? 'true' : 'false',
      'demo_mode': demoMode ? 'true' : 'false',
      'display_name': displayName.trim().isEmpty ? 'Me' : displayName.trim(),
      'avatar_key': avatarKey,
      'user_level': userLevel.wireName,
      'message_alert_mode': messageAlertMode.wireName,
      'scan_default_depth': scanDefaultDepth.toString(),
      'last_short_notice_at': lastShortNoticeAt.toString(),
      'last_long_notice_at': lastLongNoticeAt.toString(),
      'last_full_scan_at': lastFullScanAt.toString(),
    };
  }

  static String? _cleanText(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
