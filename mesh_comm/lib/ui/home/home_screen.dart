import 'dart:async';
import 'dart:io' show File, Platform, exit;
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:mesh_comm/core/ble/ble_service.dart';
import 'package:mesh_comm/core/app_version.dart';
import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/core/transport/transport_status.dart';
import 'package:mesh_comm/features/contacts/contact_file_service.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/contacts/contact_service.dart';
import 'package:mesh_comm/features/identity/identity_backup_service.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/identity/user_level.dart';
import 'package:mesh_comm/features/messaging/message_policy.dart';
import 'package:mesh_comm/features/messaging/messaging_service.dart';
import 'package:mesh_comm/features/messaging/topology_demo.dart';
import 'package:mesh_comm/features/messaging/topology_graph.dart';
import 'package:mesh_comm/features/messaging/topology_message.dart';
import 'package:mesh_comm/features/messaging/virtual_mesh_simulator.dart';
import 'package:mesh_comm/features/settings/app_settings.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
import 'package:mesh_comm/ui/avatar/avatar_registry.dart';
import 'package:mesh_comm/features/transfer/transfer_model.dart';
import 'package:mesh_comm/features/transfer/transfer_service.dart';
import 'package:mesh_comm/features/transfer/transfer_storage_service.dart';
import 'package:mesh_comm/features/groups/chat_group_model.dart';
import 'package:mesh_comm/features/groups/group_messaging_service.dart';
import 'package:mesh_comm/features/groups/group_service.dart';
import 'package:mesh_comm/ui/chat/chat_screen.dart';
import 'package:mesh_comm/ui/chat/group_chat_screen.dart';
import 'package:mesh_comm/ui/home/home_models.dart';
import 'package:mesh_comm/ui/qr/qr_screen.dart';

enum _ContactAction {
  rename,
  toggleTrust,
  toggleFavorite,
  inviteToGroup,
  setAvatar,
  setLevel,
  deleteMessages,
  delete,
}

enum _GroupAction { rename, delete }

enum _HomeSection { home, search, scan }

Color _roleColor(
  BuildContext context, {
  required UserLevel userLevel,
  required bool isSelf,
}) {
  final scheme = Theme.of(context).colorScheme;
  if (isSelf) {
    return scheme.brightness == Brightness.dark
        ? Colors.orangeAccent
        : Colors.deepOrange;
  }
  if (userLevel == UserLevel.server) {
    return scheme.brightness == Brightness.dark
        ? Colors.grey.shade500
        : Colors.grey.shade600;
  }
  if (userLevel == UserLevel.creator ||
      userLevel == UserLevel.builder ||
      userLevel == UserLevel.admin) {
    return scheme.brightness == Brightness.dark
        ? const Color(0xFFFF6B6B)
        : const Color(0xFFD32F2F);
  }
  return scheme.onSurface;
}

int _transportPriority(TransportKind kind) {
  return switch (kind) {
    TransportKind.lan => 2,
    TransportKind.bluetooth => 1,
  };
}

