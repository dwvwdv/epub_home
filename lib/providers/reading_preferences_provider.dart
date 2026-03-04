import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Preset reading themes for the EPUB reader.
enum ReadingTheme {
  day,
  night,
  sepia,
}

class ReadingPreferences {
  final ReadingTheme theme;
  final double fontSize;

  const ReadingPreferences({
    this.theme = ReadingTheme.day,
    this.fontSize = 16,
  });

  Color get backgroundColor {
    switch (theme) {
      case ReadingTheme.day:
        return Colors.white;
      case ReadingTheme.night:
        return const Color(0xFF1A1A2E);
      case ReadingTheme.sepia:
        return const Color(0xFFF5E6C8);
    }
  }

  Color get textColor {
    switch (theme) {
      case ReadingTheme.day:
        return Colors.black87;
      case ReadingTheme.night:
        return const Color(0xFFE0E0E0);
      case ReadingTheme.sepia:
        return const Color(0xFF4A3728);
    }
  }

  ReadingPreferences copyWith({
    ReadingTheme? theme,
    double? fontSize,
  }) {
    return ReadingPreferences(
      theme: theme ?? this.theme,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

class ReadingPreferencesNotifier extends StateNotifier<ReadingPreferences> {
  ReadingPreferencesNotifier() : super(const ReadingPreferences());

  void setTheme(ReadingTheme theme) {
    state = state.copyWith(theme: theme);
  }

  void setFontSize(double size) {
    state = state.copyWith(fontSize: size.clamp(12, 28));
  }
}

final readingPreferencesProvider =
    StateNotifierProvider<ReadingPreferencesNotifier, ReadingPreferences>(
  (ref) => ReadingPreferencesNotifier(),
);
