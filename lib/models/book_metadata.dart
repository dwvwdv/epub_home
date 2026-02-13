class BookMetadata {
  final String id;
  final String title;
  final String author;
  final String fileName;
  final int fileSizeBytes;
  final String fileHash;

  const BookMetadata({
    required this.id,
    required this.title,
    required this.author,
    required this.fileName,
    required this.fileSizeBytes,
    required this.fileHash,
  });

  factory BookMetadata.fromJson(Map<String, dynamic> json) {
    return BookMetadata(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String? ?? 'Unknown',
      fileName: json['file_name'] as String,
      fileSizeBytes: json['file_size_bytes'] as int,
      fileHash: json['file_hash'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'file_name': fileName,
      'file_size_bytes': fileSizeBytes,
      'file_hash': fileHash,
    };
  }

  String get fileSizeFormatted {
    if (fileSizeBytes < 1024) return '$fileSizeBytes B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
