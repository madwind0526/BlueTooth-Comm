// lib/ui/chat/chat_screen.dart

import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/messaging/message_policy.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
import 'package:mesh_comm/features/transfer/transfer_model.dart';
import 'package:mesh_comm/features/transfer/transfer_service.dart';
import 'package:mesh_comm/features/transfer/transfer_storage_service.dart';
import 'package:mesh_comm/ui/avatar/avatar_registry.dart';

import 'package:mesh_comm/features/messaging/messaging_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 내부 메시지 모델
// ─────────────────────────────────────────────────────────────────────────────

class _ChatMessage {
  final String text;
  final int timestamp;
  final bool isOutgoing;
  final bool isTrusted;

  const _ChatMessage({
    required this.text,
    required this.timestamp,
    required this.isOutgoing,
    required this.isTrusted,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ChatScreen
// ─────────────────────────────────────────────────────────────────────────────

/// 1:1 채팅 화면.
///
/// MessagingService가 구현되면 TODO 주석을 해제하고 실제 스트림과 연결한다.
class ChatScreen extends StatefulWidget {
  final Contact contact;

  const ChatScreen({super.key, required this.contact});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // ── 상수 ────────────────────────────────────────────────────────────────────

  int get _maxLength => _messageMode.maxLength;

  // ── 색상 ────────────────────────────────────────────────────────────────────

  // Material 3 다크 테마 색상
  static const Color _bgColor = Color(0xFF1A1A2E);
  static const Color _surfaceColor = Color(0xFF16213E);
  static const Color _outgoingBubble = Color(0xFF6C5CE7); // 보라
  static const Color _incomingBubble = Color(0xFF2D2D3F); // 어두운 회색
  static const Color _inputBarBg = Color(0xFF16213E);
  static const Color _textPrimary = Color(0xFFECECEC);
  static const Color _textSecondary = Color(0xFF9090A0);
  static const Color _trustedColor = Color(0xFF4ADE80); // 초록
  static const Color _untrustedColor = Color(0xFFFBBF24); // 주황
  static const Color _warningBannerBg = Color(0xFF3D2B00);
  static const Color _warningBannerBorder = Color(0xFFFBBF24);

  // ── 상태 ────────────────────────────────────────────────────────────────────

  final List<_ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final FocusNode _keyboardFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  bool _chatBlocked = false;
  MessageSendMode _messageMode = MessageSendMode.normal;
  Timer? _historyRefreshTimer;

  StreamSubscription<ReceivedMessage>? _msgSubscription;
  StreamSubscription<TransferEvent>? _transferSubscription;

  // 진행 중인 전송: tid → 진행률 (0.0~1.0) 및 메타
  final Map<String, _ActiveTransfer> _activeTransfers = {};
  // 완료된 파일/이미지 (발신·수신 모두)
  final List<_CompletedFile> _completedFiles = [];
  // 발신 이미지 캐시 tid → bytes (TransferCompleted 전까지 보관)
  final Map<String, Uint8List> _outgoingImageCache = {};

  // ── 라이프사이클 ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (!AppSettingsService().current.userLevel.canSendMessages ||
        !widget.contact.userLevel.canSendMessages) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final message = !AppSettingsService().current.userLevel.canSendMessages
            ? 'Server mode only relays messages. Chat is disabled.'
            : '$_displayName is Server mode. Chat is disabled.';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        final popped = await Navigator.of(context).maybePop();
        if (!popped && mounted) {
          setState(() => _chatBlocked = true);
        }
      });
      return;
    }
    _loadHistory();
    _subscribeToStream();
    _subscribeToTransfers();
    unawaited(_loadStoredFiles());
    _historyRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _loadHistory(replace: true),
    );
    unawaited(_markConversationRead());
  }

  @override
  void dispose() {
    _msgSubscription?.cancel();
    _transferSubscription?.cancel();
    _historyRefreshTimer?.cancel();
    _controller.dispose();
    _inputFocusNode.dispose();
    _keyboardFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── 메시지 로드 ──────────────────────────────────────────────────────────────

  Future<void> _loadHistory({bool replace = false}) async {
    final history = await MessagingService().getMessageHistory(
      widget.contact.nodeId,
    );
    if (!mounted) return;
    setState(() {
      if (replace) {
        _messages.clear();
      }
      _messages.addAll(
        history.map(
          (m) => _ChatMessage(
            text: m.text,
            timestamp: m.timestamp,
            isOutgoing: m.isOutgoing,
            isTrusted: m.isTrusted,
          ),
        ),
      );
    });
    _scrollToBottom();
  }

  void _subscribeToStream() {
    _msgSubscription = MessagingService().messageStream
        .where(
          (m) =>
              m.senderNodeId.length == widget.contact.nodeId.length &&
              List.generate(
                m.senderNodeId.length,
                (i) => m.senderNodeId[i] == widget.contact.nodeId[i],
              ).every((v) => v),
        )
        .listen((m) {
          if (!mounted) return;
          MessagingService().markMessageDisplayed(m);
          unawaited(_markConversationRead());
          setState(() {
            _messages.add(
              _ChatMessage(
                text: m.text,
                timestamp: m.timestamp,
                isOutgoing: false,
                isTrusted: m.isTrusted,
              ),
            );
          });
          _scrollToBottom();
        });
  }

  Future<void> _markConversationRead() {
    return DatabaseService().markMessagesReadForContact(
      widget.contact.nodeId,
      IdentityService().myNodeId,
    );
  }

  void _subscribeToTransfers() {
    final targetHex = widget.contact.nodeId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    // 채팅방 재진입 시 진행 중인 전송 복원
    for (final s in TransferService().activeTransferSnapshots) {
      _activeTransfers[s.tid] = _ActiveTransfer(
        meta: s.meta,
        progress: s.progress,
        direction: s.direction,
        targetNodeIdHex: targetHex,
      );
    }

    _transferSubscription = MessagingService().transferStream.listen((event) {
      if (!mounted) return;
      final isOurs = _activeTransfers.containsKey(event.tid) || event is TransferStarted;
      if (!isOurs) return;

      setState(() {
        switch (event) {
          case TransferStarted():
            _activeTransfers[event.tid] = _ActiveTransfer(
              meta: event.meta,
              progress: 0,
              direction: event.direction,
              targetNodeIdHex: targetHex,
            );
          case TransferProgress():
            _activeTransfers[event.tid]?.progress = event.progress;
          case TransferCompleted():
            _activeTransfers.remove(event.tid);
            // 이미 저장된 항목 중복 방지 (MessagingService가 디스크에 저장함)
            if (_completedFiles.any((f) => f.tid == event.tid)) break;
            final cachedBytes = _outgoingImageCache.remove(event.tid);
            final bytes = event.direction == TransferDirection.incoming
                ? event.data
                : cachedBytes;
            _completedFiles.add(_CompletedFile(
              tid: event.tid,
              meta: event.meta,
              data: bytes,
              direction: event.direction,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            ));
          case TransferFailed():
            _activeTransfers.remove(event.tid);
            _outgoingImageCache.remove(event.tid);
        }
      });
    });
  }

  /// 로컬에 저장된 파일/이미지를 불러와 채팅 목록에 표시한다.
  Future<void> _loadStoredFiles() async {
    final records = await TransferStorageService().loadAll(_contactHex);
    if (!mounted) return;
    final loaded = <_CompletedFile>[];
    for (final r in records) {
      // 이미 _completedFiles에 있으면 건너뜀 (TransferCompleted 이벤트로 이미 추가됨)
      if (_completedFiles.any((f) => f.tid == r.tid)) continue;
      Uint8List? bytes;
      if (r.isImage) {
        try {
          bytes = await File(r.filePath).readAsBytes();
        } catch (_) {}
      }
      loaded.add(_CompletedFile(
        tid: r.tid,
        meta: TransferMeta(
          tid: r.tid,
          fileName: r.fileName,
          fileSize: r.fileSize,
          totalChunks: 1,
          mimeType: r.mimeType,
          kind: r.isImage ? TransferKind.image : TransferKind.file,
        ),
        data: bytes,
        filePath: r.filePath,
        direction: r.direction,
        timestamp: r.timestamp,
      ));
    }
    if (!mounted || loaded.isEmpty) return;
    setState(() => _completedFiles.addAll(loaded));
  }

  // ── 첨부 전송 ─────────────────────────────────────────────────────────────────

  String get _contactHex =>
      widget.contact.nodeId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool _checkDirectConnection() {
    if (MessagingService().isDirectlyConnected(_contactHex)) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('직접 연결된 경우에만 파일/이미지 전송이 가능합니다.')),
    );
    return false;
  }

  Future<void> _pickAndSendFile() async {
    if (!_checkDirectConnection()) return;

    const typeGroup = XTypeGroup(label: 'files');
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;

    final data = await file.readAsBytes();
    if (!mounted) return;
    await MessagingService().sendFile(
      data: Uint8List.fromList(data),
      fileName: file.name,
      mimeType: 'application/octet-stream',
      targetNodeIdHex: _contactHex,
      kind: TransferKind.file,
    );
  }

  Future<void> _pickAndSendImages() async {
    if (!_checkDirectConnection()) return;

    const imageTypes = XTypeGroup(
      label: 'images',
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'],
    );
    // 한 번에 1개만 선택
    final file = await openFile(acceptedTypeGroups: [imageTypes]);
    if (file == null) return;
    if (!mounted) return;

    final bytes = Uint8List.fromList(await file.readAsBytes());
    final tid = await MessagingService().sendFile(
      data: bytes,
      fileName: file.name,
      mimeType: 'image/jpeg',
      targetNodeIdHex: _contactHex,
      kind: TransferKind.image,
    );
    if (tid != null && mounted) {
      setState(() => _outgoingImageCache[tid] = bytes);
    }
  }

  // ── 전송 ─────────────────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);

    final sent = await MessagingService().sendTextMessage(
      targetNodeId: widget.contact.nodeId,
      text: text,
      mode: _messageMode,
    );

    if (mounted) {
      setState(() {
        if (sent) {
          final sentMode = _messageMode;
          _controller.clear();
          _messages.add(
            _ChatMessage(
              text: sentMode.isNotice ? '[${sentMode.label}] $text' : text,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              isOutgoing: true,
              isTrusted: widget.contact.isTrusted,
            ),
          );
        }
        _isSending = false;
      });
      if (sent) {
        _scrollToBottom();
      } else {
        final message = _messageMode.isNotice
            ? '공지는 50자 이내, 종류별 하루 1회만 보낼 수 있습니다.'
            : '연결된 BLE 이웃이 없어 전송하지 못했습니다.';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  // ── 스크롤 ───────────────────────────────────────────────────────────────────

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── 헬퍼 ─────────────────────────────────────────────────────────────────────

  /// 상대방 표시 이름: displayName이 없으면 nodeId hex 앞 8자리
  String get _displayName {
    if (widget.contact.displayName != null &&
        widget.contact.displayName!.isNotEmpty) {
      return widget.contact.displayName!;
    }
    final hex = widget.contact.nodeId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return hex.substring(0, 8);
  }

  /// 타임스탬프(ms) → "HH:mm" 문자열
  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // 드롭다운 항목 정의: 텍스트 모드 4개 + 파일/이미지 액션 2개
  static const _dropdownItems = [
    ('일반', 'normal'),
    ('타임', 'timed'),
    ('공지S', 'noticeS'),
    ('공지L', 'noticeL'),
    ('파일', 'file'),
    ('이미지', 'image'),
  ];

  String get _dropdownValue => switch (_messageMode) {
    MessageSendMode.normal => 'normal',
    MessageSendMode.timed => 'timed',
    MessageSendMode.shortNotice => 'noticeS',
    MessageSendMode.longNotice => 'noticeL',
  };

  void _onDropdownChanged(String? value) {
    if (value == null || _isSending) return;
    switch (value) {
      case 'file':
        _pickAndSendFile();
      case 'image':
        _pickAndSendImages();
      case 'normal':
        setState(() => _messageMode = MessageSendMode.normal);
      case 'timed':
        setState(() => _messageMode = MessageSendMode.timed);
      case 'noticeS':
        setState(() => _messageMode = MessageSendMode.shortNotice);
      case 'noticeL':
        setState(() => _messageMode = MessageSendMode.longNotice);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_chatBlocked) {
      return Scaffold(
        backgroundColor: _bgColor,
        appBar: _buildAppBar(),
        body: const Center(
          child: Text(
            'Chat is disabled for Server mode.',
            style: TextStyle(color: _textSecondary),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // 미확인 연락처 경고 배너
          if (!widget.contact.isTrusted) _buildWarningBanner(),
          // 파일 전송 진행률 배너
          if (_activeTransfers.isNotEmpty) _buildTransferBanner(),
          // 메시지 목록
          Expanded(child: _buildMessageList()),
          // 입력바
          _buildInputBar(),
        ],
      ),
    );
  }

  // ── AppBar ───────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _surfaceColor,
      foregroundColor: _textPrimary,
      elevation: 0,
      titleSpacing: 0,
      title: Row(
        children: [
          // 아바타
          AvatarBadge(
            avatarKey: widget.contact.avatarKey,
            size: 36,
            fallbackIcon: widget.contact.isTrusted
                ? Icons.person
                : Icons.question_mark,
            fallbackColor: widget.contact.isTrusted
                ? _trustedColor
                : _untrustedColor,
          ),
          const SizedBox(width: 10),
          // 이름 + 신뢰 상태
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  widget.contact.isTrusted ? '신뢰됨' : '미확인',
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.contact.isTrusted
                        ? _trustedColor
                        : _untrustedColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        // 신뢰 상태 아이콘
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Icon(
            widget.contact.isTrusted ? Icons.lock : Icons.help_outline,
            color: widget.contact.isTrusted ? _trustedColor : _untrustedColor,
            size: 22,
          ),
        ),
      ],
    );
  }

  // ── 경고 배너 ────────────────────────────────────────────────────────────────

  Widget _buildWarningBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: _warningBannerBg,
        border: Border(
          bottom: BorderSide(color: _warningBannerBorder, width: 1),
        ),
      ),
      child: Row(
        children: const [
          Icon(Icons.warning_amber_rounded, color: _untrustedColor, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '미확인 연락처입니다. QR 코드로 신원을 확인하세요.',
              style: TextStyle(color: _untrustedColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── 전송 진행률 배너 ──────────────────────────────────────────────────────────

  Widget _buildTransferBanner() {
    return Container(
      color: const Color(0xFF1A1A2E),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: _activeTransfers.values.map((t) {
          final isOut = t.direction == TransferDirection.outgoing;
          final label = isOut ? '전송 중' : '수신 중';
          final icon = t.meta.kind == TransferKind.image
              ? Icons.image_outlined
              : Icons.insert_drive_file_outlined;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(icon, size: 14, color: const Color(0xFF9E9EB8)),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$label: ${t.meta.fileName}',
                        style: const TextStyle(
                          color: Color(0xFF9E9EB8),
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      LinearProgressIndicator(
                        value: t.progress,
                        backgroundColor: const Color(0xFF2A2A3E),
                        color: isOut
                            ? const Color(0xFF7C6AF7)
                            : const Color(0xFF4ADE80),
                        minHeight: 3,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${(t.progress * 100).toInt()}%',
                  style: const TextStyle(
                    color: Color(0xFF9E9EB8),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── 메시지 목록 ──────────────────────────────────────────────────────────────

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return const Center(
        child: Text(
          '아직 메시지가 없습니다.',
          style: TextStyle(color: _textSecondary, fontSize: 14),
        ),
      );
    }

    // 텍스트 메시지와 완료된 파일을 timestamp 순으로 합산
    final combined = <dynamic>[..._messages, ..._completedFiles]
      ..sort((a, b) {
        final at = a is _ChatMessage ? a.timestamp : (a as _CompletedFile).timestamp;
        final bt = b is _ChatMessage ? b.timestamp : (b as _CompletedFile).timestamp;
        return at.compareTo(bt);
      });

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: combined.length,
      itemBuilder: (context, index) {
        final item = combined[index];
        if (item is _ChatMessage) return _buildMessageItem(item);
        return _buildFileBubble(item as _CompletedFile);
      },
    );
  }

  Widget _buildMessageItem(_ChatMessage msg) {
    final isOutgoing = msg.isOutgoing;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: isOutgoing
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // 미확인 연락처 수신 메시지 경고
          if (!isOutgoing && !msg.isTrusted) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                '⚠️ 미확인 연락처',
                style: TextStyle(
                  fontSize: 10,
                  color: _untrustedColor.withAlpha(204), // 80% opacity
                ),
              ),
            ),
          ],
          // 버블
          Row(
            mainAxisAlignment: isOutgoing
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isOutgoing) const SizedBox(width: 4),
              // 메시지 버블
              Flexible(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.72,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
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
                      Text(
                        msg.text,
                        style: const TextStyle(
                          color: _textPrimary,
                          fontSize: 15,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatTime(msg.timestamp),
                        style: TextStyle(
                          fontSize: 10,
                          color: _textPrimary.withAlpha(153), // 60% opacity
                        ),
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

  // ── 파일/이미지 버블 ──────────────────────────────────────────────────────────

  Widget _buildFileBubble(_CompletedFile file) {
    final isOutgoing = file.direction == TransferDirection.outgoing;
    final isImage = file.meta.kind == TransferKind.image && file.data != null;

    Widget content;
    if (isImage) {
      content = GestureDetector(
        onTap: () => _showImageFullScreen(file),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            file.data!,
            width: 200,
            height: 200,
            fit: BoxFit.cover,
          ),
        ),
      );
    } else {
      content = GestureDetector(
        onTap: file.data != null ? () => _saveFile(file) : null,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isOutgoing ? _outgoingBubble : _incomingBubble,
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
                      file.meta.fileName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _textPrimary, fontSize: 13),
                    ),
                    Text(
                      _formatBytes(file.meta.fileSize),
                      style: TextStyle(color: _textSecondary, fontSize: 11),
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
      child: Row(
        mainAxisAlignment:
            isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isOutgoing) const SizedBox(width: 4),
          content,
          if (isOutgoing) const SizedBox(width: 4),
        ],
      ),
    );
  }

  void _showImageFullScreen(_CompletedFile file) {
    if (file.data == null) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.memory(file.data!, fit: BoxFit.contain),
              ),
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
                      await _saveFile(file);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Color(0xFFFF6B6B)),
                    tooltip: '삭제',
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _deleteFile(file);
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

  Future<void> _deleteFile(_CompletedFile file) async {
    await TransferStorageService().delete(file.tid, _contactHex);
    if (!mounted) return;
    setState(() => _completedFiles.removeWhere((f) => f.tid == file.tid));
  }

  Future<void> _saveFile(_CompletedFile file) async {
    if (file.data == null) return;
    try {
      final location = await getSaveLocation(
        suggestedName: file.meta.fileName,
        acceptedTypeGroups: const [XTypeGroup(label: 'all')],
      );
      if (location == null) return;
      await File(location.path).writeAsBytes(file.data!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장 완료')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('저장 실패: $e')),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ── 입력바 ───────────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _inputBarBg,
        border: const Border(
          top: BorderSide(color: Color(0xFF2A2A3E), width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 모드 선택 (일반/타임/공지S/공지L/파일/이미지)
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
                  selectedItemBuilder: (context) {
                    return _dropdownItems
                        .map(
                          (item) => Align(
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
                          ),
                        )
                        .toList();
                  },
                  items: _dropdownItems
                      .map(
                        (item) => DropdownMenuItem(
                          value: item.$2,
                          child: Center(
                            child: Text(
                              item.$1,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: _textPrimary),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _isSending ? null : _onDropdownChanged,
                ),
              ),
            ),
            // 텍스트 입력 필드
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: KeyboardListener(
                  focusNode: _keyboardFocusNode,
                  onKeyEvent: (event) {
                    if (event is! KeyDownEvent) return;
                    final isEnter =
                        event.logicalKey == LogicalKeyboardKey.enter;
                    final isCtrl = HardwareKeyboard.instance.isControlPressed;
                    if (isEnter && isCtrl) {
                      _sendMessage();
                    }
                  },
                  child: TextField(
                    focusNode: _inputFocusNode,
                    controller: _controller,
                    maxLength: _maxLength,
                    maxLines: null, // 자동 줄바꿈
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(color: _textPrimary, fontSize: 15),
                    cursorColor: _outgoingBubble,
                    decoration: InputDecoration(
                      hintText: '메시지 입력',
                      hintStyle: const TextStyle(color: _textSecondary),
                      counterText: '', // maxLength 카운터 숨김
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
                        borderSide: const BorderSide(
                          color: _outgoingBubble,
                          width: 1.5,
                        ),
                      ),
                    ),
                    onSubmitted: (_) {
                      // 모바일 전송 버튼 탭과 일관성 유지 (엔터는 줄바꿈)
                    },
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
                    onPressed: hasText && !_isSending ? _sendMessage : null,
                    style: IconButton.styleFrom(
                      backgroundColor: hasText
                          ? _outgoingBubble
                          : const Color(0xFF2A2A3E),
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
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── 전송 진행 상태 모델 ─────────────────────────────────────────────────────────

class _ActiveTransfer {
  final TransferMeta meta;
  double progress;
  final TransferDirection direction;
  final String targetNodeIdHex;

  _ActiveTransfer({
    required this.meta,
    required this.progress,
    required this.direction,
    required this.targetNodeIdHex,
  });
}

// ── 완료된 파일/이미지 모델 ─────────────────────────────────────────────────────

class _CompletedFile {
  final String tid;
  final TransferMeta meta;
  final Uint8List? data;
  final String? filePath; // 디스크에서 복원한 경우 경로
  final TransferDirection direction;
  final int timestamp;

  _CompletedFile({
    required this.tid,
    required this.meta,
    this.data,
    this.filePath,
    required this.direction,
    required this.timestamp,
  });
}
