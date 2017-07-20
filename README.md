# Azure Function Demo - Voting App
Author - Tao Yang (TY Consulting Pty. Ltd.)

**Copyright - (c) 2017 TY Consulting Pty. Ltd. All rights reserved.**

## Description
This folder contains the deployment artifacts for an Azure Functions demo app. This demo app allows users to cast vote using a HTTP GET request (i.e. by hitting an URL from browser, or scanning a QR code from mobile devices). In this demo, users can vote how much they love the famous Australian food Vegemite ([https://www.youtube.com/watch?v=P_sUhTWtvG4](https://www.youtube.com/watch?v=P_sUhTWtvG4))

> **Note:** This demo was originally developed for Pete Zerger and Tao Yang's Experts Live Australia 2017 presentation Cloud Automation Overview. In the presentation, the attendees voted by scanning the QR codes from a slide like this:
![](images/SlideSample.png)

## Architecture
This demo app is made up using the following Microsoft cloud based services:
* Azure Resources:
    * Azure Functions App
    * Azure SQL Database
    * Azure Key Vault
    * Azure AD Application and Service Principal
* Office 365 Application:
    * Power BI Pro account
    
![Voting App Architecture](images/architecture.png)

When the Azure Function is triggered via HTTP request, it performs the following steps:
1. Retrieves the Azure SQL server FQDN, database name and credential from Azure Key Vault
2. Insert the vote, client IP and time stamp to the Azure SQL database
3. Return either a successful or failure message in HTTP response

The vote result can be accessed by either querying the Azure SQL database, or via a Power BI report that is connected to the Azure SQL database.


## Provisioning Process
### Automated Process
#### Overview
Most of the components are deployed using the PowerShell script **Deploy-VotingApp.ps1**. This PowerShell script performs the following actions:
1. Checking if the following Azure resource names are avaiable (to be used):
    * Azure Function Apps Name
    * Azure SQL Server Name
    * Azure Key Vault Name
2. Create an Azure AD Application, Service Principal and certificate based key credential
3. Deploying an Azure Resource Manager (ARM) template. This template deploys the following resources:
    * Azure Function App (website, storage account, function app service)
        * Application settings
        * Retrieving Azure AD application certificate from Key Vault and stored in the web site
    * Azure Key Vault
        * Key Vault secret (SQL server FQDN, database name, credentials and Azure AD Application certificate)
    * Azure SQL Server and database
4. Once the ARM template is deployed, performing steps that cannot be performed within ARM templates:
    * Retrieving Azure Function app Kudu API credential
    * Deploying Azure Function source code using Kudu API
    * Creating SQL database read-only user
    * Executing SQL queries to configure the Azure SQL database
5. Creating QR Codes for each vote options

After executing the Deploy-VotingApp.ps1 script, you will need to manually create Power BI report (based on the report provided in this repository).

#### Pre-requisites
##### PowerShell modules
The following PowerShell modules are required to execute the Deploy-VotingApp.ps1 PowerShell script:
* AzureRM.Profile
* AzureRM.Resources
* AzureAD
* QrCodes

All of these modules can be found from the PowerShell gallery ([https://www.PowerShellGallery.com](https://www.PowerShellGallery.com)), can be installed using command **Install-Module [Module-name] -Force** on computers running Windows Powershell version 5 or later.

##### Azure AD and Subscription Privilege
You will need to specify a credential for a user that has admin privilege for Azure AD tenant and Azure subscription.

#### Executing Deploy-VotingApp.ps1 Script
**Before running the script, make sure you update variables from line 283 to 295 according to your environments**
![](images/ChangeVariables.png)

Syntax:
``` PowerShell
.\Deploy-VotingApp.ps1 $(Get-Credential)
```
When prompted, specify your Org Id that has admin access to both Azure AD tenant and Azure subscription.

The script takes approximately 10 minutes to execute. Once completed, you are able to see the following components in the resource group that you have specified (the names will be slightly different.)
**Azure Resources:**
![](images/AzureResources.png)

**Azure AD Application:**
![](images/AADApplication.png)

The QR code images are saved to the $PSScriptRoot folder (same folder of the deploy-votingapp.ps1 script):
![](images/QRCodeImages.png)

### Manual Provisioning
To better understand the architecture, you may choose to manually provision the components required for this voting app:
#### Azure AD application
1. Create a Self-Signed certificate and export it to pfx file (with private key)
2. Create an Azure AD application with the certificate based key credential (using the certificate created in step 1)
3. Create a Service Principal for the Azure AD application
4. Assign the service principal contributor role to the Azure subscription

### Azure SQL Database
1. Create an Azure SQL server and database called "VotingApp"
2. Create tables in the "VotingApp" database using the SQL query below:
~~~SQL
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
~~~
3. Populating the Voting App database using the SQL query below
~~~SQL
INSERT AzureFunctionDemo.Rating (RatingScore, RatingTitle) VALUES
(1, 'Awful'),
(2, 'So So'),
(3, 'Love It')
~~~
4. Create a new read-only SQL login & user called 'SQLReadOnly' for Power BI report

    Creating new login:
    ~~~SQL
    IF NOT EXISTS (SELECT * FROM sys.sql_logins WHERE name = 'SQLReadOnly')
        CREATE LOGIN SQLReadOnly WITH PASSWORD = 'specify-your-password'
    ~~~
    
    Create new database user:
    ~~~SQL
    IF NOT EXISTS (SELECT * FROM sys.sysusers WHERE name='SQLReadOnly')
	BEGIN
		CREATE USER SQLReadOnly FOR LOGIN SQLReadOnly WITH DEFAULT_SCHEMA = dbo;
	END

    IF is_rolemember ('db_datareader', 'SQLReadOnly') <> 1
	BEGIN
		EXEC sp_addrolemember N'db_datareader', N'SQLReadOnly';
	END
    ~~~

### Azure Key Vault
1. Create an Azure Key Vault, and assign the Azure AD application the following privilege:
    * List Secret
    * Get Secret
2. Add the following secrets:

| Secret Name | Value |
| :---: | :---:
**VotingSQLDB** | VotingApp
**SQLServerFQDN** | [Azure SQL Server FQDN]
**SQLReadOnlyUserName** | [SQL Read-Only user name]
**SQLReadOnlyUserPassword** | [SQL Read-Only user password]
**SQLAdminUserName** | [SQL Admin user name]
**SQLAdminPassword** | [SQL Admin password]

### Azure Function App
1. Create an Azure function app
2. Create a C# HTTP triggered function
    * run.csx  - get source code [here](function\Vote\run.csx)
    * Create keyvault.csx - get source code [here](function\Vote\keyvaultclient.csx)
3. Modify project.json as shown below:
    ~~~json
    {
      "frameworks": {
        "net46":{
          "dependencies": {
            "Microsoft.IdentityModel.Clients.ActiveDirectory": "3.13.1",
            "Microsoft.IdentityModel.Logging": "1.0.0",
            "Microsoft.Azure.Common": "2.1.0",
            "Microsoft.Azure.KeyVault": "1.0.0",
            "System.Data.SqlClient": "4.3.0"
          }
        }
      }
    }
    ~~~
4. The function app requires the following Application Settings:

| App Setting Name | Value |
| :---: | :---: 
|KeyVaultName|[Name of the Azure Key Vault]
|KVAADAppId|[Azure AD Application Id]
|KVCertThumbPrint|[Thumbprint of the self-signed certificate created earlier]

5. Import the certificate into Azure App Service
![](images/ImportCert.png)

6. Restart the function app

### Generate QR code
Generate QR code for different votes

* Aweful: [function URL]&rating=1
* So So: [function URL]&rating=2
* Love it: [function URL]&rating=3

    >**Note:** There are many free websites you can use to generate QR codes. Or you can use the QrCodes PowerShell module mentioned above to generate the QR code images.
    ~~~PowerShell
    Write-Output 'Generating QR Codes...'
  Out-BarcodeImage -Content $awefulURL -BarcodeFormat QR_CODE -Path 'C:\Aweful.png' -ImageFormat png -Width 500 -Height 500
  Out-BarcodeImage -Content $SosoURL -BarcodeFormat QR_CODE -Path 'C:\Soso.png' -ImageFormat png -Width 500 -Height 500
  Out-BarcodeImage -Content $LoveItURL -BarcodeFormat QR_CODE 'C:\LoveIt.png' -ImageFormat png -Width 500 -Height 500
    ~~~
### Power BI Report
Create Power BI report using your favourite visuals. Use the SQL Read-Only user name and password to connect to SQL DB. You can use the following SQL Query in Power BI report:
~~~SQL
Select v.Id as VoteId, v.RatingId, r.RatingTitle, v.ClientIP, v.SubmissionDate from AzureFunctionDemo.Vote v
JOIN AzureFunctionDemo.Rating r on v.RatingId = r.Id
~~~


## Casting Votes
To cast votes, end users can either browse to various URLs in the browser or scan QR codes using mobile devices.
For the demo environment, the URLs and QR codes are listed below:

**URLs:**

* Aweful - [https://functionsvotingappdemo.azurewebsites.net/api/Vote?code=2ErTulkW2CfE9IrbORWOrcQanXENPaY0KwVKJiBhKXlAnvBDIGCMug==&rating=1](https://functionsvotingappdemo.azurewebsites.net/api/Vote?code=2ErTulkW2CfE9IrbORWOrcQanXENPaY0KwVKJiBhKXlAnvBDIGCMug==&rating=1)
* So So - [https://functionsvotingappdemo.azurewebsites.net/api/Vote?code=2ErTulkW2CfE9IrbORWOrcQanXENPaY0KwVKJiBhKXlAnvBDIGCMug==&rating=2](https://functionsvotingappdemo.azurewebsites.net/api/Vote?code=2ErTulkW2CfE9IrbORWOrcQanXENPaY0KwVKJiBhKXlAnvBDIGCMug==&rating=2)
* Love it - [https://functionsvotingappdemo.azurewebsites.net/api/Vote?code=2ErTulkW2CfE9IrbORWOrcQanXENPaY0KwVKJiBhKXlAnvBDIGCMug==&rating=3](https://functionsvotingappdemo.azurewebsites.net/api/Vote?code=2ErTulkW2CfE9IrbORWOrcQanXENPaY0KwVKJiBhKXlAnvBDIGCMug==&rating=3)

**QR Codes:**
* **Aweful:**

![](Aweful.png)
* **So So:**

![](Soso.png)
* **Love It:**

![](LoveIt.png)

### Vote Using Mobile Devices
1. Scan QR code:

![](images/MobileVote1.png)

2. Browse to the URL:

![](images/MobileVote2.png)

3. HTTP Response displayed in the browser:

![](images/MobileVote3.png)

## Power BI Report
You may use the [Power BI report](PowerBI-report\VotingAppReport.pbix) provided in this repository and import it to your Power BI account.

### Importing Power BI report
To import the Power BI report, firstly you will need to retrieve the SQL Read-Only account credential from key vault. To access the secrets, you may need to give yourself access in the key vault:

![](images/KeyVaultAccess.png)

Once the read-only user credential is retrieved, you need to open the Power BI report in Power BI desktop and modify the connection

![](images/PowerBIConnection.png)

Once the report is loaded, you can publish it to Power BI Online.
![](images/PublishPowerBI.png)

### Sample Report
#### Sample Report Screenshot
![](images/SampleReport.png)

#### Demo Live Report
> **Note:** This report uses direct query, however, cache refresh is scheduled to run every 15 minutes. you may need to wait up to 15 minutes after voting in order to see the change reflected on this report.

[**Open Report**](https://app.powerbi.com/view?r=eyJrIjoiZDJhNzZhMGYtNjhiOS00ZDYwLTg0OWMtNWJlNTJhMThhZGJmIiwidCI6Ijc4Mzk2MjQwLTY0OWEtNGJmNC05NDE1LWQ3NDAwMWIyNGQwNyIsImMiOjEwfQ%3D%3D)

## Credit
In this project, several components come from other community projects:
* Accessing Key Vault secrets from Azure Functions: [https://blog.siliconvalve.com/2016/11/15/azure-functions-access-keyvault-secrets-with-a-cert-secured-service-principal/](https://blog.siliconvalve.com/2016/11/15/azure-functions-access-keyvault-secrets-with-a-cert-secured-service-principal/)
* Generating QR Code from PowerShell: [PowerShell Module](https://www.powershellgallery.com/packages/QrCodes), [Blog Article](http://blog.whatsupduck.net/2013/12/creating-qr-codes-in-powershell.html)


