import 'package:mesh_comm/features/messaging/message_policy.dart';

enum UserLevel {
  creator,
  builder,
  admin,
  user,
  server;

  static UserLevel fromWire(String? value) {
    return switch (value?.toLowerCase()) {
      'creator' => UserLevel.creator,
      'builder' => UserLevel.builder,
      'admin' => UserLevel.admin,
      'server' => UserLevel.server,
      _ => UserLevel.user,
    };
  }

  String get wireName => name;

  String get label {
    return switch (this) {
      UserLevel.creator => 'Creator',
      UserLevel.builder => 'Builder',
      UserLevel.admin => 'Admin',
      UserLevel.user => 'User',
      UserLevel.server => 'Server',
    };
  }

  bool get canSendMessages => this != UserLevel.server;

  int? get savedContactLimit {
    return switch (this) {
      UserLevel.user => 10,
      UserLevel.server => 10,
      _ => null,
    };
  }

  bool get canAssignContactLevels {
    return switch (this) {
      UserLevel.creator || UserLevel.builder || UserLevel.admin => true,
      UserLevel.user || UserLevel.server => false,
    };
  }

  int get rank {
    return switch (this) {
      UserLevel.creator => 4,
      UserLevel.builder => 3,
      UserLevel.admin => 2,
      UserLevel.user => 1,
      UserLevel.server => 1,
    };
  }

  bool canChangeContactLevel(UserLevel contactLevel) {
    return canAssignContactLevels &&
        contactLevel != UserLevel.server &&
        contactLevel.rank < rank;
  }

  Duration? noticeCooldown(MessageSendMode mode) {
    if (!mode.isNotice) return Duration.zero;
    if (this == UserLevel.creator) return Duration.zero;

    final shortNotice = mode == MessageSendMode.shortNotice;
    return switch (this) {
      UserLevel.builder => Duration(hours: shortNotice ? 1 : 2),
      UserLevel.admin => Duration(hours: shortNotice ? 2 : 4),
      UserLevel.user => Duration(hours: shortNotice ? 6 : 24),
      UserLevel.server => null,
      UserLevel.creator => Duration.zero,
    };
  }

  List<UserLevel> get contactAssignableLevels {
    return switch (this) {
      UserLevel.creator => const [
        UserLevel.user,
        UserLevel.admin,
        UserLevel.builder,
        UserLevel.creator,
      ],
      UserLevel.builder => const [UserLevel.user, UserLevel.admin],
      UserLevel.admin => const [UserLevel.user],
      UserLevel.user => const [],
      UserLevel.server => const [],
    };
  }

  List<UserLevel> get selfSelectableLevels {
    return switch (this) {
      UserLevel.user ||
      UserLevel.server => const [UserLevel.user, UserLevel.server],
      _ => [this],
    };
  }
}
