import 'package:flutter/material.dart';

import '../state/session_state.dart';

class StatusBanner extends StatelessWidget {
  final LoadStatus status;
  final String message;

  const StatusBanner({super.key, required this.status, required this.message});

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return const SizedBox.shrink();
    final Color color = switch (status) {
      LoadStatus.error => Colors.red.shade300,
      LoadStatus.ok => Colors.green.shade300,
      _ => Colors.grey.shade400,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(message, style: TextStyle(color: color)),
    );
  }
}
