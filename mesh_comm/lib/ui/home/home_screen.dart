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
import 'package:mesh_comm/features/messaging/messaging_service.dart';
import 'package:mesh_comm/features/messaging/topology_demo.dart';
import 'package:mesh_comm/features/messaging/topology_graph.dart';
import 'package:mesh_comm/features/messaging/topology_message.dart';
import 'package:mesh_comm/features/settings/app_settings.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
import 'package:mesh_comm/ui/avatar/avatar_registry.dart';
import 'package:mesh_comm/ui/chat/chat_screen.dart';
import 'package:mesh_comm/ui/home/home_models.dart';
import 'package:mesh_comm/ui/qr/qr_screen.dart';

enum _ContactAction {
  rename,
  toggleTrust,
  toggleFavorite,
  setGroup,
  setAvatar,
  setLevel,
  deleteMessages,
  delete,
}

enum _GroupAction { rename, toggleFavorite, delete }

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _accent = Color(0xFF7C6AF7);
  static const _bluetooth = Color(0xFF8B7CF6);
  static const _alertChannel = MethodChannel('mesh_comm/alerts');

  final _contactService = ContactService();
  final _contactFileService = ContactFileService();
  final _identityBackupService = IdentityBackupService();
  final _settingsService = AppSettingsService();
  final _bleService = BleService();
  final _searchController = TextEditingController();
  final _scanDepthController = TextEditingController(text: '3');

  StreamSubscription<List<Contact>>? _contactsSubscription;
  StreamSubscription<AppSettings>? _settingsSubscription;
  StreamSubscription<ReceivedMessage>? _messageSubscription;
  StreamSubscription<TopologyResponse>? _topologySubscription;
  Timer? _chatCleanupTimer;
  List<Contact> _contacts = [];
  Set<String> _chatContactCodes = {};
  Map<String, int> _unreadCounts = {};
  String? _activeTopologyRequestId;
  final Map<String, TopologyResponse> _topologyResponses = {};
  List<Contact> _demoContacts = const [];
  List<TopologyResponse> _demoTopologyResponses = const [];
  bool _showScanNodeCounts = false;
  AppSettings _settings = const AppSettings();
  HomeFilter _filter = HomeFilter.all;
  _HomeSection _section = _HomeSection.home;
  bool _bluetoothEnabled = true;
  bool _isScanning = false;
  Map<TransportKind, TransportStatus> _transports = const {
    TransportKind.lan: TransportStatus(
      kind: TransportKind.lan,
      enabled: false,
      available: false,
    ),
    TransportKind.wifi: TransportStatus(
      kind: TransportKind.wifi,
      enabled: false,
      available: false,
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
    _contactsSubscription = _contactService.contactsStream.listen((contacts) {
      if (mounted) setState(() => _contacts = sortContacts(contacts));
    });
    _messageSubscription = MessagingService().messageStream.listen((_) {
      _playIncomingMessageAlert();
      _loadChatContactCodes();
      _loadUnreadCounts();
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
    _searchController.addListener(_refresh);
    _scanDepthController.addListener(_refresh);
  }

  @override
  void dispose() {
    _contactsSubscription?.cancel();
    _settingsSubscription?.cancel();
    _messageSubscription?.cancel();
    _topologySubscription?.cancel();
    _chatCleanupTimer?.cancel();
    _searchController
      ..removeListener(_refresh)
      ..dispose();
    _scanDepthController
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
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
      _demoTopologyResponses = const [];
      return;
    }

    final scenario = DemoTopologyScenario.large();
    _demoContacts = scenario.directContacts;
    _demoTopologyResponses = scenario.responses;
    _activeTopologyRequestId = 'demo-large';
    _topologyResponses.clear();
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

  void _openGroup(LocalContactGroup group) {
    _showMessage('${group.name} Group 채팅은 Phase-2에서 연결됩니다.');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
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
    final myNodeId = IdentityService().myNodeId;
    return _contacts
        .where(
          (contact) =>
              contact.isSaved && !_bytesEqual(contact.nodeId, myNodeId),
        )
        .toList();
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
      case _ContactAction.setGroup:
        await _setContactGroup(contact);
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
      case _ContactAction.setGroup:
        await _setContactGroup(contact);
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
    LocalContactGroup group,
    _GroupAction action,
  ) async {
    switch (action) {
      case _GroupAction.rename:
        await _renameGroup(group);
      case _GroupAction.toggleFavorite:
        for (final contact in group.members) {
          await _contactService.setFavorite(contact.nodeId, !group.isFavorite);
        }
      case _GroupAction.delete:
        for (final contact in group.members) {
          await _contactService.setGroup(contact.nodeId, null);
        }
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
    await _contactService.renameContact(contact.nodeId, name);
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

  Future<void> _setContactGroup(Contact contact) async {
    final group = await _askForText(
      title: contact.groupName == null ? 'Group 추가' : 'Group 변경',
      label: '로컬 Group 이름',
      initialValue: contact.groupName ?? '',
      hint: '비워두면 Group에서 제외됩니다.',
    );
    if (group == null) return;
    await _contactService.setGroup(contact.nodeId, group);
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
    await _contactService.setUserLevel(contact.nodeId, nextLevel);
  }

  Future<void> _renameGroup(LocalContactGroup group) async {
    final name = await _askForText(
      title: 'Group 이름 변경',
      label: '로컬 Group 이름',
      initialValue: group.name,
      hint: 'Group에 포함된 연락처에만 로컬로 적용됩니다.',
    );
    if (name == null || name.trim().isEmpty) return;
    for (final contact in group.members) {
      await _contactService.setGroup(contact.nodeId, name);
    }
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

  Future<void> _importContacts() async {
    try {
      final file = await openFile();
      if (file == null) return;

      final count = await _contactFileService.importFromJson(
        await file.readAsString(),
      );
      await _loadContacts();
      _showMessage('$count개 연락처를 가져왔습니다.');
    } catch (e) {
      _showMessage('연락처 import 실패: $e');
    }
  }

  Future<void> _exportContacts() async {
    try {
      final json = await _contactFileService.exportToJson();
      final filename =
          'mesh_comm_contacts_${DateTime.now().millisecondsSinceEpoch}.json';
      String savedPath;

      try {
        final location = await getSaveLocation(
          suggestedName: filename,
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'MeshComm contacts',
              extensions: ['json', 'meshcontacts'],
            ),
          ],
        );
        if (location == null) return;
        await File(location.path).writeAsString(json);
        savedPath = location.path;
      } catch (_) {
        final dir = await getApplicationDocumentsDirectory();
        final file = File(p.join(dir.path, filename));
        await file.writeAsString(json);
        savedPath = file.path;
      }

      _showMessage('연락처를 저장했습니다: $savedPath');
    } catch (e) {
      _showMessage('연락처 export 실패: $e');
    }
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

      try {
        final location = await getSaveLocation(
          suggestedName: filename,
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Encrypted MeshComm identity',
              extensions: ['json'],
            ),
          ],
        );
        if (location == null) return;
        await File(location.path).writeAsString(json);
        savedPath = location.path;
      } catch (_) {
        final dir = await getApplicationDocumentsDirectory();
        final file = File(p.join(dir.path, filename));
        await file.writeAsString(json);
        savedPath = file.path;
      }

      _showMessage('Encrypted identity backup 저장 완료: $savedPath');
    } catch (e) {
      _showMessage('Identity backup 실패: $e');
    }
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
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Encrypted MeshComm identity',
            extensions: ['json'],
          ),
        ],
      );
      if (file == null) return;
      final password = await _askIdentityBackupPassword(confirm: false);
      if (password == null) return;

      final nodeId = await _identityBackupService.restoreFromJson(
        await file.readAsString(),
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
          content: Column(
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
                const SizedBox(height: 8),
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
                icon: Icons.lan_outlined,
                enabled: _transport(TransportKind.lan).enabled,
                available: _transport(TransportKind.lan).available,
              ),
              _TransportButton(
                label: _transport(TransportKind.wifi).kind.label,
                icon: Icons.wifi_outlined,
                enabled: _transport(TransportKind.wifi).enabled,
                available: _transport(TransportKind.wifi).available,
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
    if (_filter == HomeFilter.groups) {
      return _GroupList(
        groups: buildGroups([selfContact, ...savedContacts]),
        onTap: _openGroup,
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
      onTap: _openChat,
      onAction: _handleContactAction,
      onScan: _runScan,
    );
  }

  Widget _buildSearch() {
    final savedContacts = [_selfContact(), ..._savedContactsExcludingSelf()];
    final groups = searchGroups(
      buildGroups(savedContacts),
      _searchController.text,
    );
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
                _GroupTile(
                  group: group,
                  onTap: () => _openGroup(group),
                  onAction: (action) => _handleGroupAction(group, action),
                ),
              if (contacts.isNotEmpty) const _SectionLabel(label: 'Contacts'),
              for (final contact in contacts)
                _ContactTile(
                  contact: contact,
                  unreadCount: _unreadCounts[contactCode(contact)] ?? 0,
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
    final depth = _limitedScanDepth(parsedDepth);
    final demoMode = _settings.demoMode;
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
                ? _accent
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
          setState(() => _section = _HomeSection.values[index]);
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
        ? _HomeScreenState._accent
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: available ? '$label On/Off' : '$label 吏???덉젙',
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
          _ConnectionBadge(bleService: BleService()),
          const SizedBox(height: 8),
        ],
      ),
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
        ? _HomeScreenState._accent
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 66,
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(color: color, fontSize: 10)),
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
  final ValueChanged<Contact> onTap;
  final void Function(Contact, _ContactAction) onAction;
  final VoidCallback onScan;

  const _ContactList({
    required this.contacts,
    required this.unreadCounts,
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
  final VoidCallback onTap;
  final ValueChanged<_ContactAction> onAction;

  const _ContactTile({
    required this.contact,
    this.unreadCount = 0,
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
        value: _ContactAction.setGroup,
        child: Text('Group 추가 / 변경'),
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
                    _ScanLegendDot(
                      color: _roleColor(
                        context,
                        userLevel: UserLevel.user,
                        isSelf: false,
                      ),
                      label: 'User',
                    ),
                    const SizedBox(height: 5),
                    _ScanLegendDot(
                      color: _roleColor(
                        context,
                        userLevel: UserLevel.server,
                        isSelf: false,
                      ),
                      label: 'Server',
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
        final angle =
            -math.pi / 2 + (2 * math.pi * i / math.max(1, ringNodes.length));
        final radius = isSelf ? 0.0 : maxRadius * ringDepth / maxDepth;
        final position = Offset(
          center.dx + math.cos(angle) * radius,
          center.dy + math.sin(angle) * radius,
        );
        indexById[graphNode.id] = scanNodes.length;
        scanNodes.add(
          _ScanMapNode(
            id: graphNode.id,
            title: _graphNodeName(graphNode),
            subtitle: [
              _deviceLabel(graphNode.summary.deviceType),
              'depth ${graphNode.depth}',
              graphNode.contact?.isSaved ?? graphNode.summary.isSaved
                  ? 'known'
                  : 'new',
              graphNode.summary.transportKind.label,
            ].join(' · '),
            position: positions[graphNode.id] ?? position,
            deviceType: graphNode.summary.deviceType,
            userLevel: graphNode.summary.userLevel,
            connectionCount: graphNode.connectionCount,
            isMe: isSelf,
            isSavedContact:
                graphNode.contact?.isSaved ?? graphNode.summary.isSaved,
            isFavorite: graphNode.contact?.isFavorite ?? false,
            contact: graphNode.contact,
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
        title: myName.trim().isEmpty ? 'Me' : myName.trim(),
        subtitle: '${_deviceLabel(myDeviceType)} · Me',
        position: center,
        deviceType: myDeviceType,
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
          title: contactDisplayName(contact),
          subtitle: [
            _deviceLabel(contact.deviceType),
            contact.isSaved ? 'contact' : 'found',
            'BLE',
          ].join(' · '),
          position: position,
          deviceType: contact.deviceType,
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
                  const _NodeInfoLine('Route', 'BLE'),
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
              const _NodeInfoLine('Route', 'BLE'),
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
        TransportKind.wifi => 1.5,
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
  final int connectionCount;
  final bool isMe;
  final bool isSavedContact;
  final bool isFavorite;
  final Contact? contact;

  const _ScanMapNode({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.position,
    required this.deviceType,
    required this.userLevel,
    required this.connectionCount,
    this.isMe = false,
    this.isSavedContact = false,
    this.isFavorite = false,
    this.contact,
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
  late final AnimationController _pulseController;

  bool get _shouldPulse => !widget.node.isMe && !widget.node.isSavedContact;

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
    final color = _roleColor(
      context,
      userLevel: widget.node.userLevel,
      isSelf: widget.node.isMe,
    );
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

class _GroupList extends StatelessWidget {
  final List<LocalContactGroup> groups;
  final ValueChanged<LocalContactGroup> onTap;
  final void Function(LocalContactGroup, _GroupAction) onAction;

  const _GroupList({
    required this.groups,
    required this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const _EmptyState(
        icon: Icons.folder_copy_outlined,
        title: '아직 Group이 없습니다.',
        detail: '연락처의 ... 메뉴에서 Group을 추가하세요.',
      );
    }
    return ListView(
      children: [
        for (final group in groups)
          _GroupTile(
            group: group,
            onTap: () => onTap(group),
            onAction: (action) => onAction(group, action),
          ),
      ],
    );
  }
}

class _GroupTile extends StatelessWidget {
  final LocalContactGroup group;
  final VoidCallback onTap;
  final ValueChanged<_GroupAction> onAction;

  const _GroupTile({
    required this.group,
    required this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const CircleAvatar(
        backgroundColor: Color(0xFF2D2858),
        child: Icon(Icons.groups_outlined, color: _HomeScreenState._accent),
      ),
      title: Row(
        children: [
          Expanded(child: Text(group.name)),
          if (group.isFavorite)
            const Icon(Icons.star, color: Colors.amber, size: 16),
        ],
      ),
      subtitle: Text('${group.memberCount}명 · 로컬 Group'),
      trailing: PopupMenuButton<_GroupAction>(
        tooltip: 'Group 메뉴',
        onSelected: onAction,
        itemBuilder: (context) => [
          const PopupMenuItem(value: _GroupAction.rename, child: Text('이름 변경')),
          PopupMenuItem(
            value: _GroupAction.toggleFavorite,
            child: Text(group.isFavorite ? '즐겨찾기 해제' : '즐겨찾기 추가'),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _GroupAction.delete,
            child: Text('Group 삭제'),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  final BleService bleService;

  const _ConnectionBadge({required this.bleService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<String>>(
      stream: bleService.connectedDevicesStream,
      initialData: bleService.connectedDeviceIds,
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        final color = count == 0 ? Colors.redAccent : Colors.greenAccent;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 9, color: color),
            const SizedBox(height: 3),
            Text('$count 연결', style: TextStyle(color: color, fontSize: 9)),
          ],
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
  final Future<void> Function() onDeleteAllMessages;

  const _SettingsDialog({
    required this.initialSettings,
    required this.onBackupIdentity,
    required this.onRestoreIdentity,
    required this.onCleanupStaleContacts,
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
                                icon: const Icon(Icons.backup_outlined),
                                label: const Text('Backup'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: widget.onRestoreIdentity,
                                icon: const Icon(Icons.restore_page_outlined),
                                label: const Text('Restore'),
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
