<#
.SYNOPSIS
  Monitor SharePoint Online tenant storage via app-only en stuur mail bij overschrijding.

.DESCRIPTION
  - Haalt tenant storage info op via: _api/StorageQuotas()?api-version=1.3.2
  - Detecteert automatisch: TenantStorageMB, GeoUsedStorageMB, GeoAvailableStorageMB
  - Berekent percentage verbruik t.o.v. totale storage
  - Stuurt WARNING / CRITICAL e-mail bij overschrijding drempels

.NOTES
  - Vereist App Registration met SharePoint Application-permission (Sites.FullControl.All) + admin consent.
  - Geen user-account nodig, geen MFA in het script.
#>

#region CONFIG – AANPASSEN PER TENANT

# Entra / Azure AD gegevens
$TenantId   = "<TENANT-ID-GUID>"              # bv. 11111111-2222-3333-4444-555555555555
$TenantName = "<tenantnaam>"                  # bv. contoso (dan is admin-URL https://contoso-admin.sharepoint.com)
$ClientId   = "<APP-REG-CLIENT-ID>"           # Application (client) ID van de App Registration
$ClientSecret = "<JE-CLIENT-SECRET>"          # Client secret uit de App Registration (veilig opslaan!)

# Alert-drempels
$WarnThreshold = 0.85   # 85% = WARNING
$CritThreshold = 0.95   # 95% = CRITICAL

# Mail-instellingen
$NotifyTo   = "servicedesk@ict-concept.nl"            # Ontvanger alerts (mag meerdere, gescheiden door komma)
$NotifyFrom = "spo-monitor@jouwdomein.nl"    # Afzender (bestaand mailbox-/relay-adres)
$SmtpServer = "smtp.jouwdomein.nl"           # SMTP-relay of interne mailserver

# Optioneel: logging
$LogFile = "C:\Scripts\Logs\SPO-TenantStorageMonitor.log"

#endregion CONFIG

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
    $tenantStorageMB        = $quotaResponse.TenantStorageMB
    $geoUsedStorageMB       = $quotaResponse.GeoUsedStorageMB
    $geoAvailableStorageMB  = $quotaResponse.GeoAvailableStorageMB

    # Als dat niet werkt, probeer 'value[0]' (fallback voor andere structuren)
    if (-not $tenantStorageMB -and $quotaResponse.value) {
        $tenantStorageMB        = $quotaResponse.value[0].TenantStorageMB
        $geoUsedStorageMB       = $quotaResponse.value[0].GeoUsedStorageMB
        $geoAvailableStorageMB  = $quotaResponse.value[0].GeoAvailableStorageMB
    }

    if (-not $tenantStorageMB) {
        $jsonPreview = ($quotaResponse | ConvertTo-Json -Depth 5)
        throw "Kon TenantStorageMB niet vinden in StorageQuotas response. Response: $jsonPreview"
    }

    $tenantStorageMB        = [double]$tenantStorageMB
    $geoUsedStorageMB       = [double]$geoUsedStorageMB
    $geoAvailableStorageMB  = [double]$geoAvailableStorageMB

    if ($tenantStorageMB -le 0) {
        throw "TenantStorageMB is 0 of kleiner; waarde lijkt ongeldig."
    }

    $usedRatio = $geoUsedStorageMB / $tenantStorageMB
    $usedPct   = [math]::Round($usedRatio * 100, 2)

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
    Send-MailMessage `
        -From $NotifyFrom `
        -To $NotifyTo `
        -Subject $subject `
        -Body $body `
        -SmtpServer $SmtpServer

    Write-Log "Alert-mail verzonden."
    Write-Log "=== Einde SPO Tenant Storage Monitor (ALERT: $alertLevel) ==="
}
catch {
    Write-Log "Fout: $($_.Exception.Message)" "ERROR"
    throw
}