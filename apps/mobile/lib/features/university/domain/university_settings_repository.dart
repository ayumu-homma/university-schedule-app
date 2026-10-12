import 'university_settings_models.dart';

abstract interface class UniversitySettingsRepository {
  Future<List<UniversityRequestRecord>> loadRequests();

  Future<String> submitRequest(UniversityRequestInput input);

  Future<void> changeUniversity(String universityId);
}
