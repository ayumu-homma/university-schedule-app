sealed class AppError implements Exception {
  const AppError(this.message);

  final String message;

  @override
  String toString() => message;
}

class NetworkError extends AppError {
  const NetworkError(super.message);
}

class AuthError extends AppError {
  const AuthError(super.message);
}

class PermissionError extends AppError {
  const PermissionError(super.message);
}

class ValidationError extends AppError {
  const ValidationError(super.message);
}

class ConflictError extends AppError {
  const ConflictError(super.message);
}

class UnknownAppError extends AppError {
  const UnknownAppError(super.message);
}
