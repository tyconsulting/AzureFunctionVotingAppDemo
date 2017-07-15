#Requires -Version 5.0
#Requires -RunAsAdministrator
#Requires -Modules @{ModuleName="AzureRM.profile";ModuleVersion="3.1.0"}, @{ModuleName="AzureRM.Resources";ModuleVersion="4.1.0"}, Microsoft.PowerShell.Utility, PKI, AzureAD, QrCodes
<#
    =======================================================================
    AUTHOR:  Tao Yang 
    DATE:    15/07/2017
    Version: 1.0
    Comment: The deployment script for the Azure Functions Voting App Demo
    =======================================================================
#>
[CmdletBinding()]
Param (
  [Parameter(Mandatory = $true)][PSCredential]$AdminCred,
  [Parameter(Mandatory = $false)][String][ValidateScript({test-path $_ -PathType 'Leaf'})]$ARMTemplateFilePath = $(Join-path $PSScriptRoot azuredeploy.json),
  [Parameter(Mandatory = $false)][String][ValidateScript({test-path $_ -PathType 'Leaf'})]$FunctionsSourcePath = $(Join-Path $PSScriptRoot function)
)
Clear-Host
Write-Output "**** Azure Functions Voting App Demo Deployment ****", ''
#region load modules (so assemblies are loaded)
Import-Module AzureRM.Profile
Import-Module AzureRM.Resources
#endregion

#region Functions
Function New-Password
{
  param(
    [UInt32][ValidateScript({$_ -ge 8 -and $_ -le 128})] $Length=10,
    [Switch] $LowerCase=$TRUE,
    [Switch] $UpperCase=$FALSE,
    [Switch] $Numbers=$FALSE,
    [Switch] $Symbols=$FALSE
  )

  if (-not ($LowerCase -or $UpperCase -or $Numbers -or $Symbols)) {
    throw "You must specify one of: -LowerCase -UpperCase -Numbers -Symbols"
    return $null
  }
  # Specifies bitmap values for character sets selected.
  $CHARSET_LOWER = 1
  $CHARSET_UPPER = 2
  $CHARSET_NUMBER = 4
  $CHARSET_SYMBOL = 8

  # Creates character arrays for the different character classes,
  # based on ASCII character values.
  $charsLower = 97..122 | foreach-object { [Char] $_ }
  $charsUpper = 65..90 | foreach-object { [Char] $_ }
  $charsNumber = 48..57 | foreach-object { [Char] $_ }
  $charsSymbol = 35,36,42,43,44,45,46,47,58,59,61,63,64,
  91,92,93,95,123,125,126 | foreach-object { [Char] $_ }
  # Contains the array of characters to use.
  $charList = @()
  # Contains bitmap of the character sets selected.
  $charSets = 0
  if ($LowerCase) {
    $charList += $charsLower
    $charSets = $charSets -bor $CHARSET_LOWER
  }
  if ($UpperCase) {
    $charList += $charsUpper
    $charSets = $charSets -bor $CHARSET_UPPER
  }
  if ($Numbers) {
    $charList += $charsNumber
    $charSets = $charSets -bor $CHARSET_NUMBER
  }
  if ($Symbols) {
    $charList += $charsSymbol
    $charSets = $charSets -bor $CHARSET_SYMBOL
  }

  # Returns True if the string contains at least one character
  # from the array, or False otherwise.

  # Loops until the string contains at least
  # one character from each character class.
  do {
    # No character classes matched yet.
    $flags = 0
    $output = ""
    # Create output string containing random characters.
    1..$Length | foreach-object {
      $output += $charList[(get-random -maximum $charList.Length)]
    }
    # Check if character classes match.
    if ($LowerCase) {
      foreach ($char in $output.ToCharArray()) {If ($charsLower -contains $char) {$flags = $flags -bor $CHARSET_LOWER; break }}
    }
    if ($UpperCase) {
      foreach ($char in $output.ToCharArray()) {If ($charsUpper -contains $char) {$flags = $flags -bor $CHARSET_UPPER; break }}
    }
    if ($Numbers) {
      foreach ($char in $output.ToCharArray()) {If ($charsNumber -contains $char) {$flags = $flags -bor $CHARSET_NUMBER; break }}
    }
    if ($Symbols) {
      foreach ($char in $output.ToCharArray()) {If ($charsSymbol -contains $char) {$flags = $flags -bor $CHARSET_SYMBOL; break }}
    }
  }
  until ($flags -eq $charSets)
  # Output the string.
  $output
}

