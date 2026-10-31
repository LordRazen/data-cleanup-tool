# NominatimEndpoint.ps1 (3.2)
# Reverse geocoding with OpenStreetMap Nominatim: GPS coordinates -> place name. Free, no key.
# Follows the usage policy: at most one request per second (at least 1.1 s pause), one request at
# a time, own User-Agent, results cached forever in the table GeoCache, coordinates rounded before
# sending, stop on HTTP 403/429, switchable off with api.nominatim.enabled.
# Never touches files in Input, Result or ToDelete; only returns data (3 - API.md section 1).

$global:ST.NominatimRun = @{ Requests = 0; Blocked = $false; LastRequest = [datetime]::MinValue }

function New-EndpointResult {
    param([bool]$Success, $Data = $null, [string]$ErrorText = '', [string]$ErrorKind = '', [long]$DurationMs = 0)
    return [pscustomobject]@{ Success = $Success; Data = $Data; Error = $ErrorText; ErrorKind = $ErrorKind; DurationMs = $DurationMs }
}

function Reset-NominatimRun {
    # Called at the start of every function run (maxRequestsPerRun, block state).
    $global:ST.NominatimRun.Requests = 0
    $global:ST.NominatimRun.Blocked = $false
}

function Test-NominatimEndpoint {
    $cfg = $global:ST.Settings.api.nominatim
    if (-not $cfg.enabled) { return [pscustomobject]@{ Available = $false; Message = 'OpenStreetMap ist in den Einstellungen ausgeschaltet (api.nominatim.enabled).' } }
    if ($global:ST.NominatimRun.Blocked) { return [pscustomobject]@{ Available = $false; Message = 'OpenStreetMap hat die Anfragen vorübergehend gesperrt. Bitte später erneut versuchen.' } }
    return [pscustomobject]@{ Available = $true; Message = '' }
}

