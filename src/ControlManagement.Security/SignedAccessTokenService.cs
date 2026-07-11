using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace ControlManagement.Security;

public sealed class SignedAccessTokenService(IOptions<SecurityOptions> options)
{
    private readonly SecurityOptions _options = options.Value;

    public string Issue(string subject, IEnumerable<string> roles)
    {
        EnsureSigningKey();
        var payload = new AccessPrincipal
        {
            Subject = subject,
            Roles = roles.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
            ExpiresUtc = DateTimeOffset.UtcNow.AddMinutes(_options.TokenLifetimeMinutes).ToUnixTimeSeconds()
        };
        var encodedPayload = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(payload));
        return $"cm01.{encodedPayload}.{Sign(encodedPayload)}";
    }

    public bool TryValidate(string token, out AccessPrincipal principal)
    {
        principal = new AccessPrincipal();
        try
        {
            EnsureSigningKey();
            var parts = token.Split('.');
            if (parts.Length != 3 || parts[0] != "cm01") return false;
            var expected = Encoding.UTF8.GetBytes(Sign(parts[1]));
            var actual = Encoding.UTF8.GetBytes(parts[2]);
            if (!CryptographicOperations.FixedTimeEquals(expected, actual)) return false;
            principal = JsonSerializer.Deserialize<AccessPrincipal>(Base64UrlDecode(parts[1])) ?? new AccessPrincipal();
            return !string.IsNullOrWhiteSpace(principal.Subject)
                && principal.ExpiresUtc > DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        }
        catch { return false; }
    }

    private string Sign(string value)
    {
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(_options.TokenSigningKey));
        return Base64UrlEncode(hmac.ComputeHash(Encoding.UTF8.GetBytes(value)));
    }

    private void EnsureSigningKey()
    {
        if (_options.TokenSigningKey.Length < 32)
            throw new InvalidOperationException("Configure Security:TokenSigningKey with at least 32 characters.");
    }

    private static string Base64UrlEncode(byte[] value) =>
        Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] Base64UrlDecode(string value)
    {
        var padded = value.Replace('-', '+').Replace('_', '/');
        padded += new string('=', (4 - padded.Length % 4) % 4);
        return Convert.FromBase64String(padded);
    }
}
