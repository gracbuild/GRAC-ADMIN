using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using ControlManagement.Security;

namespace ControlManagement.Web.Services;

public sealed class SecureRepositoryClient(HttpClient httpClient, IConfiguration configuration, EnvelopeCrypto crypto)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public async Task<string> QueryAsync(string token, SecureRepositoryRequest request, CancellationToken cancellationToken) =>
        await SendAsync("secure/query", token, request, cancellationToken);

    public async Task<string> ManageAsync(string token, SecureRepositoryRequest request, CancellationToken cancellationToken) =>
        await SendAsync("secure/manage", token, request, cancellationToken);

    public async Task<string> SecurityDiagnosticsAsync(string token, CancellationToken cancellationToken)
    {
        var url = $"{ApiBaseUrl()}/diagnostics/security";
        using var message = new HttpRequestMessage(HttpMethod.Get, url);
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await SendRequestAsync(message, url, cancellationToken);
        var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new RepositoryApiException($"Security diagnostic API returned {(int)response.StatusCode}: {responseText}");
        return responseText;
    }

    private async Task<string> SendAsync(string path, string token, SecureRepositoryRequest request, CancellationToken cancellationToken)
    {
        request.TimestampUtc = DateTimeOffset.UtcNow;
        request.Nonce = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24));
        var envelope = crypto.EncryptRequest(JsonSerializer.Serialize(request), token);
        var url = $"{ApiBaseUrl()}/{path}";
        using var message = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = JsonContent.Create(envelope)
        };
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await SendRequestAsync(message, url, cancellationToken);
        if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            var failure = await ReadFailureAsync(response, cancellationToken);
            throw new RepositoryApiException(FormatFailure(failure,
                "The repository API rejected the authorization token. Confirm that the WebApp and API use the same Security:TokenSigningKey and that IIS forwards the Authorization header."));
        }

        var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
        EncryptedResponse? body;
        try
        {
            body = JsonSerializer.Deserialize<EncryptedResponse>(responseText, JsonOptions);
        }
        catch (JsonException)
        {
            throw new RepositoryApiException($"The repository API returned an invalid response from {url}. HTTP {(int)response.StatusCode}. {SummarizeResponse(responseText)}");
        }
        if (body is null || string.IsNullOrWhiteSpace(body.ResponseStr))
        {
            var failure = JsonSerializer.Deserialize<ApiFailure>(responseText, JsonOptions);
            throw new RepositoryApiException(FormatFailure(failure, "The repository API could not complete the request."));
        }
        return crypto.DecryptResponse(body, token);
    }

    private async Task<HttpResponseMessage> SendRequestAsync(HttpRequestMessage message, string url, CancellationToken cancellationToken)
    {
        try
        {
            return await httpClient.SendAsync(message, cancellationToken);
        }
        catch (TaskCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new RepositoryApiException($"Timed out while calling repository API: {url}. {ex.Message}");
        }
        catch (HttpRequestException ex)
        {
            throw new RepositoryApiException($"Unable to reach repository API: {url}. {ex.Message}");
        }
    }

    private string ApiBaseUrl() =>
        (configuration["ApiBaseUrl"] ?? "https://localhost:7192/api/control-management").TrimEnd('/');

    private static async Task<ApiFailure?> ReadFailureAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        try
        {
            var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
            return string.IsNullOrWhiteSpace(responseText) ? null : JsonSerializer.Deserialize<ApiFailure>(responseText, JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    private static string FormatFailure(ApiFailure? failure, string fallback)
    {
        var message = string.IsNullOrWhiteSpace(failure?.Message) ? fallback : failure.Message;
        return string.IsNullOrWhiteSpace(failure?.CorrelationId) ? message : $"{message} Reference: {failure.CorrelationId}";
    }

    private static string SummarizeResponse(string responseText)
    {
        if (string.IsNullOrWhiteSpace(responseText)) return "Response body was empty.";
        var compact = responseText.Replace("\r", " ").Replace("\n", " ").Trim();
        return compact.Length <= 300 ? compact : compact[..300] + "...";
    }

    private sealed class ApiFailure
    {
        public string Message { get; set; } = "";
        public string CorrelationId { get; set; } = "";
    }
}

public sealed class RepositoryApiException(string message) : Exception(message);
