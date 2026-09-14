import 'package:flutter/material.dart';

/// Chat input bar component
class ChatInputBar extends StatefulWidget {
  final TextEditingController textController;
  final VoidCallback onSendText;
  final VoidCallback onPickImage;
  final VoidCallback onStartVoice;

  const ChatInputBar({
    super.key,
    required this.textController,
    required this.onSendText,
    required this.onPickImage,
    required this.onStartVoice,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.textController.removeListener(_onTextChanged);
    super.dispose();
  }

  void _openVoiceMode() {
    FocusScope.of(context).unfocus();
    debugPrint('VOICE_UI: microphone button pressed');
    widget.onStartVoice();
  }

  void _onTextChanged() {
    final hasText = widget.textController.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Voice button
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                icon: const Icon(Icons.mic_outlined),
                onPressed: _openVoiceMode,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                tooltip: 'Hold to speak',
              ),
            ),

            // Text input
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.light
                      ? Colors.grey[100]
                      : Colors.grey[800],
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: widget.textController,
                  decoration: const InputDecoration(
                    hintText: 'Enter message...',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) {
                    if (_hasText) {
                      widget.onSendText();
                    }
                  },
                ),
              ),
            ),

            const SizedBox(width: 4),

            // Send button
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: _hasText ? widget.onSendText : null,
              tooltip: 'Send',
              color: _hasText
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
          ],
        ),
      ),
    );
  }
}
