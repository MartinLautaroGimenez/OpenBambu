import 'package:material_ui/material_ui.dart';

/// Paleta y tema de OpenBambu (Material 3, estilo de las apps de Google).
class AppColors {
  static const accent = Color(0xFF34C77B);
  static const warning = Color(0xFFF5B23D);
  static const danger = Color(0xFFF2675C);
  static const info = Color(0xFF6CB4FF);
  static const nozzle = Color(0xFFFF8A5C);
  static const bed = Color(0xFFFFC067);
  static const fan = Color(0xFF6FD3FF);
}

const appFont = 'Figtree';

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final seed = ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: brightness);
  final scheme = seed.copyWith(
    primary: dark ? AppColors.accent : const Color(0xFF14864F),
    onPrimary: dark ? const Color(0xFF00210F) : Colors.white,
    primaryContainer: dark ? const Color(0xFF173A28) : const Color(0xFFCDEFD9),
    onPrimaryContainer: dark ? const Color(0xFFB4F1CB) : const Color(0xFF00210F),
    secondaryContainer: dark ? const Color(0xFF233329) : const Color(0xFFDCEBE0),
    onSecondaryContainer: dark ? const Color(0xFFCFE9D7) : const Color(0xFF132119),
    surface: dark ? const Color(0xFF101214) : const Color(0xFFF7F8F7),
    onSurface: dark ? const Color(0xFFE3E5E4) : const Color(0xFF191C1B),
    onSurfaceVariant: dark ? const Color(0xFFA6ADAA) : const Color(0xFF5B635F),
    surfaceContainerLowest: dark ? const Color(0xFF0B0C0E) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF16191B) : const Color(0xFFF1F3F2),
    surfaceContainer: dark ? const Color(0xFF1B1F21) : const Color(0xFFEBEEEC),
    surfaceContainerHigh: dark ? const Color(0xFF242A2C) : const Color(0xFFE3E7E5),
    surfaceContainerHighest: dark ? const Color(0xFF2E3437) : const Color(0xFFDADFDC),
    outline: dark ? const Color(0xFF6F7774) : const Color(0xFF8A928E),
    outlineVariant: dark ? const Color(0xFF353C3A) : const Color(0xFFC9D0CC),
    error: AppColors.danger,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness, fontFamily: appFont);
  final text = base.textTheme.copyWith(
    displaySmall: base.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
    headlineLarge: base.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
    titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    labelMedium: base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.4),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.4),
  );
  const pill = StadiumBorder();
  final radius16 = BorderRadius.circular(16);
  const buttonText = TextStyle(fontFamily: appFont, fontWeight: FontWeight.w600, fontSize: 15, letterSpacing: 0.1);

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontSize: 22, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      height: 72,
      elevation: 0,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelMedium?.copyWith(
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      unselectedLabelStyle: text.titleSmall,
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: scheme.primary, width: 3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 52), shape: pill, textStyle: buttonText),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: pill,
        textStyle: buttonText,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: pill, textStyle: buttonText),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(minimumSize: const Size(0, 52), shape: pill, textStyle: buttonText),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(shape: const CircleBorder())),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 1,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      extendedTextStyle: buttonText,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        textStyle: text.labelLarge,
        selectedBackgroundColor: scheme.secondaryContainer,
        selectedForegroundColor: scheme.onSecondaryContainer,
        foregroundColor: scheme.onSurfaceVariant,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: text.labelLarge?.copyWith(color: scheme.onSurface),
      selectedColor: scheme.secondaryContainer,
      backgroundColor: Colors.transparent,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(borderRadius: radius16, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: radius16, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius16,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500, color: scheme.onSurface),
      subtitleTextStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      iconColor: scheme.onSurfaceVariant,
    ),
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? const Icon(Icons.check_rounded, size: 16) : null,
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 6,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      showValueIndicator: ShowValueIndicator.onDrag,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(99),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: text.headlineSmall?.copyWith(color: scheme.onSurface),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFFE3E5E4) : const Color(0xFF2E3130),
      contentTextStyle: text.bodyMedium?.copyWith(color: dark ? const Color(0xFF191C1B) : Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    expansionTileTheme: const ExpansionTileThemeData(shape: Border(), collapsedShape: Border()),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(8)),
    ),
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
