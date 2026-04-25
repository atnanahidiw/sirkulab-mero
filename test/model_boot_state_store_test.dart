import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picture_that/services/model_boot_state.dart';

void main() {
  test('ModelBootStateStore persists and restores boot state', () async {
    final tempDir = await Directory.systemTemp.createTemp('picture_that_state');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final store = ModelBootStateStore(File('${tempDir.path}/state.json'));
    final state = ModelBootState(
      isInitialized: true,
      isLoading: false,
      isModelLoaded: false,
      status: 'Downloading: 61%',
      error: 'network hiccup',
      downloadProgress: 0.61,
      phase: ModelBootPhase.downloading,
      downloadTaskId: 'picture_that_gemma_model',
      downloadFilePath: '/tmp/gemma-4-E2B-it.litertlm',
      updatedAt: DateTime.parse('2026-04-24T06:00:00.000Z'),
    );

    await store.write(state);
    final restored = await store.read();

    expect(restored, isNotNull);
    expect(restored!.isInitialized, true);
    expect(restored.isLoading, false);
    expect(restored.isModelLoaded, false);
    expect(restored.status, 'Downloading: 61%');
    expect(restored.error, 'network hiccup');
    expect(restored.downloadProgress, 0.61);
    expect(restored.phase, ModelBootPhase.downloading);
    expect(restored.downloadTaskId, 'picture_that_gemma_model');
    expect(restored.downloadFilePath, '/tmp/gemma-4-E2B-it.litertlm');
    expect(restored.updatedAt, DateTime.parse('2026-04-24T06:00:00.000Z'));
  });

  test('ModelBootStateStore persists and restores needsDownload phase', () async {
    final tempDir = await Directory.systemTemp.createTemp('picture_that_state');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final store = ModelBootStateStore(File('${tempDir.path}/state.json'));
    final state = ModelBootState(
      isInitialized: true,
      isLoading: false,
      isModelLoaded: false,
      status: 'Model download required',
      error: null,
      downloadProgress: null,
      phase: ModelBootPhase.needsDownload,
      downloadTaskId: null,
      downloadFilePath: null,
      updatedAt: DateTime.parse('2026-04-24T06:00:00.000Z'),
    );

    await store.write(state);
    final restored = await store.read();

    expect(restored, isNotNull);
    expect(restored!.isInitialized, true);
    expect(restored.isLoading, false);
    expect(restored.isModelLoaded, false);
    expect(restored.status, 'Model download required');
    expect(restored.error, isNull);
    expect(restored.downloadProgress, isNull);
    expect(restored.phase, ModelBootPhase.needsDownload);
    expect(restored.downloadTaskId, isNull);
    expect(restored.downloadFilePath, isNull);
  });
}
