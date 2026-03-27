<#
.SYNOPSIS
    Monitort de opslag van een SharePoint Online tenant en stuurt e-mailmeldingen bij overschrijding van drempels.

.DESCRIPTION
    Dit script haalt informatie op over de tenantopslag via de SharePoint Online API en berekent het gebruikspercentage.
    Het detecteert automatisch de waarden voor totale opslag, gebruikte opslag en beschikbare opslag.
    Bij overschrijding van de opgegeven drempels worden waarschuwings- of kritieke e-mails verzonden.

.PARAMETER TenantId
    De GUID van de Azure AD tenant. Vereist voor authenticatie.

.PARAMETER TenantName
    De naam van de tenant (bijv. contoso). Wordt gebruikt om de admin-URL samen te stellen.

.PARAMETER ClientId
    De Application (client) ID van de geregistreerde app in Azure AD.

.PARAMETER ClientSecret
    Het clientgeheim van de geregistreerde app. Moet veilig worden opgeslagen.

.PARAMETER WarnThreshold
    Het percentage (als decimaal, bijv. 0.85 voor 85%) waarboven een waarschuwing wordt verzonden.

.PARAMETER CritThreshold
    Het percentage waarboven een kritieke melding wordt verzonden.

.PARAMETER NotifyTo
    Het e-mailadres van de ontvanger(s) van de meldingen. Meerdere adressen kunnen worden gescheiden door komma's.

.PARAMETER NotifyFrom
    Het e-mailadres van de afzender.

.PARAMETER SmtpServer
    De SMTP-server voor het verzenden van e-mails.

.PARAMETER LogFile
    Het pad naar het logbestand voor het script.

.EXAMPLE
    .\SharePoint Monitoring.ps1 -TenantId "12345678-1234-1234-1234-123456789012" -TenantName "contoso" -ClientId "abcd1234" -ClientSecret "secret" -NotifyTo "admin@contoso.com"

    Voert het script uit met de opgegeven parameters.
.EXAMPLE
    .\SharePoint Monitoring.ps1 -TenantId "12345678-1234-1234-1234-123456789012" -TenantName "contoso" -ClientId "abcd1234" -ClientSecret "secret" -WarnThreshold 0.80 -CritThreshold 0.90

    Voert het script uit met aangepaste drempels voor waarschuwing en kritiek.