Function Invoke-AzureSQLQuery
{
	[CmdletBinding()]
	PARAM (
		[Parameter(Mandatory=$true,HelpMessage='Please enter the SQL Server name')][Alias('SQL','Server','s')][String]$SQLServer,
		[Parameter(Mandatory=$true,HelpMessage='Please enter the SQL Database name')][Alias('d')][String]$Database,
		[Parameter(Mandatory=$true,HelpMessage='Please enter the SQL query')][Alias('q')][String]$Query,
		[Parameter(Mandatory=$false,HelpMessage='Please enter the SQL Query Timeout in seconds')][Alias('timeout', 't')][int]$SQLQueryTimeout = 600,
		[Parameter(Mandatory=$true,HelpMessage='Please specify the database credential to connect to the SQL Server')][Alias('cred')][PSCredential]$credential
	)
	#Connect to DB
  $conString = "Server=tcp:$SQLServer,1433;Initial Catalog=$Database;Persist Security Info=False;MultipleActiveResultSets=False;Encrypt=$true;TrustServerCertificate=$false;Connection Timeout=30;" 
  $SQLCon = New-Object -TypeName System.Data.SqlClient.SqlConnection
  $SQLCon.ConnectionString = $conString
  $Credential.Password.MakeReadOnly()
  $SQLCred = New-Object -TypeName System.Data.SqlClient.SqlCredential -ArgumentList ($Credential.UserName, $Credential.Password)
  $SQLCon.Credential = $SQLCred
  $SQLCon.Open()

  #execute SQL query
  $sqlCmd = $SQLCon.CreateCommand()
  $sqlCmd.CommandTimeout=$SQLQueryTimeout
  $sqlCmd.CommandText = $Query
  $NumberOfRowsAffected = $sqlCmd.ExecuteNonQuery()
  $SQLCon.Close()

  $NumberOfRowsAffected
}
Function Get-AADToken {
       
  [CmdletBinding()]
  [OutputType([string])]
  PARAM (
    [Parameter(Position=0,Mandatory=$true)]
    [ValidateScript({
          try 
          {
            [System.Guid]::Parse($_) | Out-Null
            $true
          } 
          catch 
          {
            $false
          }
    })]
    [Alias('tID')]
    [String]$TenantID,

    [Parameter(Position=1,Mandatory=$true)][Alias('cred')]
    [pscredential]
    [System.Management.Automation.CredentialAttribute()]
    $Credential,
    
    [Parameter(Position=0,Mandatory=$false)][Alias('type')]
    [ValidateSet('UserPrincipal', 'ServicePrincipal')]
    [String]$AuthenticationType = 'UserPrincipal'
  )
  Try
  {
    $Username       = $Credential.Username
    $Password       = $Credential.Password

    If ($AuthenticationType -ieq 'UserPrincipal')
    {
      # Set well-known client ID for Azure PowerShell
      $clientId = '1950a258-227b-4e31-a9cf-717495945fc2'

      # Set Resource URI to Azure Service Management API
      $resourceAppIdURI = 'https://management.azure.com/'

      # Set Authority to Azure AD Tenant
      $authority = 'https://login.microsoftonline.com/common/' + $TenantID
      Write-Verbose "Authority: $authority"

      $AADcredential = [Microsoft.IdentityModel.Clients.ActiveDirectory.UserCredential]::new($UserName, $Password)
      $authContext = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext]::new($authority)
      $authResult = $authContext.AcquireTokenAsync($resourceAppIdURI,$clientId,$AADcredential)
      $Token = $authResult.Result.CreateAuthorizationHeader()
    } else {
      # Set Resource URI to Azure Service Management API
      $resourceAppIdURI = 'https://management.core.windows.net/'

      # Set Authority to Azure AD Tenant
      $authority = 'https://login.windows.net/' + $TenantId

      $ClientCred = [Microsoft.IdentityModel.Clients.ActiveDirectory.ClientCredential]::new($UserName, $Password)
      $authContext = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext]::new($authority)
      $authResult = $authContext.AcquireTokenAsync($resourceAppIdURI,$ClientCred)
      $Token = $authResult.Result.CreateAuthorizationHeader()
    }
    
  }
  Catch
  {
    Throw $_
    $ErrorMessage = 'Failed to aquire Azure AD token.'
    Write-Error -Message 'Failed to aquire Azure AD token'
  }

  $Token
}

