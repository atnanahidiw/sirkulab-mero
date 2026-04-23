# Add any project specific ProGuard rules here.
# See https://developer.android.com/studio/build/shrink-code

# MediaPipe classes used by flutter_gemma
-dontwarn com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile
-dontwarn com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate
-keep class com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile { *; }
-keep class com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate { *; }

# Keep Flutter/Gemma related classes
-keep class dev.flutterberlin.flutter_gemma.** { *; }
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }