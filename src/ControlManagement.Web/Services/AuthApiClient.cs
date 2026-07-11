using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace ControlManagement.Web.Services;

/// <summary>
/// Talks to the API auth endpoints over HTTPS.  The Web tier no longer opens
/// a SqlConnection; every password check goes through here.
///
/// Mirrors the API shape from ControlManagement.Api.Models.AuthModels.
/// </summary>
public sealed class AuthApiClient(HttpClient httpClient, IConfiguration configuration, ILogger<AuthApiClient> logger)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public sealed class LoginResult
    {
        public bool Success { get; set; }
        public string Message { get; set; } = "";
        public long UserId { get; set; }
        public string UserName { get; set; } = "";
        public string LoginId { get; set; } = "";
        public string Email { get; set; } = "";
        public IReadOnlyList<string> Roles { get; set; } = [];
        public IReadOnlyList<string> Permissions { get; set; } = [];
        public string Token { get; set; } = "";
        public bool IsPasswordChangeRequired { get; set; }
    }

    public sealed class ChangePasswordResult
    {
        public bool Success { get; set; }
        public string Message { get; set; } = "";
    }

    public sealed class AdminResetPasswordResult
    {
        public bool Success { get; set; }
        public string Message { get; set; } = "";
        public long UserId { get; set; }
    }

    public async Task<LoginResult> LoginAsync(string loginId, string password, CancellationToken cancellationToken)
    {
        try
        {
            using var content = JsonContent.Create(new { loginId, password });
            using var response = await httpClient.PostAsync(BuildUrl("auth/login"), content, cancellationToken);
            // Login always returns a LoginResponse-shaped JSON, even on 401, so try to read it.
            var body = await response.Content.ReadFromJsonAsync<LoginResult>(JsonOptions, cancellationToken);
            if (body is null)
                return new() { Success = false, Message = $"Authentication service returned an empty response (HTTP {(int)response.StatusCode})." };
            if (response.StatusCode is HttpStatusCode.OK or HttpStatusCode.Unauthorized or HttpStatusCode.BadRequest)
                return body;
            return new() { Success = false, Message = $"Authentication service returned HTTP {(int)response.StatusCode}." };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Auth API login call failed.");
            return new() { Success = false, Message = "Authentication service is currently unreachable." };
        }
    }

    public async Task<ChangePasswordResult> ChangePasswordAsync(string token, string currentPassword, string newPassword, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, BuildUrl("auth/change-password"))
            {
                Content = JsonContent.Create(new { currentPassword, newPassword })
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await httpClient.SendAsync(request, cancellationToken);
            var body = await response.Content.ReadFromJsonAsync<ChangePasswordResult>(JsonOptions, cancellationToken);
            if (body is null)
                return new() { Success = false, Message = $"Authentication service returned an empty response (HTTP {(int)response.StatusCode})." };
            return body;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Auth API change-password call failed.");
            return new() { Success = false, Message = "Authentication service is currently unreachable." };
        }
    }

    public async Task<AdminResetPasswordResult> AdminResetPasswordAsync(string token, long userId, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, BuildUrl("auth/admin-reset-password"))
            {
                Content = JsonContent.Create(new { userId })
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await httpClient.SendAsync(request, cancellationToken);
            var body = await response.Content.ReadFromJsonAsync<AdminResetPasswordResult>(JsonOptions, cancellationToken);
            if (body is null)
                return new() { Success = false, Message = $"Authentication service returned an empty response (HTTP {(int)response.StatusCode})." };
            return body;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Auth API admin-reset-password call failed.");
            return new() { Success = false, Message = "Authentication service is currently unreachable." };
        }
    }

    private string BuildUrl(string relativePath)
    {
        var baseUrl = (configuration["ApiBaseUrl"] ?? "https://localhost:7192/api/control-management").TrimEnd('/');
        return $"{baseUrl}/{relativePath.TrimStart('/')}";
    }
}
