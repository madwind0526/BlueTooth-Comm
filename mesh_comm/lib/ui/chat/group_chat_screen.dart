import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/groups/chat_group_model.dart';
import 'package:mesh_comm/features/groups/group_messaging_service.dart';
import 'package:mesh_comm/features/groups/group_service.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/messaging/message_policy.dart';
import 'package:mesh_comm/features/messaging/messaging_service.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
import 'package:mesh_comm/features/transfer/transfer_model.dart';
import 'package:mesh_comm/features/transfer/transfer_service.dart';
import 'package:mesh_comm/features/transfer/transfer_storage_service.dart';
import 'package:mesh_comm/ui/home/home_models.dart';

class GroupChatScreen extends StatefulWidget {
  final ChatGroup group;
  final List<Contact> contacts;

  const GroupChatScreen({
    super.key,
    required this.group,
    required this.contacts,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  static const Color _bgColor = Color(0xFF1A1A2E);
  static const Color _surfaceColor = Color(0xFF16213E);
  static const Color _outgoingBubble = Color(0xFF6C5CE7);
  static const Color _incomingBubble = Color(0xFF2D2D3F);
  static const Color _textPrimary = Color(0xFFECECEC);
  static const Color _textSecondary = Color(0xFF9090A0);

  static const _dropdownItems = [
    ('일반', 'normal'),
    ('타임', 'timed'),
    ('파일', 'file'),
    ('이미지', 'image'),
  ];

  final _groupService = GroupService();
  final _groupMessaging = GroupMessagingService();

  late ChatGroup _group;
  List<GroupMessage> _messages = [];
  final _controller = TextEditingController();
  final _keyboardFocusNode = FocusNode();
  final _scrollController = ScrollController();
  StreamSubscription<GroupMessage>? _msgSubscription;
  StreamSubscription<ChatGroup>? _updateSubscription;
  StreamSubscription<dynamic>? _transferSubscription;
  final Map<String, ({TransferMeta meta, double progress, TransferDirection direction})>
      _activeTransfers = {};
  // 완료된 파일: fileName → 절대 경로 (sent/ 또는 received/ 에 저장된 파일)
  final Map<String, String> _filePaths = {};
  final Map<String, TransferKind> _fileKinds = {};
  MessageSendMode _messageMode = MessageSendMode.normal;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _loadMessages();
    _loadExistingFiles();
    _msgSubscription = _groupMessaging.messageStream
        .where((m) => m.groupId == _group.groupId)
        .listen(_onIncomingMessage);
    _updateSubscription = _groupMessaging.updateStream
        .where((g) => g.groupId == _group.groupId)
        .listen((updated) {
      if (mounted) setState(() => _group = updated);
    });
    // 화면 복원: 진행 중인 그룹 멤버 관련 전송만 복원
    final memberHexes = _group.members.map((m) => m.nodeIdHex).toSet();
    for (final s in TransferService().activeTransferSnapshots) {
      if (!memberHexes.contains(s.contactNodeIdHex)) continue;
      _activeTransfers[s.tid] =
          (meta: s.meta, progress: s.progress, direction: s.direction);
    }

    _transferSubscription = MessagingService().transferStream.listen((event) async {
      if (!mounted) return;
      // 그룹 멤버 관련 전송만 처리 (1:1 채팅 오염 방지)
      final isGroupTransfer = _activeTransfers.containsKey(event.tid) ||
          (event is TransferStarted &&
              memberHexes.contains(event.contactNodeIdHex));
      if (!isGroupTransfer) return;

      if (event is TransferCompleted) {
        // 비동기 파일 저장 후 setState
        if (!mounted) return;
        setState(() => _activeTransfers.remove(event.tid));
        try {
          final dir = await TransferStorageService.groupFileDir(
            groupName: _group.name,
            sub: 'received',
          );
          final path = p.join(dir.path, event.meta.fileName);
          await File(path).writeAsBytes(event.data);
          if (!mounted) return;
          setState(() {
            _filePaths[event.meta.fileName] = path;
            _fileKinds[event.meta.fileName] = event.meta.kind;
          });
        } catch (e) {
          debugPrint('[GroupChat] 파일 저장 실패: $e');
        }
        return;
      }

      setState(() {
        switch (event) {
          case TransferStarted():
            _activeTransfers[event.tid] =
                (meta: event.meta, progress: 0.0, direction: event.direction);
          case TransferProgress():
            final prev = _activeTransfers[event.tid];
            if (prev != null) {
              _activeTransfers[event.tid] =
                  (meta: prev.meta, progress: event.progress, direction: prev.direction);
            }
          case TransferCompleted():
          case TransferFailed():
            _activeTransfers.remove(event.tid);
        }
      });
    });
  }

  @override
  void dispose() {
    _msgSubscription?.cancel();
    _updateSubscription?.cancel();
    _transferSubscription?.cancel();
    _controller.dispose();
    _keyboardFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    await _groupService.markMessagesRead(_group.groupId);
    final msgs = await _groupService.getMessages(_group.groupId);
    if (!mounted) return;
    setState(() => _messages = msgs);
    _scrollToBottom();
  }

  void _onIncomingMessage(GroupMessage msg) {
    if (!mounted) return;
    setState(() => _messages.add(msg));
    _groupService.markMessagesRead(_group.groupId);
    _scrollToBottom();
  }

  String _senderName(Uint8List senderId) {
    final hex = _hex(senderId);
    for (final c in widget.contacts) {
      if (contactCode(c) == hex) return contactDisplayName(c);
    }
    return hex.substring(0, 8);
  }

  bool _isMe(Uint8List senderId) {
    return _bytesEqual(senderId, IdentityService().myNodeId);
  }

  bool get _isLeader =>
      _group.isLeader(IdentityService().myNodeId);

  String get _dropdownValue => switch (_messageMode) {
        MessageSendMode.normal => 'normal',
        MessageSendMode.timed => 'timed',
        _ => 'normal',
      };

  void _onDropdownChanged(String? value) {
    if (value == null || _isSending) return;
    switch (value) {
      case 'file':
        _pickAndSendFile();
      case 'image':
        _pickAndSendImage();
      case 'normal':
        setState(() => _messageMode = MessageSendMode.normal);
      case 'timed':
        setState(() => _messageMode = MessageSendMode.timed);
    }
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;
    setState(() => _isSending = true);
    final sent = await _groupMessaging.sendGroupMessage(
      group: _group,
      text: text,
    );
    if (!mounted) return;
    setState(() {
      _isSending = false;
      if (sent >= 0) _controller.clear();
    });
    if (sent > 0) _scrollToBottom();
    await _loadMessages();
  }

  Future<void> _pickAndSendFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    final data = Uint8List.fromList(await file.readAsBytes());
    // 발신자: sent/ 에 저장 후 UI 반영
    try {
      final dir = await TransferStorageService.groupFileDir(
          groupName: _group.name, sub: 'sent');
      final path = p.join(dir.path, file.name);
      await File(path).writeAsBytes(data);
      if (!mounted) return;
      setState(() {
        _filePaths[file.name] = path;
        _fileKinds[file.name] = TransferKind.file;
      });
    } catch (_) {}
    for (final member in _group.members) {
      if (_isMe(member.nodeId)) continue;
      if (!MessagingService().isDirectlyConnected(member.nodeIdHex)) continue;
      await MessagingService().sendFile(
        data: data,
        fileName: file.name,
        mimeType: 'application/octet-stream',
        targetNodeIdHex: member.nodeIdHex,
        kind: TransferKind.file,
        groupId: _group.groupId,
      );
    }
    await _groupMessaging.sendGroupMessage(
      group: _group,
      text: file.name,
      filePrefix: '__FILE__',
    );
    if (mounted) {
      _scrollToBottom();
      await _loadMessages();
    }
  }

