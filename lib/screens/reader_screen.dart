import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import '../models/room.dart';
import '../providers/book_provider.dart';
import '../providers/room_provider.dart';
import '../providers/user_provider.dart';
import '../widgets/epub_reader.dart';
import '../widgets/page_turn_overlay.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  final bool isInRoom;

  const ReaderScreen({
    super.key,
    required this.book,
    this.isInRoom = false,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late int _currentChapterIndex;
  late int _currentPageIndex;
  List<String> _currentPages = [];

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.book.currentChapter;
    _currentPageIndex = widget.book.currentPage;
    _loadCurrentChapter();
  }

  void _loadCurrentChapter() {
    if (widget.book.chapters.isEmpty) return;

    final chapter = widget.book.chapters[_currentChapterIndex];
    // TODO: 使用 EpubService 分頁
    _currentPages = [chapter.content]; // 暫時不分頁

    setState(() {});
  }

  void _nextPage() async {
    if (widget.isInRoom) {
      // 房間模式：請求同步翻頁
      await _requestSyncPageTurn(_currentPageIndex + 1);
    } else {
      // 單人模式：直接翻頁
      _turnPage(_currentPageIndex + 1);
    }
  }

  void _previousPage() async {
    if (widget.isInRoom) {
      // 房間模式：請求同步翻頁
      await _requestSyncPageTurn(_currentPageIndex - 1);
    } else {
      // 單人模式：直接翻頁
      _turnPage(_currentPageIndex - 1);
    }
  }

  Future<void> _requestSyncPageTurn(int targetPage) async {
    final roomProvider = context.read<RoomProvider>();
    final userProvider = context.read<UserProvider>();

    if (userProvider.currentUser == null) return;

    await roomProvider.requestPageTurn(
      user: userProvider.currentUser!,
      targetPage: targetPage,
    );

    // 同步成功後翻頁
    if (roomProvider.currentRoom?.currentPage == targetPage) {
      _turnPage(targetPage);
    }
  }

  void _turnPage(int targetPage) {
    if (targetPage < 0) {
      // 上一章
      if (_currentChapterIndex > 0) {
        _currentChapterIndex--;
        _loadCurrentChapter();
        _currentPageIndex = _currentPages.length - 1;
      }
    } else if (targetPage >= _currentPages.length) {
      // 下一章
      if (_currentChapterIndex < widget.book.chapters.length - 1) {
        _currentChapterIndex++;
        _currentPageIndex = 0;
        _loadCurrentChapter();
      }
    } else {
      _currentPageIndex = targetPage;
    }

    // 保存進度
    final bookProvider = context.read<BookProvider>();
    bookProvider.updateReadingProgress(
      widget.book.id,
      _currentChapterIndex,
      _currentPageIndex,
    );

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final roomProvider = Provider.of<RoomProvider>(context);
    final isWaiting = widget.isInRoom && roomProvider.isWaitingForSync;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          if (widget.isInRoom)
            IconButton(
              icon: const Icon(Icons.people),
              onPressed: _showParticipants,
            ),
          IconButton(
            icon: const Icon(Icons.list),
            onPressed: _showChapterList,
          ),
        ],
      ),
      body: Stack(
        children: [
          GestureDetector(
            onTapUp: (details) {
              final width = MediaQuery.of(context).size.width;
              if (details.globalPosition.dx < width / 3) {
                _previousPage();
              } else if (details.globalPosition.dx > width * 2 / 3) {
                _nextPage();
              } else {
                _toggleAppBar();
              }
            },
            child: EpubReader(
              content: _currentPages.isNotEmpty
                  ? _currentPages[_currentPageIndex]
                  : '',
              chapterTitle: widget.book.chapters.isNotEmpty
                  ? widget.book.chapters[_currentChapterIndex].title
                  : '',
            ),
          ),
          if (isWaiting)
            PageTurnOverlay(
              room: roomProvider.currentRoom!,
              onCancel: () {
                final userProvider = context.read<UserProvider>();
                if (userProvider.currentUser != null) {
                  roomProvider.cancelPageTurn(userProvider.currentUser!);
                }
              },
            ),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBottomBar() {
    final totalPages = _currentPages.length;
    final progress = totalPages > 0 ? (_currentPageIndex + 1) / totalPages : 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: progress.toDouble()),
          const SizedBox(height: 8),
          Text(
            '第 ${_currentChapterIndex + 1}/${widget.book.chapters.length} 章 | '
            '第 ${_currentPageIndex + 1}/$totalPages 頁',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _toggleAppBar() {
    // TODO: 實現顯示/隱藏 AppBar
  }

  void _showChapterList() {
    showModalBottomSheet(
      context: context,
      builder: (context) => ListView.builder(
        itemCount: widget.book.chapters.length,
        itemBuilder: (context, index) {
          final chapter = widget.book.chapters[index];
          final isCurrent = index == _currentChapterIndex;

          return ListTile(
            leading: Text('${index + 1}'),
            title: Text(chapter.title),
            trailing: isCurrent ? const Icon(Icons.check) : null,
            selected: isCurrent,
            onTap: () {
              setState(() {
                _currentChapterIndex = index;
                _currentPageIndex = 0;
                _loadCurrentChapter();
              });
              Navigator.pop(context);
            },
          );
        },
      ),
    );
  }

  void _showParticipants() {
    final roomProvider = context.read<RoomProvider>();
    final room = roomProvider.currentRoom;

    if (room == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('房間參與者'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: room.participants.map((user) {
            final status = room.pageStatuses[user.id];
            return ListTile(
              leading: Icon(
                user.isHost ? Icons.star : Icons.person,
                color: user.isHost ? Colors.amber : Colors.grey,
              ),
              title: Text(user.name),
              trailing: _getStatusIcon(status),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('關閉'),
          ),
        ],
      ),
    );
  }

  Widget _getStatusIcon(status) {
    switch (status) {
      case PageStatus.viewing:
        return const Icon(Icons.visibility, color: Colors.green);
      case PageStatus.readyToTurn:
        return const Icon(Icons.check_circle, color: Colors.blue);
      case PageStatus.waiting:
        return const Icon(Icons.hourglass_empty, color: Colors.orange);
      default:
        return const Icon(Icons.help, color: Colors.grey);
    }
  }
}
