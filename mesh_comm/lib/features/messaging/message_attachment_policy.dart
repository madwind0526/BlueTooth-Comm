class MessageAttachmentPolicy {
  MessageAttachmentPolicy._();

  static const int maxImagesPerMessage = 10;
  static const int maxFilesPerMessage = 10;
  static const int maxPreviewBytes = 256 * 1024;
  static const int maxAttachmentBytes = 25 * 1024 * 1024;

  static const Set<String> imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
  };

  static const Set<String> documentExtensions = {
    'txt',
    'md',
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'json',
    'zip',
  };

  static const Set<String> mediaExtensions = {
    'mp3',
    'wav',
    'm4a',
    'mp4',
    'mov',
    'webm',
  };

  static bool isSupportedExtension(String extension) {
    final normalized = _normalizeExtension(extension);
    return imageExtensions.contains(normalized) ||
        documentExtensions.contains(normalized) ||
        mediaExtensions.contains(normalized);
  }

  static bool canPreviewInline(String extension, int bytes) {
    final normalized = _normalizeExtension(extension);
    return imageExtensions.contains(normalized) && bytes <= maxPreviewBytes;
  }

  static String _normalizeExtension(String extension) {
    return extension.trim().toLowerCase().replaceFirst('.', '');
  }
}
