using System.Security.Cryptography;
using System.Text;

namespace ControlManagement.Security;

public sealed class EnvelopeCrypto
{
    public EncryptedRequest EncryptRequest(string plainText, string token)
    {
        var cipherText = EncryptString(plainText, token);
        return new EncryptedRequest { RequestStr = cipherText, Signature = Sign(cipherText, token) };
    }

    public EncryptedResponse EncryptResponse(string status, string plainText, string token)
    {
        var cipherText = EncryptString(plainText, token);
        return new EncryptedResponse { Status = status, ResponseStr = cipherText, Signature = Sign(cipherText, token) };
    }

    public string DecryptRequest(EncryptedRequest envelope, string token)
    {
        Verify(envelope.RequestStr, envelope.Signature, token);
        return DecryptString(envelope.RequestStr, token);
    }

    public string DecryptResponse(EncryptedResponse envelope, string token)
    {
        Verify(envelope.ResponseStr, envelope.Signature, token);
        return DecryptString(envelope.ResponseStr, token);
    }

    private static string EncryptString(string plainText, string token)
    {
        ValidateTokenLength(token);
        using var aes = CreateAes(token);
        using var encryptor = aes.CreateEncryptor();
        using var output = new MemoryStream();
        using (var crypto = new CryptoStream(output, encryptor, CryptoStreamMode.Write))
        using (var writer = new StreamWriter(crypto))
            writer.Write(plainText);
        return Convert.ToBase64String(output.ToArray());
    }

    private static string DecryptString(string cipherText, string token)
    {
        ValidateTokenLength(token);
        using var aes = CreateAes(token);
        using var decryptor = aes.CreateDecryptor();
        using var input = new MemoryStream(Convert.FromBase64String(cipherText));
        using var crypto = new CryptoStream(input, decryptor, CryptoStreamMode.Read);
        using var reader = new StreamReader(crypto);
        return reader.ReadToEnd();
    }

    private static Aes CreateAes(string token)
    {
        var aes = Aes.Create();
        aes.Key = Encoding.UTF8.GetBytes(token.Substring(4, 32));
        aes.IV = Encoding.UTF8.GetBytes(token.ToLowerInvariant().Substring(4, 16));
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        return aes;
    }

    private static string Sign(string cipherText, string token)
    {
        using var hmac = new HMACSHA256(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
        return Convert.ToBase64String(hmac.ComputeHash(Encoding.UTF8.GetBytes(cipherText)));
    }

    private static void Verify(string cipherText, string signature, string token)
    {
        var expected = Convert.FromBase64String(Sign(cipherText, token));
        byte[] actual;
        try { actual = Convert.FromBase64String(signature); }
        catch (FormatException) { throw new CryptographicException("Invalid encrypted envelope."); }
        if (!CryptographicOperations.FixedTimeEquals(expected, actual))
            throw new CryptographicException("Invalid encrypted envelope.");
    }

    private static void ValidateTokenLength(string token)
    {
        if (string.IsNullOrWhiteSpace(token) || token.Length < 36)
            throw new CryptographicException("Invalid authorization token.");
    }
}
