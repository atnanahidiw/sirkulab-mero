import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

class ImageUtils {
  /// Compress image to reduce memory usage and improve inference speed
  static Future<Uint8List> compressImage(
    Uint8List imageBytes, {
    int maxWidth = 1024,
    int maxHeight = 1024,
    int quality = 85,
  }) async {
    try {
      // Decode image
      final image = img.decodeImage(imageBytes);
      if (image == null) return imageBytes;
      
      // Calculate new dimensions while maintaining aspect ratio
      final originalWidth = image.width;
      final originalHeight = image.height;
      
      if (originalWidth <= maxWidth && originalHeight <= maxHeight) {
        // No compression needed
        return imageBytes;
      }
      
      double widthRatio = originalWidth / maxWidth;
      double heightRatio = originalHeight / maxHeight;
      double ratio = widthRatio > heightRatio ? widthRatio : heightRatio;
      
      int newWidth = (originalWidth / ratio).round();
      int newHeight = (originalHeight / ratio).round();
      
      // Resize image
      final resized = img.copyResize(
        image,
        width: newWidth,
        height: newHeight,
      );
      
      // Encode as JPEG with quality
      return img.encodeJpg(resized, quality: quality);
    } catch (e) {
      print('Image compression failed: $e');
      return imageBytes;
    }
  }
  
  /// Convert image to format suitable for model input
  static Future<Uint8List> prepareImageForModel(
    Uint8List imageBytes, {
    String format = 'jpeg',
  }) async {
    // For now, just compress the image
    // In production, you might need to convert to specific format
    // or apply preprocessing required by the model
    return compressImage(imageBytes);
  }
  
  /// Get image dimensions
  static Future<ui.Size> getImageDimensions(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      return ui.Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
    } catch (e) {
      return const ui.Size(0, 0);
    }
  }
  
  /// Create thumbnail for preview
  static Future<Uint8List> createThumbnail(
    Uint8List imageBytes, {
    int size = 200,
  }) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return imageBytes;
      
      // Create square thumbnail (cover effect)
      int minDim = image.width < image.height ? image.width : image.height;
      int xOffset = (image.width - minDim) ~/ 2;
      int yOffset = (image.height - minDim) ~/ 2;
      
      final cropped = img.copyCrop(
        image,
        x: xOffset,
        y: yOffset,
        width: minDim,
        height: minDim,
      );
      
      final thumbnail = img.copyResize(
        cropped,
        width: size,
        height: size,
      );
      
      return img.encodeJpg(thumbnail, quality: 80);
    } catch (e) {
      return imageBytes;
    }
  }
  
  /// Check if image format is supported
  static bool isSupportedFormat(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ext == 'jpg' || ext == 'jpeg' || ext == 'png' || ext == 'bmp' || ext == 'gif';
  }
  
  /// Get MIME type from file extension
  static String getMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'bmp':
        return 'image/bmp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }
  
  /// Get file extension from MIME type
  static String getExtensionFromMimeType(String mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/bmp':
        return 'bmp';
      case 'image/gif':
        return 'gif';
      default:
        return 'jpg';
    }
  }
}