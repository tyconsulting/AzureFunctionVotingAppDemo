#load "keyvaultclient.csx"
#r "Newtonsoft.Json"
#r "System.Web"

using System;
using System.Net;
using System.Web;
using System.Collections;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading.Tasks;
using System.IO;
using System.Text;
using System.Data.SqlClient;
using System.Data;
using System.Security;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

public static async Task<HttpResponseMessage> Run(HttpRequestMessage req, TraceWriter log)
{
    // parse query parameter
    log.Info($"Getting Vote Rating from parameter");
    string rating = req.GetQueryNameValuePairs()
        .FirstOrDefault(q => string.Compare(q.Key, "rating", true) == 0)
        .Value;
    
    //Get client IP
    string clientIP = ((HttpContextWrapper)req.Properties["MS_HttpContext"]).Request.UserHostAddress;
    log.Info($"Someone from '{clientIP}' voted: {rating}");
    
    //variables
    var Response = new HttpResponseMessage();
    //HttpStatusCode statuscode = new HttpStatusCode();
    Encoding outputencoding = Encoding.GetEncoding("ASCII");
    //Get secrets from Key Vault
    log.Info("Getting secrets from Key Vault");
    string SQLServer = GetKeyVaultSecret("SQLServerFQDN");
    string SQLDB = GetKeyVaultSecret("VotingSQLDB");
    string SQLServerUserName = GetKeyVaultSecret("SQLAdminUserName");
    string SQLServerPassword = GetKeyVaultSecret("SQLAdminPassword");
    SecureString secureSQLServerPassword = new SecureString();
    foreach (char c in SQLServerPassword.ToCharArray())
    {
        secureSQLServerPassword.AppendChar(c);
    }
    secureSQLServerPassword.MakeReadOnly();
    log.Info($"SQL Server '{SQLServer}' DB: {SQLDB}");
    //SQL queries
    string SQLQueryTemplate = "INSERT AzureFunctionDemo.Vote (RatingId, ClientIP, SubmissionDate) VALUES ({0}, '{1}', GETUTCDATE())";
    if (rating != null)
    {
        string SQLQuery = string.Format(SQLQueryTemplate, rating, clientIP);
        string SQLConnTemplate = "Server = tcp:{0},1433; Initial Catalog ={1}; Persist Security Info = False; MultipleActiveResultSets = False; Encrypt =true; TrustServerCertificate =false; Connection Timeout = 30;";
        string SQLConn = string.Format(SQLConnTemplate, SQLServer, SQLDB);
        log.Info($"SQL Query: {SQLQuery}");
        try
        {
            SqlCredential sqlCred = new SqlCredential(SQLServerUserName, secureSQLServerPassword);
            SqlConnection conn = new SqlConnection(SQLConn);
            conn.Credential = sqlCred;
            conn.Open();
            //Insert the row to the SQL DB table
            SqlCommand SqlCmd = conn.CreateCommand();
            SqlCmd.CommandTimeout = 120;
            SqlCmd.CommandText = SQLQuery;
            int InsertRowCount = SqlCmd.ExecuteNonQuery();
            log.Info($"Number of rows inserted {InsertRowCount}");
            //close SQL connection
            conn.Close();

            //HTTP response
            string html = @"<html>
<head><title>Thank You!</title></head>
<body>
<h1>Thanks for your vote!</h1>
</body>
</html>";
            //StringContent ResponseContent = new StringContent(html); 
            //statuscode = HttpStatusCode.Accepted;
            //Response = req.CreateResponse(statuscode, ResponseContent);
            //Response.Content.Headers.ContentType = new MediaTypeHeaderValue("text/html");
            //Response.Content = ResponseContent;
            Response.StatusCode = HttpStatusCode.Accepted;
            Response.Content = new StringContent(html);
            Response.Content.Headers.ContentType = new MediaTypeHeaderValue("text/html");
        }
        catch
        {
            Response = req.CreateResponse(HttpStatusCode.InternalServerError, "Unable to process your request!");
            Response.Content.Headers.ContentType = new MediaTypeHeaderValue("text/HTML");
        }
    } else
    {
        Response = req.CreateResponse(HttpStatusCode.BadRequest, "You did not cast your vote in the URL input parameter!");
        Response.Content.Headers.ContentType = new MediaTypeHeaderValue("text/HTML");
    }
    return Response;
}
