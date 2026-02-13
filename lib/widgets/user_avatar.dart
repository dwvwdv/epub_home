import 'package:flutter/material.dart';
import '../config/theme.dart';

class UserAvatar extends StatelessWidget {
  final String nickname;
  final int colorIndex;
  final double size;
  final bool isOnline;

  const UserAvatar({
    super.key,
    required this.nickname,
    this.colorIndex = 0,
    this.size = 40,
    this.isOnline = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.avatarColors[colorIndex % AppTheme.avatarColors.length];
    final initials = nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';

    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color.withValues(alpha: isOnline ? 1.0 : 0.4),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              initials,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: size * 0.4,
              ),
            ),
          ),
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: size * 0.3,
              height: size * 0.3,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.backgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
