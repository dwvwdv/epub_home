import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
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
  StreamSubscription? _membershipChangedSub;
  StreamSubscription? _roomClosedSub;
  TransferState _transferState = const TransferState.idle();
  bool _isInitializing = true;
  bool _isLeaving = false;
  bool _isNavigatingToReader = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initRoom());
  }

  Future<void> _initRoom() async {
    try {
      await _cancelScreenSubscriptions();
      final authState = await _waitForAuthentication();
      if (!mounted) return;

      final roomState = ref.read(roomProvider);
      final room = roomState.currentRoom;
      if (room == null) {
        throw StateError('This room is not available on this device.');
      }
      if (room.code.toUpperCase() != widget.roomCode.toUpperCase()) {
        throw StateError(
          'Room link ${widget.roomCode.toUpperCase()} does not match your '
          'active room ${room.code}.',
        );
      }

      final userId = authState.userId!;
      final nickname = authState.nickname;

      if (room.currentBookHash != null &&
          !ref.read(bookProvider.notifier).hasBook(room.currentBookHash!)) {
        await ref
            .read(bookProvider.notifier)
            .loadExistingBook(room.currentBookHash!);
      }

      final ownMember = roomState.members
          .where((member) => member.userId == userId)
          .firstOrNull;

      final realtimeService = ref.read(realtimeServiceProvider);
      await ref
          .read(bookProvider.notifier)
          .initTransferService(
            realtimeService: realtimeService,
            currentUserId: userId,
            roomCode: room.code,
          );

      final transferService = ref.read(bookProvider.notifier).transferService;
      _transferState =
          transferService?.currentState ?? const TransferState.idle();
      _transferSub = transferService?.stateStream.listen((state) {
        if (mounted) setState(() => _transferState = state);
      });

      // Listen for book_shared events
      _bookSharedSub = realtimeService.broadcastStream('book_shared').listen((
        payload,
      ) {
        final bookHash = payload['file_hash'] as String?;
        final bookTitle = payload['title'] as String?;
        if (bookHash != null) {
          unawaited(
            ref.read(bookProvider.notifier).prepareForSharedBook(bookHash),
          );
          ref
              .read(roomProvider.notifier)
              .onBookSharedReceived(
                bookTitle: bookTitle ?? 'Unknown',
                bookHash: bookHash,
              );
        }
      });

      _roomClosedSub = realtimeService.broadcastStream('room_closed').listen((
        _,
      ) {
        if (mounted) _leaveRoom(reason: 'This room has been closed.');
      });

      _membershipChangedSub = realtimeService
          .broadcastStream('membership_changed')
          .listen((_) {
            if (!mounted) return;
            unawaited(_refreshMembersAfterLeaveSignal());
          });

      // Feature 3: Listen for start_reading broadcast → navigate all members to reader.
      _startReadingSub = realtimeService
          .broadcastStream('start_reading')
          .listen((payload) {
            if (!mounted || _isNavigatingToReader) return;
            final currentRoomState = ref.read(roomProvider);
            final currentRoom = currentRoomState.currentRoom;
            if (currentRoom == null ||
                payload['initiated_by'] != currentRoom.hostUserId) {
              return;
            }
            final sessionId = payload['session_id'];
            final rawParticipantUserIds = payload['participant_user_ids'];
            if (sessionId is! String ||
                sessionId.isEmpty ||
                rawParticipantUserIds is! List) {
              return;
            }
            final participantUserIds = rawParticipantUserIds
                .whereType<String>()
                .toSet();
            final roomMemberUserIds = currentRoomState.members
                .map((member) => member.userId)
                .toSet();
            if (participantUserIds.length != rawParticipantUserIds.length ||
                participantUserIds.length != roomMemberUserIds.length ||
                !participantUserIds.containsAll(roomMemberUserIds)) {
              _showError('The reading session roster is out of date.');
              return;
            }
            if (currentRoom.currentBookHash == null ||
                !ref
                    .read(bookProvider.notifier)
                    .hasBook(currentRoom.currentBookHash!)) {
              _showError('The shared book is not ready on this device.');
              return;
            }
            ref.read(roomProvider.notifier).beginReadingSession(
              sessionId: sessionId,
              participantUserIds: participantUserIds,
            );
            _isNavigatingToReader = true;
            context.goNamed('reader', pathParameters: {'roomCode': room.code});
          });

      // Install application listeners before channel subscription. A fast
      // sender can otherwise deliver the first file chunk between Presence
      // join and transfer initialization. Joining is idempotent when returning
      // from the reader and updates the current Presence payload in place.
      await ref
          .read(presenceProvider.notifier)
          .joinRoom(
            roomCode: room.code,
            userId: userId,
            nickname: nickname,
            avatarColorIndex: ownMember?.avatarColorIndex ?? 0,
            hasBook:
                room.currentBookHash != null &&
                ref.read(bookProvider.notifier).hasBook(room.currentBookHash!),
            bookHash: room.currentBookHash,
            isReading: false,
            readerReady: false,
          );

      if (mounted) setState(() => _isInitializing = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<AuthState> _waitForAuthentication() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final authState = ref.read(authProvider);
      if (authState.isAuthenticated) return authState;
      if (authState.error != null) throw StateError(authState.error!);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) throw StateError('Room initialization was cancelled.');
    }
    throw StateError('Authentication timed out. Please return home and retry.');
  }

  @override
  void dispose() {
    unawaited(_cancelScreenSubscriptions());
    super.dispose();
  }

  Future<void> _cancelScreenSubscriptions() async {
    await Future.wait<void>([
      if (_transferSub != null) _transferSub!.cancel(),
      if (_bookSharedSub != null) _bookSharedSub!.cancel(),
      if (_startReadingSub != null) _startReadingSub!.cancel(),
      if (_membershipChangedSub != null) _membershipChangedSub!.cancel(),
      if (_roomClosedSub != null) _roomClosedSub!.cancel(),
    ]);
    _transferSub = null;
    _bookSharedSub = null;
    _startReadingSub = null;
    _membershipChangedSub = null;
    _roomClosedSub = null;
  }

  Future<void> _refreshMembersAfterLeaveSignal() async {
    // The leaving client must broadcast before its membership is deleted so
    // Realtime RLS still authorizes the send. Give the following leave RPC a
    // short window to commit, then read the authoritative database state.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    await ref
        .read(roomProvider.notifier)
        .refreshMembers(presenceUsers: ref.read(presenceProvider).onlineUsers);
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
      final previousIds = (previous?.onlineUserIds ?? const <String>[]).toSet();
      final nextIds = next.onlineUserIds.toSet();
      if (!const SetEquality<String>().equals(previousIds, nextIds)) {
        notifier.refreshMembers(presenceUsers: next.onlineUsers);
      }
    });

    if (_isInitializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final routeMatchesRoom =
        room != null &&
        room.code.toUpperCase() == widget.roomCode.toUpperCase();
    if (_initError != null || !routeMatchesRoom) {
      return _buildRouteError(
        _initError ?? 'This room is no longer available.',
      );
    }
    final activeRoom = room;
    final hasCurrentBook =
        activeRoom.currentBookHash != null &&
        ref.read(bookProvider.notifier).hasBook(activeRoom.currentBookHash!);

    final canStartReading = _canStartReading(
      roomState: roomState,
      presenceState: presenceState,
      hasLocalBook: hasCurrentBook,
      currentBookHash: activeRoom.currentBookHash,
    );

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
            onPressed: _isLeaving ? null : () => _leaveRoom(),
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
              RoomCodeDisplay(code: activeRoom.code),
              const SizedBox(height: 24),

              // Members section
              Row(
                children: [
                  const Text(
                    'Members',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
              if (activeRoom.currentBookTitle != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.cardColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.menu_book, color: AppTheme.primaryColor),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              activeRoom.currentBookTitle!,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              hasCurrentBook
                                  ? 'Ready to read'
                                  : 'Receiving book...',
                              style: TextStyle(
                                color: hasCurrentBook
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
                      onPressed:
                          _isLeaving ||
                              bookState.isLoading ||
                              _transferState.isActive
                          ? null
                          : _shareBook,
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
                      onPressed: _isLeaving || !canStartReading
                          ? null
                          : _startReading,
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
                    color: AppTheme.errorColor,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (presenceState.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  presenceState.error!,
                  style: const TextStyle(
                    color: AppTheme.errorColor,
                    fontSize: 12,
                  ),
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

  Future<void> _startReading() async {
    final realtimeService = ref.read(realtimeServiceProvider);
    final currentRoom = ref.read(roomProvider).currentRoom;
    final currentUserId = ref.read(authProvider).userId;
    if (currentRoom == null || currentRoom.hostUserId != currentUserId) {
      _showError('Only the room host can start reading.');
      return;
    }
    final currentHash = currentRoom.currentBookHash;
    final isReady = _canStartReading(
      roomState: ref.read(roomProvider),
      presenceState: ref.read(presenceProvider),
      hasLocalBook:
          currentHash != null &&
          ref.read(bookProvider.notifier).hasBook(currentHash),
      currentBookHash: currentHash,
    );
    if (!isReady) {
      _showError('Wait until every room member is online with this book.');
      return;
    }
    try {
      final participantUserIds = ref
          .read(roomProvider)
          .members
          .map((member) => member.userId)
          .toList()
        ..sort();
      await realtimeService.broadcast(
        event: 'start_reading',
        payload: {
          'room_code': widget.roomCode,
          'initiated_by': currentUserId,
          'session_id': const Uuid().v4(),
          'participant_user_ids': participantUserIds,
        },
      );
      // Broadcast is configured with self=true. The single listener above
      // performs navigation for host and guests, avoiding host double-nav.
    } catch (error) {
      if (mounted) _showError('Unable to start reading: $error');
    }
  }

  bool _canStartReading({
    required RoomState roomState,
    required PresenceState presenceState,
    required bool hasLocalBook,
    required String? currentBookHash,
  }) {
    if (!roomState.isHost ||
        !hasLocalBook ||
        !presenceState.isConnected ||
        !presenceState.hasInitialSync ||
        currentBookHash == null ||
        roomState.members.isEmpty) {
      return false;
    }

    final onlineById = {
      for (final user in presenceState.onlineUsers)
        if (user['user_id'] is String) user['user_id'] as String: user,
    };
    return roomState.members.every((member) {
      final presence = onlineById[member.userId];
      final readyHashes = presence?['ready_book_hashes'];
      return presence != null &&
          presence['has_book'] == true &&
          readyHashes is List &&
          readyHashes.contains(currentBookHash);
    });
  }

  Widget _buildRouteError(String message) {
    return Scaffold(
      appBar: AppBar(title: const Text('Room unavailable')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.meeting_room_outlined,
                size: 56,
                color: AppTheme.errorColor,
              ),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.goNamed('home'),
                child: const Text('Return Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leaveRoom({String? reason}) async {
    if (_isLeaving) return;
    if (mounted) setState(() => _isLeaving = true);

    final errors = <String>[];
    try {
      await ref.read(presenceProvider.notifier).announceLeaving();
    } catch (error) {
      // The database leave remains authoritative. Presence sync and the stale
      // membership cleanup job provide eventual convergence if this hint fails.
      debugPrint('Unable to announce room departure: $error');
    }
    try {
      await ref.read(roomProvider.notifier).leaveRoom();
    } catch (error) {
      errors.add('room membership: $error');
    }
    try {
      await ref.read(presenceProvider.notifier).leaveRoom();
    } catch (error) {
      errors.add('realtime presence: $error');
    }
    await ref.read(bookProvider.notifier).reset();

    if (mounted) {
      final message = [
        if (reason != null) reason,
        if (errors.isNotEmpty)
          'Room cleanup needs attention: ${errors.join('; ')}',
      ].join('\n');
      if (message.isNotEmpty) _showError(message);
      context.goNamed('home');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
