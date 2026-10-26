import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/integrations/youtube/youtube_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ScheduledUpload upload({
    String title = 'Title',
    String description = 'Description',
    List<String> tags = const ['a', 'b'],
    String videoName = 'holiday_clip.mp4',
  }) => ScheduledUpload.create(
    videoPath: '/videos/$videoName',
    videoName: videoName,
    videoSizeBytes: 10,
    title: title,
    description: description,
    tags: tags,
    scheduledTime: DateTime(2026, 11, 1, 9),
    platform: UploadPlatform.youtube,
  );

  test('maps the schedule to a public snippet/status without publishAt', () {
    final meta = YouTubeMetadata.fromUpload(upload());
    final json = meta.toJson();

    expect(json['snippet'], {
      'title': 'Title',
      'description': 'Description',
      'tags': ['a', 'b'],
      'categoryId': '22',
    });
    expect(json['status'], {
      'privacyStatus': 'public',
      'selfDeclaredMadeForKids': false,
    });
    expect(meta.warnings, isEmpty);
  });

  test('strips angle brackets and collapses whitespace in the title', () {
    final meta = YouTubeMetadata.fromUpload(
      upload(title: '  Hello <b>world</b>\n  again  '),
    );
    expect(meta.title, 'Hello bworld/b again');
    expect(meta.warnings.single, contains('Removed "<" and ">"'));
  });

  test('shortens an over-long title and description', () {
    final meta = YouTubeMetadata.fromUpload(
      upload(title: 'T' * 120, description: 'D' * 6000),
    );
    expect(meta.title.length, 100);
    expect(meta.description.length, 5000);
    expect(meta.warnings, [
      contains('Title shortened to 100'),
      contains('Description shortened to 5000'),
    ]);
  });

  test('does not split a surrogate pair when truncating', () {
    final meta = YouTubeMetadata.fromUpload(upload(title: '${'x' * 99}😀'));
    // 99 chars + a 2-unit emoji = 101 units → the emoji is dropped whole.
    expect(meta.title, 'x' * 99);
  });

  test('falls back to the file name when the title is empty', () {
    final meta = YouTubeMetadata.fromUpload(upload(title: '<>'));
    expect(meta.title, 'holiday_clip');
    expect(meta.warnings, contains(contains('Title was empty')));
  });

  test('keeps tags within the 500 character budget', () {
    final tags = List.generate(60, (i) => 'tag number $i'); // ~13 chars + quotes
    final meta = YouTubeMetadata.fromUpload(upload(tags: tags));

    var total = 0;
    for (final tag in meta.tags) {
      total += tag.length + (tag.contains(' ') ? 2 : 0);
    }
    total += meta.tags.length - 1; // commas
    expect(total, lessThanOrEqualTo(500));
    expect(meta.tags.length, lessThan(tags.length));
    expect(meta.warnings.single, contains('Dropped'));
    // Order of the kept tags is preserved.
    expect(meta.tags.first, 'tag number 0');
  });

  test('omits the tags property when there are none', () {
    final meta = YouTubeMetadata.fromUpload(upload(tags: const []));
    expect((meta.toJson()['snippet'] as Map).containsKey('tags'), isFalse);
  });
}
