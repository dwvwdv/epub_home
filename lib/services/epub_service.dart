import 'dart:io';
import 'package:epubx/epubx.dart';
import 'package:uuid/uuid.dart';
import '../models/book.dart';

class EpubService {
  final _uuid = const Uuid();

  /// 解析 EPUB 文件
  Future<Book> parseEpubFile(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final epubBook = await EpubReader.readBook(bytes);

      // 提取書籍信息
      final title = epubBook.Title ?? 'Unknown Title';
      final author = epubBook.Author ?? 'Unknown Author';

      // 提取章節
      final chapters = <Chapter>[];
      int order = 0;

      for (final chapter in epubBook.Chapters ?? <EpubChapter>[]) {
        final chapterContent = await _extractChapterContent(chapter);
        chapters.add(Chapter(
          id: _uuid.v4(),
          title: chapter.Title ?? 'Chapter ${order + 1}',
          content: chapterContent,
          order: order++,
        ));
      }

      // 創建 Book 對象
      return Book(
        id: _uuid.v4(),
        title: title,
        author: author,
        filePath: filePath,
        chapters: chapters,
      );
    } catch (e) {
      throw Exception('Failed to parse EPUB file: $e');
    }
  }

  /// 提取章節內容
  Future<String> _extractChapterContent(EpubChapter chapter) async {
    final htmlContent = chapter.HtmlContent ?? '';

    // 遞歸處理子章節
    if (chapter.SubChapters != null && chapter.SubChapters!.isNotEmpty) {
      final subContents = <String>[];
      for (final subChapter in chapter.SubChapters!) {
        final subContent = await _extractChapterContent(subChapter);
        subContents.add(subContent);
      }
      return '$htmlContent\n${subContents.join('\n')}';
    }

    return htmlContent;
  }

  /// 分頁處理（根據內容長度估算）
  List<String> paginateContent(String content, {int maxLength = 2000}) {
    final pages = <String>[];

    if (content.length <= maxLength) {
      return [content];
    }

    int startIndex = 0;
    while (startIndex < content.length) {
      int endIndex = startIndex + maxLength;

      if (endIndex >= content.length) {
        pages.add(content.substring(startIndex));
        break;
      }

      // 嘗試在段落或句子邊界分頁
      final chunk = content.substring(startIndex, endIndex);
      final lastParagraph = chunk.lastIndexOf('</p>');
      final lastSentence = chunk.lastIndexOf('。');

      if (lastParagraph > maxLength * 0.7) {
        endIndex = startIndex + lastParagraph + 4; // '</p>'.length
      } else if (lastSentence > maxLength * 0.7) {
        endIndex = startIndex + lastSentence + 1;
      }

      pages.add(content.substring(startIndex, endIndex));
      startIndex = endIndex;
    }

    return pages;
  }
}
