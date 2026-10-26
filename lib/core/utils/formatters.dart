import 'package:intl/intl.dart';

/// Human friendly formatting helpers used across the UI.
abstract final class Formatters {
  /// e.g. "Mon, Oct 26, 2026 9:45 PM"
  static String dateTime(DateTime value) =>
      DateFormat.yMMMEd().add_jm().format(value.toLocal());

  /// e.g. "Oct 26, 2026"
  static String date(DateTime value) =>
      DateFormat.yMMMd().format(value.toLocal());

  /// e.g. "9:45 PM"
  static String time(DateTime value) => DateFormat.jm().format(value.toLocal());

  /// e.g. "1.2 GB", "845 MB", "12 KB"
  static String bytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = unit == 0
        ? value.toStringAsFixed(0)
        : value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }

  /// Relative countdown such as "in 2h 15m", "in 3d 4h", "due now" or
  /// "overdue by 12m".
  static String countdown(DateTime scheduled, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final diff = scheduled.difference(reference);
    if (diff.inSeconds.abs() < 60) return 'due now';
    final text = _compactDuration(diff.abs());
    return diff.isNegative ? 'overdue by $text' : 'in $text';
  }

  /// "2h 15m", "3d 4h", "45m", "12s"
  static String _compactDuration(Duration d) {
    if (d.inDays >= 1) {
      final hours = d.inHours % 24;
      return hours == 0 ? '${d.inDays}d' : '${d.inDays}d ${hours}h';
    }
    if (d.inHours >= 1) {
      final minutes = d.inMinutes % 60;
      return minutes == 0 ? '${d.inHours}h' : '${d.inHours}h ${minutes}m';
    }
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  /// Percentage label for a 0..1 progress value, e.g. "42%".
  static String percent(double progress) =>
      '${(progress.clamp(0, 1) * 100).round()}%';

  /// Masks a secret for display: "sk_live_••••••••abcd".
  static String maskSecret(String value, {int visibleSuffix = 4}) {
    if (value.isEmpty) return '';
    if (value.length <= visibleSuffix) return '•' * value.length;
    final suffix = value.substring(value.length - visibleSuffix);
    return '${'•' * 8}$suffix';
  }
}
