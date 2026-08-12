class AppConstants {
  // Room
  static const int roomCodeLength = 6;
  static const String roomCodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  // Page sync
  static const Duration pageTurnTimeout = Duration(seconds: 30);

  // File transfer
  // 32KB raw → ~43KB base64; safe within Supabase Realtime broadcast limit
  static const int fileChunkSize = 32 * 1024;
  static const int maxFileSize = 10 * 1024 * 1024; // 10MB limit for MVP
  static const Duration chunkDelay = Duration(milliseconds: 100);

  // Realtime
  static String roomChannelName(String roomCode) => 'cotime_book:room:$roomCode';
}
