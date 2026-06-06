// lib/ui/chat/chat_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_comm/core/storage/database_service.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/identity_service.dart';
import 'package:mesh_comm/features/messaging/message_policy.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
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
  MessageSendMode _messageMode = MessageSendMode.normal;
  Timer? _historyRefreshTimer;

  StreamSubscription<ReceivedMessage>? _msgSubscription;

  // ── 라이프사이클 ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (!AppSettingsService().current.userLevel.canSendMessages ||
        !widget.contact.userLevel.canSendMessages) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final message = !AppSettingsService().current.userLevel.canSendMessages
            ? 'Server mode only relays messages. Chat is disabled.'
            : '$_displayName is Server mode. Chat is disabled.';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        Navigator.of(context).maybePop();
      });
      return;
    }
    _loadHistory();
    _subscribeToStream();
    _historyRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _loadHistory(replace: true),
    );
    unawaited(_markConversationRead());
  }

  @override
  void dispose() {
    _msgSubscription?.cancel();
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

  String _modeCompactLabel(MessageSendMode mode) {
    return switch (mode) {
      MessageSendMode.normal => '일반',
      MessageSendMode.timed => '타임',
      MessageSendMode.shortNotice => '공지S',
      MessageSendMode.longNotice => '공지L',
    };
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // 미확인 연락처 경고 배너
          if (!widget.contact.isTrusted) _buildWarningBanner(),
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

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        return _buildMessageItem(_messages[index]);
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
            Container(
              width: 92,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F1E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF2A2A3E)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<MessageSendMode>(
                  value: _messageMode,
                  isExpanded: true,
                  dropdownColor: _incomingBubble,
                  selectedItemBuilder: (context) {
                    return MessageSendMode.values
                        .map(
                          (mode) => Align(
                            alignment: Alignment.center,
                            child: Text(
                              _modeCompactLabel(mode),
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
                  items: MessageSendMode.values
                      .map(
                        (mode) => DropdownMenuItem(
                          value: mode,
                          child: Center(
                            child: Text(
                              mode.label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: _textPrimary),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _isSending
                      ? null
                      : (mode) {
                          if (mode == null) return;
                          setState(() => _messageMode = mode);
                        },
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
