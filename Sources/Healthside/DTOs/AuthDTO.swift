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
