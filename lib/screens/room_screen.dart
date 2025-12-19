import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/room_provider.dart';
import '../providers/user_provider.dart';
import '../providers/book_provider.dart';
import '../models/room.dart';

class RoomScreen extends StatelessWidget {
  const RoomScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final roomProvider = Provider.of<RoomProvider>(context);
    final userProvider = Provider.of<UserProvider>(context);
    final currentUser = userProvider.currentUser;

    if (currentUser == null) {
      return const Center(child: Text('請先設置用戶信息'));
    }

    final userRooms = roomProvider.rooms
        .where((room) => room.participants.any((p) => p.id == currentUser.id))
        .toList();

    return Scaffold(
      body: userRooms.isEmpty
          ? _buildEmptyState(context)
          : _buildRoomList(context, userRooms, currentUser.id),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateRoomDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('創建房間'),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.group_outlined,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '還沒有加入任何房間',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '創建或加入房間開始共享閱讀',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoomList(
    BuildContext context,
    List<Room> rooms,
    String currentUserId,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: rooms.length,
      itemBuilder: (context, index) {
        final room = rooms[index];
        return _buildRoomCard(context, room, currentUserId);
      },
    );
  }

  Widget _buildRoomCard(BuildContext context, Room room, String currentUserId) {
    final isHost = room.hostId == currentUserId;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        room.book.title,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                if (isHost)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      '房主',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.people, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 4),
                Text(
                  '${room.participants.length} 人',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(width: 16),
                Icon(Icons.book, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 4),
                Text(
                  '第 ${room.currentPage + 1} 頁',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    final roomProvider = context.read<RoomProvider>();
                    roomProvider.leaveRoom(
                      roomId: room.id,
                      userId: currentUserId,
                    );
                  },
                  child: const Text('離開'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    // TODO: 進入房間閱讀
                  },
                  child: const Text('進入房間'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateRoomDialog(BuildContext context) {
    final nameController = TextEditingController();
    final bookProvider = context.read<BookProvider>();
    final userProvider = context.read<UserProvider>();
    final roomProvider = context.read<RoomProvider>();

    final books = bookProvider.books;

    if (books.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先導入書籍')),
      );
      return;
    }

    var selectedBook = books.first;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('創建房間'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '房間名稱',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField(
              value: selectedBook,
              decoration: const InputDecoration(
                labelText: '選擇書籍',
                border: OutlineInputBorder(),
              ),
              items: books
                  .map((book) => DropdownMenuItem(
                        value: book,
                        child: Text(book.title),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  selectedBook = value;
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty &&
                  userProvider.currentUser != null) {
                roomProvider.createRoom(
                  name: nameController.text,
                  host: userProvider.currentUser!,
                  book: selectedBook,
                );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('房間創建成功')),
                );
              }
            },
            child: const Text('創建'),
          ),
        ],
      ),
    );
  }
}
