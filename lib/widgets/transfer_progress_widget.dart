import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/transfer_state.dart';

class TransferProgressWidget extends StatelessWidget {
  final TransferState transferState;

  const TransferProgressWidget({
    super.key,
    required this.transferState,
  });

  @override
  Widget build(BuildContext context) {
    if (!transferState.isActive && transferState.status != TransferStatus.completed) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                _icon,
                color: _color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                _statusText,
                style: TextStyle(
                  color: _color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (transferState.isActive) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: transferState.progress,
                backgroundColor: Colors.white12,
                color: AppTheme.primaryColor,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${transferState.receivedChunks}/${transferState.totalChunks} chunks '
              '(${(transferState.progress * 100).toStringAsFixed(0)}%)',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
          if (transferState.status == TransferStatus.completed)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Book received successfully!',
                style: TextStyle(color: Colors.green, fontSize: 13),
              ),
            ),
          if (transferState.status == TransferStatus.failed &&
              transferState.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                transferState.errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  IconData get _icon {
    switch (transferState.status) {
      case TransferStatus.transferring:
        return Icons.download;
      case TransferStatus.completed:
        return Icons.check_circle;
      case TransferStatus.failed:
        return Icons.error;
      default:
        return Icons.hourglass_empty;
    }
  }

  Color get _color {
    switch (transferState.status) {
      case TransferStatus.transferring:
        return AppTheme.primaryColor;
      case TransferStatus.completed:
        return Colors.green;
      case TransferStatus.failed:
        return Colors.red;
      default:
        return Colors.white54;
    }
  }

  String get _statusText {
    switch (transferState.status) {
      case TransferStatus.idle:
        return 'Idle';
      case TransferStatus.offering:
        return 'Offering...';
      case TransferStatus.accepting:
        return 'Accepting...';
      case TransferStatus.transferring:
        return 'Receiving book...';
      case TransferStatus.completed:
        return 'Transfer complete';
      case TransferStatus.failed:
        return 'Transfer failed';
    }
  }
}