function Get-NominatimPlace {
    # Short place name for folder names: city, else town, village, municipality (3.2 section 4).
    param($Address)
    if ($null -eq $Address) { return '' }
    foreach ($key in @('city', 'town', 'village', 'municipality', 'hamlet', 'suburb', 'county')) {
        $p = $Address.PSObject.Properties[$key]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return ''
}

function Invoke-NominatimEndpoint {
    param([Parameter(Mandatory)][double]$Latitude, [Parameter(Mandatory)][double]$Longitude)
    $cfg = $global:ST.Settings.api.nominatim
    $run = $global:ST.NominatimRun
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $cfg.enabled) { return (New-EndpointResult -Success $false -ErrorText 'Endpoint disabled' -ErrorKind 'Other') }
    $precision = [int]$cfg.coordinatePrecision
    $lat = [Math]::Round($Latitude, $precision)
    $lon = [Math]::Round($Longitude, $precision)
    $zoom = [int]$cfg.zoom
    $language = [string]$cfg.language

    # Cache first (3.2 section 5).
    $cached = Invoke-DbQuery 'SELECT * FROM GeoCache WHERE Latitude = @lat AND Longitude = @lon AND Zoom = @z AND Language = @l' @{ lat = $lat; lon = $lon; z = $zoom; l = $language }
    if ($cached.Count -gt 0) {
        $data = $null
        try { $data = ([string]$cached[0].Response | ConvertFrom-Json) } catch { }
        $result = Convert-NominatimResponse -Response $data -Place ([string]$cached[0].Place)
        $result | Add-Member -NotePropertyName FromCache -NotePropertyValue $true
        $result | Add-Member -NotePropertyName Latitude -NotePropertyValue $lat
        $result | Add-Member -NotePropertyName Longitude -NotePropertyValue $lon
        return (New-EndpointResult -Success $true -Data $result -DurationMs $watch.ElapsedMilliseconds)
    }
    if ($run.Blocked) { return (New-EndpointResult -Success $false -ErrorText 'Blocked by server in this run' -ErrorKind 'LimitReached') }
    if ($run.Requests -ge [int]$cfg.maxRequestsPerRun) { return (New-EndpointResult -Success $false -ErrorText 'maxRequestsPerRun reached' -ErrorKind 'LimitReached') }

    # At least minSecondsBetweenRequests between two requests, never in parallel.
    $minGap = [Math]::Max(1.0, [double]$cfg.minSecondsBetweenRequests)
    while (((Get-Date) - $run.LastRequest).TotalSeconds -lt $minGap) {
        Start-Sleep -Milliseconds 100
        [System.Windows.Forms.Application]::DoEvents()
    }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $url = '{0}/reverse?format=jsonv2&lat={1}&lon={2}&zoom={3}&addressdetails=1&accept-language={4}' -f `
        ([string]$cfg.baseUrl).TrimEnd('/'), $lat.ToString($inv), $lon.ToString($inv), $zoom, [uri]::EscapeDataString($language)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch { }
    $run.LastRequest = Get-Date
    $run.Requests++
    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.UserAgent = "SortingTool/$($global:ST.Version) (private photo sorting tool)"
        $request.Timeout = [int]$cfg.timeoutSeconds * 1000
        $request.ReadWriteTimeout = [int]$cfg.timeoutSeconds * 1000
        $request.Accept = 'application/json'
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            $reader.Dispose()
        }
        finally { $response.Close() }
    }
    catch [System.Net.WebException] {
        $ex = $_.Exception
        $kind = 'Offline'
        $message = $ex.Message
        if ($ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) { $kind = 'Timeout' }
        elseif ($ex.Response) {
            $code = [int]$ex.Response.StatusCode
            if ($code -eq 429 -or $code -eq 403) {
                # Stop all further requests in this run, no retry (3.2 section 6).
                $run.Blocked = $true
                $kind = 'LimitReached'
            }
            else { $kind = 'Other' }
            $message = "HTTP $code"
        }
        return (New-EndpointResult -Success $false -ErrorText $message -ErrorKind $kind -DurationMs $watch.ElapsedMilliseconds)
    }
    catch {
        return (New-EndpointResult -Success $false -ErrorText $_.Exception.Message -ErrorKind 'Other' -DurationMs $watch.ElapsedMilliseconds)
    }
    $data = $null
    try { $data = $text | ConvertFrom-Json } catch { return (New-EndpointResult -Success $false -ErrorText 'Invalid JSON' -ErrorKind 'InvalidResponse' -DurationMs $watch.ElapsedMilliseconds) }
    $place = ''
    if ($data.PSObject.Properties['address']) { $place = Get-NominatimPlace $data.address }
    [void](Invoke-DbExecute 'INSERT OR REPLACE INTO GeoCache (Latitude, Longitude, Zoom, Language, Response, Place, RetrievedAt) VALUES (@lat, @lon, @z, @l, @r, @p, @t)' `
            @{ lat = $lat; lon = $lon; z = $zoom; l = $language; r = $text; p = $place; t = (Get-NowText) })
    $result = Convert-NominatimResponse -Response $data -Place $place
    $result | Add-Member -NotePropertyName FromCache -NotePropertyValue $false
    $result | Add-Member -NotePropertyName Latitude -NotePropertyValue $lat
    $result | Add-Member -NotePropertyName Longitude -NotePropertyValue $lon
    return (New-EndpointResult -Success $true -Data $result -DurationMs $watch.ElapsedMilliseconds)
}

function Convert-NominatimResponse {
    param($Response, [string]$Place)
    $address = $null
    if ($Response -and $Response.PSObject.Properties['address']) { $address = $Response.address }
    $get = {
        param($name)
        if ($address -and $address.PSObject.Properties[$name]) { return [string]$address.$name }
        return ''
    }
    $display = ''
    if ($Response -and $Response.PSObject.Properties['display_name']) { $display = [string]$Response.display_name }
    $city = & $get 'city'
    if (-not $city) { $city = & $get 'town' }
    if (-not $city) { $city = & $get 'village' }
    if (-not $city) { $city = & $get 'municipality' }
    return [pscustomobject]@{
        Place       = $Place
        City        = $city
        Suburb      = (& $get 'suburb')
        County      = (& $get 'county')
        State       = (& $get 'state')
        Country     = (& $get 'country')
        CountryCode = (& $get 'country_code')
        DisplayName = $display
    }
}
