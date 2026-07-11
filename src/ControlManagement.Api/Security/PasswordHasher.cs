using System.Security.Cryptography;

namespace ControlManagement.Api.Security;

/// <summary>
/// PBKDF2-SHA256 password hasher.  Lives in the API project so the Web tier
/// never needs the hashing primitives or the database connection string.
///
/// Stored format: "{iterations}.{saltB64}.{hashB64}"
/// - iterations: integer >= 100,000 (currently 210,000)
/// - saltB64:    Base64 of a 16-byte cryptographically random salt
/// - hashB64:    Base64 of a 32-byte PBKDF2-SHA256 derivation
/// </summary>
public sealed class PasswordHasher
{
    private const int Iterations = 210_000;
    private const int SaltBytes = 16;
    private const int HashBytes = 32;

    public bool Verify(string password, string encodedHash)
    {
        try
        {
            var parts = encodedHash.Split('.');
            if (parts.Length != 3 || !int.TryParse(parts[0], out var iterations) || iterations < 100_000) return false;
            var salt = Convert.FromBase64String(parts[1]);
            var expected = Convert.FromBase64String(parts[2]);
            var actual = Rfc2898DeriveBytes.Pbkdf2(password, salt, iterations, HashAlgorithmName.SHA256, expected.Length);
            return CryptographicOperations.FixedTimeEquals(expected, actual);
        }
        catch { return false; }
    }

    public string Hash(string password)
    {
        if (string.IsNullOrEmpty(password)) throw new ArgumentException("Password is required.", nameof(password));
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var derived = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations, HashAlgorithmName.SHA256, HashBytes);
        return $"{Iterations}.{Convert.ToBase64String(salt)}.{Convert.ToBase64String(derived)}";
    }
}
