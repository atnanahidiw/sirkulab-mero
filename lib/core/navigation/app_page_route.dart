import 'package:flutter/material.dart';

class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute._fadeScale({required super.pageBuilder})
      : super(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (context, animation, secondary, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
                child: child,
              ),
            );
          },
        );

  AppPageRoute._slideUp({required super.pageBuilder})
      : super(
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 280),
          transitionsBuilder: (context, animation, secondary, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.fastOutSlowIn,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.08),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );

  AppPageRoute._slideRight({required super.pageBuilder})
      : super(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (context, animation, secondary, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1.0, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        );

  /// Zoom-fade: Home → Analyzing
  static AppPageRoute<T> fadeScale<T>(
    Widget Function(BuildContext) builder,
  ) =>
      AppPageRoute._fadeScale(
        pageBuilder: (context, _, __) => builder(context),
      );

  /// Slide-up with fade: Analyzing → Result
  static AppPageRoute<T> slideUp<T>(
    Widget Function(BuildContext) builder,
  ) =>
      AppPageRoute._slideUp(
        pageBuilder: (context, _, __) => builder(context),
      );

  /// Slide from right: standard push (→ Settings)
  static AppPageRoute<T> slideRight<T>(
    Widget Function(BuildContext) builder,
  ) =>
      AppPageRoute._slideRight(
        pageBuilder: (context, _, __) => builder(context),
      );
}
