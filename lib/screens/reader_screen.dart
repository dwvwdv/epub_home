import 'dart:async';

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
import '../providers/reading_preferences_provider.dart';
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
  bool _isStoppingPageSync = false;
  PageTurnCommand? _queuedTurnCommand;
  PageTurnCommand? _awaitingTurnRelocation;
  String? _queuedTargetCfi;
  String? _displayingTargetCfi;
  Future<void> _cfiWriteChain = Future<void>.value();

  // Track key so we can rebuild the viewer when theme changes.
  int _viewerKey = 0;

  @override
  void initState() {
    super.initState();
    _epubController = EpubController();
    // Seed from cached room state immediately so the first build has a CFI.
    // A fresh DB fetch happens inside _initReader(); if the CFI differs the
    // viewer is rebuilt via _viewerKey.
    _currentCfi = ref.read(roomProvider).currentRoom?.currentCfi;
    WidgetsBinding.instance.addPostFrameCallback((_) => _initReader());
  }

  Future<void> _initReader() async {
    final authState = ref.read(authProvider);
    final realtimeService = ref.read(realtimeServiceProvider);

    if (!authState.isAuthenticated) return;

    // Entering the route means "reading", but the client must remain outside
    // the page-turn quorum until the EPUB controller has loaded its chapters.
    final presence = ref.read(presenceProvider.notifier);
    await presence.updateReaderReady(false);
    if (!mounted || _isStoppingPageSync) return;
    await presence.updateIsReading(true);
    if (!mounted || _isStoppingPageSync) return;

    final pageSync = ref.read(pageSyncProvider.notifier);
    pageSync.onPageTurn = _handlePageTurn;
    pageSync.onPositionCommit = _handlePositionCommit;
    await pageSync.initialize(
      realtimeService: realtimeService,
      currentUserId: authState.userId!,
      currentNickname: authState.nickname,
      initialCfi: _currentCfi,
    );
    if (!mounted || _isStoppingPageSync) return;

    // Fetch the latest room CFI from DB (in case other users advanced the page
    // while this user was away).  If it differs from cached, force viewer reload.
    await ref.read(roomProvider.notifier).refreshRoom();
    if (!mounted || _isStoppingPageSync) return;
    final freshRoom = ref.read(roomProvider).currentRoom;
    final freshCfi = freshRoom?.currentCfi;
    if (freshCfi != null && freshCfi != _currentCfi && mounted) {
      _currentCfi = freshCfi;
      _rebuildViewer();
    }
    pageSync.updateReaderContext(
      isReady: _isReaderReady,
      currentCfi: _currentCfi,
    );
    await presence.updateReaderReady(_isReaderReady);
  }

  @override
  void dispose() {
    _isStoppingPageSync = true;
    final pageSync = ref.read(pageSyncProvider.notifier);
    pageSync.updateReaderContext(isReady: false, currentCfi: _currentCfi);
    unawaited(pageSync.stop());
    final presence = ref.read(presenceProvider.notifier);
    unawaited(presence.updateReaderReady(false));
    unawaited(presence.updateIsReading(false));
    _epubController = null;
    super.dispose();
  }

  void _handlePageTurn(PageTurnCommand command) {
    if (!mounted || _isStoppingPageSync) return;
    if (!_isReaderReady || _epubController == null) {
      _queuedTurnCommand = command;
      return;
    }
    _executePageTurn(command);
  }

  void _executePageTurn(PageTurnCommand command) {
    final controller = _epubController;
    if (controller == null || !_isReaderReady) {
      _queuedTurnCommand = command;
      return;
    }

    _queuedTurnCommand = null;
    _awaitingTurnRelocation = command;
    if (command.direction == PageTurnDirection.next) {
      controller.next();
    } else {
      controller.prev();
    }
  }

  void _handlePositionCommit(PagePositionCommit commit) {
    if (!mounted || _isStoppingPageSync) return;
    _queuedTurnCommand = null;
    _awaitingTurnRelocation = null;
    ref.read(bookProvider.notifier).updateCfi(commit.targetCfi);

    if (!_isReaderReady || _epubController == null) {
      _queuedTargetCfi = commit.targetCfi;
      return;
    }
    _displayCommittedPosition(commit.targetCfi);
  }

  void _displayCommittedPosition(String targetCfi) {
    _queuedTargetCfi = null;
    if (_currentCfi == targetCfi) return;
    _displayingTargetCfi = targetCfi;
    ref.read(pageSyncProvider.notifier).updateReaderContext(
          isReady: false,
        );
    unawaited(
      ref.read(presenceProvider.notifier).updateReaderReady(false),
    );
    _epubController?.display(cfi: targetCfi);
  }

  void _rebuildViewer() {
    if (_isStoppingPageSync ||
        ref.read(pageSyncProvider).currentRequest != null) {
      return;
    }
    _isReaderReady = false;
    ref.read(pageSyncProvider.notifier).updateReaderContext(
          isReady: false,
          currentCfi: _currentCfi,
        );
    unawaited(
      ref.read(presenceProvider.notifier).updateReaderReady(false),
    );
    setState(() => _viewerKey++);
  }

  Future<void> _commitRequesterPosition(
    PageTurnCommand command,
    String targetCfi,
  ) async {
    if (!command.isRequester || _isStoppingPageSync) return;
    final committed = await ref
        .read(pageSyncProvider.notifier)
        .commitPagePosition(targetCfi);
    if (!committed || !mounted) return;

    // The requester is the sole database writer. Followers only display the
    // committed CFI received through Realtime. Serialize writes so a slower
    // older request can never overwrite a newer committed position.
    final roomNotifier = ref.read(roomProvider.notifier);
    _cfiWriteChain = _cfiWriteChain.then((_) async {
      try {
        await roomNotifier.updateCfi(targetCfi);
      } catch (_) {
        // Realtime convergence already succeeded. Keep the write chain usable;
        // a later committed CFI must still be allowed to persist.
      }
    });
    await _cfiWriteChain;
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(pageSyncProvider);
    final presenceState = ref.watch(presenceProvider);
    final bookState = ref.watch(bookProvider);
    final prefs = ref.watch(readingPreferencesProvider);

    if (bookState.bookFile == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reader')),
        body: const Center(child: Text('No book loaded')),
      );
    }

    // Feature 2: intercept hardware back button in reader → go back to lobby.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveReader();
      },
      child: Scaffold(
        backgroundColor: prefs.backgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              // Sync status bar
              SyncStatusBar(
                syncState: syncState,
                onlineUsers: presenceState.onlineUsers,
                onConfirm: () => unawaited(
                  ref.read(pageSyncProvider.notifier).confirmPageTurn(),
                ),
                onDecline: () => unawaited(
                  ref.read(pageSyncProvider.notifier).declinePageTurn(),
                ),
              ),

              // EPUB reader with gesture overlay
              Expanded(
                child: Stack(
                  children: [
                    // Layer 1: EPUB viewer
                    AbsorbPointer(
                      absorbing: true,
                      child: EpubViewer(
                        key: ValueKey(_viewerKey),
                        epubController: _epubController!,
                        epubSource: EpubSource.fromFile(bookState.bookFile!),
                        displaySettings: EpubDisplaySettings(
                          flow: EpubFlow.paginated,
                          snap: false,
                        ),
                        initialCfi: _currentCfi,
                        onChaptersLoaded: (chapters) {
                          if (!mounted || _isStoppingPageSync) return;
                          setState(() => _isReaderReady = true);
                          ref
                              .read(pageSyncProvider.notifier)
                              .updateReaderContext(
                                isReady: true,
                                currentCfi: _currentCfi,
                              );
                          unawaited(
                            ref
                                .read(presenceProvider.notifier)
                                .updateReaderReady(true),
                          );

                          final targetCfi = _queuedTargetCfi;
                          if (targetCfi != null) {
                            _displayCommittedPosition(targetCfi);
                            return;
                          }
                          final queuedTurn = _queuedTurnCommand;
                          if (queuedTurn != null) _executePageTurn(queuedTurn);
                        },
                        onRelocated: (location) {
                          if (!mounted || _isStoppingPageSync) return;
                          final committedTarget = _displayingTargetCfi;
                          final relocatedCfi =
                              committedTarget ?? location.startCfi;
                          _currentCfi = relocatedCfi;
                          if (committedTarget != null) {
                            setState(() => _displayingTargetCfi = null);
                          }
                          ref
                              .read(bookProvider.notifier)
                              .updateCfi(relocatedCfi);
                          ref
                              .read(pageSyncProvider.notifier)
                              .updateReaderContext(
                                isReady: _isReaderReady &&
                                    _displayingTargetCfi == null,
                                currentCfi: relocatedCfi,
                              );
                          if (_displayingTargetCfi == null) {
                            unawaited(
                              ref
                                  .read(presenceProvider.notifier)
                                  .updateReaderReady(true),
                            );
                          }

                          final command = _awaitingTurnRelocation;
                          if (command != null) {
                            _awaitingTurnRelocation = null;
                            unawaited(
                              _commitRequesterPosition(command, relocatedCfi),
                            );
                          }
                        },
                      ),
                    ),

                    // Layer 2: Gesture interceptor overlay
                    if (_isReaderReady)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragEnd: (details) {
                            if (syncState.status != SyncStatus.idle ||
                                _displayingTargetCfi != null) {
                              return;
                            }
                            if (details.primaryVelocity == null) return;

                            if (details.primaryVelocity! < -200) {
                              unawaited(
                                ref
                                    .read(pageSyncProvider.notifier)
                                    .requestPageTurn(
                                      direction: PageTurnDirection.next,
                                      fromCfi: _currentCfi,
                                    ),
                              );
                            } else if (details.primaryVelocity! > 200) {
                              unawaited(
                                ref
                                    .read(pageSyncProvider.notifier)
                                    .requestPageTurn(
                                      direction: PageTurnDirection.previous,
                                      fromCfi: _currentCfi,
                                    ),
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
      ),
    );
  }

  Widget _buildBottomBar(PageSyncState syncState) {
    final isIdle = syncState.status == SyncStatus.idle &&
        _isReaderReady &&
        _displayingTargetCfi == null;

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
                ? () => unawaited(
                      ref.read(pageSyncProvider.notifier).requestPageTurn(
                            direction: PageTurnDirection.previous,
                            fromCfi: _currentCfi,
                          ),
                    )
                : null,
          ),

          const SizedBox(width: 24),

          // Next page button
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 32),
            onPressed: isIdle
                ? () => unawaited(
                      ref.read(pageSyncProvider.notifier).requestPageTurn(
                            direction: PageTurnDirection.next,
                            fromCfi: _currentCfi,
                          ),
                    )
                : null,
          ),

          const Spacer(),

          // Theme / color settings button (Feature 1)
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            onPressed: syncState.status == SyncStatus.idle &&
                    syncState.currentRequest == null &&
                    _isReaderReady &&
                    !_isStoppingPageSync
                ? _showThemeSettings
                : null,
            tooltip: 'Reading theme',
          ),

          // Members indicator
          IconButton(
            icon: const Icon(Icons.people_outline),
            onPressed: _showMembersDrawer,
            tooltip: 'Room members',
          ),
        ],
      ),
    );
  }

  // Feature 1: Show reading theme settings panel.
  void _showThemeSettings() {
    final prefs = ref.read(readingPreferencesProvider);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reading Theme',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // Theme presets row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ThemeOption(
                  label: 'Day',
                  bgColor: Colors.white,
                  textColor: Colors.black87,
                  isSelected: prefs.theme == ReadingTheme.day,
                  onTap: () {
                    if (ref.read(pageSyncProvider).currentRequest != null) {
                      Navigator.pop(ctx);
                      return;
                    }
                    ref
                        .read(readingPreferencesProvider.notifier)
                        .setTheme(ReadingTheme.day);
                    _rebuildViewer();
                    Navigator.pop(ctx);
                  },
                ),
                _ThemeOption(
                  label: 'Sepia',
                  bgColor: const Color(0xFFF5E6C8),
                  textColor: const Color(0xFF4A3728),
                  isSelected: prefs.theme == ReadingTheme.sepia,
                  onTap: () {
                    if (ref.read(pageSyncProvider).currentRequest != null) {
                      Navigator.pop(ctx);
                      return;
                    }
                    ref
                        .read(readingPreferencesProvider.notifier)
                        .setTheme(ReadingTheme.sepia);
                    _rebuildViewer();
                    Navigator.pop(ctx);
                  },
                ),
                _ThemeOption(
                  label: 'Night',
                  bgColor: const Color(0xFF1A1A2E),
                  textColor: const Color(0xFFE0E0E0),
                  isSelected: prefs.theme == ReadingTheme.night,
                  onTap: () {
                    if (ref.read(pageSyncProvider).currentRequest != null) {
                      Navigator.pop(ctx);
                      return;
                    }
                    ref
                        .read(readingPreferencesProvider.notifier)
                        .setTheme(ReadingTheme.night);
                    _rebuildViewer();
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // Feature 3: Members panel showing who's reading and who left (yellow).
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
              '${presenceState.onlineCount} Members Online',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ...presenceState.onlineUsers.map((user) {
              final isReading = user['is_reading'] as bool? ?? false;
              final nickname = user['nickname'] as String? ?? 'Unknown';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        // Green = reading, Yellow = left the page
                        color: isReading ? Colors.green : Colors.amber,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        nickname,
                        style: TextStyle(
                          fontSize: 16,
                          color: isReading ? Colors.white : Colors.amber,
                        ),
                      ),
                    ),
                    if (!isReading)
                      const Text(
                        'Left',
                        style: TextStyle(color: Colors.amber, fontSize: 12),
                      ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _leaveReader() async {
    // Feature 3: Mark this user as no longer reading.
    if (_isStoppingPageSync) return;
    _isStoppingPageSync = true;
    final pageSync = ref.read(pageSyncProvider.notifier);
    pageSync.updateReaderContext(isReady: false, currentCfi: _currentCfi);
    final presence = ref.read(presenceProvider.notifier);
    try {
      await pageSync.stop();
    } catch (_) {
      // Local navigation must not be held hostage by a stale subscription.
    }
    try {
      await presence.updateReaderReady(false);
      await presence.updateIsReading(false);
    } catch (_) {
      // Presence reconciliation/room cleanup handles disconnected exits.
    }
    if (mounted) {
      context.goNamed('lobby', pathParameters: {'roomCode': widget.roomCode});
    }
  }
}

/// A circular theme-selection button shown in the theme picker.
class _ThemeOption extends StatelessWidget {
  final String label;
  final Color bgColor;
  final Color textColor;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.label,
    required this.bgColor,
    required this.textColor,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? AppTheme.primaryColor : Colors.white24,
                width: isSelected ? 3 : 1,
              ),
            ),
            child: Center(
              child: Text(
                'Aa',
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? AppTheme.primaryColor : Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