Function Validate-WebAppName
{
  Param(
    [Parameter(Mandatory = $true)][String]$WebAppName
  )
  $WebAppDNSName = "$WebAppName`.azurewebsites.net"
  Try{
    $ResolveDNS = [System.Net.Dns]::Resolve($WebAppDNSName)
    If ($ResolveDNS -ne $null)
    {
      $bNameAvailable = $false
    } else {
      $bNameAvailable = $true
    }
  } Catch {
    $bNameAvailable = $true
  }
  $bNameAvailable
}
Function Validate-AzureSQLServerName
{
  Param(
    [Parameter(Mandatory = $true)][String]$SQLServerName
  )
  $SQLServerDNSName = "$SQLServerName`.database.windows.net"
  Try{
    $ResolveDNS = [System.Net.Dns]::Resolve($SQLServerDNSName)
    If ($ResolveDNS -ne $null)
    {
      $bNameAvailable = $false
    } else {
      $bNameAvailable = $true
    }
  } Catch {
    $bNameAvailable = $true
  }
  $bNameAvailable
}
Function Validate-KeyVaultName
{
  Param(
    [Parameter(Mandatory = $true)][String]$KeyVaultName
  )
  $KeyVaultDNSName = "$KeyVaultName`.vault.azure.net"
  Try{
    $ResolveDNS = [System.Net.Dns]::Resolve($KeyVaultDNSName)
    If ($ResolveDNS -ne $null)
    {
      $bNameAvailable = $false
    } else {
      $bNameAvailable = $true
    }
  } Catch {
    $bNameAvailable = $true
  }
  $bNameAvailable
}
function Format-ValidationOutput {
  param ($ValidationOutput, [int] $Depth = 0)
  Set-StrictMode -Off
  return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @('  ' * $Depth + ': ' + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}
#endregion

#region variables
#do not change these variables
$SQLDBName = 'VotingApp'
$SQLDBEdition = 'Standard'
$VotingAppFunctionName = 'Vote'
$AADAppCertValidMonth = 24
$SQLAdminUserPassword = New-Password -Length 12 -LowerCase -UpperCase -Numbers -Symbols
$SQLReadOnlyUserPassword = New-Password -Length 12 -LowerCase -UpperCase -Numbers -Symbols
$arrFilesToRemove = New-Object System.Collections.ArrayList

#Change the following variables to suit your environment
$AzureSubscriptionId = '28ff2389-2cd4-448d-bbf2-e6c5b15cc395'
$ResourceGroupName = 'VotingAppDemo'
$ResourceGroupLocation = 'East US'
$StorageAccountType= 'Standard_GRS'
$SQLServerName = 'VotingAppSQL'
$SQLDBPricingTier = 'S0'
$SQLAdminUserName = 'SQLAdmin'
$SQLReadOnlyUserName = 'SQLReadOnly'
$FunctionAppName = "functionsvotingappdemo"
$AzureFunctionAppsRegion = 'East US'
$KeyVaultName = 'votingappdemokv'
$QRCodeImageFormat = 'png'
$QRCodeSize = 500

#endregion

#region SQL queries for Azure DB config
$CreateVotingAppDBTablesQuery = @"
CREATE SCHEMA [AzureFunctionDemo] AUTHORIZATION [dbo]

CREATE TABLE AzureFunctionDemo.Rating
	(
		Id int PRIMARY KEY NOT NULL IDENTITY(1,1),
		RatingScore int NOT NULL,
		RatingTitle varchar(10) NOT NULL
	)
CREATE TABLE AzureFunctionDemo.Vote
	(
		Id int PRIMARY KEY NOT NULL IDENTITY(1,1),
		RatingId int NOT NULL,
		ClientIP varchar(128) NOT NULL,
		SubmissionDate datetime NOT NULL,
		FOREIGN KEY (RatingId) REFERENCES AzureFunctionDemo.Rating(Id),
	)
"@

$InsertVotingAppDBRowsQuery = @"
INSERT AzureFunctionDemo.Rating (RatingScore, RatingTitle) VALUES
(1, 'Awful'),
(2, 'So So'),
(3, 'Love It')
"@

$NewLoginQueryTemplate = @"
IF NOT EXISTS (SELECT * FROM sys.sql_logins WHERE name = '{0}')
    CREATE LOGIN {0} WITH PASSWORD = '{1}'
"@

$NewUserQueryTemplate = @"
IF NOT EXISTS (SELECT * FROM sys.sysusers WHERE name='{0}')
	BEGIN
		CREATE USER {0} FOR LOGIN {0} WITH DEFAULT_SCHEMA = dbo;
	END

IF is_rolemember ('{1}', '{0}') <> 1
	BEGIN
		EXEC sp_addrolemember N'{1}', N'{0}';
	END
"@

#endregion

#region validating azure resource names
Write-Output "Validating Azure resource names..."
$bFunctionAppNameAvailable = Validate-WebAppName $FunctionAppName
$bSQLServerNameAvailable = Validate-AzureSQLServerName $SQLServerName
$bKeyVaultNameAvailable = Validate-KeyVaultName $KeyVaultName
$bResourceNamesAvaialble = $true
If (!$bFunctionAppNameAvailable)
{
  Write-Error "The function app name '$FunctionAppName' is already taken."
  $bResourceNamesAvaialble = $false
}
If (!$bSQLServerNameAvailable)
{
  Write-Error "The SQL server name '$SQLServerName' is already taken."
  $bResourceNamesAvaialble = $false
}
If (!$bKeyVaultNameAvailable)
{
  Write-Error "The SQL server name '$KeyVaultName' is already taken."
  $bResourceNamesAvaialble = $false
}

If (!$bResourceNamesAvaialble)
{
  Exit -1
} else {
  Write-Output "Specified function app name, SQL server name and key vault name all available."
}
#endregion

#region login to Azure
Try {
  $null = Add-AzureRmAccount -Credential $AdminCred -SubscriptionId $AzureSubscriptionId
  $context = Get-azurermcontext
  $TenantId = $context.Tenant.Id
  $AADToken = Get-AADToken -TenantID $TenantId -Credential $AdminCred
  $RESTAPIHeaders = @{'Authorization'=$AADToken;'Accept'='application/json'}
} catch {
  Throw $_
  Exit -1
}
#endregion

#region deploy Azure components
#Retrieve MSFT Azure AD app Microsoft.Azure.Websites
$ConnectAzureAD = connect-azuread -Credential $AdminCred
$AzureWebsitesSP = Get-AzureADServicePrincipal -SearchString 'Microsoft.Azure.Websites' | Where-Object {$_.DisplayName -eq 'Microsoft.Azure.Websites'}
If ($AzureWebsitesSP -ne $null)
{
  Write-Output "Found Azure AD app 'Microsoft.Azure.Websites'."
  $AzureWebSitesObjectId = $AzureWebsitesSP.ObjectId
} else {
  Throw "Azure AD application 'Microsoft.Azure.Websites' not found."
  Exit -1
}

$ExistingResourceGroup = Get-AzureRmResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue

#Azure AD application
Try {
  Write-Output '', "Creating an Azure AD application for the Voting App Demo"
  $KeyId = (New-Guid).Guid
  $AADAppnDisplayNameSuffix = $KeyId -replace('-', '')
  $AADAppDisplayName = "VotingAppDemo"
  Write-Output '', "AAD Application Display Name: '$AADAppDisplayName'"

  Write-Output '', 'Creating certificate based key for the Voting App AAD application...'
  $StartDate = ([Datetime]::Now).AddHours(-25)
  $EndDate = $StartDate.AddMonths($AADAppCertValidMonth)
  $CertPath = Join-Path -Path $env:TEMP -ChildPath ($AADAppDisplayName + '.pfx')
  [void]$arrFilesToRemove.Add($CertPath)

  $Cert = New-SelfSignedCertificate -DnsName $AADAppDisplayName -CertStoreLocation cert:\LocalMachine\My -KeyExportPolicy Exportable -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -NotAfter $EndDate -NotBefore $StartDate
  $CertThumbprint = $Cert.Thumbprint
  $CertPlainPassword = New-Password -Length 12 -LowerCase -UpperCase -Numbers -Symbols
  $CertPassword = ConvertTo-SecureString -String $CertPlainPassword -AsPlainText -Force
  Export-PfxCertificate -Cert ('Cert:\localmachine\my\' + $CertThumbprint) -FilePath $CertPath -Password $CertPassword -Force | out-null
  #Delete cert from local machine cert store
  $DeleteCert = Remove-Item (Join-Path Cert:\LocalMachine\My $CertThumbprint) -Force

  #Creating AAD application key credential
  Write-Output '', "Self signed certificated created. It is temporarily located at '$CertPath'. Creating key credential for the AAD application now."
  $PFXCert = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @($CertPath, $CertPlainPassword)
  $KeyValue = [System.Convert]::ToBase64String($PFXCert.GetRawCertData())
  $KeyCredential = New-Object  -TypeName Microsoft.Azure.Commands.Resources.Models.ActiveDirectory.PSADKeyCredential
  $KeyCredential.StartDate = $PFXCert.NotBefore
  $KeyCredential.EndDate = $PFXCert.NotAfter
  $KeyCredential.KeyId = $KeyId
  $KeyCredential.CertValue = $KeyValue

  Write-Output '', "Creating AAD application now."
  $AADApplication = New-AzureRmADApplication -DisplayName $AADAppDisplayName -HomePage ('http://' + $AADAppDisplayName) -IdentifierUris ('http://' + $KeyId) -KeyCredentials $KeyCredential

  Write-Output '', "Creating Service Principal for AAD application now..."
  $ServicePrincipal = New-AzureRMADServicePrincipal -ApplicationId $AADApplication.ApplicationId
  $ServicePrincipalObjectId = $ServicePrincipal.Id.ToString()

  Write-Output '', "Assigning Azure subscription 'Contributor' role to the AAD Application Service Principal."
  $NewRole = $null
  # Sleep here for a few seconds to allow the service principal application to become active (ordinarily takes a few seconds)
  $Retries = 0
  While ($NewRole -eq $null -and $Retries -le 6)
  {
    Start-Sleep -s 15
    New-AzureRMRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $AADApplication.ApplicationId -ErrorAction SilentlyContinue
    $NewRole = Get-AzureRMRoleAssignment -ServicePrincipalName $AADApplication.ApplicationId -ErrorAction SilentlyContinue
    $Retries++
  }
  Write-output '', 'Finished creating Azure AD application.'
} catch {
  Throw $_
  Exit -1
}

#ARM Template deployment
#Create resource group if does not exist.
If (!$ExistingResourceGroup)
{
  Write-output '', "Resource group '$ResourceGroupName' does not exist in subscription '$AzureSubscriptionId'. Creating it now..."
  $NewRG = New-AzureRmResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Force
} else {
  Write-Output '', "Resource group '$ResourceGroupName' already exists in subscription '$AzureSubscriptionId'."
}

#Getting pfx cert content
Write-Output '', "Getting pfx file content..."
$flag = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
$collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$collection.Import($CertPath, $CertPlainPassword, $flag)
$pkcs12ContentType = [System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12
$clearBytes = $collection.Export($pkcs12ContentType)
$PfxFileContentEncoded = [System.Convert]::ToBase64String($clearBytes)

#Construct ARM template input parameters
Write-output '', 'Preparing input parameters for the ARM template.'
$parms = @{
  'AADApplicationId' = $($AADApplication.ApplicationId.ToString())
  'AADApplicationSPObjectId' = $ServicePrincipalObjectId
  'MSFTAzureWebsitesRPSPObjectId' = $AzureWebSitesObjectId
  'Storage-AccountType' = $StorageAccountType
  'SQL-ServerName' = $SQLServerName.ToLower()
  'SQL-DBName' = $SQLDBName
  'SQL-AdminLogin' = $SQLAdminUserName
  'SQL-AdminLoginPassword' = (ConvertTo-SecureString $SQLAdminUserPassword -AsPlainText -Force)
  'SQL-ReadOnlyLogin' = $SQLReadOnlyUserName
  'SQL-ReadOnlyLoginPassword' = (ConvertTo-SecureString $SQLReadOnlyUserPassword -AsPlainText -Force)
  'SQL-DBEdition' = $SQLDBEdition
  'SQL-DBPricingTier' = $SQLDBPricingTier
  'Function-Name' = $FunctionAppName
  'Function-FunctionAppsRegion' = $AzureFunctionAppsRegion
  'KeyVault-Name' = $KeyVaultName
  'Cert-AADAppCertFileBase64Content' = $PfxFileContentEncoded
  'Cert-AADAppThumbPrint' = $CertThumbprint
}

#Test ARM template
Write-Output '', "Validating ARM template"
$ARMTemplateValidationResult = Test-AzureRmResourceGroupDeployment -TemplateFile $ARMTemplateFilePath -ResourceGroupName $ResourceGroupName @parms
$ValidationErrors = Format-ValidationOutput $ARMTemplateValidationResult
if ($ValidationErrors) {
  Write-Output 'Validation returned the following errors:', @($ValidationErrors), '', "Template '$ARMTemplateFilePath' is invalid."
}
else {
  Write-Output "Template '$ARMTemplateFilePath' is valid."
  Write-Output '', "Deploying Voting App Demo ARM template now. This will take a while..."
  $ARMDeploymentStartTime = Get-date
  $ARMDeploymentName = 'VotingAppDemo' + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')
  $ARMTemplateDeploymentResult = New-AzureRmResourceGroupDeployment -Name $ARMDeploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $ARMTemplateFilePath @parms -Force -ErrorVariable DeployError
  $ARMDeplymentFinishedTime = Get-date
  $ARMTemplateDeploymentTimeConsumed = $ARMDeplymentFinishedTime.Subtract($ARMDeploymentStartTime)
  Write-Output "Total time for ARM template deployment: $($ARMTemplateDeploymentTimeConsumed.Hours) Hours $($ARMTemplateDeploymentTimeConsumed.Minutes) minutes and $($ARMTemplateDeploymentTimeConsumed.Seconds) seconds."
  if ($DeployError) {
    Write-Output '', 'Template deployment returned the following errors:', @(@($DeployError) | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") })
  } else {
    Write-Output '', 'Template deployment successful.'
  }
}
#endregion

#region post deployment configurations - for everything can't be done in ARM.
If (!$DeployError)
{
  Write-Output '', 'Starting post ARM deployment configuration tasks.'
  ##Post deployment config - Azure Functions
  Write-Output '', "Deploying voting app function to function app..."
  #restart function app before uploading the vote function
  Write-Output "Restarting the function app '$FunctionAppName' before uploading the function..."
  $FunctionAppRestartURI = "https://management.azure.com/subscriptions/$AzureSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/restart?api-version=2016-08-01"
  $FunctionAppRestartRequest = Invoke-WebRequest -UseBasicParsing -Uri $FunctionAppRestartURI -Method Post -Headers $RESTAPIHeaders
  If ($FunctionAppRestartRequest.StatusCode -ge 200 -and $FunctionAppRestartRequest.StatusCode -le 299)
  {
    Write-Output "Function App '$FunctionAppName' successfully restarted."
  } else {
    Write-Error  "Failed to restart the Function App '$FunctionAppName' Please manually restart it."
  }

  #Get publishing keys
  Write-OUtput "Getting the '$FunctionAppName' Function App publishing credentials"
  $GetAzureFunctionPublishingCredAPIURI = "https://management.azure.com/subscriptions/$AzureSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/publishingcredentials/list?api-version=2016-08-01"
  $AzureFunctionPublishingCredRequest = Invoke-WebRequest -UseBasicParsing -Uri $GetAzureFunctionPublishingCredAPIURI -Method Post -Headers $RESTAPIHeaders
  $AzureFunctionPublishingCred = ($AzureFunctionPublishingCredRequest | ConvertFrom-Json).Properties
  $AzureFunctionPublishingUserName = $AzureFunctionPublishingCred.publishingUserName
  $AzureFunctionPublishingPassword = $AzureFunctionPublishingCred.publishingPassword
  $KUDUbase64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $AzureFunctionPublishingUserName,$AzureFunctionPublishingPassword)))
  $KUDUApiURI = "https://$FunctionAppName.scm.azurewebsites.net/api/zip/site/wwwroot"
  $KUDUApiDNSName = "$FunctionAppName.scm.azurewebsites.net"
  #Deploy functions via KUDU API
  $Retries = 0
  $ResolveKUDUApiDNS = [System.Net.Dns]::Resolve($KUDUApiDNSName)
  While ($ResolveKUDUApiDNS -eq $false -and $Retries -le 6)
  {
    Write-Output -InputObject "Unable to resolve Kudu API DNS name '$KUDUApiDNSName'. Waiting for 10 seconds to try again."
    Start-Sleep -Seconds 10
    $ResolveKUDUApiDNS = [System.Net.Dns]::Resolve($KUDUApiDNSName)
    $Retries++
  }
  If ($ResolveKUDUApiDNS -eq $false)
  {
    Throw "Kudu API DNS name '$KUDUApiDNSName' could not be resolved. deployment failed. Please delete the resource group '$ResourceGroupName and try again later."
    Exit -1
  }
  Foreach ($item in (get-ChildItem -Path $FunctionsSourcePath -Directory))
  {
    Write-output "Uploading function $($item.Name) via Kudu REST API '$KUDUApiURI'..."
    $ZipPath = Join-Path $env:Temp "$($item.Name)`.zip"
    If (Test-Path $ZipPath) {Remove-Item $ZipPath -Force}
    [void]$arrFilesToRemove.Add($ZipPath)
    $ZipResult = Compress-Archive -Path $item.PSPath -DestinationPath $ZipPath
    Try {
      $UploadFunction = Invoke-WebRequest -UseBasicParsing -Uri $KUDUApiURI -Headers @{Authorization=("Basic {0}" -f $KUDUbase64AuthInfo)} -Method PUT -InFile $ZipPath -ContentType 'multipart/form-data'
    } Catch {
      Write-Output "upload failed. wait for 30 seconds and try again..."
      Start-Sleep -Seconds 30
      $UploadFunction = Invoke-WebRequest -UseBasicParsing -Uri $KUDUApiURI -Headers @{Authorization=("Basic {0}" -f $KUDUbase64AuthInfo)} -Method PUT -InFile $ZipPath -ContentType 'multipart/form-data'
    }
    
    If ($UploadFunction.StatusCode -ge 200 -and $UploadFunction.StatusCode -le 299)
    {
      Write-Output "The Azure Function '$($item.Name)' has been successfully uploaded."
    } else {
      Write-Error  "Failed to upload the Azure Function '$($item.Name)'."
      Exit -1
    }
  }

  #Restart the funciton app
  Write-Output "Restarting the function app '$FunctionAppName'..."
  $FunctionAppRestartURI = "https://management.azure.com/subscriptions/$AzureSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/restart?api-version=2016-08-01"
  $FunctionAppRestartRequest = Invoke-WebRequest -UseBasicParsing -Uri $FunctionAppRestartURI -Method Post -Headers $RESTAPIHeaders
  If ($FunctionAppRestartRequest.StatusCode -ge 200 -and $FunctionAppRestartRequest.StatusCode -le 299)
  {
    Write-Output "Function App '$FunctionAppName' successfully restarted."
  } else {
    Write-Error  "Failed to restart the Function App '$FunctionAppName' Please manually restart it."
  }
  #Get Function keys
  Write-output "Retrieving function keys"
  $VotingAppFunctionKey = Invoke-AzureRmResourceAction -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/sites/Functions -ResourceName "$FunctionAppName/$VotingAppFunctionName" -Action listsecrets -ApiVersion '2015-08-01' -Force
    
  ##Post deployment config - Azure SQL DB
  Write-Output '', "Configuring the voting app DB '$SQLDBName' on SQL Server '$SQLServerName'."
  $SQLServerFQDN = "$SQLServerName`.database.windows.net"
  $SQLAdminCred = New-object System.Management.Automation.PSCredential($SQLAdminUserName, (ConvertTo-SecureString $SQLAdminUserPassword -AsPlainText -Force))
  
  #configure DB user
  Write-Output "Creating read-only user for the voting app databases in the SQL Server"
  #Create login first
  $SQLQuery = [string]::Format($NewLoginQueryTemplate, $SQLReadOnlyUserName, $SQLReadOnlyUserPassword)
  $AddSQLLogin = Invoke-AzureSQLQuery -SQLServer $SQLServerFQDN -Database master -Query $SQLQuery -Credential $SQLAdminCred
  #Create users
  $SQLQuery = [string]::Format($NewUserQueryTemplate, $SQLReadOnlyUserName, 'db_datareader')
  $AddSQLDBUser = Invoke-AzureSQLQuery -SQLServer $SQLServerFQDN -Database $SQLDBName -Query $SQLQuery -Credential $SQLAdminCred

  #Configuring the VotingApp DB
  Write-Output "Configuring the VotingApp database"
  $CreateDBTables = Invoke-AzureSQLQuery -SQLServer $SQLServerFQDN -Database $SQLDBName -Query $CreateVotingAppDBTablesQuery -Credential $SQLAdminCred
  $InsertDBRows = Invoke-AzureSQLQuery -SQLServer $SQLServerFQDN -Database $SQLDBName -Query $InsertVotingAppDBRowsQuery -Credential $SQLAdminCred

  #Voting URLs
  $VotingURL1 = "$($VotingAppFunctionKey.trigger_url)`&rating=1"
  $VotingURL2 = "$($VotingAppFunctionKey.trigger_url)`&rating=2"
  $VotingURL3 = "$($VotingAppFunctionKey.trigger_url)`&rating=3"

  Write-Output 'Generating QR Codes...'
  Out-BarcodeImage -Content $VotingURL1 -BarcodeFormat QR_CODE -Path $(Join-Path $PSScriptRoot "Aweful.$QRCodeImageFormat") -ImageFormat $QRCodeImageFormat -Width $QRCodeSize -Height $QRCodeSize
  Out-BarcodeImage -Content $VotingURL2 -BarcodeFormat QR_CODE -Path $(Join-Path $PSScriptRoot "Soso.$QRCodeImageFormat") -ImageFormat $QRCodeImageFormat -Width $QRCodeSize -Height $QRCodeSize
  Out-BarcodeImage -Content $VotingURL3 -BarcodeFormat QR_CODE -Path $(Join-Path $PSScriptRoot "LoveIt.$QRCodeImageFormat") -ImageFormat $QRCodeImageFormat -Width $QRCodeSize -Height $QRCodeSize

  Write-Output '', "voting URLs:"
  Write-output '', "Vote 'Aweful:'", $VotingURL1
  Write-output '', "Vote 'So-So':", $VotingURL2
  Write-output '', "Vote 'Love it!':", $VotingURL3

  Write-Output '', "Please retrieve the SQL Read-Only user name and password for Power BI connection."
  
} else {
  Write-Output '', 'ARM template deployment was not successful, therefore Azure functions deployment will be skipped.'
}

#endregion

#region house clean
Write-Output '', 'Removing temporary files'
Foreach ($item in $arrFilesToRemove)
{
  Write-Output "Deleting '$item'..."
  Remove-Item $item -Force
}
Write-Output '', "Done!"
#endregion