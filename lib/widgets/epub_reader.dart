import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

class EpubReader extends StatelessWidget {
  final String content;
  final String chapterTitle;

  const EpubReader({
    super.key,
    required this.content,
    required this.chapterTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (chapterTitle.isNotEmpty) ...[
                  Text(
                    chapterTitle,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                Html(
                  data: content,
                  style: {
                    'body': Style(
                      fontSize: FontSize(18),
                      lineHeight: const LineHeight(1.8),
                    ),
                    'p': Style(
                      margin: Margins.only(bottom: 16),
                    ),
                    'h1': Style(
                      fontSize: FontSize(24),
                      fontWeight: FontWeight.bold,
                      margin: Margins.only(top: 24, bottom: 16),
                    ),
                    'h2': Style(
                      fontSize: FontSize(22),
                      fontWeight: FontWeight.bold,
                      margin: Margins.only(top: 20, bottom: 14),
                    ),
                    'h3': Style(
                      fontSize: FontSize(20),
                      fontWeight: FontWeight.bold,
                      margin: Margins.only(top: 16, bottom: 12),
                    ),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