  Future<void> _pickAndSendImage() async {
    const imageTypes = XTypeGroup(
      label: 'images',
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    );
    final file = await openFile(acceptedTypeGroups: [imageTypes]);
    if (file == null || !mounted) return;
    final data = Uint8List.fromList(await file.readAsBytes());
    // 발신자: sent/ 에 저장 후 UI 반영
    try {
      final dir = await TransferStorageService.groupFileDir(
          groupName: _group.name, sub: 'sent');
      final path = p.join(dir.path, file.name);
      await File(path).writeAsBytes(data);
      if (!mounted) return;
      setState(() {
        _filePaths[file.name] = path;
        _fileKinds[file.name] = TransferKind.image;
      });
    } catch (_) {}
    for (final member in _group.members) {
      if (_isMe(member.nodeId)) continue;
      if (!MessagingService().isDirectlyConnected(member.nodeIdHex)) continue;
      await MessagingService().sendFile(
        data: data,
        fileName: file.name,
        mimeType: 'image/jpeg',
        targetNodeIdHex: member.nodeIdHex,
        kind: TransferKind.image,
        groupId: _group.groupId,
      );
    }
    await _groupMessaging.sendGroupMessage(
      group: _group,
      text: file.name,
      filePrefix: '__IMAGE__',
    );
    if (mounted) {
      _scrollToBottom();
      await _loadMessages();
    }
  }

