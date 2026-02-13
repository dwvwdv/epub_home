import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/theme.dart';
import '../models/page_sync_state.dart';
import '../providers/auth_provider.dart';
import '../providers/book_provider.dart';
import '../providers/page_sync_provider.dart';
import '../providers/presence_provider.dart';
import '../providers/room_provider.dart';
import '../widgets/sync_status_bar.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  final String roomCode;

  const ReaderScreen({super.key, required this.roomCode});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  EpubController? _epubController;
  String? _currentCfi;
  bool _isReaderReady = false;

  @override
  void initState() {
    super.initState();
    _epubController = EpubController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initSync());
  }

  void _initSync() {
    final authState = ref.read(authProvider);
    final realtimeService = ref.read(realtimeServiceProvider);

    if (!authState.isAuthenticated) return;

    ref.read(pageSyncProvider.notifier).initialize(
          realtimeService: realtimeService,
          currentUserId: authState.userId!,
          currentNickname: authState.nickname,
        );

    // Set page turn callback
    ref.read(pageSyncProvider.notifier).onPageTurn = (direction) {
      if (_epubController != null && _isReaderReady) {
        if (direction == PageTurnDirection.next) {
          _epubController!.next();
        } else {
          _epubController!.prev();
        }
      }
    };

    // Load initial CFI position
    final room = ref.read(roomProvider).currentRoom;
    if (room?.currentCfi != null) {
      _currentCfi = room!.currentCfi;
    }
  }

  @override
  void dispose() {
    _epubController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(pageSyncProvider);
    final presenceState = ref.watch(presenceProvider);
    final bookState = ref.watch(bookProvider);

    if (bookState.bookFile == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reader')),
        body: const Center(
          child: Text('No book loaded'),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Sync status bar
            SyncStatusBar(
              syncState: syncState,
              onlineUsers: presenceState.onlineUsers,
              onConfirm: () =>
                  ref.read(pageSyncProvider.notifier).confirmPageTurn(),
              onDecline: () =>
                  ref.read(pageSyncProvider.notifier).declinePageTurn(),
            ),

            // EPUB reader with gesture overlay
            Expanded(
              child: Stack(
                children: [
                  // Layer 1: EPUB viewer
                  EpubViewer(
                    epubController: _epubController!,
                    epubSource: EpubSource.fromFile(bookState.bookFile!),
                    displaySettings: EpubDisplaySettings(
                      flow: EpubFlow.paginated,
                      snap: true,
                    ),
                    initialCfi: _currentCfi,
                    onChaptersLoaded: (chapters) {
                      setState(() => _isReaderReady = true);
                    },
                    onRelocated: (location) {
                      _currentCfi = location.startCfi;
                      ref.read(bookProvider.notifier).updateCfi(location.startCfi);
                      ref
                          .read(roomProvider.notifier)
                          .updateCfi(location.startCfi);
                    },
                  ),

                  // Layer 2: Gesture interceptor overlay
                  if (_isReaderReady)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragEnd: (details) {
                          if (syncState.status != SyncStatus.idle) return;
                          if (details.primaryVelocity == null) return;

                          if (details.primaryVelocity! < -200) {
                            // Swipe left = next page
                            ref
                                .read(pageSyncProvider.notifier)
                                .requestPageTurn(
                                  direction: PageTurnDirection.next,
                                  fromCfi: _currentCfi,
                                );
                          } else if (details.primaryVelocity! > 200) {
                            // Swipe right = previous page
                            ref
                                .read(pageSyncProvider.notifier)
                                .requestPageTurn(
                                  direction: PageTurnDirection.previous,
                                  fromCfi: _currentCfi,
                                );
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),

            // Bottom navigation bar
            _buildBottomBar(syncState),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(PageSyncState syncState) {
    final isIdle = syncState.status == SyncStatus.idle;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppTheme.surfaceColor,
      child: Row(
        children: [
          // Leave button
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _leaveReader,
            tooltip: 'Leave reading',
          ),

          const Spacer(),

          // Previous page button
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 32),
            onPressed: isIdle
                ? () => ref.read(pageSyncProvider.notifier).requestPageTurn(
                      direction: PageTurnDirection.previous,
                      fromCfi: _currentCfi,
                    )
                : null,
          ),

          const SizedBox(width: 24),

          // Next page button
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 32),
            onPressed: isIdle
                ? () => ref.read(pageSyncProvider.notifier).requestPageTurn(
                      direction: PageTurnDirection.next,
                      fromCfi: _currentCfi,
                    )
                : null,
          ),

          const Spacer(),

          // Members indicator
          IconButton(
            icon: const Icon(Icons.people_outline),
            onPressed: () => _showMembersDrawer(),
            tooltip: 'Room members',
          ),
        ],
      ),
    );
  }

  void _showMembersDrawer() {
    final presenceState = ref.read(presenceProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${presenceState.onlineCount} Readers Online',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ...presenceState.onlineUsers.map((user) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        user['nickname'] as String? ?? 'Unknown',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _leaveReader() {
    context.goNamed('lobby', pathParameters: {'roomCode': widget.roomCode});
  }
}
