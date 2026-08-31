import 'package:flutter_test/flutter_test.dart';
import 'package:penbridge/main.dart';

void main() {
  test('input mode protocol ids stay stable', () {
    expect(BridgeMode.values.map((mode) => mode.id), [
      'pen',
      'mouse',
      'trackpad',
      'blender',
    ]);
  });
}
