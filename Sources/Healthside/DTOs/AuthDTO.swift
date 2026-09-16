import Vapor

/// Body of `POST /auth/register` and `POST /auth/login`.
struct AuthRequest: Content {
    let email: String
    let password: String
}

extension AuthRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
        validations.add("password", as: String.self, is: .count(8...128))
    }
}

/// Safe representation of a user — never exposes the password hash.
struct UserResponse: Content {
    let id: UUID
    let email: String
    let emailVerified: Bool
    let createdAt: Date?
}

/// Body of `POST /auth/refresh` and `POST /auth/logout`.
struct RefreshRequest: Content {
    let refreshToken: String
}

/// Body of `POST /auth/change-password`.
struct ChangePasswordRequest: Content {
    let currentPassword: String
    let newPassword: String
}

extension ChangePasswordRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("newPassword", as: String.self, is: .count(8...128))
    }
}

/// Returned on successful login and refresh.
struct TokenResponse: Content {
    let accessToken: String
    let refreshToken: String
}

/// Body of `POST /auth/verify-email`.
struct VerifyEmailRequest: Content {
    let email: String
    let code: String
}

extension VerifyEmailRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
        validations.add("code", as: String.self, is: .count(6...6) && .characterSet(.decimalDigits))
    }
}

/// Body of `POST /auth/resend-verification`.
struct ResendVerificationRequest: Content {
    let email: String
}

extension ResendVerificationRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
    }
}

/// Body of `POST /auth/forgot-password`.
struct ForgotPasswordRequest: Content {
    let email: String
}

extension ForgotPasswordRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
    }
}

/// Body of `POST /auth/reset-password`.
struct ResetPasswordRequest: Content {
    let email: String
    let code: String
    let newPassword: String
}

extension ResetPasswordRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
        validations.add("code", as: String.self, is: .count(6...6) && .characterSet(.decimalDigits))
        validations.add("newPassword", as: String.self, is: .count(8...128))
    }
}
