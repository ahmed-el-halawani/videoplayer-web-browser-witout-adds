import 'package:flutter_test/flutter_test.dart';
import 'package:adblock_browser/main.dart';

void main() {
  test('isUrl distinguishes hosts from search queries', () {
    expect(isUrl('example.com'), true);
    expect(isUrl('https://x.org'), true);
    expect(isUrl('cute cats'), false);
    expect(isUrl(''), false);
  });

  test('toLoadUrl prefixes scheme and falls back to search', () {
    expect(toLoadUrl('example.com'), 'https://example.com');
    expect(toLoadUrl('cute cats'), startsWith('https://www.google.com/search?q='));
  });
}