  void _showMemberList() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E).withAlpha(230),
        title: Text(
          '${_group.name} 그룹원 (${_group.memberCount}명)',
          style: const TextStyle(fontSize: 15),
        ),
        content: SizedBox(
          width: 280,
          height: 300,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(10),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _group.members.length,
              itemBuilder: (_, i) {
                final m = _group.members[i];
                final isLeader = _group.isLeader(m.nodeId);
                final name = _senderName(m.nodeId);
                return ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.person_outline,
                    size: 20,
                    color: isLeader ? Colors.orange : Colors.grey,
                  ),
                  title: Text(name, style: const TextStyle(fontSize: 14)),
                  trailing: isLeader
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.orange.withAlpha(50),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '방장',
                            style: TextStyle(fontSize: 11, color: Colors.orange),
                          ),
                        )
                      : null,
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Future<void> _inviteMember() async {
    final unconnected = widget.contacts.where((c) {
      if (_bytesEqual(c.nodeId, IdentityService().myNodeId)) return false;
      if (_group.hasMember(c.nodeId)) return false;
      return true;
    }).toList();

    if (unconnected.isEmpty) {
      _showMessage('초대 가능한 연락처가 없습니다.');
      return;
    }
    if (_group.isFull) {
      _showMessage('그룹이 가득 찼습니다. (최대 10명)');
      return;
    }

    final contact = await showDialog<Contact>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('멤버 초대'),
        content: SizedBox(
          width: 300,
          child: ListView(
            shrinkWrap: true,
            children: unconnected
                .map((c) => ListTile(
                      title: Text(contactDisplayName(c)),
                      onTap: () => Navigator.pop(ctx, c),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        ],
      ),
    );

    if (contact == null || !mounted) return;
    // 수락 전 addMember 하지 않음 — _handleInviteResp에서 처리
    await _groupMessaging.sendInvite(group: _group, targetNodeId: contact.nodeId);
    _showMessage('${contactDisplayName(contact)}에게 초대장을 보냈습니다.');
  }

  Future<void> _kickMember() async {
    final others = _group.members.where((m) => !_isMe(m.nodeId)).toList();
    if (others.isEmpty) return;

    final target = await showDialog<GroupMember>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('멤버 추방'),
        content: SizedBox(
          width: 300,
          child: ListView(
            shrinkWrap: true,
            children: others
                .map((m) => ListTile(
                      title: Text(_senderName(m.nodeId)),
                      onTap: () => Navigator.pop(ctx, m),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        ],
      ),
    );
    if (target == null || !mounted) return;

    // 추방 확인
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('멤버 추방'),
        content: Text('${_senderName(target.nodeId)}을(를) 추방하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('추방'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _groupService.removeMember(_group.groupId, target.nodeId);
    await _groupMessaging.broadcastMemberUpdate(
      group: _group,
      action: 'remove',
      targetNodeId: target.nodeId,
    );
    final updated = await _groupService.getGroup(_group.groupId);
    if (updated != null && mounted) setState(() => _group = updated);
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('그룹 나가기'),
        content: Text('${_group.name}에서 나가시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final myNodeId = IdentityService().myNodeId;
    Uint8List? newLeaderId;
    if (_isLeader) {
      newLeaderId = await _groupService.getNextLeader(_group.groupId, myNodeId);
      if (newLeaderId != null) {
        await _groupService.setLeader(_group.groupId, newLeaderId);
      }
    }
    await _groupMessaging.broadcastLeave(
      group: _group,
      newLeaderId: newLeaderId,
    );
    await _groupService.removeMember(_group.groupId, myNodeId);
    if (mounted) Navigator.pop(context);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Widget _buildTransferBanner() {
    return Container(
      color: const Color(0xFF1A1A2E),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: _activeTransfers.entries.map((entry) {
          final tid = entry.key;
          final t = entry.value;
          final isOut = t.direction == TransferDirection.outgoing;
          final label = isOut ? '전송 중' : '수신 중';
          final icon = t.meta.kind == TransferKind.image
              ? Icons.image_outlined
              : Icons.insert_drive_file_outlined;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(icon, size: 14, color: _textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$label: ${t.meta.fileName}',
                              style: const TextStyle(
                                color: _textSecondary,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!isOut) ...[
                            const SizedBox(width: 4),
                            const _BlinkingDots(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      LinearProgressIndicator(
                        value: t.progress,
                        backgroundColor: const Color(0xFF2A2A3E),
                        color: isOut
                            ? const Color(0xFFFF9800)
                            : const Color(0xFF4ADE80),
                        minHeight: 3,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${(t.progress * 100).toInt()}%',
                  style: const TextStyle(color: _textSecondary, fontSize: 10),
                ),
                GestureDetector(
                  onTap: () {
                    TransferService().cancelTransfer(tid);
                    MessagingService().cancelTransfer(tid);
                  },
                  child: const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.close, size: 14, color: Color(0xFFF87171)),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          if (_activeTransfers.isNotEmpty) _buildTransferBanner(),
          Expanded(child: _buildMessageList()),
          _buildInputBar(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _surfaceColor,
      foregroundColor: _textPrimary,
      elevation: 0,
      titleSpacing: 0,
      title: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFF2D2858),
            child: Icon(Icons.groups_outlined, color: Color(0xFFFF9800)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _group.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _textPrimary,
                  ),
                ),
                Text(
                  '${_group.memberCount}명',
                  style: const TextStyle(fontSize: 11, color: _textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.group_outlined),
          onPressed: _showMemberList,
          tooltip: '그룹원 보기',
        ),
        IconButton(
          icon: const Icon(Icons.person_add_outlined),
          onPressed: _inviteMember,
          tooltip: '멤버 초대',
        ),
        if (_isLeader)
          IconButton(
            icon: const Icon(Icons.person_remove_outlined, color: Colors.orangeAccent),
            onPressed: _kickMember,
            tooltip: '멤버 추방',
          ),
        IconButton(
          icon: const Icon(Icons.exit_to_app, color: Colors.redAccent),
          onPressed: _leaveGroup,
          tooltip: '그룹 나가기',
        ),
      ],
    );
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return const Center(
        child: Text(
          '아직 메시지가 없습니다.',
          style: TextStyle(color: _textSecondary, fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: _messages.length,
      itemBuilder: (context, index) => _buildMessageItem(_messages[index]),
    );
  }

  Widget _buildMessageItem(GroupMessage msg) {
    final isOut = msg.isOutgoing || _isMe(msg.senderId);
    final label = isOut ? 'Me' : _senderName(msg.senderId);
    final isFile = msg.isFile;
    final isImage = msg.isImage;
    final displayText = isFile
        ? msg.text.replaceFirst('__FILE__', '')
        : isImage
            ? msg.text.replaceFirst('__IMAGE__', '')
            : msg.text;

    final time = DateTime.fromMillisecondsSinceEpoch(msg.timestamp);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    // 저장된 파일/이미지가 있으면 미리보기 버블
    final savedPath = (isFile || isImage) ? _filePaths[displayText] : null;
    if (savedPath != null) {
      final kind = _fileKinds[displayText] ??
          (isImage ? TransferKind.image : TransferKind.file);
      return _buildFileBubble(
        isOut: isOut,
        label: label,
        timeStr: timeStr,
        fileName: displayText,
        filePath: savedPath,
        kind: kind,
      );
    }

    // 아직 전송/수신 중이거나 데이터 없음: 아이콘 + 파일명 텍스트 버블
    final icon = isImage
        ? Icons.image_outlined
        : isFile
            ? Icons.insert_drive_file_outlined
            : null;

    Widget content = icon != null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: _textPrimary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  displayText,
                  style: const TextStyle(color: _textPrimary, fontSize: 15, height: 1.4),
                ),
              ),
            ],
          )
        : Text(
            displayText,
            style: const TextStyle(color: _textPrimary, fontSize: 15, height: 1.4),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!isOut)
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 2),
              child: Text(
                label,
                style: const TextStyle(color: _textSecondary, fontSize: 11),
              ),
            ),
          Row(
            mainAxisAlignment: isOut ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.72,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isOut ? _outgoingBubble : _incomingBubble,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isOut ? 18 : 4),
                      bottomRight: Radius.circular(isOut ? 4 : 18),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      content,
                      const SizedBox(height: 4),
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 10,
                          color: _textPrimary.withAlpha(153),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 앱 시작 시 sent/received 디렉토리에 기존 파일이 있으면 불러온다.
  Future<void> _loadExistingFiles() async {
    const imageExts = {'.jpg', '.jpeg', '.png', '.gif', '.webp'};
    for (final sub in ['sent', 'received']) {
      try {
        final dir = await TransferStorageService.groupFileDir(
            groupName: _group.name, sub: sub);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (_filePaths.containsKey(name)) continue;
          final ext = p.extension(name).toLowerCase();
          _filePaths[name] = entity.path;
          _fileKinds[name] =
              imageExts.contains(ext) ? TransferKind.image : TransferKind.file;
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Widget _buildFileBubble({
    required bool isOut,
    required String label,
    required String timeStr,
    required String fileName,
    required String filePath,
    required TransferKind kind,
  }) {
    Widget fileContent;
    if (kind == TransferKind.image) {
      fileContent = GestureDetector(
        onTap: () => _showImageFullScreen(filePath, fileName),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(filePath),
            width: 200,
            height: 200,
            fit: BoxFit.cover,
            errorBuilder: (ctx, err, stack) => const Icon(
              Icons.broken_image_outlined,
              size: 60,
              color: _textSecondary,
            ),
          ),
        ),
      );
    } else {
      fileContent = GestureDetector(
        onTap: () => _showSaveDialog(filePath, fileName),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isOut ? _outgoingBubble : _incomingBubble,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file, color: Colors.white70, size: 28),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _textPrimary, fontSize: 13),
                    ),
                    Text(
                      '탭하여 저장',
                      style: const TextStyle(color: _textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment:
            isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!isOut)
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 2),
              child: Text(label,
                  style: const TextStyle(color: _textSecondary, fontSize: 11)),
            ),
          Row(
            mainAxisAlignment:
                isOut ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [fileContent],
          ),
          Padding(
            padding: EdgeInsets.only(
              left: isOut ? 0 : 8,
              right: isOut ? 8 : 0,
              top: 2,
            ),
            child: Text(timeStr,
                style:
                    TextStyle(fontSize: 10, color: _textPrimary.withAlpha(153))),
          ),
        ],
      ),
    );
  }

  void _showImageFullScreen(String filePath, String fileName) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(child: Image.file(File(filePath))),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.download_rounded, color: Colors.white),
                    tooltip: '저장',
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _showSaveDialog(filePath, fileName);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSaveDialog(String srcPath, String fileName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('파일 저장'),
        content: Text('$fileName\nDownloads 폴더에 저장하시겠습니까?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('저장')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final dest = await TransferStorageService.meshCommPublicDir(sub: 'Downloads');
      final destPath = p.join(dest.path, fileName);
      await File(srcPath).copy(destPath);
      _showMessage('저장 완료: Downloads/$fileName');
    } catch (e) {
      _showMessage('저장 실패: $e');
    }
  }

  Widget _buildInputBar() {
    final canSend = AppSettingsService().current.userLevel.canSendMessages;
    if (!canSend) {
      return Container(
        color: _surfaceColor,
        padding: const EdgeInsets.all(12),
        child: const Text(
          'Server mode: 메시지 전송 불가',
          style: TextStyle(color: _textSecondary),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: _surfaceColor,
        border: Border(top: BorderSide(color: Color(0xFF2A2A3E), width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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
                              style: const TextStyle(
                                color: _textPrimary,
                                fontSize: 12,
                              ),
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
                  onChanged: _isSending ? null : _onDropdownChanged,
                ),
              ),
            ),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: KeyboardListener(
                  focusNode: _keyboardFocusNode,
                  onKeyEvent: (event) {
                    if (event is! KeyDownEvent) return;
                    if (event.logicalKey == LogicalKeyboardKey.enter &&
                        HardwareKeyboard.instance.isControlPressed) {
                      _sendText();
                    }
                  },
                  child: TextField(
                    controller: _controller,
                    maxLength: _messageMode.maxLength,
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
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
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
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                return IconButton(
                  onPressed: hasText && !_isSending ? _sendText : null,
                  style: IconButton.styleFrom(
                    backgroundColor:
                        hasText ? _outgoingBubble : const Color(0xFF2A2A3E),
                    foregroundColor: _textPrimary,
                    padding: const EdgeInsets.all(12),
                    minimumSize: const Size(44, 44),
                  ),
                  icon: _isSending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _textPrimary,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 20),
                  tooltip: '전송',
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _BlinkingDots extends StatefulWidget {
  const _BlinkingDots();
  @override
  State<_BlinkingDots> createState() => _BlinkingDotsState();
}

class _BlinkingDotsState extends State<_BlinkingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addListener(() {
        final f = (_ctrl.value * 4).floor() % 4;
        if (f != _frame) setState(() => _frame = f);
      })
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dots = '.' * (_frame + 1);
    return Text(
      dots.padRight(3),
      style: const TextStyle(color: Color(0xFF9E9EB8), fontSize: 11),
    );
  }
}
