import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picture_that/services/model_boot_state.dart';
import 'package:picture_that/widgets/model_boot_splash.dart';

void main() {
  group('ModelBootSplash', () {
    group('needsDownload phase', () {
      testWidgets('shows download confirmation card', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model download required',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.needsDownload,
              onConfirmDownload: ({String? customUrl}) {},
              onCancel: () {},
            ),
          ),
        );

        expect(find.text('Download Required'), findsOneWidget);
        expect(find.textContaining('machine learning model'), findsOneWidget);
        expect(find.text('Download Model'), findsOneWidget);
        expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
      });

      testWidgets('shows WiFi warning', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model download required',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.needsDownload,
              onConfirmDownload: ({String? customUrl}) {},
            ),
          ),
        );

        expect(find.byIcon(Icons.wifi_outlined), findsOneWidget);
        expect(find.textContaining('Connect to WiFi'), findsOneWidget);
      });

      testWidgets('displays model size when provided', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model download required',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.needsDownload,
              modelSize: '1.8 GB',
              onConfirmDownload: ({String? customUrl}) {},
            ),
          ),
        );

        expect(find.textContaining('1.8 GB'), findsOneWidget);
      });

      testWidgets('calls onConfirmDownload when Download Model pressed', (tester) async {
        String? capturedCustomUrl;

        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model download required',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.needsDownload,
              onConfirmDownload: ({String? customUrl}) {
                capturedCustomUrl = customUrl;
              },
            ),
          ),
        );

        await tester.tap(find.text('Download Model'));
        await tester.pump();

        expect(capturedCustomUrl, isNull);
      });

      testWidgets('shows advanced section when Advanced tapped', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model download required',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.needsDownload,
              onConfirmDownload: ({String? customUrl}) {},
            ),
          ),
        );

        expect(find.text('Custom Model URL'), findsNothing);

        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();

        expect(find.text('Custom Model URL'), findsOneWidget);
        expect(find.text('Leave empty to use default (Hugging Face)'), findsOneWidget);
        expect(find.text('Download from Custom URL'), findsOneWidget);
      });

      testWidgets('passes custom URL when downloading from custom URL', (tester) async {
        const testUrl = 'https://internal-server.com/model.litertlm';
        String? capturedCustomUrl;

        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model download required',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.needsDownload,
              onConfirmDownload: ({String? customUrl}) {
                capturedCustomUrl = customUrl;
              },
            ),
          ),
        );

        // Open advanced section
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();

        // Enter custom URL
        await tester.enterText(find.byType(TextField), testUrl);
        await tester.pump();

        // Tap download from custom URL button
        await tester.tap(find.text('Download from Custom URL'));
        await tester.pump();

        expect(capturedCustomUrl, testUrl);
      });

      testWidgets('passes null when custom URL is empty', (tester) async {
        String? capturedCustomUrl;

        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model download required',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.needsDownload,
              onConfirmDownload: ({String? customUrl}) {
                capturedCustomUrl = customUrl;
              },
            ),
          ),
        );

        // Open advanced section
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();

        // Leave field empty and tap download
        await tester.tap(find.text('Download from Custom URL'));
        await tester.pump();

        expect(capturedCustomUrl, isNull);
      });
    });

    group('other phases', () {
      testWidgets('shows progress bar when downloading', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Downloading: 50%',
              error: null,
              progress: 0.5,
              isLoading: true,
              phase: ModelBootPhase.downloading,
            ),
          ),
        );

        expect(find.text('Downloading… 50%'), findsOneWidget);
        // Progress bar container should be present
        expect(find.byType(Container), findsWidgets);
      });

      testWidgets('shows ready state', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Model ready',
              error: null,
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.ready,
            ),
          ),
        );

        expect(find.text('Ready!'), findsOneWidget);
      });

      testWidgets('shows error state with retry button', (tester) async {
        bool retryPressed = false;

        await tester.pumpWidget(
          MaterialApp(
            home: ModelBootSplash(
              status: 'Error: download failed',
              error: 'download failed',
              progress: null,
              isLoading: false,
              phase: ModelBootPhase.failed,
              onRetry: () {
                retryPressed = true;
              },
            ),
          ),
        );

        expect(find.text('Model setup failed'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);

        await tester.tap(find.text('Retry'));
        await tester.pump();

        expect(retryPressed, true);
      });
    });
  });
}
