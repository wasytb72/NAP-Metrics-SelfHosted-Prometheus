param(
    [Parameter()]
    [string]$PrometheusUrl = 'http://localhost:9090',

    [Parameter()]
    [ValidateSet('query', 'query_range')]
    [string]$Mode = 'query',

    [Parameter(Mandatory = $true)]
    [string]$Query,

    [Parameter()]
    [string]$Time,

    [Parameter()]
    [string]$Start,

    [Parameter()]
    [string]$End,

    [Parameter()]
    [string]$Step = '30s',

    [Parameter()]
    [int]$TimeoutSec = 30,

    [Parameter()]
    [switch]$RawResponse,

    [Parameter()]
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-LabelsToString {
    param([hashtable]$Labels)

    if (-not $Labels -or $Labels.Count -eq 0) {
        return '{}'
    }

    $pairs = $Labels.GetEnumerator() |
        Sort-Object -Property Name |
        ForEach-Object { "{0}=`"{1}`"" -f $_.Name, $_.Value }

    return '{' + ($pairs -join ',') + '}'
}

$endpoint = "{0}/api/v1/{1}" -f $PrometheusUrl.TrimEnd('/'), $Mode
$params = @{
    query = $Query
}

if ($Mode -eq 'query') {
    if ($Time) {
        $params.time = $Time
    }
}
else {
    if (-not $Start -or -not $End) {
        throw "Mode 'query_range' requires both -Start and -End (RFC3339 or unix timestamp)."
    }
    $params.start = $Start
    $params.end = $End
    $params.step = $Step
}

$response = Invoke-RestMethod -Method Get -Uri $endpoint -Body $params -TimeoutSec $TimeoutSec

if ($response.status -ne 'success') {
    throw "Prometheus API returned status '$($response.status)'."
}

if ($RawResponse) {
    $response
    return
}

if ($AsJson) {
    $response | ConvertTo-Json -Depth 20
    return
}

$resultType = $response.data.resultType
$result = $response.data.result

Write-Host "Prometheus API: $endpoint"
Write-Host "Query: $Query"
Write-Host "ResultType: $resultType"

switch ($resultType) {
    'vector' {
        $rows = foreach ($item in $result) {
            $ts = [double]$item.value[0]
            [pscustomobject]@{
                Metric      = Convert-LabelsToString -Labels $item.metric
                Timestamp   = [DateTimeOffset]::FromUnixTimeSeconds([math]::Floor($ts)).UtcDateTime
                Value       = $item.value[1]
            }
        }

        if ($rows) {
            $rows | Format-Table -AutoSize
        }
        else {
            Write-Host 'No data points returned.'
        }
    }
    'matrix' {
        $rows = foreach ($item in $result) {
            $samples = @($item.values)
            $last = if ($samples.Count -gt 0) { $samples[$samples.Count - 1][1] } else { $null }
            [pscustomobject]@{
                Metric      = Convert-LabelsToString -Labels $item.metric
                Samples     = $samples.Count
                LastValue   = $last
            }
        }

        if ($rows) {
            $rows | Format-Table -AutoSize
        }
        else {
            Write-Host 'No data points returned.'
        }
    }
    'scalar' {
        $scalar = $response.data.result
        Write-Host ("Timestamp: {0}" -f ([DateTimeOffset]::FromUnixTimeSeconds([math]::Floor([double]$scalar[0])).UtcDateTime))
        Write-Host ("Value: {0}" -f $scalar[1])
    }
    'string' {
        $str = $response.data.result
        Write-Host ("Timestamp: {0}" -f ([DateTimeOffset]::FromUnixTimeSeconds([math]::Floor([double]$str[0])).UtcDateTime))
        Write-Host ("Value: {0}" -f $str[1])
    }
    default {
        Write-Host 'Unknown result type. Use -RawResponse or -AsJson to inspect full payload.'
    }
}
