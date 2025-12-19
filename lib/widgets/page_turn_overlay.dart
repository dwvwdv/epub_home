import 'package:flutter/material.dart';
import '../models/room.dart';

class PageTurnOverlay extends StatelessWidget {
  final Room room;
  final VoidCallback onCancel;

  const PageTurnOverlay({
    super.key,
    required this.room,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(32),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                const Text(
                  '等待其他人確認翻頁...',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '已確認: ${room.readyCount}/${room.totalCount}',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                _buildParticipantsList(),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: onCancel,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                  ),
                  child: const Text('取消翻頁'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildParticipantsList() {
    return Column(
      children: room.participants.map((user) {
        final status = room.pageStatuses[user.id];
        final isReady = status == PageStatus.readyToTurn;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(
                isReady ? Icons.check_circle : Icons.hourglass_empty,
                color: isReady ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Text(user.name),
              if (user.isHost) ...[
                const SizedBox(width: 8),
                const Icon(Icons.star, size: 16, color: Colors.amber),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }
}
