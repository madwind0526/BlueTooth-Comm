import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/user_level.dart';

enum HomeFilter { all, groups, favorites, chats }

class LocalContactGroup {
  final String name;
  final List<Contact> members;

  const LocalContactGroup({required this.name, required this.members});

  bool get isFavorite => members.any((contact) => contact.isFavorite);
  int get memberCount => members.length;
}

String contactDisplayName(Contact contact) {
  final displayName = contact.displayName?.trim();
  if (displayName != null && displayName.isNotEmpty) return displayName;

  final hex = contactCode(contact);
  return hex.substring(0, hex.length >= 8 ? 8 : hex.length);
}

String contactCode(Contact contact) {
  return contact.nodeId
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

bool canOpenChatWithContact(UserLevel myLevel, Contact contact) {
  return myLevel.canSendMessages && contact.userLevel.canSendMessages;
}

List<Contact> sortContacts(Iterable<Contact> contacts) {
  final sorted = List<Contact>.from(contacts);
  sorted.sort((left, right) {
    final favoriteOrder = _compareFavorite(left.isFavorite, right.isFavorite);
    if (favoriteOrder != 0) return favoriteOrder;
    return contactDisplayName(
      left,
    ).toLowerCase().compareTo(contactDisplayName(right).toLowerCase());
  });
  return sorted;
}

List<LocalContactGroup> buildGroups(Iterable<Contact> contacts) {
  final grouped = <String, List<Contact>>{};
  for (final contact in contacts) {
    final groupName = contact.groupName?.trim();
    if (groupName == null || groupName.isEmpty) continue;
    grouped.putIfAbsent(groupName, () => []).add(contact);
  }

  final groups = grouped.entries
      .map(
        (entry) => LocalContactGroup(
          name: entry.key,
          members: sortContacts(entry.value),
        ),
      )
      .toList();
  groups.sort((left, right) {
    final favoriteOrder = _compareFavorite(left.isFavorite, right.isFavorite);
    if (favoriteOrder != 0) return favoriteOrder;
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return groups;
}

List<Contact> searchContacts(Iterable<Contact> contacts, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return sortContacts(contacts);

  return sortContacts(
    contacts.where((contact) {
      final name = contactDisplayName(contact).toLowerCase();
      final groupName = contact.groupName?.toLowerCase() ?? '';
      return name.contains(normalized) || groupName.contains(normalized);
    }),
  );
}

List<LocalContactGroup> searchGroups(
  Iterable<LocalContactGroup> groups,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return List<LocalContactGroup>.from(groups);
  return groups
      .where((group) => group.name.toLowerCase().contains(normalized))
      .toList();
}

String formatRelativeTime(int timestampMs) {
  if (timestampMs <= 0) return '기록 없음';

  final difference = DateTime.now().millisecondsSinceEpoch - timestampMs;
  if (difference < 60000) return '방금 전';

  final minutes = difference ~/ 60000;
  if (minutes < 60) return '$minutes분 전';

  final hours = minutes ~/ 60;
  if (hours < 24) return '$hours시간 전';

  final days = hours ~/ 24;
  if (days < 30) return '$days일 전';

  final months = days ~/ 30;
  if (months < 12) return '$months개월 전';

  return '${months ~/ 12}년 전';
}

int _compareFavorite(bool left, bool right) {
  if (left == right) return 0;
  return left ? -1 : 1;
}
