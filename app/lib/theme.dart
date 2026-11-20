import 'package:material_ui/material_ui.dart';

/// Paleta y tema de OpenBambu.
class AppColors {
  static const accent = Color(0xFF2EC27E);
  static const warning = Color(0xFFF5A524);
  static const danger = Color(0xFFF0564A);
  static const info = Color(0xFF4EA8FF);
  static const nozzle = Color(0xFFFF7A45);
  static const bed = Color(0xFFFFB547);
  static const fan = Color(0xFF5CC8FF);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: brightness,
    primary: AppColors.accent,
    surface: dark ? const Color(0xFF0E1013) : const Color(0xFFF6F7F9),
    surfaceContainerLowest: dark ? const Color(0xFF0A0B0D) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF15181C) : Colors.white,
    surfaceContainer: dark ? const Color(0xFF1A1E23) : const Color(0xFFEFF1F4),
    surfaceContainerHigh: dark ? const Color(0xFF22272D) : const Color(0xFFE6E9ED),
    surfaceContainerHighest: dark ? const Color(0xFF2B3138) : const Color(0xFFDCE0E5),
    error: AppColors.danger,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.25 : 0.5)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Color stateColor(String state) => switch (state) {
  'RUNNING' => AppColors.accent,
  'PREPARE' || 'SLICING' || 'INIT' => AppColors.info,
  'PAUSE' => AppColors.warning,
  'FAILED' => AppColors.danger,
  'FINISH' => AppColors.accent,
  'OFFLINE' => Colors.grey,
  _ => Colors.blueGrey,
};

Color? parseHex(String? hex) {
  if (hex == null || hex.length < 7) return null;
  final v = int.tryParse(hex.substring(1, 7), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}