.NOTES
    Vereist een app-registratie in Azure AD met de Sites.FullControl.All permissie en admin consent.
    Geen gebruikersaccount of MFA nodig in het script.
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    $TenantId = "<TENANT-ID-GUID>",              # bv. 11111111-2222-3333-4444-555555555555
    $TenantName = "<tenantnaam>",                  # bv. contoso (dan is admin-URL https://contoso-admin.sharepoint.com)
    $ClientId = "<APP-REG-CLIENT-ID>",           # Application (client) ID van de App Registration
    $ClientSecret = "<JE-CLIENT-SECRET>",          # Client secret uit de App Registration (veilig opslaan!)

    # Alert-drempels
    $WarnThreshold = 0.85,   # 85% = WARNING
    $CritThreshold = 0.95,   # 95% = CRITICAL

    # Mail-instellingen
    $NotifyTo = "Dummy@jouwdomein.nl",            # Ontvanger alerts (mag meerdere, gescheiden door komma)
    $NotifyFrom = "spo-monitor@jouwdomein.nl",    # Afzender (bestaand mailbox-/relay-adres)
    $SmtpServer = "smtp.jouwdomein.nl",           # SMTP-relay of interne mailserver
    $LogFile = "C:\Scripts\Logs\SPO-TenantStorageMonitor.log"

)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    Write-Host $line
    if ($LogFile) {
        try {
            $dir = Split-Path $LogFile -Parent
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Add-Content -Path $LogFile -Value $line
        }
        catch {
            Write-Host "Kon niet naar logbestand schrijven: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

try {
    Write-Log "=== Start SPO Tenant Storage Monitor ==="

    # ============================
    # 1. Access token ophalen (client credentials, app-only)
    # ============================

    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    # Voor SharePoint Online gebruiken we scope op de admin-URL
    $scope = "https://$TenantName-admin.sharepoint.com/.default"

    $tokenBody = @{
        client_id     = $ClientId
        scope         = $scope
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
    }

    Write-Log "Access token ophalen bij Entra ID (tenant $TenantId, scope $scope)..."
    $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $tokenBody -ContentType "application/x-www-form-urlencoded"

    if (-not $tokenResponse.access_token) {
        throw "Access token ontbreekt in token response."
    }

    $accessToken = $tokenResponse.access_token
    Write-Log "Access token succesvol verkregen."

    # ============================
    # 2. Tenant storage info via _api/StorageQuotas()
    # ============================

    $spAdminUrl = "https://$TenantName-admin.sharepoint.com"
    $quotaEndpoint = "$spAdminUrl/_api/StorageQuotas()?api-version=1.3.2"

    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Accept"        = "application/json;odata=nometadata"
    }

    Write-Log "Ophalen StorageQuotas van $quotaEndpoint ..."
    $quotaResponse = Invoke-RestMethod -Method Get -Uri $quotaEndpoint -Headers $headers

    # In de praktijk bevat deze response waarde(n) met:
    # TenantStorageMB, GeoUsedStorageMB, GeoAvailableStorageMB [1](https://learn.microsoft.com/en-us/graph/permissions-selected-overview)

    # Probeer eerst root-level properties
    $tenantStorageMB = $quotaResponse.TenantStorageMB
    $geoUsedStorageMB = $quotaResponse.GeoUsedStorageMB
    $geoAvailableStorageMB = $quotaResponse.GeoAvailableStorageMB

    # Als dat niet werkt, probeer 'value[0]' (fallback voor andere structuren)
    if (-not $tenantStorageMB -and $quotaResponse.value) {
        $tenantStorageMB = $quotaResponse.value[0].TenantStorageMB
        $geoUsedStorageMB = $quotaResponse.value[0].GeoUsedStorageMB
        $geoAvailableStorageMB = $quotaResponse.value[0].GeoAvailableStorageMB
    }

    if (-not $tenantStorageMB) {
        $jsonPreview = ($quotaResponse | ConvertTo-Json -Depth 5)
        throw "Kon TenantStorageMB niet vinden in StorageQuotas response. Response: $jsonPreview"
    }

    $tenantStorageMB = [double]$tenantStorageMB
    $geoUsedStorageMB = [double]$geoUsedStorageMB
    $geoAvailableStorageMB = [double]$geoAvailableStorageMB

    if ($tenantStorageMB -le 0) {
        throw "TenantStorageMB is 0 of kleiner; waarde lijkt ongeldig."
    }

    $usedRatio = $geoUsedStorageMB / $tenantStorageMB
    $usedPct = [math]::Round($usedRatio * 100, 2)

    Write-Log ("Tenant storage: {0} MB totaal, {1} MB gebruikt, {2} MB vrij ({3}% gebruikt)" -f `
            $tenantStorageMB, $geoUsedStorageMB, $geoAvailableStorageMB, $usedPct)

    # ============================
    # 3. Drempel-check
    # ============================

    $alertLevel = $null

    if ($usedRatio -ge $CritThreshold) {
        $alertLevel = "CRITICAL"
    }
    elseif ($usedRatio -ge $WarnThreshold) {
        $alertLevel = "WARNING"
    }

    if (-not $alertLevel) {
        Write-Log "Geen alert: gebruik ($usedPct%) ligt onder de warning-drempel ($([math]::Round($WarnThreshold*100,0))%)."
        Write-Log "=== Einde SPO Tenant Storage Monitor (OK) ==="
        return
    }

    # ============================
    # 4. Alert-mail opbouwen en verzenden
    # ============================

    $subject = "[SPO Storage $alertLevel] SharePoint tenant bijna vol - $TenantName"

    $body = @"
Beste collega,

De SharePoint Online-tenant '$TenantName' nadert zijn opslaglimiet.

Status:            $alertLevel
Totaal quota:      $tenantStorageMB MB
Gebruikt:          $geoUsedStorageMB MB
Vrij:              $geoAvailableStorageMB MB
Gebruik:           $usedPct %

Drempels:
- Warning:   $([math]::Round($WarnThreshold*100,0))%
- Critical:  $([math]::Round($CritThreshold*100,0))%

Neem actie in het SharePoint Admin Center:
- Controleer welke sites veel verbruiken.
- Opschonen (Recycle Bins, versies, oude sites/dossiers).
- Indien nodig: opslag uitbreiden of retentiebeleid aanpassen.

Script: SPO-TenantStorageMonitor.ps1
Host:   $(hostname)

Met vriendelijke groet,
SPO Tenant Storage Monitor

"@

    Write-Log "Versturen van alert-mail ($alertLevel) naar $NotifyTo ..."

    $SendMailMessageParams = @{
        From       = $NotifyFrom
        To         = $NotifyTo
        Subject    = $subject
        Body       = $body
        SmtpServer = $SmtpServer
    }
    Send-MailMessage @SendMailMessageParams


    Write-Log "Alert-mail verzonden."
    Write-Log "=== Einde SPO Tenant Storage Monitor (ALERT: $alertLevel) ==="
}
catch {
    Write-Log "Fout: $($_.Exception.Message)" "ERROR"
    throw
}