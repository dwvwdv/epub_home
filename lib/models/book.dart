class Book {
  final String id;
  final String title;
  final String author;
  final String filePath;
  final List<Chapter> chapters;
  final String? coverImagePath;
  int currentChapter;
  int currentPage;

  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.filePath,
    required this.chapters,
    this.coverImagePath,
    this.currentChapter = 0,
    this.currentPage = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'filePath': filePath,
        'coverImagePath': coverImagePath,
        'currentChapter': currentChapter,
        'currentPage': currentPage,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String,
        filePath: json['filePath'] as String,
        chapters: [],
        coverImagePath: json['coverImagePath'] as String?,
        currentChapter: json['currentChapter'] as int? ?? 0,
        currentPage: json['currentPage'] as int? ?? 0,
      );
}

class Chapter {
  final String id;
  final String title;
  final String content;
  final int order;

  Chapter({
    required this.id,
    required this.title,
    required this.content,
    required this.order,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'order': order,
      };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        id: json['id'] as String,
        title: json['title'] as String,
        content: json['content'] as String,
        order: json['order'] as int,
      );
}
