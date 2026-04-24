import 'package:flutter_test/flutter_test.dart';

import 'package:picture_that/services/model_service.dart';

void main() {
  test('cancellation error descriptions are detected', () {
    expect(
      isCancellationErrorDescription(
        'kotlinx.coroutines.JobCancellationException: StandaloneCoroutine was cancelled; job=StandaloneCoroutine{Cancelling}@4c190ca',
      ),
      isTrue,
    );

    expect(
      isCancellationErrorDescription('TaskHttpException: response code 404'),
      isFalse,
    );
  });
}
