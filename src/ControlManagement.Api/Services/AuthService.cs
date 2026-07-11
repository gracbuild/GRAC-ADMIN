using System.Data;
using ControlManagement.Api.Models;
using ControlManagement.Api.Security;
using ControlManagement.Security;
using Microsoft.Data.SqlClient;

namespace ControlManagement.Api.Services;

public interface IAuthService
{
    Task<LoginResponse> LoginAsync(LoginRequest request, CancellationToken cancellationToken);
    Task<ChangePasswordResponse> ChangePasswordAsync(ChangePasswordRequest request, CancellationToken cancellationToken);
    Task<AdminResetPasswordResponse> AdminResetPasswordAsync(AdminResetPasswordRequest request, string actingLoginId, CancellationToken cancellationToken);
}

/// <summary>
/// All authentication and password-change logic.  Lives entirely in the API
/// project so the Web tier never opens a SqlConnection.  Uses the same
/// PasswordHasher (PBKDF2-SHA256, 210k iterations) that hashes the default
/// password on Add User, so the format is guaranteed consistent.
/// </summary>
public sealed class AuthService(IConfiguration configuration, PasswordHasher passwordHasher,
    SignedAccessTokenService tokenService, ILogger<AuthService> logger) : IAuthService
{
    public async Task<LoginResponse> LoginAsync(LoginRequest request, CancellationToken cancellationToken)
    {
        var identifier = (request.LoginId ?? "").Trim();
        var password = request.Password ?? "";
        if (string.IsNullOrWhiteSpace(identifier) || string.IsNullOrEmpty(password))
            return new() { Success = false, Message = "Login ID / Email and Password are required." };

        try
        {
            var connectionString = GetConnectionString();
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                logger.LogError("Login attempted but no Repository connection string is configured on the API.");
                return new() { Success = false, Message = "Authentication service is not configured." };
            }

            await using var connection = new SqlConnection(ConfigureConnectionString(connectionString));
            await connection.OpenAsync(cancellationToken);

            // Pull the row without filtering by status so we can give a better log line.
            await using var command = connection.CreateCommand();
            command.CommandText = """
            SELECT TOP (1)
                   user_id, user_name, login_id, email, password_hash, status,
                   is_password_change_required
            FROM GRAC_New.cm_user
            WHERE LOWER(login_id) = LOWER(@i) OR LOWER(email) = LOWER(@i);
            """;
            command.Parameters.Add(new SqlParameter("@i", SqlDbType.NVarChar, 250) { Value = identifier });

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
            {
                logger.LogWarning("Login rejected: no cm_user row for identifier '{Identifier}'.", Mask(identifier));
                return new() { Success = false, Message = "Invalid Login ID / Email or Password." };
            }

            var userId = Convert.ToInt64(reader["user_id"]);
            var userName = Convert.ToString(reader["user_name"]) ?? identifier;
            var resolvedLoginId = Convert.ToString(reader["login_id"]) ?? identifier;
            var email = Convert.ToString(reader["email"]) ?? "";
            var status = Convert.ToString(reader["status"]) ?? "";
            var passwordHash = Convert.ToString(reader["password_hash"]);
            var isPasswordChangeRequired = reader["is_password_change_required"] != DBNull.Value
                && Convert.ToBoolean(reader["is_password_change_required"]);
            await reader.CloseAsync();

            if (!string.Equals(status, "Active", StringComparison.OrdinalIgnoreCase))
            {
                logger.LogWarning("Login rejected: user {LoginId} status is '{Status}'.", resolvedLoginId, status);
                return new() { Success = false, Message = "This account is not active. Contact your administrator." };
            }
            if (string.IsNullOrWhiteSpace(passwordHash) || !passwordHasher.Verify(password, passwordHash))
            {
                logger.LogWarning("Login rejected: password mismatch for user {LoginId}.", resolvedLoginId);
                return new() { Success = false, Message = "Invalid Login ID / Email or Password." };
            }

            var roles = await LoadRolesAsync(connection, userId, cancellationToken);
            var permissions = await LoadPermissionsAsync(connection, userId, cancellationToken);
            var tokenClaims = roles.Concat(permissions).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            var token = tokenService.Issue(resolvedLoginId, tokenClaims);

            logger.LogInformation("Login succeeded for {LoginId}. roles={Roles} permissions={Perms} changeRequired={ChangeRequired}",
                resolvedLoginId, roles.Count, permissions.Count, isPasswordChangeRequired);

            return new()
            {
                Success = true,
                Message = "Sign-in successful.",
                UserId = userId,
                UserName = userName,
                LoginId = resolvedLoginId,
                Email = email,
                Roles = roles,
                Permissions = permissions,
                Token = token,
                IsPasswordChangeRequired = isPasswordChangeRequired
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Login crashed for identifier '{Identifier}'.", Mask(identifier));
            return new() { Success = false, Message = "Authentication service is temporarily unavailable." };
        }
    }

    public async Task<ChangePasswordResponse> ChangePasswordAsync(ChangePasswordRequest request, CancellationToken cancellationToken)
    {
        var loginId = (request.LoginId ?? "").Trim();
        var current = request.CurrentPassword ?? "";
        var next = request.NewPassword ?? "";
        if (string.IsNullOrWhiteSpace(loginId)) return new() { Success = false, Message = "Session expired. Please sign in again." };
        if (string.IsNullOrEmpty(current)) return new() { Success = false, Message = "Current password is required." };
        if (next.Length < 8) return new() { Success = false, Message = "New password must be at least 8 characters long." };
        if (string.Equals(current, next, StringComparison.Ordinal))
            return new() { Success = false, Message = "New password must be different from the current password." };

        try
        {
            var connectionString = GetConnectionString();
            if (string.IsNullOrWhiteSpace(connectionString))
                return new() { Success = false, Message = "Password change service is not configured." };

            await using var connection = new SqlConnection(ConfigureConnectionString(connectionString));
            await connection.OpenAsync(cancellationToken);

            string? currentHash;
            await using (var verifyCommand = connection.CreateCommand())
            {
                verifyCommand.CommandText = "SELECT TOP 1 password_hash FROM GRAC_New.cm_user WHERE LOWER(login_id) = LOWER(@i) AND status = 'Active';";
                verifyCommand.Parameters.Add(new SqlParameter("@i", SqlDbType.NVarChar, 250) { Value = loginId });
                currentHash = (string?)await verifyCommand.ExecuteScalarAsync(cancellationToken);
            }
            if (string.IsNullOrWhiteSpace(currentHash) || !passwordHasher.Verify(current, currentHash))
                return new() { Success = false, Message = "Current password is incorrect." };

            var newHash = passwordHasher.Hash(next);
            await using (var updateCommand = connection.CreateCommand())
            {
                updateCommand.CommandText = "dbo.cm_change_password";
                updateCommand.CommandType = CommandType.StoredProcedure;
                updateCommand.Parameters.Add(new SqlParameter("@p_login_id", SqlDbType.NVarChar, 160) { Value = loginId });
                updateCommand.Parameters.Add(new SqlParameter("@p_new_password_hash", SqlDbType.NVarChar, 500) { Value = newHash });
                updateCommand.Parameters.Add(new SqlParameter("@p_usr_id", SqlDbType.NVarChar, 100) { Value = loginId });
                await updateCommand.ExecuteNonQueryAsync(cancellationToken);
            }
            logger.LogInformation("Password changed for {LoginId}.", loginId);
            return new() { Success = true, Message = "Password updated successfully." };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ChangePassword crashed for {LoginId}.", Mask(loginId));
            return new() { Success = false, Message = "Password change failed. Please try again." };
        }
    }

    public async Task<AdminResetPasswordResponse> AdminResetPasswordAsync(AdminResetPasswordRequest request, string actingLoginId, CancellationToken cancellationToken)
    {
        if (request.UserId <= 0) return new() { Success = false, Message = "A valid user identifier is required." };
        try
        {
            var connectionString = GetConnectionString();
            if (string.IsNullOrWhiteSpace(connectionString))
                return new() { Success = false, Message = "Password reset service is not configured." };

            await using var connection = new SqlConnection(ConfigureConnectionString(connectionString));
            await connection.OpenAsync(cancellationToken);

            var defaultPassword = configuration["Security:DefaultUserPassword"] ?? "";
            if (string.IsNullOrEmpty(defaultPassword)) defaultPassword = "Welcome@123";
            var newHash = passwordHasher.Hash(defaultPassword);

            await using var command = connection.CreateCommand();
            command.CommandText = "dbo.cm_admin_reset_user_password";
            command.CommandType = CommandType.StoredProcedure;
            command.Parameters.Add(new SqlParameter("@p_user_id", SqlDbType.BigInt) { Value = request.UserId });
            command.Parameters.Add(new SqlParameter("@p_new_password_hash", SqlDbType.NVarChar, 500) { Value = newHash });
            command.Parameters.Add(new SqlParameter("@p_usr_id", SqlDbType.NVarChar, 100) { Value = actingLoginId ?? "admin" });
            await command.ExecuteNonQueryAsync(cancellationToken);

            logger.LogInformation("Admin password reset for userId={UserId} by {Acting}. is_password_change_required=1 set.",
                request.UserId, actingLoginId);
            return new()
            {
                Success = true,
                Message = "Password reset to default. The user must change it on next sign-in.",
                UserId = request.UserId
            };
        }
        catch (SqlException ex) when (ex.Number is 50050 or 50051 or 50052)
        {
            return new() { Success = false, Message = ex.Message };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AdminResetPassword crashed for userId={UserId}.", request.UserId);
            return new() { Success = false, Message = "Password reset failed. Please try again." };
        }
    }

    private static async Task<List<string>> LoadRolesAsync(SqlConnection connection, long userId, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT DISTINCT r.role_name
            FROM GRAC_New.cm_user_role ur
            JOIN GRAC_New.cm_role r ON r.role_id = ur.role_id
            WHERE ur.user_id = @user_id AND ur.status = 'Active' AND r.status = 'Active';
            """;
        command.Parameters.Add(new SqlParameter("@user_id", SqlDbType.BigInt) { Value = userId });
        var roles = new List<string>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            roles.Add(Convert.ToString(reader["role_name"]) ?? "");
        return roles.Where(role => !string.IsNullOrWhiteSpace(role)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static async Task<List<string>> LoadPermissionsAsync(SqlConnection connection, long userId, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT DISTINCT m.menu_code, rp.can_view, rp.can_add, rp.can_edit, rp.can_inactive, rp.can_approve
            FROM GRAC_New.cm_user_role ur
            JOIN GRAC_New.cm_role r ON r.role_id = ur.role_id
            JOIN GRAC_New.cm_role_permission rp ON rp.role_id = r.role_id
            JOIN GRAC_New.cm_menu m ON m.menu_id = rp.menu_id
            WHERE ur.user_id = @user_id
              AND ur.status = 'Active' AND r.status = 'Active'
              AND rp.status = 'Active' AND m.status = 'Active';
            """;
        command.Parameters.Add(new SqlParameter("@user_id", SqlDbType.BigInt) { Value = userId });
        var permissions = new List<string>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var key = Convert.ToString(reader["menu_code"]) ?? "";
            if (string.IsNullOrWhiteSpace(key)) continue;
            if (Convert.ToBoolean(reader["can_view"]))     permissions.Add($"{key}:VIEW");
            if (Convert.ToBoolean(reader["can_add"]))      permissions.Add($"{key}:ADD");
            if (Convert.ToBoolean(reader["can_edit"]))     permissions.Add($"{key}:EDIT");
            if (Convert.ToBoolean(reader["can_inactive"])) permissions.Add($"{key}:DELETE");
            if (Convert.ToBoolean(reader["can_approve"]))
            {
                permissions.Add($"{key}:APPROVE");
                permissions.Add($"{key}:REJECT");
            }
        }
        return permissions.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private string? GetConnectionString()
    {
        var connectionString = configuration.GetConnectionString("ControlManagement");
        if (!string.IsNullOrWhiteSpace(connectionString)) return connectionString;
        var gracConnection = configuration.GetConnectionString("DbConnection");
        var encryptedPassword = configuration.GetConnectionString("Password");
        if (string.IsNullOrWhiteSpace(gracConnection) || string.IsNullOrWhiteSpace(encryptedPassword)) return null;
        var passwordParts = encryptedPassword.Split('~', 2);
        if (passwordParts.Length != 2)
            throw new InvalidOperationException("ConnectionStrings:Password must contain the GRAC encryption key and encrypted password.");
        return gracConnection + DecryptPassword(passwordParts[1], passwordParts[0]);
    }

    private string ConfigureConnectionString(string connectionString) =>
        new SqlConnectionStringBuilder(connectionString)
        {
            Encrypt = configuration.GetValue("Database:Encrypt", true),
            TrustServerCertificate = configuration.GetValue("Database:TrustServerCertificate", false)
        }.ConnectionString;

    private static string DecryptPassword(string encryptedPassword, string key)
    {
        using var aes = System.Security.Cryptography.Aes.Create();
        aes.Key = System.Text.Encoding.UTF8.GetBytes(key.Substring(4, 32));
        aes.IV = System.Text.Encoding.UTF8.GetBytes(key.ToLowerInvariant().Substring(4, 16));
        aes.Mode = System.Security.Cryptography.CipherMode.CBC;
        aes.Padding = System.Security.Cryptography.PaddingMode.PKCS7;
        using var decryptor = aes.CreateDecryptor(aes.Key, aes.IV);
        using var memoryStream = new MemoryStream(Convert.FromBase64String(encryptedPassword));
        using var cryptoStream = new System.Security.Cryptography.CryptoStream(memoryStream, decryptor, System.Security.Cryptography.CryptoStreamMode.Read);
        using var streamReader = new StreamReader(cryptoStream);
        return streamReader.ReadToEnd();
    }

    private static string Mask(string value)
    {
        if (string.IsNullOrEmpty(value)) return "<empty>";
        var atIndex = value.IndexOf('@');
        if (atIndex > 2) return value[..2] + "***" + value[atIndex..];
        return value.Length <= 2 ? value : value[..2] + "***";
    }
}
