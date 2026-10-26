import 'package:googleapis/youtube/v3.dart' as yt;

import '../../core/constants.dart';
import '../../data/models/scheduled_upload.dart';

/// The `snippet` + `status` sent with `videos.insert`, cleaned up so YouTube
/// accepts it (length limits, forbidden characters) with a note for every
/// adjustment so the user can see what changed.
class YouTubeMetadata {
  const YouTubeMetadata._(this.video, this.warnings);

  factory YouTubeMetadata.fromUpload(
    ScheduledUpload upload, {
    String categoryId = AppConstants.youtubeDefaultCategoryId,
  }) {
    final warnings = <String>[];

    if (_hasAngleBrackets(upload.title) ||
        _hasAngleBrackets(upload.description) ||
        upload.tags.any(_hasAngleBrackets)) {
      warnings.add('Removed "<" and ">" characters (not allowed by YouTube).');
    }

    var title = _stripAngleBrackets(
      upload.title,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.isEmpty) {
      title = _fallbackTitle(upload);
      warnings.add('Title was empty; using "$title".');
    }
    if (title.length > AppConstants.youtubeTitleMaxLength) {
      title = _truncate(title, AppConstants.youtubeTitleMaxLength);
      warnings.add(
        'Title shortened to ${AppConstants.youtubeTitleMaxLength} characters '
        'for YouTube.',
      );
    }

    var description = _stripAngleBrackets(upload.description).trim();
    if (description.length > AppConstants.youtubeDescriptionMaxLength) {
      description = _truncate(
        description,
        AppConstants.youtubeDescriptionMaxLength,
      );
      warnings.add(
        'Description shortened to '
        '${AppConstants.youtubeDescriptionMaxLength} characters for YouTube.',
      );
    }

    final tags = <String>[];
    var budget = AppConstants.youtubeTagsMaxTotalLength;
    var dropped = 0;
    for (final raw in upload.tags) {
      final tag = _stripAngleBrackets(raw).trim();
      if (tag.isEmpty) continue;
      // YouTube counts a comma between tags and wraps tags containing spaces
      // in quotes, which count too.
      final cost =
          tag.length + (tag.contains(' ') ? 2 : 0) + (tags.isEmpty ? 0 : 1);
      if (cost > budget) {
        dropped++;
        continue;
      }
      budget -= cost;
      tags.add(tag);
    }
    if (dropped > 0) {
      warnings.add(
        'Dropped $dropped tag(s) to stay within YouTube\'s '
        '${AppConstants.youtubeTagsMaxTotalLength}-character tag limit.',
      );
    }

    final video = yt.Video(
      snippet: yt.VideoSnippet(
        title: title,
        description: description,
        tags: tags.isEmpty ? null : tags,
        categoryId: categoryId,
      ),
      status: yt.VideoStatus(
        privacyStatus: 'public',
        selfDeclaredMadeForKids: false,
        // No publishAt: the video goes live as soon as YouTube finishes
        // processing it.
      ),
    );
    return YouTubeMetadata._(video, List.unmodifiable(warnings));
  }

  /// Request body for the resumable session.
  final yt.Video video;

  /// Human-readable adjustments made to the user's input.
  final List<String> warnings;

  Map<String, Object?> toJson() => video.toJson();

  String get title => video.snippet?.title ?? '';
  String get description => video.snippet?.description ?? '';
  List<String> get tags => video.snippet?.tags ?? const [];

  static bool _hasAngleBrackets(String value) =>
      value.contains('<') || value.contains('>');

  static String _stripAngleBrackets(String value) =>
      value.replaceAll('<', '').replaceAll('>', '');

  static String _fallbackTitle(ScheduledUpload upload) {
    final name = upload.videoName.trim();
    if (name.isEmpty) return 'Untitled video';
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.isEmpty ? 'Untitled video' : base;
  }

  /// Cuts at [max] UTF-16 code units without splitting a surrogate pair.
  static String _truncate(String value, int max) {
    if (value.length <= max) return value;
    var end = max;
    final last = value.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return value.substring(0, end).trimRight();
  }
}
