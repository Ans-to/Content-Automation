import 'package:content_automation/core/utils/formatters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Formatters.bytes', () {
    test('formats common sizes', () {
      expect(Formatters.bytes(0), '0 B');
      expect(Formatters.bytes(512), '512 B');
      expect(Formatters.bytes(1024), '1.0 KB');
      expect(Formatters.bytes(5 * 1024 * 1024), '5.0 MB');
      expect(Formatters.bytes(845 * 1024 * 1024), '845 MB');
      expect(Formatters.bytes((1.2 * 1024 * 1024 * 1024).round()), '1.2 GB');
    });
  });

  group('Formatters.countdown', () {
    final now = DateTime(2026, 10, 26, 12);

    test('future times', () {
      expect(
        Formatters.countdown(now.add(const Duration(minutes: 45)), now: now),
        'in 45m',
      );
      expect(
        Formatters.countdown(
          now.add(const Duration(hours: 2, minutes: 15)),
          now: now,
        ),
        'in 2h 15m',
      );
      expect(
        Formatters.countdown(
          now.add(const Duration(days: 3, hours: 4)),
          now: now,
        ),
        'in 3d 4h',
      );
    });

    test('due now within a minute', () {
      expect(
        Formatters.countdown(now.add(const Duration(seconds: 20)), now: now),
        'due now',
      );
    });

    test('overdue', () {
      expect(
        Formatters.countdown(
          now.subtract(const Duration(minutes: 12)),
          now: now,
        ),
        'overdue by 12m',
      );
    });
  });

  test('percent clamps and rounds', () {
    expect(Formatters.percent(0.421), '42%');
    expect(Formatters.percent(1.4), '100%');
    expect(Formatters.percent(-1), '0%');
  });

  test('maskSecret keeps only the suffix', () {
    expect(Formatters.maskSecret('sk_live_1234abcd'), '••••••••abcd');
    expect(Formatters.maskSecret('ab'), '••');
    expect(Formatters.maskSecret(''), '');
  });
}
