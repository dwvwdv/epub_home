import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/theme.dart';
import '../models/transfer_state.dart';
import '../providers/auth_provider.dart';
import '../providers/book_provider.dart';
import '../providers/presence_provider.dart';
import '../providers/room_provider.dart';
import '../widgets/member_list.dart';
import '../widgets/room_code_display.dart';
import '../widgets/transfer_progress_widget.dart';

class RoomLobbyScreen extends ConsumerStatefulWidget {
  final String roomCode;

  const RoomLobbyScreen({super.key, required this.roomCode});

  @override
  ConsumerState<RoomLobbyScreen> createState() => _RoomLobbyScreenState();
}

class _RoomLobbyScreenState extends ConsumerState<RoomLobbyScreen> {
  StreamSubscription? _transferSub;
  StreamSubscription? _bookSharedSub;
  StreamSubscription? _startReadingSub;
  TransferState _transferState = const TransferState.idle();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initRoom());
  }

  void _initRoom() {
    final authState = ref.read(authProvider);
    if (!authState.isAuthenticated) return;

    final userId = authState.userId!;
    final nickname = authState.nickname;

    // Join presence (not reading, just in lobby).
    ref.read(presenceProvider.notifier).joinRoom(
          roomCode: widget.roomCode,
          userId: userId,
          nickname: nickname,
          avatarColorIndex: 0,
          isReading: false,
        );

    // Initialize file transfer service
    final realtimeService = ref.read(realtimeServiceProvider);
    ref.read(bookProvider.notifier).initTransferService(
          realtimeService: realtimeService,
          currentUserId: userId,
        );

    // Listen to transfer state
    final transferService = ref.read(bookProvider.notifier).transferService;
    _transferSub = transferService?.stateStream.listen((state) {
      if (mounted) {
        setState(() => _transferState = state);
      }
    });

    // Listen for book_shared events
    _bookSharedSub = realtimeService.broadcastStream('book_shared').listen((payload) {
      final bookHash = payload['file_hash'] as String?;
      final bookTitle = payload['title'] as String?;
      if (bookHash != null) {
        ref.read(roomProvider.notifier).onBookSharedReceived(
              bookTitle: bookTitle ?? 'Unknown',
              bookHash: bookHash,
            );
      }
    });

    // Feature 3: Listen for start_reading broadcast → navigate all members to reader.
    _startReadingSub =
        realtimeService.broadcastStream('start_reading').listen((_) {
      if (mounted) {
        context.goNamed('reader',
            pathParameters: {'roomCode': widget.roomCode});
      }
    });

    // Check if room already has a book
    final room = ref.read(roomProvider).currentRoom;
    if (room?.currentBookHash != null) {
      ref.read(bookProvider.notifier).loadExistingBook(room!.currentBookHash!);
    }
  }

  @override
  void dispose() {
    _transferSub?.cancel();
    _bookSharedSub?.cancel();
    _startReadingSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roomState = ref.watch(roomProvider);
    final presenceState = ref.watch(presenceProvider);
    final bookState = ref.watch(bookProvider);
    final authState = ref.watch(authProvider);
    final room = roomState.currentRoom;

    // Keep member online/hasBook status in sync with presence on every update
    ref.listen<PresenceState>(presenceProvider, (previous, next) {
      final notifier = ref.read(roomProvider.notifier);
      notifier.updateMembersFromPresence(next.onlineUsers);
      if ((previous?.onlineCount ?? 0) != next.onlineCount) {
        notifier.refreshMembers(presenceUsers: next.onlineUsers);
      }
    });

    if (room == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Feature 2: hardware back → leave room properly.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveRoom();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Room Lobby'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _leaveRoom,
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Room code
              const Text(
                'Room Code',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 8),
              RoomCodeDisplay(code: room.code),
              const SizedBox(height: 24),

              // Members section
              Row(
                children: [
                  const Text(
                    'Members',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${presenceState.onlineCount} online',
                      style: const TextStyle(
                        color: AppTheme.primaryColor,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: MemberList(
                  members: roomState.members,
                  currentUserId: authState.userId,
                ),
              ),

              // Transfer progress
              TransferProgressWidget(transferState: _transferState),

              // Book info
              if (room.currentBookTitle != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.cardColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.menu_book,
                        color: AppTheme.primaryColor,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              room.currentBookTitle!,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              bookState.hasBook
                                  ? 'Ready to read'
                                  : 'Receiving book...',
                              style: TextStyle(
                                color: bookState.hasBook
                                    ? Colors.green
                                    : Colors.orange,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: bookState.isLoading ? null : _shareBook,
                      icon: const Icon(Icons.upload_file),
                      label: bookState.isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Share Book'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: AppTheme.primaryColor),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      // Feature 3: Start Reading broadcasts to all members.
                      onPressed: bookState.hasBook ? _startReading : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start Reading'),
                    ),
                  ),
                ],
              ),

              if (bookState.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  bookState.error!,
                  style: const TextStyle(
                      color: AppTheme.errorColor, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareBook() async {
    await ref.read(bookProvider.notifier).pickAndShareBook();
  }

  /// Feature 3: Broadcast start_reading so every member navigates to reader.
  Future<void> _startReading() async {
    final realtimeService = ref.read(realtimeServiceProvider);
    try {
      await realtimeService.broadcast(
        event: 'start_reading',
        payload: {'room_code': widget.roomCode},
      );
    } catch (_) {
      // If broadcast fails, still navigate self.
    }
    if (mounted) {
      context.goNamed('reader', pathParameters: {'roomCode': widget.roomCode});
    }
  }

  Future<void> _leaveRoom() async {
    try {
      await ref.read(presenceProvider.notifier).leaveRoom();
    } catch (_) {}
    try {
      await ref.read(roomProvider.notifier).leaveRoom();
    } catch (_) {}
    try {
      ref.read(bookProvider.notifier).reset();
    } catch (_) {}
    if (mounted) {
      context.goNamed('home');
    }
  }
}
