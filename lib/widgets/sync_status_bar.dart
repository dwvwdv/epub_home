import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/page_sync_state.dart';

class SyncStatusBar extends StatelessWidget {
  final PageSyncState syncState;
  final List<Map<String, dynamic>> onlineUsers;
  final VoidCallback? onConfirm;
  final VoidCallback? onDecline;

  const SyncStatusBar({
    super.key,
    required this.syncState,
    required this.onlineUsers,
    this.onConfirm,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    switch (syncState.status) {
      case SyncStatus.idle:
        return _buildIdleBar();
      case SyncStatus.requesting:
        return _buildRequestingBar();
      case SyncStatus.confirming:
        return _buildConfirmingBar();
      case SyncStatus.waiting:
        return _buildWaitingBar();
      case SyncStatus.turning:
        return _buildTurningBar();
    }
  }

  Widget _buildIdleBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppTheme.surfaceColor,
      child: Row(
        children: [
          const Icon(Icons.people, size: 16, color: Colors.white54),
          const SizedBox(width: 8),
          Text(
            '${onlineUsers.length} readers online',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const Spacer(),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'Synced',
            style: TextStyle(color: Colors.green, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestingBar() {
    final request = syncState.currentRequest;
    if (request == null) return const SizedBox.shrink();

    final pending = request.pendingUserIds;
    final pendingNames = _getUserNames(pending);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.primaryColor.withValues(alpha: 0.2),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Waiting for ${pendingNames.join(", ")}...',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${request.confirmedUserIds.length}/${request.requiredUserIds.length}',
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmingBar() {
    final request = syncState.currentRequest;
    if (request == null) return const SizedBox.shrink();

    final direction =
        request.direction == PageTurnDirection.next ? 'next' : 'previous';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.orange.withValues(alpha: 0.2),
      child: Row(
        children: [
          const Icon(Icons.swipe, size: 18, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${request.requestedByNickname} wants to go to $direction page',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onDecline,
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: Size.zero,
            ),
            child: const Text('Wait'),
          ),
          const SizedBox(width: 4),
          ElevatedButton(
            onPressed: onConfirm,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: Size.zero,
            ),
            child: const Text('Turn'),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingBar() {
    final request = syncState.currentRequest;
    if (request == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.blue.withValues(alpha: 0.2),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Waiting for others to confirm... '
              '${request.confirmedUserIds.length}/${request.requiredUserIds.length}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTurningBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.green.withValues(alpha: 0.2),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle, size: 16, color: Colors.green),
          SizedBox(width: 8),
          Text(
            'Turning page...',
            style: TextStyle(color: Colors.green, fontSize: 13),
          ),
        ],
      ),
    );
  }

  List<String> _getUserNames(Set<String> userIds) {
    return userIds.map((id) {
      final user = onlineUsers.firstWhere(
        (u) => u['user_id'] == id,
        orElse: () => {'nickname': 'Unknown'},
      );
      return user['nickname'] as String? ?? 'Unknown';
    }).toList();
  }
}
