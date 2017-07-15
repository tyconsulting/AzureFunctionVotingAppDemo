#r "System.Runtime"
#r "System.Threading.Tasks"

using System;
using System.Threading.Tasks;
using System.Web;
using Microsoft.IdentityModel.Clients.ActiveDirectory;
using Microsoft.Azure.KeyVault;
using System.Security.Cryptography.X509Certificates;

public static string GetKeyVaultSecret(string secretNode)
{
    string KeyVaultName = System.Environment.GetEnvironmentVariable("KeyVaultName", EnvironmentVariableTarget.Process);
    string KeyVaultUri = @"https://" + KeyVaultName + ".vault.azure.net/secrets/";
    var secretUri = string.Format("{0}{1}", KeyVaultUri, secretNode);

    var keyVaultClient = new KeyVaultClient(new KeyVaultClient.AuthenticationCallback(GetAccessToken));
    return keyVaultClient.GetSecretAsync(secretUri).Result.Value;
}

private static async Task<string> GetAccessToken(string authority, string resource, string scope)
{
    var authContext = new AuthenticationContext(authority);
    AuthenticationResult result = await authContext.AcquireTokenAsync(resource, GetCert());

    if (result == null)
        throw new InvalidOperationException("Failed to obtain the JWT token");

    return result.AccessToken;
}

private static ClientAssertionCertificate GetCert()
{
    string CertThumbprint = System.Environment.GetEnvironmentVariable("KVCertThumbPrint", EnvironmentVariableTarget.Process);
    string AADAppId = System.Environment.GetEnvironmentVariable("KVAADAppId", EnvironmentVariableTarget.Process);
    var clientAssertionCertPfx = FindCertificateByThumbprint(CertThumbprint);
    // the left-hand GUID here is the output of $adapp.ApplicationId in our Service Principal setup script
    return new ClientAssertionCertificate(AADAppId, clientAssertionCertPfx);
}

private static X509Certificate2 FindCertificateByThumbprint(string findValue)
{
    X509Store store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
    try
    {
        store.Open(OpenFlags.ReadOnly);
        X509Certificate2Collection col = store.Certificates.Find(X509FindType.FindByThumbprint, findValue, false);
        if (col == null || col.Count == 0)
        {
            return null;
        }
        return col[0];
    }
    finally
    {
        store.Close();
    }
}