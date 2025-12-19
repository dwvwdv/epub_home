class AppConstants {
  // App Info
  static const String appName = 'EPUB Home';
  static const String appVersion = '1.0.0';

  // Network
  static const String webhookBaseUrl = 'https://n8n.lazyrhythm.com/webhook';
  static const int defaultPort = 8888;

  // Storage Keys
  static const String keyBooks = 'books';
  static const String keyCurrentUser = 'current_user';
  static const String keyDeviceId = 'device_id';

  // UI
  static const double defaultPadding = 16.0;
  static const double defaultBorderRadius = 8.0;

  // EPUB
  static const int defaultPageLength = 2000;
  static const int maxChapterCacheSize = 5;

  // Sync
  static const Duration syncPollInterval = Duration(seconds: 1);
  static const Duration syncTimeout = Duration(seconds: 30);
}
