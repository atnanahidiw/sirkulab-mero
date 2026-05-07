import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const _seedColor = Color(0xFF2D6A4F);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );

    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final textTheme = _buildTextTheme(base.textTheme, colorScheme);

    return base.copyWith(
      colorScheme: colorScheme,
      textTheme: textTheme,
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 52),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 48),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surfaceContainer,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.dmSans(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
        iconTheme: IconThemeData(color: colorScheme.onSurface),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        selectedColor: colorScheme.secondaryContainer,
        labelStyle: GoogleFonts.dmSans(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static TextTheme _buildTextTheme(TextTheme base, ColorScheme colorScheme) {
    final dmSans = GoogleFonts.dmSansTextTheme(base);
    final serifDisplay = GoogleFonts.dmSerifDisplay();

    return dmSans.copyWith(
      displayLarge: serifDisplay.copyWith(
        fontSize: dmSans.displayLarge?.fontSize,
        color: colorScheme.onSurface,
      ),
      displayMedium: serifDisplay.copyWith(
        fontSize: dmSans.displayMedium?.fontSize,
        color: colorScheme.onSurface,
      ),
      displaySmall: serifDisplay.copyWith(
        fontSize: dmSans.displaySmall?.fontSize,
        color: colorScheme.onSurface,
        letterSpacing: -0.5,
      ),
      headlineLarge: serifDisplay.copyWith(
        fontSize: dmSans.headlineLarge?.fontSize,
        color: colorScheme.onSurface,
      ),
      headlineMedium: serifDisplay.copyWith(
        fontSize: dmSans.headlineMedium?.fontSize,
        color: colorScheme.onSurface,
      ),
      headlineSmall: serifDisplay.copyWith(
        fontSize: dmSans.headlineSmall?.fontSize,
        color: colorScheme.onSurface,
      ),
    );
  }
}
