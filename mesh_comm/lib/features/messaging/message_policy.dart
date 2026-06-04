class MessagePolicy {
  MessagePolicy._();

  static const int normalMaxLength = 160;
  static const int noticeMaxLength = 50;
  static const Duration timedMessageReadTtl = Duration(minutes: 1);
  static const Duration noticeCooldown = Duration(days: 1);
  static const int shortNoticeTtl = 3;
  static const int longNoticeTtl = 7;
}

enum MessageSendMode {
  normal('일반'),
  timed('타임'),
  shortNotice('공지S'),
  longNotice('공지L');

  final String label;
  const MessageSendMode(this.label);

  bool get isNotice =>
      this == MessageSendMode.shortNotice ||
      this == MessageSendMode.longNotice;

  int get maxLength =>
      isNotice ? MessagePolicy.noticeMaxLength : MessagePolicy.normalMaxLength;
}
