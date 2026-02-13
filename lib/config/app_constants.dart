class AppConstants {
  // Room
  static const int roomCodeLength = 6;
  static const String roomCodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  // Page sync
  static const Duration pageTurnTimeout = Duration(seconds: 30);

  // File transfer
  static const int fileChunkSize = 700 * 1024; // 700KB raw per chunk
  static const int maxFileSize = 10 * 1024 * 1024; // 10MB limit for MVP
  static const Duration chunkDelay = Duration(milliseconds: 50);

  // Realtime
  static String roomChannelName(String roomCode) => 'room:$roomCode';
}