const Object _demoNoChange = Object();

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _accent = Color(0xFFFF9800);
  static const _bluetooth = Color(0xFFFF9800);

  // 선택된 탭/아이콘 색상: dark=오렌지, light=딥오렌지
  static Color selectedColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.orange
          : Colors.deepOrange;

  // 상단 transport 버튼 ON 색상: dark=흰색, light=검정
  static Color transportOnColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : Colors.grey.shade800;

  // 상단 transport 버튼 OFF 색상
  static Color transportOffColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.grey.shade500
          : Colors.grey.shade400;

  static const _alertChannel = MethodChannel('mesh_comm/alerts');

  final _contactService = ContactService();
  final _contactFileService = ContactFileService();
  final _identityBackupService = IdentityBackupService();
  final _settingsService = AppSettingsService();
  final _bleService = BleService();
  final _searchController = TextEditingController();
  final _scanDepthController = TextEditingController(text: '3');

  final _groupService = GroupService();
  final _groupMessaging = GroupMessagingService();

  StreamSubscription<List<Contact>>? _contactsSubscription;
  StreamSubscription<AppSettings>? _settingsSubscription;
  StreamSubscription<ReceivedMessage>? _messageSubscription;
  StreamSubscription<GroupInvite>? _groupInviteSubscription;
  StreamSubscription<GroupMessage>? _groupMessageSubscription;
  StreamSubscription<ChatGroup>? _groupUpdateSubscription;

  List<ChatGroup> _chatGroups = [];
  List<ChatGroup> _demoChatGroups = [];
  final List<_NoticeEntry> _notices = [];
  StreamSubscription<TopologyResponse>? _topologySubscription;
  StreamSubscription<List<String>>? _lanPeersSubscription;
  StreamSubscription<TransferEvent>? _transferSubscription;
  Timer? _chatCleanupTimer;
  List<Contact> _contacts = [];
  Set<String> _chatContactCodes = {};
  Map<String, int> _unreadCounts = {};
  Set<String> _incomingContactIds = {};
  String? _activeTopologyRequestId;
  final Map<String, TopologyResponse> _topologyResponses = {};
  List<Contact> _demoContacts = const [];
  List<Contact> _demoSavedContacts = const [];
  List<TopologyResponse> _demoTopologyResponses = const [];
  bool _showScanNodeCounts = false;
  AppSettings _settings = const AppSettings();
  HomeFilter _filter = HomeFilter.all;
  _HomeSection _section = _HomeSection.home;
  bool _bluetoothEnabled = true;
  bool _lanEnabled = true;
  bool _isScanning = false;
  Map<TransportKind, TransportStatus> _transports = const {
    TransportKind.lan: TransportStatus(
      kind: TransportKind.lan,
      enabled: true,
      available: true,
    ),
    TransportKind.bluetooth: TransportStatus(
      kind: TransportKind.bluetooth,
      enabled: true,
      available: true,
    ),
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadContacts();
    _loadNotices();
    _contactsSubscription = _contactService.contactsStream.listen((contacts) {
      if (mounted) setState(() => _contacts = sortContacts(contacts));
    });
    _messageSubscription = MessagingService().messageStream.listen((msg) {
      _playIncomingMessageAlert();
      if (msg.isNotice && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('📢 공지: ${msg.text}'),
            duration: const Duration(seconds: 10),
            backgroundColor: const Color(0xFFFF9800).withValues(alpha: 0.95),
          ),
        );
        final senderHex = msg.senderNodeId
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final sender = _contacts.cast<Contact?>().firstWhere(
          (c) => contactCode(c!) == senderHex,
          orElse: () => null,
        );
        final senderName = sender != null
            ? contactDisplayName(sender)
            : senderHex.substring(0, 8);
        final entry = _NoticeEntry(
          senderName: senderName,
          text: msg.text,
          timestamp: msg.timestamp,
          isLong: false,
        );
        setState(() => _notices.add(entry));
        DatabaseService().saveNotice(
          senderName: entry.senderName,
          text: entry.text,
          timestamp: entry.timestamp,
          isLong: entry.isLong,
        );
      }
      _loadChatContactCodes();
      _loadUnreadCounts();
    });
    _transferSubscription = TransferService().transferStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _incomingContactIds = TransferService().incomingContactIds;
        if (event is TransferCompleted && event.direction == TransferDirection.incoming) {
          _unreadCounts[event.contactNodeIdHex] =
              (_unreadCounts[event.contactNodeIdHex] ?? 0) + 1;
        }
      });
    });
    _topologySubscription = MessagingService().topologyStream.listen((
      response,
    ) {
      if (!mounted) return;
      final activeRequestId = _activeTopologyRequestId;
      if (activeRequestId != null && response.requestId != activeRequestId) {
        return;
      }
      setState(() {
        _topologyResponses[_nodeHex(response.responder.nodeId)] = response;
      });
    });
    _chatCleanupTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _loadChatContactCodes(),
    );
    _settingsSubscription = _settingsService.settingsStream.listen((settings) {
      if (!mounted) return;
      unawaited(_ensureSelfContact(settings));
      _syncDemoTopology(settings.demoMode);
      setState(() {
        _settings = settings;
        _scanDepthController.text = settings.scanDefaultDepth.toString();
      });
    });
    _lanPeersSubscription = MessagingService().lanPeersStream.listen((_) {
      if (mounted) setState(() {});
    });
    _searchController.addListener(_refresh);
    _scanDepthController.addListener(_refresh);

    _loadChatGroups();
    _groupInviteSubscription = _groupMessaging.inviteStream.listen(
      _handleIncomingGroupInvite,
    );
    _groupMessageSubscription = _groupMessaging.messageStream.listen((_) {
      _loadChatGroups();
    });
    _groupUpdateSubscription = _groupMessaging.updateStream.listen((_) {
      _loadChatGroups();
    });
  }

  @override
  void dispose() {
    _contactsSubscription?.cancel();
    _settingsSubscription?.cancel();
    _lanPeersSubscription?.cancel();
    _messageSubscription?.cancel();
    _topologySubscription?.cancel();
    _transferSubscription?.cancel();
    _chatCleanupTimer?.cancel();
    _groupInviteSubscription?.cancel();
    _groupMessageSubscription?.cancel();
    _groupUpdateSubscription?.cancel();
    _searchController
      ..removeListener(_refresh)
      ..dispose();
    _scanDepthController
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  Future<void> _loadChatGroups() async {
    if (_settings.demoMode) {
      if (mounted) setState(() {});
      return;
    }
    final groups = await _groupService.getAllGroups();
    if (!mounted) return;
    setState(() => _chatGroups = groups);
  }

  void _handleIncomingGroupInvite(GroupInvite invite) {
    if (!mounted) return;
    final groupName = invite.groupName;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('그룹 초대'),
        content: Text('[$groupName] 그룹에 초대되었습니다.\n수락하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _groupMessaging.sendInviteResponse(
                groupId: invite.groupId,
                toNodeId: invite.fromNodeId,
                accepted: false,
              );
            },
            child: const Text('거절'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _groupService.acceptInvite(invite);
              await _groupMessaging.sendInviteResponse(
                groupId: invite.groupId,
                toNodeId: invite.fromNodeId,
                accepted: true,
              );
              _loadChatGroups();
            },
            child: const Text('수락'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadNotices() async {
    final rows = await DatabaseService().loadNotices();
    if (!mounted) return;
    setState(() {
      _notices
        ..clear()
        ..addAll(rows.map((r) => _NoticeEntry(
              senderName: r['sender_name'] as String,
              text: r['text'] as String,
              timestamp: r['timestamp'] as int,
              isLong: (r['is_long'] as int) == 1,
            )));
    });
  }

  Future<void> _loadContacts() async {
    final contacts = await _contactService.getAllContacts();
    if (mounted) setState(() => _contacts = sortContacts(contacts));
    await _loadChatContactCodes();
    await _loadUnreadCounts();
  }

  Future<void> _loadChatContactCodes() async {
    final nodeIds = await DatabaseService().getContactNodeIdsWithMessages(
      IdentityService().myNodeId,
    );
    if (!mounted) return;
    setState(() => _chatContactCodes = nodeIds.map(_hex).toSet());
  }

  Future<void> _loadUnreadCounts() async {
    final counts = await DatabaseService().getUnreadMessageCounts(
      IdentityService().myNodeId,
    );
    if (!mounted) return;
    setState(() => _unreadCounts = counts);
  }

  Future<void> _loadSettings() async {
    final settings = await _settingsService.load();
    await _ensureSelfContact(settings);
    _syncDemoTopology(settings.demoMode);
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _scanDepthController.text = settings.scanDefaultDepth.toString();
    });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _playIncomingMessageAlert() {
    switch (_settings.messageAlertMode) {
      case MessageAlertMode.sound:
        unawaited(_playNativeAlert());
      case MessageAlertMode.vibration:
        unawaited(_vibrateNativeAlert());
      case MessageAlertMode.silent:
        break;
    }
  }

  Future<void> _playNativeAlert() async {
    try {
      await _alertChannel.invokeMethod<void>('playAlert');
    } catch (_) {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  Future<void> _vibrateNativeAlert() async {
    try {
      await _alertChannel.invokeMethod<void>('vibrate');
    } catch (_) {
      await HapticFeedback.vibrate();
    }
  }

  TransportStatus _transport(TransportKind kind) => _transports[kind]!;

  Future<void> _toggleBluetooth() async {
    final enable = !_bluetoothEnabled;
    setState(() {
      _bluetoothEnabled = enable;
      _transports = Map.of(_transports)
        ..[TransportKind.bluetooth] = _transports[TransportKind.bluetooth]!
            .copyWith(enabled: enable);
    });

    if (enable) {
      await _bleService.startScan();
      if (Platform.isAndroid) await _bleService.startAdvertising();
      return;
    }

    setState(() => _isScanning = false);
    await _bleService.stopScan();
    if (Platform.isAndroid) await _bleService.stopAdvertising();
    for (final deviceId in List<String>.from(_bleService.connectedDeviceIds)) {
      await _bleService.disconnect(deviceId);
    }
  }

  Future<void> _toggleLan() async {
    final enable = !_lanEnabled;
    setState(() {
      _lanEnabled = enable;
      _transports = Map.of(_transports)
        ..[TransportKind.lan] = _transports[TransportKind.lan]!
            .copyWith(enabled: enable);
    });
    if (enable) {
      await MessagingService().startLan();
    } else {
      await MessagingService().stopLan();
    }
  }

  Future<void> _runScan() async {
    if (_settings.demoMode) {
      setState(() {
        _isScanning = false;
        _syncDemoTopology(true);
        _scanDepthController.text = '5';
      });
      return;
    }

    if (!_bluetoothEnabled) {
      _showMessage('Bluetooth를 먼저 켜주세요.');
      return;
    }
    await _contactService.cleanupStaleContacts(
      staleAfter: const Duration(minutes: 5),
    );
    await _loadContacts();
    if (!mounted) return;
    setState(() {
      _isScanning = true;
      if (!_settings.demoMode) {
        _demoContacts = const [];
        _demoTopologyResponses = const [];
      }
      _activeTopologyRequestId = null;
      _topologyResponses.clear();
    });
    await _bleService.startScan();
    await MessagingService().broadcastKeyAnnounce();
    final scanDepth =
        int.tryParse(_scanDepthController.text.trim()) ??
        _settings.scanDefaultDepth;
    final requestId = await MessagingService().requestTopologyScan(
      depth: _limitedScanDepth(scanDepth),
    );
    if (mounted && requestId != null) {
      setState(() => _activeTopologyRequestId = requestId);
    }
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 3),
        () => MessagingService().broadcastKeyAnnounce(),
      ),
    );
    Future<void>.delayed(const Duration(seconds: 10), () {
      if (mounted) setState(() => _isScanning = false);
    });
  }

  void _syncDemoTopology(bool enabled) {
    if (!enabled) {
      _demoContacts = const [];
      _demoSavedContacts = const [];
      _demoTopologyResponses = const [];
      _demoChatGroups = [];
      return;
    }

    final scenario = DemoTopologyScenario.large();
    _demoContacts = scenario.directContacts;
    _demoSavedContacts = scenario.allContacts();
    _demoTopologyResponses = scenario.responses;
    _activeTopologyRequestId = 'demo-large';
    _topologyResponses.clear();
    _demoChatGroups = _buildDemoChatGroups(_demoSavedContacts);
  }

  List<ChatGroup> _buildDemoChatGroups(List<Contact> contacts) {
    final grouped = <String, List<Contact>>{};
    for (final c in contacts) {
      final g = c.groupName;
      if (g != null && g.isNotEmpty) grouped.putIfAbsent(g, () => []).add(c);
    }
    final myNodeId = IdentityService().myNodeId;
    final now = DateTime.now().millisecondsSinceEpoch;
    return grouped.entries.map((entry) {
      final members = entry.value;
      return ChatGroup(
        groupId: 'demo-${entry.key.toLowerCase().replaceAll(' ', '-')}',
        name: entry.key,
        leaderId: members.first.nodeId,
        members: [
          GroupMember(nodeId: myNodeId, joinedAt: now),
          ...members.map((c) => GroupMember(nodeId: c.nodeId, joinedAt: now)),
        ],
        createdAt: now,
      );
    }).toList();
  }

  Future<void> _openQrScreen() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const QrScreen()),
    );
    if (!mounted) return;
    _goHome();
  }

  Future<void> _openChat(Contact contact) async {
    if (!canOpenChatWithContact(_settings.userLevel, contact)) {
      final message = !_settings.userLevel.canSendMessages
          ? 'Server mode only relays messages. Chat is disabled.'
          : '${contactDisplayName(contact)} is Server mode. Chat is disabled.';
      _showMessage(message);
      return;
    }
    if (_settings.demoMode) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _DemoChatScreen(
            self: _demoSelfSummary(),
            contact: contact,
            scenario: DemoTopologyScenario.large(),
          ),
        ),
      );
      if (!mounted) return;
      _goHome();
      return;
    }
    await DatabaseService().markMessagesReadForContact(
      contact.nodeId,
      IdentityService().myNodeId,
    );
    await _loadUnreadCounts();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(contact: contact)),
    );
    await DatabaseService().markMessagesReadForContact(
      contact.nodeId,
      IdentityService().myNodeId,
    );
    await _loadChatContactCodes();
    await _loadUnreadCounts();
    if (!mounted) return;
    _goHome();
  }

  void _goHome() {
    if (!mounted) return;
    setState(() {
      _section = _HomeSection.home;
      _filter = HomeFilter.all;
    });
  }

  Future<void> _addScannedContact(Contact contact) async {
    if (_settings.demoMode) {
      final savedDemoContact = _copyDemoContact(contact, isSaved: true);
      setState(() {
        final savedIds = _demoSavedContacts
            .map((item) => _nodeHex(item.nodeId))
            .toSet();
        if (!savedIds.contains(_nodeHex(contact.nodeId))) {
          _demoSavedContacts = [..._demoSavedContacts, savedDemoContact];
        } else {
          _demoSavedContacts = _demoSavedContacts
              .map(
                (item) => _bytesEqual(item.nodeId, contact.nodeId)
                    ? savedDemoContact
                    : item,
              )
              .toList();
        }
        _demoContacts = _demoContacts
            .map(
              (item) => _bytesEqual(item.nodeId, contact.nodeId)
                  ? savedDemoContact
                  : item,
            )
            .toList();
      });
      _showMessage('${contactDisplayName(savedDemoContact)} added in demo.');
      return;
    }
    final saved = await _contactService.setSaved(contact.nodeId, true);
    if (!saved) {
      final limit = _settings.userLevel.savedContactLimit ?? 0;
      _showMessage(
        'Contact limit reached: ${_settings.userLevel.label} can save $limit contacts.',
      );
      return;
    }
    await _loadContacts();
    _showMessage('${contactDisplayName(contact)} 연락처에 추가했습니다.');
  }

  void _openGroupChat(ChatGroup group) {
    if (!_settings.userLevel.canSendMessages) {
      _showMessage('Server mode only relays messages. Group chat is disabled.');
      return;
    }
    if (_settings.demoMode) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _DemoGroupChatScreen(
            self: _demoSelfSummary(),
            group: group,
            allContacts: _demoSavedContacts,
          ),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupChatScreen(group: group, contacts: _contacts),
      ),
    ).then((_) => _loadChatGroups());
  }

  Future<void> _inviteToGroupChat(Contact contact) async {
    if (!mounted) return;
    final myNodeId = IdentityService().myNodeId;

    // Show a dialog: pick existing group or create new
    final groups = _settings.demoMode ? _demoChatGroups : _chatGroups;
    final availableGroups = groups
        .where((g) => !g.isFull && !g.hasMember(contact.nodeId))
        .toList();

    String? result;
    if (!mounted) return;
    result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setDs) => AlertDialog(
            title: const Text('그룹 채팅에 초대'),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (availableGroups.isNotEmpty) ...[
                    const Text(
                      '기존 그룹 선택',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    ...availableGroups.map(
                      (g) => ListTile(
                        dense: true,
                        title: Text(g.name),
                        subtitle: Text('${g.memberCount}명'),
                        onTap: () => Navigator.pop(ctx, 'existing:${g.groupId}'),
                      ),
                    ),
                    const Divider(),
                  ],
                  const Text(
                    '새 그룹 만들기',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      hintText: '그룹 이름 입력',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => Navigator.pop(ctx, 'new:${controller.text}'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'new:${controller.text}'),
                child: const Text('초대'),
              ),
            ],
          ),
        );
      },
    );

    if (result == null || !mounted) return;

    if (result.startsWith('existing:')) {
      final groupId = result.substring('existing:'.length);
      final group = (_settings.demoMode ? _demoChatGroups : _chatGroups)
          .firstWhere((g) => g.groupId == groupId, orElse: () => throw StateError('not found'));
      if (_settings.demoMode) {
        _showMessage('${contactDisplayName(contact)}을(를) ${group.name}에 초대했습니다. (Demo)');
        return;
      }
      await _groupService.addMember(groupId, contact.nodeId);
      await _groupMessaging.sendInvite(group: group, targetNodeId: contact.nodeId);
      _loadChatGroups();
    } else if (result.startsWith('new:')) {
      final name = result.substring('new:'.length).trim();
      if (name.isEmpty) return;
      if (_settings.demoMode) {
        _showMessage('[$name] Demo 그룹에 ${contactDisplayName(contact)}을(를) 초대했습니다.');
        return;
      }
      final group = await _groupService.createGroup(name: name, myNodeId: myNodeId);
      await _groupMessaging.sendInvite(group: group, targetNodeId: contact.nodeId);
      _loadChatGroups();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _showNoticeDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _NoticeSendDialog(
        settings: _settings,
        onSent: (text, mode) {
          if (!mounted) return;
          final name = _settings.displayName.trim();
          final senderName = name.isNotEmpty ? name : '나';
          final entry = _NoticeEntry(
            senderName: senderName,
            text: text,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            isLong: mode == MessageSendMode.longNotice,
          );
          setState(() => _notices.add(entry));
          DatabaseService().saveNotice(
            senderName: entry.senderName,
            text: entry.text,
            timestamp: entry.timestamp,
            isLong: entry.isLong,
          );
        },
      ),
    );
  }

  Future<Contact> _ensureSelfContact([AppSettings? settings]) {
    final current = settings ?? _settings;
    return _contactService.ensureSelfContact(
      nodeId: IdentityService().myNodeId,
      publicKey: IdentityService().myPublicKey,
      encryptionPublicKey: IdentityService().myEncryptionPublicKey,
      displayName: current.displayName,
      avatarKey: current.avatarKey,
      userLevel: current.userLevel,
      deviceType: IdentityService().myDeviceType,
    );
  }

  Contact? _storedSelfContact() {
    final myNodeId = IdentityService().myNodeId;
    for (final contact in _contacts) {
      if (_bytesEqual(contact.nodeId, myNodeId)) return contact;
    }
    return null;
  }

  Contact _selfContact() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final stored = _storedSelfContact();
    return Contact(
      nodeId: IdentityService().myNodeId,
      publicKey: IdentityService().myPublicKey,
      encryptionPublicKey: IdentityService().myEncryptionPublicKey,
      displayName: _settings.displayName,
      isTrusted: true,
      fingerprint: IdentityService().myFingerprint,
      firstSeen: stored?.firstSeen ?? nowMs,
      lastSeen: stored?.lastSeen ?? nowMs,
      isFavorite: stored?.isFavorite ?? false,
      groupName: stored?.groupName,
      deviceType: IdentityService().myDeviceType,
      avatarKey: _settings.avatarKey,
      isSaved: true,
      userLevel: _settings.userLevel,
    );
  }

  List<Contact> _savedContactsExcludingSelf() {
    if (_settings.demoMode) return _demoSavedContacts;
    final myNodeId = IdentityService().myNodeId;
    return _contacts
        .where(
          (contact) =>
              contact.isSaved && !_bytesEqual(contact.nodeId, myNodeId),
        )
        .toList();
  }

  TopologyNodeSummary _demoSelfSummary() {
    return TopologyNodeSummary(
      nodeId: IdentityService().myNodeId,
      displayName: _settings.displayName.trim().isEmpty
          ? 'Me'
          : _settings.displayName.trim(),
      deviceType: IdentityService().myDeviceType,
      userLevel: _settings.userLevel,
      isSaved: true,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
    );
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _nodeHex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _showSettings() async {
    final nextSettings = await showDialog<AppSettings>(
      context: context,
      builder: (context) => _SettingsDialog(
        initialSettings: _settings,
        onBackupIdentity: _backupIdentity,
        onRestoreIdentity: _restoreIdentity,
        onCleanupStaleContacts: _cleanupStaleContacts,
        onDeleteAllContacts: _deleteAllContacts,
        onDeleteAllMessages: _deleteAllMessages,
      ),
    );
    if (nextSettings == null) return;

    // Let Android finish closing the IME/dialog before broadcasting a theme
    // rebuild to the whole app.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _saveSelfSettings(nextSettings);
    if (!mounted) return;
    setState(() {
      _settings = nextSettings;
      _scanDepthController.text = nextSettings.scanDefaultDepth.toString();
    });
  }

  Future<void> _powerOff() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('MeshComm 종료'),
        content: const Text('BLE 연결을 닫고 프로그램을 종료할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('종료'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await MessagingService().dispose();
    await _bleService.dispose();
    if (Platform.isWindows || Platform.isLinux) {
      exit(0);
    }
    await SystemNavigator.pop();
  }

  Future<void> _handleContactAction(
    Contact contact,
    _ContactAction action,
  ) async {
    if (_settings.demoMode &&
        !_bytesEqual(contact.nodeId, IdentityService().myNodeId)) {
      await _handleDemoContactAction(contact, action);
      return;
    }
    if (_bytesEqual(contact.nodeId, IdentityService().myNodeId)) {
      await _handleSelfContactAction(contact, action);
      return;
    }
    switch (action) {
      case _ContactAction.rename:
        await _renameContact(contact);
      case _ContactAction.toggleTrust:
        await _contactService.setTrusted(contact.nodeId, !contact.isTrusted);
      case _ContactAction.toggleFavorite:
        await _contactService.setFavorite(contact.nodeId, !contact.isFavorite);
      case _ContactAction.inviteToGroup:
        await _inviteToGroupChat(contact);
      case _ContactAction.setAvatar:
        await _setContactAvatar(contact);
      case _ContactAction.setLevel:
        await _setContactLevel(contact);
      case _ContactAction.deleteMessages:
        await _deleteContactMessages(contact);
      case _ContactAction.delete:
        await _deleteContact(contact);
    }
  }

  Future<void> _handleDemoContactAction(
    Contact contact,
    _ContactAction action,
  ) async {
    switch (action) {
      case _ContactAction.rename:
        final name = await _askForText(
          title: 'Demo rename',
          label: 'Display name',
          initialValue: contact.displayName ?? '',
          hint: 'Demo mode only. Real contacts are not changed.',
        );
        if (name == null) return;
        _replaceDemoContact(
          contact.nodeId,
          (current) => _copyDemoContact(
            current,
            displayName: name.trim().isEmpty ? null : name.trim(),
          ),
        );
      case _ContactAction.toggleTrust:
        _replaceDemoContact(
          contact.nodeId,
          (current) => _copyDemoContact(current, isTrusted: !current.isTrusted),
        );
      case _ContactAction.toggleFavorite:
        _replaceDemoContact(
          contact.nodeId,
          (current) =>
              _copyDemoContact(current, isFavorite: !current.isFavorite),
        );
      case _ContactAction.inviteToGroup:
        await _inviteToGroupChat(contact);
      case _ContactAction.setAvatar:
        var selectedKey = contact.avatarKey ?? AvatarRegistry.defaultKey;
        final nextKey = await showDialog<String>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('Demo avatar'),
              content: SizedBox(
                width: 300,
                child: AvatarPickerGrid(
                  selectedKey: selectedKey,
                  onSelected: (key) => setDialogState(() => selectedKey = key),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, selectedKey),
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        );
        if (nextKey == null) return;
        _replaceDemoContact(
          contact.nodeId,
          (current) => _copyDemoContact(current, avatarKey: nextKey),
        );
      case _ContactAction.setLevel:
        await _setDemoContactLevel(contact);
      case _ContactAction.deleteMessages:
        _showMessage('Demo messages are cleared when you leave demo chat.');
      case _ContactAction.delete:
        setState(() {
          _demoSavedContacts = _demoSavedContacts
              .where((item) => !_bytesEqual(item.nodeId, contact.nodeId))
              .toList();
          _demoContacts = _demoContacts
              .where((item) => !_bytesEqual(item.nodeId, contact.nodeId))
              .toList();
        });
    }
  }

  Future<void> _handleSelfContactAction(
    Contact contact,
    _ContactAction action,
  ) async {
    switch (action) {
      case _ContactAction.rename:
        await _renameSelfContact(contact);
      case _ContactAction.toggleTrust:
        await _contactService.setTrusted(contact.nodeId, true);
      case _ContactAction.toggleFavorite:
        await _contactService.setFavorite(contact.nodeId, !contact.isFavorite);
      case _ContactAction.inviteToGroup:
        _showMessage('자신을 그룹에 초대할 수 없습니다.');
      case _ContactAction.setAvatar:
        await _setSelfAvatar(contact);
      case _ContactAction.setLevel:
        await _setSelfLevel();
      case _ContactAction.deleteMessages:
        await _deleteContactMessages(contact);
      case _ContactAction.delete:
        _showMessage('This device contact cannot be deleted.');
    }
    await _ensureSelfContact();
    await _loadContacts();
  }

  Future<void> _handleGroupAction(
    ChatGroup group,
    _GroupAction action,
  ) async {
    if (_settings.demoMode) {
      await _handleDemoGroupAction(group, action);
      return;
    }
    switch (action) {
      case _GroupAction.rename:
        await _renameChatGroup(group);
      case _GroupAction.delete:
        await _groupService.deleteGroup(group.groupId);
        _loadChatGroups();
    }
  }

  Future<void> _handleDemoGroupAction(
    ChatGroup group,
    _GroupAction action,
  ) async {
    switch (action) {
      case _GroupAction.rename:
        final name = await _askForText(
          title: 'Demo group rename',
          label: 'Group name',
          initialValue: group.name,
          hint: 'Demo mode only.',
        );
        if (name == null || name.trim().isEmpty) return;
        setState(() {
          _demoChatGroups = _demoChatGroups
              .map((g) => g.groupId == group.groupId ? g.copyWith(name: name.trim()) : g)
              .toList();
        });
      case _GroupAction.delete:
        setState(() {
          _demoChatGroups = _demoChatGroups
              .where((g) => g.groupId != group.groupId)
              .toList();
        });
    }
  }

  Future<void> _renameContact(Contact contact) async {
    final name = await _askForText(
      title: '이름 변경',
      label: '로컬 표시 이름',
      initialValue: contact.displayName ?? '',
      hint: '비워두면 node ID로 표시됩니다.',
    );
    if (name == null) return;
    final trimmed = name.trim();
    await _contactService.renameContact(
      contact.nodeId,
      trimmed.isEmpty ? null : trimmed,
    );
  }

  Future<void> _renameSelfContact(Contact contact) async {
    final name = await _askForText(
      title: 'Rename',
      label: 'My name',
      initialValue: contact.displayName ?? _settings.displayName,
      hint: 'Empty name becomes Me',
    );
    if (name == null) return;
    final displayName = name.trim().isEmpty ? 'Me' : name.trim();
    await _saveSelfSettings(_settings.copyWith(displayName: displayName));
  }


  Future<void> _setContactAvatar(Contact contact) async {
    var selectedKey = contact.avatarKey ?? AvatarRegistry.defaultKey;
    final nextKey = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Avatar'),
              content: SizedBox(
                width: 300,
                child: AvatarPickerGrid(
                  selectedKey: selectedKey,
                  onSelected: (key) {
                    setDialogState(() => selectedKey = key);
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, selectedKey),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (nextKey == null) return;
    await _contactService.setAvatar(contact.nodeId, nextKey);
  }

  Future<void> _setSelfAvatar(Contact contact) async {
    var selectedKey = contact.avatarKey ?? _settings.avatarKey;
    final nextKey = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Avatar'),
              content: SizedBox(
                width: 300,
                child: AvatarPickerGrid(
                  selectedKey: selectedKey,
                  onSelected: (key) {
                    setDialogState(() => selectedKey = key);
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, selectedKey),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (nextKey == null) return;
    await _saveSelfSettings(_settings.copyWith(avatarKey: nextKey));
  }

  Future<void> _setSelfLevel() async {
    final levels = _settings.userLevel.selfSelectableLevels;
    if (levels.length <= 1) {
      _showMessage('This level is fixed on this device.');
      return;
    }
    var selected = _settings.userLevel;
    final nextLevel = await showDialog<UserLevel>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('My level'),
          content: DropdownButton<UserLevel>(
            value: selected,
            isExpanded: true,
            items: [
              for (final level in levels)
                DropdownMenuItem(value: level, child: Text(level.label)),
            ],
            onChanged: (level) {
              if (level != null) setDialogState(() => selected = level);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (nextLevel == null) return;
    await _saveSelfSettings(_settings.copyWith(userLevel: nextLevel));
  }

  Future<void> _setContactLevel(Contact contact) async {
    if (!_settings.userLevel.canAssignContactLevels) {
      _showMessage(
        'Only Admin, Builder, or Creator can change contact levels.',
      );
      return;
    }
    if (!_settings.userLevel.canChangeContactLevel(contact.userLevel)) {
      _showMessage(
        'Cannot change ${contact.userLevel.label}; only lower levels can be changed.',
      );
      return;
    }
    final levels = _settings.userLevel.contactAssignableLevels;
    var selected = levels.contains(contact.userLevel)
        ? contact.userLevel
        : levels.first;
    final nextLevel = await showDialog<UserLevel>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Contact level'),
          content: DropdownButton<UserLevel>(
            value: selected,
            isExpanded: true,
            items: [
              for (final level in levels)
                DropdownMenuItem(value: level, child: Text(level.label)),
            ],
            onChanged: (level) {
              if (level != null) setDialogState(() => selected = level);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (nextLevel == null) return;
    try {
      await _contactService.setUserLevel(contact.nodeId, nextLevel);
    } catch (_) {
      _showMessage('Not authorized to change this level.');
      return;
    }
    if (!_settings.demoMode) {
      final sent = await MessagingService().sendLevelChangeRequest(
        targetNodeId: contact.nodeId,
        level: nextLevel,
      );
      if (!sent) {
        _showMessage(
          'Level saved locally. Remote update will retry when connected.',
        );
      }
    }
  }

  Future<void> _setDemoContactLevel(Contact contact) async {
    if (!_settings.userLevel.canAssignContactLevels) {
      _showMessage(
        'Only Admin, Builder, or Creator can change contact levels.',
      );
      return;
    }
    if (!_settings.userLevel.canChangeContactLevel(contact.userLevel)) {
      _showMessage(
        'Cannot change ${contact.userLevel.label}; only lower levels can be changed.',
      );
      return;
    }
    final levels = _settings.userLevel.contactAssignableLevels;
    var selected = levels.contains(contact.userLevel)
        ? contact.userLevel
        : levels.first;
    final nextLevel = await showDialog<UserLevel>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Demo contact level'),
          content: DropdownButton<UserLevel>(
            value: selected,
            isExpanded: true,
            items: [
              for (final level in levels)
                DropdownMenuItem(value: level, child: Text(level.label)),
            ],
            onChanged: (level) {
              if (level != null) setDialogState(() => selected = level);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (nextLevel == null) return;
    _replaceDemoContact(
      contact.nodeId,
      (current) => _copyDemoContact(current, userLevel: nextLevel),
    );
  }

  void _replaceDemoContact(
    Uint8List nodeId,
    Contact Function(Contact contact) transform,
  ) {
    _replaceAllDemoContacts(
      (contact) =>
          _bytesEqual(contact.nodeId, nodeId) ? transform(contact) : contact,
    );
  }

  void _replaceAllDemoContacts(Contact Function(Contact contact) transform) {
    setState(() {
      _demoSavedContacts = _demoSavedContacts.map(transform).toList();
      _demoContacts = _demoContacts.map(transform).toList();
    });
  }

  Contact _copyDemoContact(
    Contact contact, {
    Object? displayName = _demoNoChange,
    bool? isTrusted,
    bool? isFavorite,
    Object? groupName = _demoNoChange,
    MeshDeviceType? deviceType,
    Object? avatarKey = _demoNoChange,
    bool? isSaved,
    UserLevel? userLevel,
  }) {
    return Contact(
      nodeId: contact.nodeId,
      publicKey: contact.publicKey,
      encryptionPublicKey: contact.encryptionPublicKey,
      displayName: identical(displayName, _demoNoChange)
          ? contact.displayName
          : displayName as String?,
      isTrusted: isTrusted ?? contact.isTrusted,
      fingerprint: contact.fingerprint,
      firstSeen: contact.firstSeen,
      lastSeen: contact.lastSeen,
      isFavorite: isFavorite ?? contact.isFavorite,
      groupName: identical(groupName, _demoNoChange)
          ? contact.groupName
          : groupName as String?,
      deviceType: deviceType ?? contact.deviceType,
      avatarKey: identical(avatarKey, _demoNoChange)
          ? contact.avatarKey
          : avatarKey as String?,
      isSaved: isSaved ?? contact.isSaved,
      userLevel: userLevel ?? contact.userLevel,
    );
  }

  Future<void> _renameChatGroup(ChatGroup group) async {
    final name = await _askForText(
      title: 'Group 이름 변경',
      label: '그룹 이름',
      initialValue: group.name,
      hint: '그룹 이름을 변경합니다.',
    );
    if (name == null || name.trim().isEmpty) return;
    await _groupService.renameGroup(group.groupId, name.trim());
    _loadChatGroups();
  }

  Future<String?> _askForText({
    required String title,
    required String label,
    required String initialValue,
    required String hint,
  }) {
    var value = initialValue;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initialValue,
          autofocus: true,
          maxLength: 40,
          onChanged: (next) => value = next,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('저장'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteContact(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('연락처 삭제'),
        content: Text(
          '${contactDisplayName(contact)} 연락처를 목록에서 삭제합니다.\n\n'
          '채팅 기록은 유지되며, 다시 발견되면 연락처가 다시 추가될 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _contactService.deleteContact(contact.nodeId);
    }
  }

  Future<void> _deleteContactMessages(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete messages'),
        content: Text(
          'Delete all messages with ${contactDisplayName(contact)}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await DatabaseService().deleteMessagesForContact(
      contact.nodeId,
      myNodeId: IdentityService().myNodeId,
    );
    await _loadChatContactCodes();
    await _loadUnreadCounts();
    _showMessage('Deleted $count messages.');
  }

  Future<void> _deleteAllMessages() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all messages'),
        content: const Text('Delete all local message history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await DatabaseService().deleteAllMessages();
    await _loadChatContactCodes();
    await _loadUnreadCounts();
    _showMessage('Deleted $count messages.');
  }

  Future<void> _saveSelfSettings(AppSettings settings) async {
    await _settingsService.save(settings);
    await _ensureSelfContact(settings);
    await MessagingService().broadcastKeyAnnounce();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _scanDepthController.text = settings.scanDefaultDepth.toString();
    });
  }

  Future<void> _importContacts() => _showImportDialog();
  Future<void> _exportContacts() => _showExportDialog();

  Future<void> _showExportDialog() async {
    final contacts = _savedContactsExcludingSelf();
    final result = await showDialog<({List<Contact> contacts, bool includeConversations})>(
      context: context,
      builder: (context) => _ExportDialog(contacts: contacts),
    );
    if (result == null) return;

    final ts = DateTime.now().millisecondsSinceEpoch;
    final saved = <String>[];

    try {
      // ── 연락처 파일 ────────────────────────────────────────────
      if (result.contacts.isNotEmpty) {
        final json = await _contactFileService.exportContactsToJson(result.contacts);
        final name = 'mesh_comm_contacts_$ts.json';
        final path = await _saveJsonFile(json, name);
        if (path == null) return; // 사용자가 취소
        saved.add(path);
      }

      // ── 대화 파일 ─────────────────────────────────────────────
      if (result.includeConversations) {
        final json = await _contactFileService.exportConversationsToJson();
        final name = 'mesh_comm_conversations_$ts.json';
        final path = await _saveJsonFile(json, name);
        if (path == null) return; // 사용자가 취소
        saved.add(path);
      }

      if (saved.isNotEmpty) {
        _showMessage('Export 완료 (${saved.length}개 파일)');
      }
    } catch (e) {
      _showMessage('Export 실패: $e');
    }
  }

  Future<String?> _saveJsonFile(String json, String filename) async {
    final meshDir = await TransferStorageService.meshCommPublicDir();
    try {
      // Desktop(Windows): 파일 저장 다이얼로그
      final location = await getSaveLocation(
        suggestedName: filename,
        initialDirectory: meshDir.path,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (location == null) return null;
      await File(location.path).writeAsString(json);
      return location.path;
    } catch (_) {
      // Android: getSaveLocation 미지원 → 폴더 선택창 (선택 즉시 저장)
      String? dirPath;
      try {
        dirPath = await getDirectoryPath(initialDirectory: meshDir.path);
      } catch (_) {}
      // 사용자가 취소하거나 폴더 선택 미지원 시 기본 경로로 저장
      dirPath ??= meshDir.path;
      final file = File(p.join(dirPath, filename));
      await file.writeAsString(json);
      return file.path;
    }
  }

  Future<void> _showImportDialog() async {
    if (!mounted) return;
    final type = await showDialog<String>(
      context: context,
      builder: (context) => const _ImportDialog(),
    );
    if (type == null) return;

    try {
      final meshDir = await TransferStorageService.meshCommPublicDir();
      final file = await openFile(initialDirectory: meshDir.path);
      if (file == null) return;
      final rawJson = await file.readAsString();

      if (type == 'contacts') {
        final count = await _contactFileService.importContactsFromBackupJson(rawJson);
        await _loadContacts();
        _showMessage('$count개 연락처를 가져왔습니다.');
      } else {
        final count = await _contactFileService.importConversationsFromJson(rawJson);
        await _loadChatContactCodes();
        await _loadUnreadCounts();
        _showMessage('$count개 메시지를 가져왔습니다.');
      }
    } catch (e) {
      _showMessage('Import 실패: $e');
    }
  }

  Future<void> _deleteAllContacts() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('연락처 전부 지우기'),
        content: const Text('저장된 연락처를 모두 삭제합니까?\n대화 기록은 유지됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DatabaseService().deleteAllSavedContacts();
    await ContactService().refresh();
    if (!mounted) return;
    await _loadContacts();
    _showMessage('연락처를 모두 삭제했습니다.');
  }

  Future<void> _backupIdentity() async {
    try {
      final password = await _askIdentityBackupPassword(confirm: true);
      if (password == null) return;
      final json = await _identityBackupService.exportToJson(
        password: password,
      );
      final filename =
          'mesh_comm_identity_${DateTime.now().millisecondsSinceEpoch}.enc.json';
      String savedPath;

      final meshDir = await TransferStorageService.meshCommPublicDir();
      try {
        // Desktop: 파일 저장 다이얼로그
        final location = await getSaveLocation(
          suggestedName: filename,
          initialDirectory: meshDir.path,
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Encrypted MeshComm identity', extensions: ['json']),
          ],
        );
        if (location == null) return;
        await File(location.path).writeAsString(json);
        savedPath = location.path;
      } catch (_) {
        // Android: 폴더 선택창 (선택 즉시 저장)
        String? dirPath;
        try { dirPath = await getDirectoryPath(initialDirectory: meshDir.path); } catch (_) {}
        dirPath ??= meshDir.path;
        final file = File(p.join(dirPath, filename));
        await file.writeAsString(json);
        savedPath = file.path;
      }

      final autoFile = await _identityAutoBackupFile();
      await autoFile.writeAsString(json);

      _showMessage('Encrypted identity backup 저장 완료: $savedPath');
    } catch (e) {
      _showMessage('Identity backup 실패: $e');
    }
  }

  Future<File> _identityAutoBackupFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'mesh_comm_identity_auto.enc.json'));
  }

  Future<void> _restoreIdentity() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore identity'),
        content: const Text(
          'Identity를 복원하면 이 기기의 node ID가 백업 파일의 값으로 바뀝니다.\n\n'
          '복원 후에는 앱을 종료하고 다시 실행해야 적용됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final autoFile = await _identityAutoBackupFile();
      final hasAutoFile = await autoFile.exists();
      if (!mounted) return;
      final useAutoFile = hasAutoFile
          ? await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Use auto backup?'),
                content: Text('Use ${p.basename(autoFile.path)}?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Choose file'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Use backup'),
                  ),
                ],
              ),
            )
          : false;
      final rawJson = useAutoFile == true
          ? await autoFile.readAsString()
          : await (() async {
              final meshDir = await TransferStorageService.meshCommPublicDir();
              final file = await openFile(
                initialDirectory: meshDir.path,
                acceptedTypeGroups: const [
                  XTypeGroup(
                    label: 'Encrypted MeshComm identity',
                    extensions: ['json'],
                  ),
                ],
              );
              return file?.readAsString();
            })();
      if (rawJson == null) return;
      final password = await _askIdentityBackupPassword(confirm: false);
      if (password == null) return;

      final nodeId = await _identityBackupService.restoreFromJson(
        rawJson,
        password: password,
      );
      _showMessage(
        'Identity restore 완료: ${nodeId.substring(0, 8)}. 앱을 재시작해주세요.',
      );
    } catch (e) {
      _showMessage('Identity restore 실패: $e');
    }
  }

  Future<String?> _askIdentityBackupPassword({required bool confirm}) {
    var password = '';
    var confirmPassword = '';
    String? errorText;

    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(confirm ? 'Backup password' : 'Restore password'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  confirm
                      ? '이 암호는 identity backup 파일을 암호화합니다. 앱은 암호를 저장하지 않습니다.'
                      : 'Backup 때 정한 암호를 입력하세요.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    helperText: '8자 이상',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    password = value;
                    if (errorText != null) {
                      setDialogState(() => errorText = null);
                    }
                  },
                ),
                if (confirm) ...[
                  const SizedBox(height: 12),
                  TextField(
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Confirm password',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      confirmPassword = value;
                      if (errorText != null) {
                        setDialogState(() => errorText = null);
                      }
                    },
                  ),
                ],
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      errorText!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (password.length < 8) {
                  setDialogState(() => errorText = '암호는 8자 이상이어야 합니다.');
                  return;
                }
                if (confirm && password != confirmPassword) {
                  setDialogState(() => errorText = '암호가 일치하지 않습니다.');
                  return;
                }
                Navigator.pop(context, password);
              },
              child: Text(confirm ? 'Backup' : 'Restore'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cleanupStaleContacts() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clean stale contacts'),
        content: const Text(
          '다음 조건을 모두 만족하는 연락처만 삭제합니다.\n\n'
          '- 미확인 연락처\n'
          '- 즐겨찾기 아님\n'
          '- Group 없음\n'
          '- 메시지 이력 없음\n'
          '- 10분 이상 보이지 않음\n\n'
          '삭제된 연락처의 메시지 이력도 함께 삭제됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clean'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final removed = await _contactService.cleanupStaleContacts();
    await _loadContacts();
    _showMessage('$removed개 오래된 연락처를 정리했습니다.');
  }

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goHome();
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ColoredBox(
              color: scheme.surface,
              child: SafeArea(
                child: Column(
                  children: [
                    _buildSystemMenu(),
                    Expanded(child: _buildSection()),
                    _buildBottomMenu(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSystemMenu() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      height: 66,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Mesh\nComm',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    height: 1.0,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  AppVersion.shortLabel,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 8),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TransportButton(
                label: _transport(TransportKind.lan).kind.label,
                icon: Icons.wifi,
                enabled: _transport(TransportKind.lan).enabled,
                available: _transport(TransportKind.lan).available,
                onPressed: _toggleLan,
              ),
              _TransportButton(
                label: _transport(TransportKind.bluetooth).kind.label,
                icon: Icons.bluetooth,
                enabled: _transport(TransportKind.bluetooth).enabled,
                available: _transport(TransportKind.bluetooth).available,
                onPressed: _toggleBluetooth,
              ),
            ],
          ),
          Positioned(
            right: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Settings',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _showSettings,
                  icon: const Icon(Icons.settings_outlined, size: 19),
                ),
                IconButton(
                  tooltip: 'Power Off',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _powerOff,
                  icon: const Icon(Icons.power_settings_new, size: 19),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection() {
    return switch (_section) {
      _HomeSection.home => _buildHome(),
      _HomeSection.search => _buildSearch(),
      _HomeSection.scan => _buildScan(),
    };
  }

  Widget _buildHome() {
    return Row(
      children: [
        _FilterRail(
          selected: _filter,
          onSelected: (filter) => setState(() => _filter = filter),
          onImport: _importContacts,
          onExport: _exportContacts,
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _buildFilteredList()),
      ],
    );
  }

  Widget _buildFilteredList() {
    final selfContact = _selfContact();
    final savedContacts = _savedContactsExcludingSelf();
    if (_filter == HomeFilter.notices) {
      return _NoticePanel(
        notices: _notices,
        onSendNotice: () => _showNoticeDialog(context),
      );
    }
    if (_filter == HomeFilter.groups) {
      final groups = _settings.demoMode ? _demoChatGroups : _chatGroups;
      return _ChatGroupList(
        groups: groups,
        onTap: _openGroupChat,
        onAction: _handleGroupAction,
      );
    }

    final contacts = switch (_filter) {
      HomeFilter.favorites => [
        if (selfContact.isFavorite) selfContact,
        ...savedContacts.where((contact) => contact.isFavorite),
      ],
      HomeFilter.chats => [
        if (_chatContactCodes.contains(contactCode(selfContact))) selfContact,
        ...savedContacts.where(
          (contact) => _chatContactCodes.contains(contactCode(contact)),
        ),
      ],
      _ => [selfContact, ...savedContacts],
    };
    return _ContactList(
      contacts: contacts,
      unreadCounts: _unreadCounts,
      incomingContactIds: _incomingContactIds,
      onTap: _openChat,
      onAction: _handleContactAction,
      onScan: _runScan,
    );
  }

  Widget _buildSearch() {
    final savedContacts = [_selfContact(), ..._savedContactsExcludingSelf()];
    final allGroups = _settings.demoMode ? _demoChatGroups : _chatGroups;
    final groups = searchChatGroups(allGroups, _searchController.text);
    final contacts = searchContacts(savedContacts, _searchController.text);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: TextField(
            controller: _searchController,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '연락처 또는 Group 찾기',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              if (groups.isNotEmpty) const _SectionLabel(label: 'Groups'),
              for (final group in groups)
                _ChatGroupTile(
                  group: group,
                  onTap: () => _openGroupChat(group),
                  onAction: (action) => _handleGroupAction(group, action),
                ),
              if (contacts.isNotEmpty) const _SectionLabel(label: 'Contacts'),
              for (final contact in contacts)
                _ContactTile(
                  contact: contact,
                  unreadCount: _unreadCounts[contactCode(contact)] ?? 0,
                  isReceiving: _incomingContactIds.contains(contactCode(contact)),
                  onTap: () => _openChat(contact),
                  onAction: (action) => _handleContactAction(contact, action),
                ),
              if (groups.isEmpty && contacts.isEmpty)
                const _EmptyState(
                  icon: Icons.search_off,
                  title: '검색 결과가 없습니다.',
                  detail: '연락처 이름이나 Group 이름을 확인해주세요.',
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScan() {
    final parsedDepth =
        int.tryParse(_scanDepthController.text.trim()) ??
        _settings.scanDefaultDepth;
    final demoMode = _settings.demoMode;
    final depth = demoMode ? parsedDepth : _limitedScanDepth(parsedDepth);
    final visibleContacts = depth == 0
        ? <Contact>[]
        : demoMode
        ? _demoContacts
        : _scanVisibleContacts();
    final topologyResponses = demoMode
        ? _demoTopologyResponses
        : _topologyResponses.values.toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = math.min(220.0, constraints.maxWidth - 32);
              return Center(
                child: SizedBox(
                  width: math.max(168.0, width),
                  height: 40,
                  child: _ScanStartButton(
                    isScanning: _isScanning,
                    onPressed: _isScanning ? null : _runScan,
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: _ScanTreePreview(
            contacts: visibleContacts,
            knownContacts: demoMode ? _demoSavedContacts : _contacts,
            topologyResponses: topologyResponses,
            depth: depth,
            isScanning: _isScanning,
            myName: _settings.displayName,
            myDeviceType: IdentityService().myDeviceType,
            myUserLevel: _settings.userLevel,
            onOpenContact: _openChat,
            onAddContact: _addScannedContact,
            depthController: _scanDepthController,
            showNodeCounts: _showScanNodeCounts,
            onShowNodeCountsChanged: (value) {
              setState(() => _showScanNodeCounts = value);
            },
          ),
        ),
      ],
    );
  }

  int _limitedScanDepth(int depth) {
    final limit =
        _settings.userLevel == UserLevel.user ||
            _settings.userLevel == UserLevel.server
        ? 3
        : null;
    if (limit == null) return depth;
    if (depth == -1) return limit;
    return depth > limit ? limit : depth;
  }

  List<Contact> _scanVisibleContacts() {
    final recentCutoff =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(minutes: 3).inMilliseconds;
    final myNodeId = IdentityService().myNodeId;
    return _contacts
        .where(
          (contact) =>
              !_bytesEqual(contact.nodeId, myNodeId) &&
              (contact.isSaved || contact.lastSeen >= recentCutoff),
        )
        .toList();
  }

  Widget _buildBottomMenu() {
    final scheme = Theme.of(context).colorScheme;
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? _HomeScreenState.selectedColor(context)
                : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      child: NavigationBar(
        height: 66,
        selectedIndex: _section.index,
        onDestinationSelected: (index) {
          if (index == 3) {
            unawaited(_openQrScreen());
            return;
          }
          setState(() {
            _section = _HomeSection.values[index];
            if (index == 0) _filter = HomeFilter.all;
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.radar), label: 'SCAN'),
          NavigationDestination(icon: Icon(Icons.qr_code), label: 'QR'),
        ],
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final bool available;
  final VoidCallback? onPressed;

  const _TransportButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.available,
    // ignore: unused_element_parameter
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? _HomeScreenState.transportOnColor(context)
        : _HomeScreenState.transportOffColor(context);
    return Tooltip(
      message: available ? '$label On/Off' : '$label 지원 예정',
      child: InkWell(
        onTap: available ? onPressed : null,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 45,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: color, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanStartButton extends StatelessWidget {
  final bool isScanning;
  final VoidCallback? onPressed;

  const _ScanStartButton({required this.isScanning, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isScanning ? Icons.sync : Icons.radar, size: 19),
            const SizedBox(width: 8),
            Text(
              isScanning ? 'SCANNING' : 'SCAN START',
              maxLines: 1,
              softWrap: false,
            ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _TransportButtonOldRemoved extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final bool available;
  final VoidCallback? onPressed;

  const _TransportButtonOldRemoved({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.available,
    // ignore: unused_element_parameter
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? _HomeScreenState._accent
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: available ? '$label On/Off' : '$label 지원 예정',
      child: InkWell(
        onTap: available ? onPressed : null,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 45,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: color, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeEntry {
  final String senderName;
  final String text;
  final int timestamp;
  final bool isLong;
  const _NoticeEntry({
    required this.senderName,
    required this.text,
    required this.timestamp,
    required this.isLong,
  });
}

class _FilterRail extends StatelessWidget {
  final HomeFilter selected;
  final ValueChanged<HomeFilter> onSelected;
  final VoidCallback onImport;
  final VoidCallback onExport;

  const _FilterRail({
    required this.selected,
    required this.onSelected,
    required this.onImport,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      child: Column(
        children: [
          const SizedBox(height: 10),
          _FilterButton(
            icon: Icons.campaign_outlined,
            label: '공지',
            selected: selected == HomeFilter.notices,
            onPressed: () => onSelected(HomeFilter.notices),
          ),
          _FilterButton(
            icon: Icons.people_outline,
            label: 'All',
            selected: selected == HomeFilter.all,
            onPressed: () => onSelected(HomeFilter.all),
          ),
          _FilterButton(
            icon: Icons.folder_copy_outlined,
            label: 'Group',
            selected: selected == HomeFilter.groups,
            onPressed: () => onSelected(HomeFilter.groups),
          ),
          _FilterButton(
            icon: Icons.star_outline,
            label: '즐겨찾기',
            selected: selected == HomeFilter.favorites,
            onPressed: () => onSelected(HomeFilter.favorites),
          ),
          _FilterButton(
            icon: Icons.chat_bubble_outline,
            label: '채팅',
            selected: selected == HomeFilter.chats,
            onPressed: () => onSelected(HomeFilter.chats),
          ),
          const Divider(height: 16, indent: 16, endIndent: 16),
          _FilterButton(
            icon: Icons.file_download_outlined,
            label: 'Import',
            selected: false,
            onPressed: onImport,
          ),
          _FilterButton(
            icon: Icons.file_upload_outlined,
            label: 'Export',
            selected: false,
            onPressed: onExport,
          ),
          const Spacer(),
          const SizedBox(height: 12),
          _ConnectionBadge(
            bleService: BleService(),
            messagingService: MessagingService(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// 공지 보내기 버튼이 포함된 공지 패널
class _NoticePanel extends StatelessWidget {
  final List<_NoticeEntry> notices;
  final VoidCallback onSendNotice;
  const _NoticePanel({required this.notices, required this.onSendNotice});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _NoticeBoardView(notices: notices)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Colors.white12)),
          ),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onSendNotice,
              icon: const Icon(Icons.add_alert_outlined, size: 18),
              label: const Text('공지 보내기'),
            ),
          ),
        ),
      ],
    );
  }
}

class _NoticeBoardView extends StatelessWidget {
  final List<_NoticeEntry> notices;
  const _NoticeBoardView({required this.notices});

  @override
  Widget build(BuildContext context) {
    if (notices.isEmpty) {
      return const Center(
        child: Text('수신된 공지가 없습니다', style: TextStyle(color: Colors.white54)),
      );
    }
    return ListView.separated(
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: notices.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = notices[notices.length - 1 - index];
        final time = formatRelativeTime(entry.timestamp);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: Color(0xFFFF9800),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.campaign, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.senderName,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF9800).withAlpha(40),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            entry.isLong ? '공지L' : '공지S',
                            style: const TextStyle(color: Color(0xFFFF9800), fontSize: 10),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(time, style: const TextStyle(color: Colors.white38, fontSize: 10)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(entry.text, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FilterButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const _FilterButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? _HomeScreenState.selectedColor(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 66,
          height: 46,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, style: TextStyle(color: color, fontSize: 10)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactList extends StatelessWidget {
  final List<Contact> contacts;
  final Map<String, int> unreadCounts;
  final Set<String> incomingContactIds;
  final ValueChanged<Contact> onTap;
  final void Function(Contact, _ContactAction) onAction;
  final VoidCallback onScan;

  const _ContactList({
    required this.contacts,
    required this.unreadCounts,
    required this.incomingContactIds,
    required this.onTap,
    required this.onAction,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      return _EmptyState(
        icon: Icons.people_outline,
        title: '표시할 연락처가 없습니다.',
        detail: 'SCAN을 실행하거나 QR 코드로 연락처를 추가하세요.',
        actionLabel: 'START',
        onAction: onScan,
      );
    }

    return ListView.builder(
      itemCount: contacts.length,
      itemBuilder: (context, index) {
        final contact = contacts[index];
        return _ContactTile(
          contact: contact,
          unreadCount: unreadCounts[contactCode(contact)] ?? 0,
          isReceiving: incomingContactIds.contains(contactCode(contact)),
          onTap: () => onTap(contact),
          onAction: (action) => onAction(contact, action),
        );
      },
    );
  }
}

class _ContactTile extends StatelessWidget {
  final Contact contact;
  final int unreadCount;
  final bool isReceiving;
  final VoidCallback onTap;
  final ValueChanged<_ContactAction> onAction;

  const _ContactTile({
    required this.contact,
    this.unreadCount = 0,
    this.isReceiving = false,
    required this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final group = contact.groupName?.trim();
    final groupLabel = group == null || group.isEmpty ? '[]' : '[$group]';
    final isSelf = _isSelfContact(contact);
    final nameColor = _roleColor(
      context,
      userLevel: contact.userLevel,
      isSelf: isSelf,
    );
    return ListTile(
      minLeadingWidth: 46,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          AvatarBadge(
            avatarKey: contact.avatarKey,
            size: 40,
            fallbackIcon: contact.isTrusted
                ? Icons.person
                : Icons.question_mark,
            fallbackColor: contact.isTrusted
                ? Colors.green.shade300
                : Colors.orange.shade300,
          ),
          Positioned(
            left: -6,
            bottom: -5,
            child: Icon(
              _deviceIcon(contact.deviceType),
              color: _deviceColor(contact.deviceType),
              size: 16,
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              contactDisplayName(contact),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: nameColor, fontWeight: FontWeight.w600),
            ),
          ),
          if (contact.isFavorite)
            const Icon(Icons.star, color: Colors.amber, size: 16),
        ],
      ),
      subtitle: Text(
        [
          groupLabel,
          contact.userLevel.label,
          contact.isTrusted ? '신뢰O' : '신뢰X',
          'BLE',
          formatRelativeTime(contact.lastSeen),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unreadCount > 0) _UnreadBadge(count: unreadCount),
          if (isReceiving) ...[
            const _BlinkingDot(),
            const SizedBox(width: 2),
          ],
          PopupMenuButton<_ContactAction>(
            tooltip: '연락처 메뉴',
            onSelected: onAction,
            itemBuilder: (context) => _contactMenuItems(isSelf),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  List<PopupMenuEntry<_ContactAction>> _contactMenuItems(bool isSelf) {
    return [
      PopupMenuItem(
        enabled: false,
        child: Text(
          'Code: ${contactCode(contact)}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
      const PopupMenuDivider(),
      if (!isSelf)
        PopupMenuItem(
          value: _ContactAction.toggleTrust,
          child: Text(contact.isTrusted ? '신뢰 해제' : '신뢰 등록'),
        ),
      const PopupMenuItem(value: _ContactAction.rename, child: Text('이름 변경')),
      PopupMenuItem(
        value: _ContactAction.toggleFavorite,
        child: Text(contact.isFavorite ? '즐겨찾기 해제' : '즐겨찾기 추가'),
      ),
      const PopupMenuItem(
        value: _ContactAction.inviteToGroup,
        child: Text('그룹 채팅에 초대'),
      ),
      const PopupMenuItem(
        value: _ContactAction.setAvatar,
        child: Text('Avatar'),
      ),
      const PopupMenuItem(value: _ContactAction.setLevel, child: Text('Level')),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: _ContactAction.deleteMessages,
        child: Text('Delete messages'),
      ),
      if (!isSelf)
        const PopupMenuItem(value: _ContactAction.delete, child: Text('삭제')),
    ];
  }

  bool _isSelfContact(Contact contact) {
    final myNodeId = IdentityService().myNodeId;
    if (contact.nodeId.length != myNodeId.length) return false;
    for (var i = 0; i < myNodeId.length; i++) {
      if (contact.nodeId[i] != myNodeId[i]) return false;
    }
    return true;
  }

  IconData _deviceIcon(MeshDeviceType type) {
    return switch (type) {
      MeshDeviceType.pc => Icons.computer,
      MeshDeviceType.phone => Icons.phone_android,
      MeshDeviceType.unknown => Icons.device_unknown,
    };
  }

  Color _deviceColor(MeshDeviceType type) {
    return switch (type) {
      MeshDeviceType.pc => Colors.lightBlueAccent,
      MeshDeviceType.phone => _HomeScreenState._bluetooth,
      MeshDeviceType.unknown => Colors.white54,
    };
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : count.toString();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onError,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanTreePreview extends StatelessWidget {
  final List<Contact> contacts;
  final List<Contact> knownContacts;
  final List<TopologyResponse> topologyResponses;
  final int depth;
  final bool isScanning;
  final String myName;
  final MeshDeviceType myDeviceType;
  final UserLevel myUserLevel;
  final ValueChanged<Contact> onOpenContact;
  final ValueChanged<Contact> onAddContact;
  final TextEditingController depthController;
  final bool showNodeCounts;
  final ValueChanged<bool> onShowNodeCountsChanged;

  const _ScanTreePreview({
    required this.contacts,
    required this.knownContacts,
    required this.topologyResponses,
    required this.depth,
    required this.isScanning,
    required this.myName,
    required this.myDeviceType,
    required this.myUserLevel,
    required this.onOpenContact,
    required this.onAddContact,
    required this.depthController,
    required this.showNodeCounts,
    required this.onShowNodeCountsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Stack(
        children: [
          Positioned.fill(
            child: _ScanMapCard(
              contacts: contacts,
              knownContacts: knownContacts,
              topologyResponses: topologyResponses,
              depth: depth,
              isScanning: isScanning,
              myName: myName,
              myDeviceType: myDeviceType,
              myUserLevel: myUserLevel,
              onOpenContact: onOpenContact,
              onAddContact: onAddContact,
              depthController: depthController,
              showNodeCounts: showNodeCounts,
              onShowNodeCountsChanged: onShowNodeCountsChanged,
            ),
          ),
          if (contacts.isEmpty)
            Positioned.fill(
              child: Center(
                child: _EmptyState(
                  icon: Icons.account_tree_outlined,
                  title: depth == 0 ? 'Depth 0: 나만 표시' : '표시할 노드가 없습니다.',
                  detail: isScanning
                      ? 'SCAN이 끝나면 발견된 MeshComm 노드가 여기에 표시됩니다.'
                      : 'START를 눌러 주변 MeshComm 기기를 찾으세요.',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScanMapCard extends StatefulWidget {
  final List<Contact> contacts;
  final List<Contact> knownContacts;
  final List<TopologyResponse> topologyResponses;
  final int depth;
  final bool isScanning;
  final String myName;
  final MeshDeviceType myDeviceType;
  final UserLevel myUserLevel;
  final ValueChanged<Contact> onOpenContact;
  final ValueChanged<Contact> onAddContact;
  final TextEditingController depthController;
  final bool showNodeCounts;
  final ValueChanged<bool> onShowNodeCountsChanged;

  const _ScanMapCard({
    required this.contacts,
    required this.knownContacts,
    required this.topologyResponses,
    required this.depth,
    required this.isScanning,
    required this.myName,
    required this.myDeviceType,
    required this.myUserLevel,
    required this.onOpenContact,
    required this.onAddContact,
    required this.depthController,
    required this.showNodeCounts,
    required this.onShowNodeCountsChanged,
  });

  @override
  State<_ScanMapCard> createState() => _ScanMapCardState();
}

class _ScanMapCardState extends State<_ScanMapCard> {
  _ScanMapNode? _selectedNode;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapSize = Size(
          math.max(260, constraints.maxWidth),
          math.max(260, constraints.maxHeight - 34),
        );
        final visibleContacts = widget.contacts.take(40).toList();
        final layout = _buildLayout(visibleContacts, mapSize);
        final nodes = layout.nodes;
        final edges = layout.edges;
        _ScanMapNode? selectedNode;
        if (_selectedNode != null) {
          for (final node in nodes) {
            if (node.id == _selectedNode!.id) {
              selectedNode = node;
              break;
            }
          }
        }

        return Card(
          child: Stack(
            children: [
              Positioned.fill(
                bottom: 8,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: InteractiveViewer(
                    boundaryMargin: const EdgeInsets.all(160),
                    minScale: 0.8,
                    maxScale: 3,
                    child: Center(
                      child: SizedBox(
                        width: mapSize.width,
                        height: mapSize.height,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _ScanMapPainter(
                                  nodes: nodes,
                                  edges: edges,
                                  isScanning: widget.isScanning,
                                  scheme: Theme.of(context).colorScheme,
                                ),
                              ),
                            ),
                            for (final node in nodes)
                              Positioned(
                                left: node.position.dx - 27,
                                top: node.position.dy - 25,
                                child: _ScanMapNodeButton(
                                  node: node,
                                  showConnectionCount: widget.showNodeCounts,
                                  onTap: () =>
                                      setState(() => _selectedNode = node),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: _ScanDepthBox(controller: widget.depthController),
              ),
              Positioned(
                right: 12,
                top: 12,
                child: _ScanNodeBox(
                  enabled: widget.showNodeCounts,
                  onChanged: widget.onShowNodeCountsChanged,
                ),
              ),
              Positioned(
                left: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ScanLegendDot(
                      color: _roleColor(
                        context,
                        userLevel: widget.myUserLevel,
                        isSelf: true,
                      ),
                      label: 'Me',
                    ),
                    const SizedBox(height: 5),
                    _ScanLegendDot(
                      color: _roleColor(
                        context,
                        userLevel: UserLevel.admin,
                        isSelf: false,
                      ),
                      label: 'Admin+',
                    ),
                    const SizedBox(height: 5),
                    const _ScanLegendDot(
                      color: Color(0xFF87CEEB),
                      label: 'User',
                    ),
                  ],
                ),
              ),
              if (selectedNode != null)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _ScanNodeInfoPanel(
                    node: selectedNode,
                    deviceLabel: _deviceLabel(selectedNode.deviceType),
                    onClose: () => setState(() => _selectedNode = null),
                    onAdd:
                        selectedNode.contact != null &&
                            !selectedNode.isSavedContact
                        ? () {
                            widget.onAddContact(selectedNode!.contact!);
                            setState(() => _selectedNode = null);
                          }
                        : null,
                    onChat:
                        selectedNode.contact == null ||
                            !widget.myUserLevel.canSendMessages ||
                            !selectedNode.contact!.userLevel.canSendMessages
                        ? null
                        : () {
                            setState(() => _selectedNode = null);
                            widget.onOpenContact(selectedNode!.contact!);
                          },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  _ScanMapLayout _buildLayout(List<Contact> visibleContacts, Size mapSize) {
    final selfSummary = TopologyNodeSummary(
      nodeId: IdentityService().myNodeId,
      displayName: widget.myName.trim().isEmpty ? 'Me' : widget.myName.trim(),
      deviceType: widget.myDeviceType,
      userLevel: widget.myUserLevel,
      transportKind: TransportKind.bluetooth,
      isSaved: true,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
    );
    final graph = buildTopologyGraph(
      self: selfSummary,
      directContacts: visibleContacts,
      responses: widget.topologyResponses,
      depth: widget.depth,
    );
    final knownById = {
      for (final contact in widget.knownContacts) contactCode(contact): contact,
    };
    final routeByNodeId = _routesFromSelf(graph);
    final positions = _buildClusterPositions(graph, mapSize);
    final center = Offset(mapSize.width / 2, mapSize.height / 2);
    final maxDepth = math.max(
      1,
      graph.nodes.map((node) => node.depth).fold(0, math.max),
    );
    final maxRadius = math.min(mapSize.width, mapSize.height) * 0.38;
    final groups = <int, List<TopologyGraphNode>>{};
    for (final node in graph.nodes) {
      groups.putIfAbsent(node.depth, () => []).add(node);
    }

    final scanNodes = <_ScanMapNode>[];
    final indexById = <String, int>{};
    for (final entry
        in groups.entries.toList()
          ..sort((left, right) => left.key.compareTo(right.key))) {
      final ringDepth = entry.key;
      final ringNodes = entry.value;
      for (var i = 0; i < ringNodes.length; i++) {
        final graphNode = ringNodes[i];
        final isSelf = ringDepth == 0;
        final contact = graphNode.contact ?? knownById[graphNode.id];
        final routeKind =
            routeByNodeId[graphNode.id] ?? graphNode.summary.transportKind;
        final angle =
            -math.pi / 2 + (2 * math.pi * i / math.max(1, ringNodes.length));
        final radius = isSelf ? 0.0 : maxRadius * ringDepth / maxDepth;
        final position = Offset(
          center.dx + math.cos(angle) * radius,
          center.dy + math.sin(angle) * radius,
        );
        final isLive = !isSelf && MessagingService().isDirectlyConnected(graphNode.id);
        indexById[graphNode.id] = scanNodes.length;
        scanNodes.add(
          _ScanMapNode(
            id: graphNode.id,
            title: _graphNodeName(graphNode),
            subtitle: [
              _deviceLabel(graphNode.summary.deviceType),
              'depth ${graphNode.depth}',
              contact?.isSaved ?? graphNode.summary.isSaved ? 'known' : 'new',
              routeKind.label,
            ].join(' · '),
            position: positions[graphNode.id] ?? position,
            deviceType: graphNode.summary.deviceType,
            userLevel: graphNode.summary.userLevel,
            routeKind: routeKind,
            connectionCount: graphNode.connectionCount,
            isMe: isSelf,
            isSavedContact: contact?.isSaved ?? graphNode.summary.isSaved,
            isFavorite: contact?.isFavorite ?? false,
            contact: contact,
            isLive: isLive,
          ),
        );
      }
    }

    final scanEdges = <_ScanMapEdge>[];
    for (final edge in graph.edges) {
      final from = indexById[edge.fromId];
      final to = indexById[edge.toId];
      if (from == null || to == null) continue;
      scanEdges.add(_ScanMapEdge(from, to, edge.transportKind));
    }
    return _ScanMapLayout(nodes: scanNodes, edges: scanEdges);
  }

  Map<String, TransportKind> _routesFromSelf(TopologyGraph graph) {
    String? self;
    for (final node in graph.nodes) {
      if (node.depth == 0) {
        self = node.id;
        break;
      }
    }
    if (self == null) return const {};
    final adjacency = <String, List<(String, TransportKind)>>{};
    for (final edge in graph.edges) {
      adjacency.putIfAbsent(edge.fromId, () => <(String, TransportKind)>[]).add(
        (edge.toId, edge.transportKind),
      );
      adjacency.putIfAbsent(edge.toId, () => <(String, TransportKind)>[]).add((
        edge.fromId,
        edge.transportKind,
      ));
    }
    final routes = <String, TransportKind>{};
    final visited = <String>{self};
    final queue = <String>[self];
    for (var index = 0; index < queue.length; index++) {
      final current = queue[index];
      final neighbors = adjacency[current] ?? const <(String, TransportKind)>[];
      for (final (next, transportKind) in neighbors) {
        if (!visited.add(next)) continue;
        final parentRoute = routes[current];
        routes[next] = parentRoute == null
            ? transportKind
            : _bestTransport(parentRoute, transportKind);
        queue.add(next);
      }
    }
    return routes;
  }

  TransportKind _bestTransport(TransportKind left, TransportKind right) {
    return _transportPriority(left) >= _transportPriority(right) ? left : right;
  }

  Map<String, Offset> _buildClusterPositions(
    TopologyGraph graph,
    Size mapSize,
  ) {
    if (graph.nodes.isEmpty) return const {};

    final self = graph.nodes.firstWhere(
      (node) => node.depth == 0,
      orElse: () => graph.nodes.first,
    );
    final nodesById = {for (final node in graph.nodes) node.id: node};
    final adjacency = <String, Set<String>>{};
    for (final edge in graph.edges) {
      adjacency.putIfAbsent(edge.fromId, () => <String>{}).add(edge.toId);
      adjacency.putIfAbsent(edge.toId, () => <String>{}).add(edge.fromId);
    }

    final childrenById = <String, List<TopologyGraphNode>>{};
    final orderedNodes =
        graph.nodes.where((node) => node.id != self.id).toList()
          ..sort((left, right) {
            final depthOrder = left.depth.compareTo(right.depth);
            if (depthOrder != 0) return depthOrder;
            return _graphNodeName(left).compareTo(_graphNodeName(right));
          });

    for (final node in orderedNodes) {
      final parentCandidates =
          (adjacency[node.id] ?? const <String>{})
              .where((id) => (nodesById[id]?.depth ?? 9999) == node.depth - 1)
              .toList()
            ..sort((left, right) {
              final childOrder = (childrenById[left]?.length ?? 0).compareTo(
                childrenById[right]?.length ?? 0,
              );
              if (childOrder != 0) return childOrder;
              return _graphNodeName(
                nodesById[left]!,
              ).compareTo(_graphNodeName(nodesById[right]!));
            });
      final parentId = parentCandidates.isEmpty
          ? self.id
          : parentCandidates.first;
      childrenById.putIfAbsent(parentId, () => []).add(node);
    }

    for (final children in childrenById.values) {
      children.sort(
        (left, right) => _graphNodeName(left).compareTo(_graphNodeName(right)),
      );
    }

    final shortestSide = math.min(mapSize.width, mapSize.height);
    final step = math.max(74.0, math.min(118.0, shortestSide * 0.18));
    final rawPositions = <String, Offset>{self.id: Offset.zero};
    final anglesById = <String, double>{self.id: -math.pi / 2};

    late void Function(String parentId) placeChildren;
    placeChildren = (String parentId) {
      final children = childrenById[parentId] ?? const <TopologyGraphNode>[];
      if (children.isEmpty) return;

      final parentPosition = rawPositions[parentId] ?? Offset.zero;
      final parentAngle = anglesById[parentId] ?? -math.pi / 2;
      final isRoot = parentId == self.id;
      final spread = isRoot ? 2 * math.pi : _childSpread(children.length);
      final start = isRoot ? -math.pi / 2 : parentAngle - spread / 2;

      for (var i = 0; i < children.length; i++) {
        final child = children[i];
        final angle = isRoot
            ? start + (2 * math.pi * i / math.max(1, children.length))
            : children.length == 1
            ? _singleChildAngle(parentAngle, child)
            : start + (spread * i / (children.length - 1));
        rawPositions[child.id] =
            parentPosition + Offset(math.cos(angle), math.sin(angle)) * step;
        anglesById[child.id] = angle;
        placeChildren(child.id);
      }
    };
    placeChildren(self.id);

    for (final node in graph.nodes) {
      rawPositions.putIfAbsent(node.id, () => Offset.zero);
    }

    _relaxClusterPositions(rawPositions, fixedId: self.id);
    return _fitClusterPositions(rawPositions, mapSize);
  }

  double _childSpread(int childCount) {
    if (childCount <= 1) return 0;
    if (childCount == 2) return math.pi / 2;
    if (childCount == 3) return math.pi * 0.9;
    if (childCount == 4) return math.pi * 1.1;
    return math.pi * 1.35;
  }

  double _singleChildAngle(double parentAngle, TopologyGraphNode child) {
    final turn = child.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
    final direction = (turn + child.depth).isEven ? 1.0 : -1.0;
    return parentAngle + direction * math.pi / 3;
  }

  void _relaxClusterPositions(
    Map<String, Offset> positions, {
    required String fixedId,
  }) {
    const minDistance = 48.0;
    final ids = positions.keys.toList();
    for (var iteration = 0; iteration < 28; iteration++) {
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          final a = ids[i];
          final b = ids[j];
          final delta = positions[b]! - positions[a]!;
          final distance = delta.distance;
          if (distance <= 0 || distance >= minDistance) continue;
          final push = delta / distance * ((minDistance - distance) * 0.18);
          if (a != fixedId) positions[a] = positions[a]! - push;
          if (b != fixedId) positions[b] = positions[b]! + push;
        }
      }
    }
  }

  Map<String, Offset> _fitClusterPositions(
    Map<String, Offset> rawPositions,
    Size mapSize,
  ) {
    if (rawPositions.isEmpty) return const {};
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final position in rawPositions.values) {
      minX = math.min(minX, position.dx);
      minY = math.min(minY, position.dy);
      maxX = math.max(maxX, position.dx);
      maxY = math.max(maxY, position.dy);
    }

    const margin = 68.0;
    final mapCenter = Offset(mapSize.width / 2, mapSize.height / 2);
    final scaleCandidates = <double>[1.0];
    if (maxX > 0) {
      scaleCandidates.add((mapSize.width - mapCenter.dx - margin) / maxX);
    }
    if (minX < 0) scaleCandidates.add((mapCenter.dx - margin) / -minX);
    if (maxY > 0) {
      scaleCandidates.add((mapSize.height - mapCenter.dy - margin) / maxY);
    }
    if (minY < 0) scaleCandidates.add((mapCenter.dy - margin) / -minY);
    final scale = scaleCandidates
        .where((value) => value.isFinite && value > 0)
        .fold<double>(1.0, math.min);

    return {
      for (final entry in rawPositions.entries)
        entry.key: mapCenter + entry.value * scale,
    };
  }

  String _graphNodeName(TopologyGraphNode node) {
    final contact = node.contact;
    if (contact != null) return contactDisplayName(contact);
    final name = node.summary.displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return node.id.substring(0, math.min(8, node.id.length));
  }

  // ignore: unused_element
  List<_ScanMapNode> _buildNodes(List<Contact> visibleContacts, Size mapSize) {
    final center = Offset(mapSize.width / 2, mapSize.height / 2);
    final nodes = <_ScanMapNode>[
      _ScanMapNode(
        id: 'me',
        title: widget.myName.trim().isEmpty ? 'Me' : widget.myName.trim(),
        subtitle: '${_deviceLabel(widget.myDeviceType)} · Me',
        position: center,
        deviceType: widget.myDeviceType,
        userLevel: widget.myUserLevel,
        routeKind: TransportKind.bluetooth,
        connectionCount: visibleContacts.length,
        isMe: true,
        isSavedContact: true,
      ),
    ];

    if (visibleContacts.isEmpty) return nodes;

    final outerRadius = math.min(mapSize.width, mapSize.height) * 0.34;
    final innerRadius = outerRadius * 0.66;
    for (var i = 0; i < visibleContacts.length; i++) {
      final contact = visibleContacts[i];
      final angle = -math.pi / 2 + (2 * math.pi * i / visibleContacts.length);
      final radius = visibleContacts.length > 12 && i.isEven
          ? innerRadius
          : outerRadius;
      final position = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      nodes.add(
        _ScanMapNode(
          id: contactCode(contact),
          title: contactDisplayName(contact),
          subtitle: [
            _deviceLabel(contact.deviceType),
            contact.isSaved ? 'known' : 'new',
            'BLE',
          ].join(' · '),
          position: position,
          deviceType: contact.deviceType,
          userLevel: contact.userLevel,
          routeKind: TransportKind.bluetooth,
          connectionCount: 1,
          isSavedContact: contact.isSaved,
          isFavorite: contact.isFavorite,
          contact: contact,
        ),
      );
    }
    return nodes;
  }

  // ignore: unused_element
  List<_ScanMapEdge> _buildEdges(int contactCount) {
    return [
      for (var i = 0; i < contactCount; i++)
        _ScanMapEdge(0, i + 1, TransportKind.bluetooth),
    ];
  }

  String _deviceLabel(MeshDeviceType type) {
    return switch (type) {
      MeshDeviceType.pc => 'PC',
      MeshDeviceType.phone => 'Phone',
      MeshDeviceType.unknown => 'Unknown',
    };
  }
}

/*
        _ScanMapCard(
          contacts: contacts,
          isScanning: isScanning,
          myName: myName,
          myDeviceType: myDeviceType,
          onOpenContact: onOpenContact,
          onAddContact: onAddContact,
        ),
        if (contacts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 36),
            child: _EmptyState(
              icon: Icons.account_tree_outlined,
              title: depth == 0 ? 'Depth 0: 나만 표시' : '표시할 노드가 없습니다.',
              detail: isScanning
                  ? 'SCAN이 끝나면 발견된 MeshComm 노드가 여기에 표시됩니다.'
                  : 'START를 눌러 주변 MeshComm 기기를 찾으세요.',
            ),
          )
      ],
    );
  }
}

class _ScanMapCard extends StatelessWidget {
  static const _mapSize = Size(360, 300);

  final List<Contact> contacts;
  final bool isScanning;
  final String myName;
  final MeshDeviceType myDeviceType;
  final ValueChanged<Contact> onOpenContact;
  final ValueChanged<Contact> onAddContact;

  const _ScanMapCard({
    required this.contacts,
    required this.isScanning,
    required this.myName,
    required this.myDeviceType,
    required this.onOpenContact,
    required this.onAddContact,
  });

  @override
  Widget build(BuildContext context) {
    final visibleContacts = contacts.take(40).toList();
    final nodes = _buildNodes(visibleContacts);
    final edges = _buildEdges(visibleContacts.length);

    return Card(
      child: SizedBox(
        height: 430,
        child: Stack(
          children: [
            Positioned(
              left: 12,
              bottom: 8,
              child: Row(
                children: [
                  _ScanLegendDot(
                    color: Colors.white70,
                    label: 'Contact',
                  ),
                  const SizedBox(width: 10),
                  _ScanLegendDot(
                    color: Colors.white38,
                    label: 'Found',
                  ),
                ],
              ),
            ),
            Positioned.fill(
              top: 8,
              bottom: 28,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: InteractiveViewer(
                  boundaryMargin: const EdgeInsets.all(160),
                  minScale: 0.8,
                  maxScale: 3,
                  child: Center(
                    child: SizedBox(
                      width: _mapSize.width,
                      height: _mapSize.height,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _ScanMapPainter(
                                nodes: nodes,
                                edges: edges,
                                isScanning: isScanning,
                                scheme: Theme.of(context).colorScheme,
                              ),
                            ),
                          ),
                          for (final node in nodes)
                            Positioned(
                              left: node.position.dx - 24,
                              top: node.position.dy - 22,
                              child: _ScanMapNodeButton(
                                node: node,
                                onTap: () => _showNodeInfo(context, node),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_ScanMapNode> _buildNodes(List<Contact> visibleContacts) {
    final center = Offset(_mapSize.width / 2, _mapSize.height / 2);
    final nodes = <_ScanMapNode>[
      _ScanMapNode(
        id: 'me',
        title: myName.trim().isEmpty ? 'Me' : myName.trim(),
        subtitle: '${_deviceLabel(myDeviceType)} · Me',
        position: center,
        deviceType: myDeviceType,
        userLevel: myUserLevel,
        routeKind: TransportKind.bluetooth,
        connectionCount: visibleContacts.length,
        isMe: true,
        isSavedContact: true,
      ),
    ];

    if (visibleContacts.isEmpty) return nodes;

    final outerRadius = math.min(_mapSize.width, _mapSize.height) * 0.34;
    final innerRadius = outerRadius * 0.66;
    for (var i = 0; i < visibleContacts.length; i++) {
      final contact = visibleContacts[i];
      final angle = -math.pi / 2 + (2 * math.pi * i / visibleContacts.length);
      final radius = visibleContacts.length > 12 && i.isEven
          ? innerRadius
          : outerRadius;
      final position = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      nodes.add(
        _ScanMapNode(
          id: contactCode(contact),
          title: contactDisplayName(contact),
          subtitle: [
            _deviceLabel(contact.deviceType),
            contact.isSaved ? 'contact' : 'found',
            'BLE',
          ].join(' · '),
          position: position,
          deviceType: contact.deviceType,
          userLevel: contact.userLevel,
          routeKind: TransportKind.bluetooth,
          connectionCount: 1,
          isSavedContact: contact.isSaved,
          isFavorite: contact.isFavorite,
          contact: contact,
        ),
      );
    }
    return nodes;
  }

  List<_ScanMapEdge> _buildEdges(int contactCount) {
    return [
      for (var i = 0; i < contactCount; i++) _ScanMapEdge(0, i + 1),
    ];
  }

  void _showNodeInfo(BuildContext context, _ScanMapNode node) {
    showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 54),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withAlpha(215),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 10),
                  _NodeInfoLine('Type', _deviceLabel(node.deviceType)),
                  _NodeInfoLine('Links', node.connectionCount.toString()),
                  _NodeInfoLine('Route', node.routeKind.label),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                      if (node.contact != null && !node.isSavedContact) ...[
                        const SizedBox(width: 12),
                        IconButton(
                          tooltip: 'Add',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            Navigator.pop(context);
                            onAddContact(node.contact!);
                          },
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                      if (node.contact != null &&
                          node.contact!.userLevel.canSendMessages) ...[
                        const SizedBox(width: 12),
                        IconButton(
                          tooltip: 'Chat',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            Navigator.pop(context);
                            onOpenContact(node.contact!);
                          },
                          icon: const Icon(Icons.chat_bubble_outline),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _deviceLabel(MeshDeviceType type) {
    return switch (type) {
      MeshDeviceType.pc => 'PC',
      MeshDeviceType.phone => 'Phone',
      MeshDeviceType.unknown => 'Unknown',
    };
  }
}
*/

class _ScanNodeInfoPanel extends StatelessWidget {
  final _ScanMapNode node;
  final String deviceLabel;
  final VoidCallback onClose;
  final VoidCallback? onAdd;
  final VoidCallback? onChat;

  const _ScanNodeInfoPanel({
    required this.node,
    required this.deviceLabel,
    required this.onClose,
    this.onAdd,
    this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withAlpha(205),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withAlpha(130)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: SizedBox(
          width: 120,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              _NodeInfoLine('Type', deviceLabel),
              _NodeInfoLine('Level', node.userLevel.label),
              _NodeInfoLine('Links', node.connectionCount.toString()),
              _NodeInfoLine('Route', node.routeKind.label),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 19),
                  ),
                  if (onAdd != null)
                    IconButton(
                      tooltip: 'Add',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      onPressed: onAdd,
                      icon: const Icon(Icons.add_circle_outline, size: 19),
                    ),
                  if (onChat != null)
                    IconButton(
                      tooltip: 'Chat',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      onPressed: onChat,
                      icon: const Icon(Icons.chat_bubble_outline, size: 19),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanMapPainter extends CustomPainter {
  final List<_ScanMapNode> nodes;
  final List<_ScanMapEdge> edges;
  final bool isScanning;
  final ColorScheme scheme;

  const _ScanMapPainter({
    required this.nodes,
    required this.edges,
    required this.isScanning,
    required this.scheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final center = nodes.first.position;
    final radius = math.min(size.width, size.height) * 0.34;
    if (isScanning) {
      final scanPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _HomeScreenState._accent.withAlpha(120);
      for (final scale in [0.55, 0.8, 1.05]) {
        canvas.drawCircle(center, radius * scale, scanPaint);
      }
    }

    for (final edge in edges) {
      if (edge.from >= nodes.length || edge.to >= nodes.length) continue;
      final from = nodes[edge.from].position;
      final to = nodes[edge.to].position;
      final linePaint = _linePaint(edge.transportKind);
      if (edge.transportKind == TransportKind.bluetooth) {
        _drawDashedLine(canvas, from, to, linePaint);
      } else {
        canvas.drawLine(from, to, linePaint);
      }
    }
  }

  Paint _linePaint(TransportKind kind) {
    return Paint()
      ..color = scheme.outlineVariant.withAlpha(
        kind == TransportKind.lan ? 220 : 180,
      )
      ..strokeWidth = switch (kind) {
        TransportKind.lan => 2.8,
        TransportKind.bluetooth => 1.2,
      }
      ..strokeCap = StrokeCap.round;
  }

  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    final delta = to - from;
    final distance = delta.distance;
    if (distance == 0) return;
    final direction = delta / distance;
    const dash = 5.0;
    const gap = 4.0;
    var drawn = 0.0;
    while (drawn < distance) {
      final segmentEnd = math.min(drawn + dash, distance);
      canvas.drawLine(
        from + direction * drawn,
        from + direction * segmentEnd,
        paint,
      );
      drawn += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _ScanMapPainter oldDelegate) {
    return oldDelegate.nodes != nodes ||
        oldDelegate.edges != edges ||
        oldDelegate.isScanning != isScanning ||
        oldDelegate.scheme != scheme;
  }
}

class _ScanMapNode {
  final String id;
  final String title;
  final String subtitle;
  final Offset position;
  final MeshDeviceType deviceType;
  final UserLevel userLevel;
  final TransportKind routeKind;
  final int connectionCount;
  final bool isMe;
  final bool isSavedContact;
  final bool isFavorite;
  final Contact? contact;
  final bool isLive;

  const _ScanMapNode({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.position,
    required this.deviceType,
    required this.userLevel,
    required this.routeKind,
    required this.connectionCount,
    this.isMe = false,
    this.isSavedContact = false,
    this.isFavorite = false,
    this.contact,
    this.isLive = false,
  });
}

class _ScanMapLayout {
  final List<_ScanMapNode> nodes;
  final List<_ScanMapEdge> edges;

  const _ScanMapLayout({required this.nodes, required this.edges});
}

class _ScanLegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _ScanLegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const SizedBox(width: 8, height: 8),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ScanDepthBox extends StatelessWidget {
  final TextEditingController controller;

  const _ScanDepthBox({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(210),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withAlpha(110)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Depth',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(165),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
              ),
              child: SizedBox(
                width: 42,
                height: 34,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanNodeBox extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ScanNodeBox({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(190),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withAlpha(110)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(9, 8, 9, 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Node',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              width: 34,
              height: 30,
              child: Checkbox(
                value: enabled,
                onChanged: (value) => onChanged(value ?? false),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NodeInfoLine extends StatelessWidget {
  final String label;
  final String value;

  const _NodeInfoLine(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: style?.copyWith(color: Theme.of(context).hintColor),
            ),
          ),
          Text(value, style: style),
        ],
      ),
    );
  }
}

class _ScanMapEdge {
  final int from;
  final int to;
  final TransportKind transportKind;

  const _ScanMapEdge(this.from, this.to, this.transportKind);
}

class _ScanMapNodeButton extends StatefulWidget {
  final _ScanMapNode node;
  final bool showConnectionCount;
  final VoidCallback onTap;

  const _ScanMapNodeButton({
    required this.node,
    required this.showConnectionCount,
    required this.onTap,
  });

  @override
  State<_ScanMapNodeButton> createState() => _ScanMapNodeButtonState();
}

class _ScanMapNodeButtonState extends State<_ScanMapNodeButton>
    with SingleTickerProviderStateMixin {
  static const Color _liveUserColor = Color(0xFF87CEEB);
  late final AnimationController _pulseController;

  bool get _shouldPulse => !widget.node.isMe && !widget.node.isSavedContact;

  Color _nodeColor(BuildContext context) {
    if (widget.node.isMe) return _roleColor(context, userLevel: widget.node.userLevel, isSelf: true);
    if (widget.node.userLevel == UserLevel.creator ||
        widget.node.userLevel == UserLevel.builder ||
        widget.node.userLevel == UserLevel.admin) {
      return _roleColor(context, userLevel: widget.node.userLevel, isSelf: false);
    }
    if (widget.node.isLive) return _liveUserColor;
    return _roleColor(context, userLevel: widget.node.userLevel, isSelf: false);
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _ScanMapNodeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _syncPulse() {
    if (_shouldPulse) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat();
      }
      return;
    }
    _pulseController.stop();
    _pulseController.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final color = _nodeColor(context);
    final isServer = widget.node.userLevel == UserLevel.server;
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final pulse = _shouldPulse ? _pulseController.value : 0.0;
        final pulseAlpha = isDark ? 95 : 125;
        final pulseWidth = isDark ? 0.85 : 1.0;
        final iconColor = isDark ? color.withAlpha(225) : color;
        return Material(
          color: Colors.transparent,
          child: InkResponse(
            radius: 28,
            onTap: widget.onTap,
            child: SizedBox(
              width: 54,
              height: 50,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_shouldPulse)
                    Container(
                      width: 26 + (18 * pulse),
                      height: 26 + (18 * pulse),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color.withAlpha(
                            (pulseAlpha * (1 - pulse))
                                .round()
                                .clamp(18, pulseAlpha)
                                .toInt(),
                          ),
                          width: pulseWidth,
                        ),
                      ),
                    ),
                  if (isServer)
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: iconColor.withAlpha(200),
                      ),
                    )
                  else
                    _ThinDeviceIcon(
                      type: widget.node.deviceType,
                      color: iconColor,
                      size: 25,
                      strokeWidth: isDark ? 1.35 : 1.45,
                    ),
                  if (widget.showConnectionCount)
                    Positioned(
                      right: 3,
                      top: 9,
                      child: Text(
                        widget.node.connectionCount.toString(),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (widget.node.isFavorite)
                    const Positioned(
                      right: 2,
                      bottom: 4,
                      child: Icon(
                        Icons.star_border,
                        color: Colors.white70,
                        size: 11,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _DemoChatItemType { text, file, image }

class _DemoChatMessage {
  final String text;
  final bool outgoing;
  final int timestamp;
  final _DemoChatItemType type;
  final String? fileName;
  final bool isTimedMsg;

  const _DemoChatMessage({
    required this.text,
    required this.outgoing,
    required this.timestamp,
    this.type = _DemoChatItemType.text,
    this.fileName,
    this.isTimedMsg = false,
  });
}

class _DemoChatScreen extends StatefulWidget {
  final TopologyNodeSummary self;
  final Contact contact;
  final DemoTopologyScenario scenario;

  const _DemoChatScreen({
    required this.self,
    required this.contact,
    required this.scenario,
  });

  @override
  State<_DemoChatScreen> createState() => _DemoChatScreenState();
}

class _DemoChatScreenState extends State<_DemoChatScreen> {
  // ── 색상 (chat_screen.dart와 동일) ────────────────────────────────────────────
  static const Color _bgColor = Color(0xFF1A1A2E);
  static const Color _surfaceColor = Color(0xFF16213E);
  static const Color _outgoingBubble = Color(0xFF6C5CE7);
  static const Color _incomingBubble = Color(0xFF2D2D3F);
  static const Color _inputBarBg = Color(0xFF16213E);
  static const Color _textPrimary = Color(0xFFECECEC);
  static const Color _textSecondary = Color(0xFF9090A0);

  // 드롭다운: 일반/타임/파일/이미지 (chat_screen.dart와 동일 구조)
  static const _dropdownItems = [
    ('일반', 'normal'),
    ('타임', 'timed'),
    ('파일', 'file'),
    ('이미지', 'image'),
  ];

  late final VirtualMeshSimulator _simulator;
  final _messages = <_DemoChatMessage>[];
  final _controller = TextEditingController();
  final _keyboardFocusNode = FocusNode();
  final _scrollController = ScrollController();
  MessageSendMode _mode = MessageSendMode.normal;

  String get _selfName {
    final name = widget.self.displayName?.trim() ?? '';
    return name.isNotEmpty ? name : 'Me';
  }

  String get _contactName => contactDisplayName(widget.contact);

  @override
  void initState() {
    super.initState();
    _simulator = VirtualMeshSimulator.fromDemo(
      self: widget.self,
      scenario: widget.scenario,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _keyboardFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send({String? overrideText, _DemoChatItemType type = _DemoChatItemType.text, String? fileName}) {
    final text = overrideText ?? _controller.text.trim();
    if (text.isEmpty && type == _DemoChatItemType.text) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = _simulator.send(
      senderId: nodeIdHex(widget.self.nodeId),
      targetId: contactCode(widget.contact),
      text: text.isNotEmpty ? text : (fileName ?? '파일'),
      mode: _mode,
      nowMs: now,
    );
    if (!result.accepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.blockedReason ?? 'Demo send failed.')),
      );
      return;
    }

    setState(() {
      _messages.add(
        _DemoChatMessage(
          text: text.isNotEmpty ? text : (fileName ?? '파일'),
          outgoing: true,
          timestamp: now,
          type: type,
          fileName: fileName,
          isTimedMsg: _mode == MessageSendMode.timed,
        ),
      );
      if (!_mode.isNotice) {
        final replyText = '(Re: "$_selfName"-"$_contactName") ${text.isNotEmpty ? text : (fileName ?? "파일")}';
        _messages.add(
          _DemoChatMessage(
            text: replyText,
            outgoing: false,
            timestamp: now + 500,
            type: type,
            fileName: null, // Re: prefix is in text; don't show raw filename
            isTimedMsg: _mode == MessageSendMode.timed,
          ),
        );
      }
      _controller.clear();
    });
    _scrollToBottom();

    if (_mode.isNotice) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Demo notice propagated to ${result.deliveries.length} nodes.',
          ),
        ),
      );
    }
  }

  String get _dropdownValue => switch (_mode) {
    MessageSendMode.normal => 'normal',
    MessageSendMode.timed => 'timed',
    MessageSendMode.shortNotice => 'normal',
    MessageSendMode.longNotice => 'normal',
  };

  void _onDropdownChanged(String? value) {
    if (value == null) return;
    switch (value) {
      case 'file':
        _sendFileOrImage(_DemoChatItemType.file);
      case 'image':
        _sendFileOrImage(_DemoChatItemType.image);
      case 'normal':
        setState(() => _mode = MessageSendMode.normal);
      case 'timed':
        setState(() => _mode = MessageSendMode.timed);
    }
  }

  /// 실제 파일 선택창을 열어 파일명을 가져온 뒤 demo 메시지로 전송.
  Future<void> _sendFileOrImage(_DemoChatItemType type) async {
    final XFile? file;
    if (type == _DemoChatItemType.image) {
      const imageTypes = XTypeGroup(
        label: 'images',
        extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
      );
      file = await openFile(acceptedTypeGroups: [imageTypes]);
    } else {
      const typeGroup = XTypeGroup(label: 'files');
      file = await openFile(acceptedTypeGroups: [typeGroup]);
    }
    if (file == null || !mounted) return;
    _send(overrideText: '', type: type, fileName: file.name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _surfaceColor,
        foregroundColor: _textPrimary,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF2D2858),
              child: Text(
                _contactName.isNotEmpty ? _contactName[0].toUpperCase() : '?',
                style: const TextStyle(color: Color(0xFFFF9800), fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _contactName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Text('Demo', style: TextStyle(fontSize: 11, color: Color(0xFFFF9800))),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('메시지를 입력하세요.', style: TextStyle(color: _textSecondary, fontSize: 14)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => _buildBubble(context, _messages[index]),
                  ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: _inputBarBg,
        border: Border(top: BorderSide(color: Color(0xFF2A2A3E), width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 모드 드롭다운 (chat_screen.dart와 동일 스타일)
            Container(
              width: 80,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F1E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF2A2A3E)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _dropdownValue,
                  isExpanded: true,
                  dropdownColor: _incomingBubble,
                  selectedItemBuilder: (context) => _dropdownItems
                      .map((item) => Align(
                            alignment: Alignment.center,
                            child: Text(
                              item.$1,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _textPrimary, fontSize: 12),
                            ),
                          ))
                      .toList(),
                  items: _dropdownItems
                      .map((item) => DropdownMenuItem(
                            value: item.$2,
                            child: Center(
                              child: Text(item.$1,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: _textPrimary)),
                            ),
                          ))
                      .toList(),
                  onChanged: _onDropdownChanged,
                ),
              ),
            ),
            // 텍스트 입력
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: KeyboardListener(
                  focusNode: _keyboardFocusNode,
                  onKeyEvent: (event) {
                    if (event is! KeyDownEvent) return;
                    if (event.logicalKey == LogicalKeyboardKey.enter &&
                        HardwareKeyboard.instance.isControlPressed) {
                      _send();
                    }
                  },
                  child: TextField(
                    controller: _controller,
                    maxLength: _mode.maxLength,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(color: _textPrimary, fontSize: 15),
                    cursorColor: _outgoingBubble,
                    decoration: InputDecoration(
                      hintText: '메시지 입력',
                      hintStyle: const TextStyle(color: _textSecondary),
                      counterText: '',
                      filled: true,
                      fillColor: const Color(0xFF0F0F1E),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: _outgoingBubble, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 전송 버튼
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  child: IconButton(
                    onPressed: hasText ? _send : null,
                    style: IconButton.styleFrom(
                      backgroundColor: hasText ? _outgoingBubble : const Color(0xFF2A2A3E),
                      foregroundColor: _textPrimary,
                      padding: const EdgeInsets.all(12),
                      minimumSize: const Size(44, 44),
                    ),
                    icon: const Icon(Icons.send_rounded, size: 20),
                    tooltip: '전송',
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(BuildContext context, _DemoChatMessage msg) {
    final isOutgoing = msg.outgoing;

    // 파일/이미지 아이콘 포함 내용
    Widget innerContent;
    if (msg.type == _DemoChatItemType.file || msg.type == _DemoChatItemType.image) {
      final icon = msg.type == _DemoChatItemType.image
          ? Icons.image_outlined
          : Icons.insert_drive_file_outlined;
      innerContent = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: _textPrimary.withAlpha(200)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              msg.fileName ?? msg.text,
              style: const TextStyle(color: _textPrimary, fontSize: 15, height: 1.4),
            ),
          ),
        ],
      );
    } else {
      innerContent = Text(
        msg.text,
        style: const TextStyle(color: _textPrimary, fontSize: 15, height: 1.4),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isOutgoing) const SizedBox(width: 4),
              Flexible(
                child: Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isOutgoing ? _outgoingBubble : _incomingBubble,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isOutgoing ? 18 : 4),
                      bottomRight: Radius.circular(isOutgoing ? 4 : 18),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      innerContent,
                      const SizedBox(height: 4),
                      Text(
                        _formatTime(msg.timestamp),
                        style: TextStyle(fontSize: 10, color: _textPrimary.withAlpha(153)),
                      ),
                    ],
                  ),
                ),
              ),
              if (isOutgoing) const SizedBox(width: 4),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}


class _ThinDeviceIcon extends StatelessWidget {
  final MeshDeviceType type;
  final Color color;
  final double size;
  final double strokeWidth;

  const _ThinDeviceIcon({
    required this.type,
    required this.color,
    required this.size,
    required this.strokeWidth,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _ThinDeviceIconPainter(
          type: type,
          color: color,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _ThinDeviceIconPainter extends CustomPainter {
  final MeshDeviceType type;
  final Color color;
  final double strokeWidth;

  const _ThinDeviceIconPainter({
    required this.type,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (type) {
      case MeshDeviceType.pc:
        _paintPc(canvas, size, paint);
      case MeshDeviceType.phone:
        _paintPhone(canvas, size, paint);
      case MeshDeviceType.unknown:
        _paintUnknown(canvas, size, paint);
    }
  }

  void _paintPc(Canvas canvas, Size size, Paint paint) {
    final screen = Rect.fromLTWH(
      size.width * 0.2,
      size.height * 0.24,
      size.width * 0.6,
      size.height * 0.42,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(screen, Radius.circular(size.width * 0.04)),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.66),
      Offset(size.width * 0.5, size.height * 0.78),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.33, size.height * 0.78),
      Offset(size.width * 0.67, size.height * 0.78),
      paint,
    );
  }

  void _paintPhone(Canvas canvas, Size size, Paint paint) {
    final body = Rect.fromLTWH(
      size.width * 0.31,
      size.height * 0.14,
      size.width * 0.38,
      size.height * 0.72,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(size.width * 0.08)),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.43, size.height * 0.76),
      Offset(size.width * 0.57, size.height * 0.76),
      paint,
    );
  }

  void _paintUnknown(Canvas canvas, Size size, Paint paint) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, size.width * 0.28, paint);
    final textPainter = TextPainter(
      text: TextSpan(
        text: '?',
        style: TextStyle(
          color: color,
          fontSize: size.width * 0.5,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _ThinDeviceIconPainter oldDelegate) {
    return oldDelegate.type != type ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _ChatGroupList extends StatelessWidget {
  final List<ChatGroup> groups;
  final ValueChanged<ChatGroup> onTap;
  final void Function(ChatGroup, _GroupAction) onAction;

  const _ChatGroupList({
    required this.groups,
    required this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const _EmptyState(
        icon: Icons.groups_outlined,
        title: '아직 그룹 채팅이 없습니다.',
        detail: '연락처의 ... 메뉴에서 그룹 채팅에 초대하세요.',
      );
    }
    return ListView(
      children: [
        for (final group in groups)
          _ChatGroupTile(
            group: group,
            onTap: () => onTap(group),
            onAction: (action) => onAction(group, action),
          ),
      ],
    );
  }
}

class _ChatGroupTile extends StatelessWidget {
  final ChatGroup group;
  final VoidCallback onTap;
  final ValueChanged<_GroupAction> onAction;

  const _ChatGroupTile({
    required this.group,
    required this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Stack(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFF2D2858),
            child: Icon(Icons.groups_outlined, color: _HomeScreenState._accent),
          ),
          if (group.unreadCount > 0)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  group.unreadCount > 9 ? '9+' : '${group.unreadCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        group.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${group.memberCount}명',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: PopupMenuButton<_GroupAction>(
        tooltip: 'Group 메뉴',
        onSelected: onAction,
        itemBuilder: (context) => const [
          PopupMenuItem(value: _GroupAction.rename, child: Text('이름 변경')),
          PopupMenuDivider(),
          PopupMenuItem(value: _GroupAction.delete, child: Text('그룹 나가기/삭제')),
        ],
      ),
      onTap: onTap,
    );
  }
}

// ── Demo Group Chat Screen ────────────────────────────────────────────────────

class _DemoGroupMsg {
  final String text;
  final String senderLabel;
  final int timestamp;
  final bool isOutgoing;
  final String? fileName;

  const _DemoGroupMsg({
    required this.text,
    required this.senderLabel,
    required this.timestamp,
    required this.isOutgoing,
    this.fileName,
  });
}

class _DemoGroupChatScreen extends StatefulWidget {
  final TopologyNodeSummary self;
  final ChatGroup group;
  final List<Contact> allContacts;

  const _DemoGroupChatScreen({
    required this.self,
    required this.group,
    required this.allContacts,
  });

  @override
  State<_DemoGroupChatScreen> createState() => _DemoGroupChatScreenState();
}

class _DemoGroupChatScreenState extends State<_DemoGroupChatScreen> {
  static const Color _bgColor = Color(0xFF1A1A2E);
  static const Color _surfaceColor = Color(0xFF16213E);
  static const Color _outgoingBubble = Color(0xFF6C5CE7);
  static const Color _incomingBubble = Color(0xFF2D2D3F);

  final List<_DemoGroupMsg> _messages = [];
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  String get _selfName => widget.self.displayName ?? 'Me';

  String _nameForNodeId(Uint8List nodeId) {
    final hex = nodeId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    for (final c in widget.allContacts) {
      final cHex = c.nodeId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (cHex == hex) return c.displayName ?? hex.substring(0, 6);
    }
    return hex.substring(0, 6);
  }

  List<GroupMember> get _otherMembers {
    final selfHex = widget.self.nodeId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return widget.group.members
        .where((m) => m.nodeIdHex != selfHex)
        .toList();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send({String? text, String? fileName}) {
    final content = (text ?? '').trim();
    if (content.isEmpty && fileName == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final displayText = content.isNotEmpty ? content : (fileName ?? '파일');
    setState(() {
      _messages.add(_DemoGroupMsg(
        text: displayText,
        senderLabel: _selfName,
        timestamp: now,
        isOutgoing: true,
        fileName: fileName,
      ));
      for (final member in _otherMembers) {
        final memberName = _nameForNodeId(member.nodeId);
        final replyText = '(Re $memberName-$_selfName): $displayText';
        _messages.add(_DemoGroupMsg(
          text: replyText,
          senderLabel: memberName,
          timestamp: now + 300,
          isOutgoing: false,
          fileName: null,
        ));
      }
      _controller.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendFile() async {
    final file = await openFile();
    if (file == null) return;
    _send(fileName: file.name);
  }

  Future<void> _sendImage() async {
    const imageTypes = XTypeGroup(
      label: 'images',
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    );
    final file = await openFile(acceptedTypeGroups: [imageTypes]);
    if (file == null) return;
    _send(fileName: file.name);
  }

  Widget _buildBubble(_DemoGroupMsg msg) {
    final time = DateTime.fromMillisecondsSinceEpoch(msg.timestamp);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: msg.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Column(
          crossAxisAlignment: msg.isOutgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (!msg.isOutgoing)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                child: Text(
                  msg.senderLabel,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: msg.isOutgoing ? _outgoingBubble : _incomingBubble,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    msg.fileName != null ? '📎 ${msg.fileName}' : msg.text,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    timeStr,
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _surfaceColor,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.group.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              '${widget.group.memberCount}명 · Demo',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      '그룹 채팅을 시작하세요.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _buildBubble(_messages[i]),
                  ),
          ),
          Container(
            color: _surfaceColor,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file, color: Colors.white70),
                  onPressed: _sendFile,
                  tooltip: '파일',
                ),
                IconButton(
                  icon: const Icon(Icons.image_outlined, color: Colors.white70),
                  onPressed: _sendImage,
                  tooltip: '이미지',
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: '메시지 입력',
                      hintStyle: TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                    ),
                    onSubmitted: (v) => _send(text: v),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFF6C5CE7)),
                  onPressed: () => _send(text: _controller.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  final BleService bleService;
  final MessagingService messagingService;

  const _ConnectionBadge({
    required this.bleService,
    required this.messagingService,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<String>>(
      stream: bleService.connectedDevicesStream,
      initialData: bleService.connectedDeviceIds,
      builder: (context, bleSnap) {
        return StreamBuilder<List<String>>(
          stream: messagingService.lanPeersStream,
          initialData: const [],
          builder: (context, lanSnap) {
            final bleCount = bleSnap.data?.length ?? 0;
            final lanCount = lanSnap.data?.length ?? 0;
            final total = bleCount + lanCount;
            final dotColor = total == 0 ? Colors.redAccent : Colors.greenAccent;
            final lanColor = lanCount > 0 ? Colors.greenAccent : Colors.redAccent;
            final bleColor = bleCount > 0 ? Colors.greenAccent : Colors.redAccent;

            String fmt(int n) => n >= 9 ? '9+' : '$n';

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 9, color: dotColor),
                const SizedBox(height: 2),
                Text(
                  '${fmt(lanCount)} WiFi',
                  style: TextStyle(color: lanColor, fontSize: 9),
                  textAlign: TextAlign.center,
                ),
                Text(
                  '${fmt(bleCount)} BLE',
                  style: TextStyle(color: bleColor, fontSize: 9),
                  textAlign: TextAlign.center,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  final AppSettings initialSettings;
  final Future<void> Function() onBackupIdentity;
  final Future<void> Function() onRestoreIdentity;
  final Future<void> Function() onCleanupStaleContacts;
  final Future<void> Function() onDeleteAllContacts;
  final Future<void> Function() onDeleteAllMessages;

  const _SettingsDialog({
    required this.initialSettings,
    required this.onBackupIdentity,
    required this.onRestoreIdentity,
    required this.onCleanupStaleContacts,
    required this.onDeleteAllContacts,
    required this.onDeleteAllMessages,
  });

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late bool _darkMode;
  late bool _demoMode;
  late String _avatarKey;
  late UserLevel _userLevel;
  late MessageAlertMode _messageAlertMode;
  late final TextEditingController _nameController;
  late final TextEditingController _depthController;

  @override
  void initState() {
    super.initState();
    _darkMode = widget.initialSettings.darkMode;
    _demoMode = widget.initialSettings.demoMode;
    _avatarKey = widget.initialSettings.avatarKey;
    _userLevel = widget.initialSettings.userLevel;
    _messageAlertMode = widget.initialSettings.messageAlertMode;
    _nameController = TextEditingController(
      text: widget.initialSettings.displayName,
    );
    _depthController = TextEditingController(
      text: widget.initialSettings.scanDefaultDepth.toString(),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _depthController.dispose();
    super.dispose();
  }

  String get _myCode => IdentityService().myNodeId
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final levelOptions = widget.initialSettings.userLevel.selfSelectableLevels;
    final canChooseSelfLevel = levelOptions.length > 1;

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1.0)),
      child: Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Settings',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            AppVersion.buildLabel,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: _myCode));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('내 Code를 복사했습니다.')),
                            );
                          },
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'My Code: $_myCode',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _darkMode,
                          onChanged: (value) {
                            setState(() => _darkMode = value);
                            unawaited(
                              AppSettingsService().save(_settingsFromFields()),
                            );
                          },
                          title: const Text('Dark mode'),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _demoMode,
                          onChanged: (value) {
                            setState(() => _demoMode = value);
                            unawaited(
                              AppSettingsService().save(_settingsFromFields()),
                            );
                          },
                          title: const Text('Demo mode'),
                        ),
                        const SizedBox(height: 8),
                        if (canChooseSelfLevel)
                          DropdownButtonFormField<UserLevel>(
                            initialValue: _userLevel,
                            decoration: const InputDecoration(
                              labelText: 'My level',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final level in levelOptions)
                                DropdownMenuItem(
                                  value: level,
                                  child: Text(level.label),
                                ),
                            ],
                            onChanged: (level) {
                              if (level != null) {
                                setState(() => _userLevel = level);
                              }
                            },
                          )
                        else
                          InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'My level',
                              border: OutlineInputBorder(),
                            ),
                            child: Text(_userLevel.label),
                          ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<MessageAlertMode>(
                          initialValue: _messageAlertMode,
                          decoration: const InputDecoration(
                            labelText: '문자 알림',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final mode in MessageAlertMode.values)
                              DropdownMenuItem(
                                value: mode,
                                child: Text(mode.label),
                              ),
                          ],
                          onChanged: (mode) {
                            if (mode != null) {
                              setState(() => _messageAlertMode = mode);
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _nameController,
                          maxLength: 32,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: 'My name',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Avatar',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 6),
                        AvatarPickerGrid(
                          selectedKey: _avatarKey,
                          onSelected: (key) {
                            setState(() => _avatarKey = key);
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _depthController,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: 'Default scan depth',
                            helperText: 'Default: 3, use -1 for all nodes',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 18),
                        OutlinedButton.icon(
                          onPressed: widget.onDeleteAllContacts,
                          icon: const Icon(Icons.people_outline),
                          label: const Text('연락처 전부 지우기'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: widget.onDeleteAllMessages,
                          icon: const Icon(Icons.delete_sweep_outlined),
                          label: const Text('Delete all messages'),
                        ),
                        const SizedBox(height: 18),
                        OutlinedButton.icon(
                          onPressed: widget.onCleanupStaleContacts,
                          icon: const Icon(Icons.cleaning_services_outlined),
                          label: const Text('Clean stale contacts'),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Removes old unconfirmed contacts without messages.',
                          style: TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                        const SizedBox(height: 18),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Identity backup',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: widget.onBackupIdentity,
                                icon: const Icon(Icons.backup_outlined, size: 18),
                                label: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('Backup'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: widget.onRestoreIdentity,
                                icon: const Icon(Icons.restore_page_outlined, size: 18),
                                label: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('Restore'),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Backup file contains this device identity keys. Keep it private.',
                          style: TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _save, child: const Text('Save')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    Navigator.pop(context, _settingsFromFields());
  }

  AppSettings _settingsFromFields() {
    final parsedDepth = int.tryParse(_depthController.text.trim()) ?? 3;
    final normalizedDepth = _normalizeDepth(parsedDepth);
    final displayName = _nameController.text.trim();
    final currentSettings = AppSettingsService().current;

    return AppSettings(
      darkMode: _darkMode,
      demoMode: _demoMode,
      displayName: displayName.isEmpty ? 'Me' : displayName,
      avatarKey: _avatarKey,
      scanDefaultDepth: normalizedDepth,
      userLevel: _userLevel,
      messageAlertMode: _messageAlertMode,
      lastShortNoticeAt: currentSettings.lastShortNoticeAt,
      lastLongNoticeAt: currentSettings.lastLongNoticeAt,
    );
  }

  int _normalizeDepth(int depth) {
    final normalized = depth < -1 ? 3 : depth;
    if (_userLevel != UserLevel.user && _userLevel != UserLevel.server) {
      return normalized;
    }
    if (normalized == -1) return 3;
    return normalized > 3 ? 3 : normalized;
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white30, size: 50),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Export Dialog ─────────────────────────────────────────────────────────────

class _ExportDialog extends StatefulWidget {
  final List<Contact> contacts;

  const _ExportDialog({required this.contacts});

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _includeContacts = true;
  bool _includeConversations = false;

  bool get _canExport => _includeContacts || _includeConversations;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(
            title: const Text('연락처'),
            value: _includeContacts,
            onChanged: (v) => setState(() => _includeContacts = v!),
          ),
          CheckboxListTile(
            title: const Text('대화'),
            value: _includeConversations,
            onChanged: (v) => setState(() => _includeConversations = v!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _canExport
              ? () => Navigator.pop(context, (
                    contacts: _includeContacts ? widget.contacts : <Contact>[],
                    includeConversations: _includeConversations,
                  ))
              : null,
          child: const Text('Export'),
        ),
      ],
    );
  }
}

// ── Import Dialog ─────────────────────────────────────────────────────────────

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

// 라디오 버튼 타일 (RadioListTile 신버전 deprecated 우회)
class _ImportRadioTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  const _ImportRadioTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onTap: onTap,
    );
  }
}

class _ImportDialogState extends State<_ImportDialog> {
  String _type = 'contacts';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ImportRadioTile(
            title: '연락처',
            subtitle: '현재 연락처에 추가',
            value: 'contacts',
            selected: _type == 'contacts',
            onTap: () => setState(() => _type = 'contacts'),
          ),
          _ImportRadioTile(
            title: '대화',
            subtitle: '기존 대화를 교체',
            value: 'conversations',
            selected: _type == 'conversations',
            onTap: () => setState(() => _type = 'conversations'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _type),
          child: const Text('파일 선택'),
        ),
      ],
    );
  }
}

// ── Notice Send Dialog ────────────────────────────────────────────────────────

class _NoticeSendDialog extends StatefulWidget {
  final AppSettings settings;
  final void Function(String text, MessageSendMode mode)? onSent;
  const _NoticeSendDialog({required this.settings, this.onSent});

  @override
  State<_NoticeSendDialog> createState() => _NoticeSendDialogState();
}

class _NoticeSendDialogState extends State<_NoticeSendDialog> {
  MessageSendMode _mode = MessageSendMode.shortNotice;
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (widget.settings.demoMode) {
      widget.onSent?.call(text, _mode);
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() => _sending = true);
    try {
      final sent = await MessagingService().sendTextMessage(
        targetNodeId: IdentityService().myNodeId, // notice broadcasts to all
        text: text,
        mode: _mode,
      );
      if (!mounted) return;
      if (sent) {
        widget.onSent?.call(text, _mode);
        Navigator.pop(context);
      } else {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('공지 전송 실패. 쿨다운 또는 연결을 확인하세요.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('공지 전송 오류: $e')),
      );
    }
  }

  String _cooldownStr(MessageSendMode mode) {
    final settings = AppSettingsService().current;
    final cooldown = settings.userLevel.noticeCooldown(mode);
    if (cooldown == null) return '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastUsed = mode == MessageSendMode.shortNotice
        ? settings.lastShortNoticeAt
        : settings.lastLongNoticeAt;
    if (lastUsed <= 0) return '';
    final remaining = cooldown.inMilliseconds - (now - lastUsed);
    if (remaining <= 0) return '';
    final hours = remaining ~/ 3600000;
    final minutes = (remaining % 3600000) ~/ 60000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E).withAlpha(235),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '공지 보내기',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _NoticeModeCard(
                    label: '공지S',
                    description: '연락처 전송',
                    cooldown: _cooldownStr(MessageSendMode.shortNotice),
                    selected: _mode == MessageSendMode.shortNotice,
                    onTap: () => setState(() => _mode = MessageSendMode.shortNotice),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _NoticeModeCard(
                    label: '공지L',
                    description: '전체 mesh 전송',
                    cooldown: _cooldownStr(MessageSendMode.longNotice),
                    selected: _mode == MessageSendMode.longNotice,
                    onTap: () => setState(() => _mode = MessageSendMode.longNotice),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 50,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '공지 내용 입력',
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white10,
                counterStyle: TextStyle(color: Colors.white54),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _sending ? null : _send,
                  child: _sending
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('전송'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── 공지 모드 선택 카드 ──────────────────────────────────────────────────────────
class _NoticeModeCard extends StatelessWidget {
  final String label;
  final String description;
  final String cooldown;
  final bool selected;
  final VoidCallback onTap;

  const _NoticeModeCard({
    required this.label,
    required this.description,
    required this.cooldown,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF7C6AF7).withAlpha(50)
              : Colors.white.withAlpha(13),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF7C6AF7) : Colors.white24,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: selected ? const Color(0xFF7C6AF7) : Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
            if (cooldown.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                cooldown,
                style: const TextStyle(color: Color(0xFFFF9800), fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 수신 중 깜박이는 점 ──────────────────────────────────────────────────────────
class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.15, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Text(
        '●',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 18,
        ),
      ),
    );
  }
}
