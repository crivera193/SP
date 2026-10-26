/// Supabase and Mapbox configuration for UTRGV-GO.
abstract final class AppConfiguration {
  // Supabase configuration
  static const supabaseUrl = 'https://bsvcnndqvjizxgnxhxkd.supabase.co';

  static const supabaseKey = 'sb_publishable_0TeJ8pFvThAfWNm9gCPTwQ_vqEfSDRs';

  static bool get hasBackend =>
      supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;

  static const mapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue: '',
  );
}
