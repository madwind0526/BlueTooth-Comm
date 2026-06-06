import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/messaging/message_policy.dart';
import 'package:mesh_comm/features/messaging/messaging_service.dart';
import 'package:mesh_comm/features/settings/app_settings_service.dart';
import 'package:mesh_comm/ui/home/home_models.dart';

class GroupChatScreen extends StatefulWidget {
  final String groupName;
  final List<Contact> members;

  const GroupChatScreen({
    super.key,
    required this.groupName,
    required this.members,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatMessage {
  final String text;
  final String senderLabel;
  final int timestamp;
  final bool isOutgoing;
  final String? status;

  const _GroupChatMessage({
    required this.text,
    required this.senderLabel,
    required this.timestamp,
    required this.isOutgoing,
    this.status,
  });
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  static const Color _bgColor = Color(0xFF1A1A2E);
  static const Color _surfaceColor = Color(0xFF16213E);
  static const Color _outgoingBubble = Color(0xFF6C5CE7);
  static const Color _incomingBubble = Color(0xFF2D2D3F);
  static const Color _inputBarBg = Color(0xFF16213E);
  static const Color _textPrimary = Color(0xFFECECEC);
  static const Color _textSecondary = Color(0xFF9090A0);

  final _messages = <_GroupChatMessage>[];
  final _controller = TextEditingController();
  final _keyboardFocusNode = FocusNode();
  final _scrollController = ScrollController();
  StreamSubscription<ReceivedMessage>? _subscription;
  MessageSendMode _messageMode = MessageSendMode.normal;
  bool _isSending = false;

  int get _maxLength => _messageMode.maxLength;

  @override
  void initState() {
    super.initState();
    _subscribeToGroupMessages();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.dispose();
    _keyboardFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _subscribeToGroupMessages() {
    final memberIds = widget.members.map(contactCode).toSet();
    _subscription = MessagingService().messageStream
        .where((message) => memberIds.contains(_nodeHex(message.senderNodeId)))
        .listen((message) {
          if (!mounted) return;
          final sender = widget.members.firstWhere(
            (contact) => contactCode(contact) == _nodeHex(message.senderNodeId),
            orElse: () => widget.members.first,
          );
          MessagingService().markMessageDisplayed(message);
          setState(() {
            _messages.add(
              _GroupChatMessage(
                text: message.text,
                senderLabel: contactDisplayName(sender),
                timestamp: message.timestamp,
                isOutgoing: false,
              ),
            );
          });
          _scrollToBottom();
        });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    final result = await MessagingService().sendGroupTextMessage(
      recipients: widget.members,
      text: text,
      mode: _messageMode,
    );

    if (!mounted) return;
    setState(() {
      _isSending = false;
      if (result.sentAny) {
        final sentMode = _messageMode;
        _controller.clear();
        _messages.add(
          _GroupChatMessage(
            text: sentMode.isNotice ? '[${sentMode.label}] $text' : text,
            senderLabel: 'Me',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            isOutgoing: true,
            status: sentMode.isNotice
                ? '공지 전송'
                : '${result.sent}/${result.attempted} 전송',
          ),
        );
      }
    });

    if (result.sentAny) {
      _scrollToBottom();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.blockedReason ?? 'Group send failed.')),
    );
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

  @override
  Widget build(BuildContext context) {
    final myLevel = AppSettingsService().current.userLevel;
    if (!myLevel.canSendMessages) {
      return Scaffold(
        backgroundColor: _bgColor,
        appBar: _buildAppBar(),
        body: const Center(
          child: Text(
            'Server mode only relays messages.',
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
            child: Icon(Icons.groups_outlined, color: Color(0xFF8B7CF6)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.groupName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _textPrimary,
                  ),
                ),
                Text(
                  'Group · ${widget.members.length}명',
                  style: const TextStyle(fontSize: 11, color: _textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return const Center(
        child: Text(
          '아직 Group 메시지가 없습니다.',
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

  Widget _buildMessageItem(_GroupChatMessage message) {
    final isOutgoing = message.isOutgoing;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: isOutgoing
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
            child: Text(
              message.senderLabel,
              style: const TextStyle(color: _textSecondary, fontSize: 11),
            ),
          ),
          Row(
            mainAxisAlignment: isOutgoing
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
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
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        message.text,
                        style: const TextStyle(
                          color: _textPrimary,
                          fontSize: 15,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          _formatTime(message.timestamp),
                          if (message.status != null) message.status!,
                        ].join(' · '),
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
                  selectedItemBuilder: (context) => MessageSendMode.values
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
                      .toList(),
                  items: MessageSendMode.values
                      .map(
                        (mode) => DropdownMenuItem(
                          value: mode,
                          child: Center(
                            child: Text(
                              _modeCompactLabel(mode),
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
                    controller: _controller,
                    maxLength: _maxLength,
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
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _modeCompactLabel(MessageSendMode mode) {
    return switch (mode) {
      MessageSendMode.normal => '일반',
      MessageSendMode.timed => '타임',
      MessageSendMode.shortNotice => '공지S',
      MessageSendMode.longNotice => '공지L',
    };
  }

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _nodeHex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
