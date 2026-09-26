# Helpers for the Second Key half of the bench: the sk command line, the recording proxy,
# scripted browser sessions and HTML forms. Dot-source NopBench.Common.ps1 first; this file
# only defines functions.
#
# Same compatibility contract as NopBench.Common.ps1: Windows PowerShell 5.1 and
# PowerShell 7+, ASCII only.

# --- The chain's tools --------------------------------------------------------------

function Resolve-BenchChainTool {
    # Path of a chain tool's entry assembly: the environment variable first, then the folder
    # the chain-tools CI artifact (or a local build) is unpacked into:
    #   <work>\tools\chain\secondkey\SecondKey.Cli.dll    (NOPBENCH_SK)
    #   <work>\tools\chain\portcullis\Portcullis.Cli.dll  (NOPBENCH_PORTCULLIS)
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][ValidateSet('secondkey', 'portcullis')][string] $Name
    )
    if ($Name -eq 'secondkey') { $variable = 'NOPBENCH_SK'; $assembly = 'SecondKey.Cli.dll' }
    else { $variable = 'NOPBENCH_PORTCULLIS'; $assembly = 'Portcullis.Cli.dll' }
    $path = [System.Environment]::GetEnvironmentVariable($variable)
    if (-not $path) { $path = Join-Path (Join-Path (Join-Path (Join-Path $WorkRoot 'tools') 'chain') $Name) $assembly }
    if (-not (Test-Path -LiteralPath $path)) {
        throw ('{0} not found at {1}. Build it from the commit pinned in pins.json (scripts/README.md, "The chain''s tools") or set {2}.' -f $assembly, $path, $variable)
    }
    Assert-BenchCommand -Name 'dotnet' -Hint 'Install the .NET 10 runtime or SDK (https://dot.net).'
    return (Get-BenchFullPath $path)
}

function Invoke-BenchChainTool {
    # Runs a chain tool (dotnet <assembly> <arguments>) with its output streamed to the host,
    # and returns its exit code. Anything outside -SuccessExitCodes throws: the exit codes of
    # sk are its interface (docs/cli.md in the core repository), so a caller lists exactly
    # the ones it accepts.
    param(
        [Parameter(Mandatory = $true)][string] $Tool,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [int[]] $SuccessExitCodes = @(0)
    )
    return (Invoke-BenchNative -FilePath 'dotnet' -ArgumentList (@($Tool) + $Arguments) -SuccessExitCodes $SuccessExitCodes -PassThru)
}

function ConvertTo-BenchCommandLine {
    # Quotes arguments for Start-Process, which joins an argument array with spaces and
    # quotes nothing on Windows PowerShell 5.1.
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"{0}"' -f ($argument -replace '"', '\"') } else { $argument }
    }
    return ($quoted -join ' ')
}

# --- The recording proxy ------------------------------------------------------------

function Start-BenchCapture {
    # Starts `sk capture` in the background and waits until it is recording. The proxy
    # tags every exchange with the session named by the -SessionKey request header, which
    # the traffic scripts set to the scenario id: one scenario, one replayed session.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a child process that the calling runbook script owns and stops; there is nothing to confirm.')]
    param(
        [Parameter(Mandatory = $true)][string] $Sk,
        [Parameter(Mandatory = $true)][string] $Listen,
        [Parameter(Mandatory = $true)][string] $Target,
        [Parameter(Mandatory = $true)][string] $Out,
        [Parameter(Mandatory = $true)][string] $SessionKey,
        [Parameter(Mandatory = $true)][string] $LogPath,
        [int] $TimeoutSeconds = 60
    )
    foreach ($file in @($Out, $LogPath, "$LogPath.err")) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath)
    $arguments = ConvertTo-BenchCommandLine -Arguments @($Sk, 'capture', '--listen', $Listen, '--target', $Target, '--out', $Out, '--session-key', $SessionKey)
    Write-BenchLog ('> dotnet {0}' -f $arguments)
    $process = Start-Process -FilePath 'dotnet' -ArgumentList $arguments -RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.err" -PassThru -NoNewWindow
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $log = ''
        if (Test-Path -LiteralPath $LogPath) { $log = Read-BenchSharedText -Path $LogPath }
        if ($log -match 'sk capture: recording') { break }
        if ($process.HasExited -or (Get-Date) -ge $deadline) {
            $errors = ''
            if (Test-Path -LiteralPath "$LogPath.err") { $errors = Read-BenchSharedText -Path "$LogPath.err" }
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            throw ('sk capture did not start recording within {0} s. Output: {1} {2}' -f $TimeoutSeconds, $log.Trim(), $errors.Trim())
        }
        Start-Sleep -Milliseconds 500
    }
    Write-BenchLog ('Recording proxy {0} -> {1} into {2} (process {3})' -f $Listen, $Target, $Out, $process.Id)
    return $process
}

function Read-BenchSharedText {
    # Reads a file another process still has open for writing.
    param([Parameter(Mandatory = $true)][string] $Path)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-BenchCaptureCount {
    # The number of exchanges a *.skcap holds so far (one JSON line each after the header).
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $lines = (Read-BenchSharedText -Path $Path) -split "`n"
    return @($lines | Where-Object { $_ -match '^\{"type":"http\.exchange"' }).Count
}

function Stop-BenchCapture {
    # Stops the recording proxy once it has written every exchange the traffic scripts sent
    # through it. The proxy flushes each exchange to disk as it is written, so stopping the
    # process afterwards loses nothing; waiting for the count first closes the gap between
    # a client receiving its answer and the proxy appending that exchange.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops the child process Start-BenchCapture started for the same script.')]
    param(
        [Parameter(Mandatory = $true)] $Process,
        [Parameter(Mandatory = $true)][string] $Out,
        [Parameter(Mandatory = $true)][int] $Expected,
        [string] $LogPath,
        [int] $TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $count = Get-BenchCaptureCount -Path $Out
    while ($count -lt $Expected -and -not $Process.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $count = Get-BenchCaptureCount -Path $Out
    }
    $exited = $Process.HasExited
    if (-not $exited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $null = $Process.WaitForExit(15000)
    }
    $count = Get-BenchCaptureCount -Path $Out
    if ($exited -and $LogPath -and (Test-Path -LiteralPath $LogPath)) { Get-Content -LiteralPath $LogPath | Out-Host }
    if ($count -ne $Expected) {
        throw ('The capture holds {0} exchange(s), but {1} request(s) were sent through the proxy. A request the legacy system did not answer is not recorded, and a request from anything else is not ours; either way the recording is not the traffic that was scripted.' -f $count, $Expected)
    }
    Write-BenchLog ('Capture complete: {0} exchanges in {1}' -f $count, $Out)
}

function Get-BenchSessionId {
    # The session id `sk capture` gives the exchanges of one scenario: "s-" and the first 12
    # hex digits of SHA-256("<key>`n<value>") (SessionTracker in the core repository). The
    # verdict names scenarios by this id; the traffic scripts print the mapping.
    param(
        [Parameter(Mandatory = $true)][string] $Key,
        [Parameter(Mandatory = $true)][string] $Value
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(('{0}{1}{2}' -f $Key, "`n", $Value)))
    }
    finally {
        $sha.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return ('s-{0}' -f $hex.Substring(0, 12))
}

# --- Scripted sessions --------------------------------------------------------------

function New-BenchSession {
    # One browser session of one scenario: its own cookie jar, and every request tagged with
    # the scenario id in the -HeaderName header (the capture's session key).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object; changes no system state.')]
    param(
        [Parameter(Mandatory = $true)][string] $BaseUrl,
        [Parameter(Mandatory = $true)][string] $Scenario,
        [Parameter(Mandatory = $true)][string] $HeaderName,
        [int] $TimeoutSeconds = 300
    )
    $client = New-BenchHttpClient -TimeoutSeconds $TimeoutSeconds
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation($HeaderName, $Scenario)
    return [pscustomobject]@{
        Client   = $client
        BaseUrl  = $BaseUrl.TrimEnd('/')
        Scenario = $Scenario
        Requests = 0
    }
}

function Invoke-BenchStep {
    # One request of a scenario, with what the scenario needs it to answer. A step that does
    # not get the answer it needs throws: a recording of a scenario that never reached what
    # it was written to exercise is not evidence of anything.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)][string] $Path,
        [ValidateSet('GET', 'POST')][string] $Method = 'GET',
        [System.Collections.IDictionary] $Form,
        $FormPairs,
        [System.Collections.IDictionary] $Headers,
        [int[]] $ExpectStatus = @(200),
        [string[]] $MustContain = @(),
        [string[]] $MustNotContain = @(),
        [string] $ExpectContentType,
        [string] $ExpectLocation
    )
    if (-not $Path.StartsWith('/')) { throw ('A step path starts with "/": {0}' -f $Path) }
    $parameters = @{ Client = $Session.Client; Uri = ($Session.BaseUrl + $Path); Method = $Method }
    if ($Form) { $parameters['Form'] = $Form }
    if ($null -ne $FormPairs) { $parameters['FormPairs'] = $FormPairs }
    if ($Headers) { $parameters['Headers'] = $Headers }
    try {
        $response = Invoke-BenchHttp @parameters
    }
    finally {
        # Counted even when the transport failed: the proxy may still have recorded it.
        $Session.Requests++
    }
    $shown = $Path
    if ($shown.Length -gt 90) { $shown = $shown.Substring(0, 87) + '...' }
    $detail = '{0} {1}' -f $response.ContentType, $response.Length
    if ($response.Location) { $detail = 'Location {0}' -f $response.Location }
    Write-BenchLog ('  {0,-5} {1,-4} {2} -> {3} ({4}, {5} ms)' -f $Session.Scenario, $Method, $shown, $response.StatusCode, $detail, $response.Ms)

    $problems = New-Object System.Collections.Generic.List[string]
    if ($ExpectStatus -notcontains $response.StatusCode) { $problems.Add(('status {0}, expected {1}' -f $response.StatusCode, ($ExpectStatus -join ' or '))) }
    foreach ($text in $MustContain) {
        if ($response.Body.IndexOf($text, [System.StringComparison]::Ordinal) -lt 0) { $problems.Add(('missing "{0}"' -f $text)) }
    }
    foreach ($text in $MustNotContain) {
        if ($response.Body.IndexOf($text, [System.StringComparison]::Ordinal) -ge 0) { $problems.Add(('unexpected "{0}"' -f $text)) }
    }
    if ($ExpectContentType -and $response.ContentType -ne $ExpectContentType) { $problems.Add(('content type {0}, expected {1}' -f $response.ContentType, $ExpectContentType)) }
    if ($ExpectLocation -and "$($response.Location)" -notmatch $ExpectLocation) { $problems.Add(('Location "{0}" does not match {1}' -f $response.Location, $ExpectLocation)) }
    if ($problems.Count -gt 0) {
        $excerpt = $response.Body
        if ($excerpt.Length -gt 600) { $excerpt = $excerpt.Substring(0, 600) + '...' }
        Write-BenchLog ('  answer excerpt: {0}' -f ($excerpt -replace '\s+', ' '))
        throw ('{0}: {1} {2}: {3}' -f $Session.Scenario, $Method, $Path, ($problems -join '; '))
    }
    return $response
}

function Get-BenchLocationPath {
    # The path and query of a redirect, so the next request goes through the same proxy
    # rather than to whatever host the legacy system put in the Location header.
    param([Parameter(Mandatory = $true)][string] $Location)
    $uri = $null
    if ([System.Uri]::TryCreate($Location, [System.UriKind]::Absolute, [ref] $uri) -and $uri.Scheme -match '^https?$') { return $uri.PathAndQuery }
    return $Location
}

# --- HTML forms ---------------------------------------------------------------------

function Get-BenchTagAttribute {
    # The attributes of one start tag as a case-insensitive hashtable; values HTML-decoded,
    # attributes without a value (checked, selected, disabled) map to an empty string.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Tag)
    $attributes = @{}
    foreach ($match in [regex]::Matches($Tag, '([^\s=/>"'']+)(?:\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>"'']+)))?')) {
        $name = $match.Groups[1].Value.ToLowerInvariant()
        if ($attributes.ContainsKey($name)) { continue }
        $value = ''
        foreach ($group in 2, 3, 4) { if ($match.Groups[$group].Success) { $value = $match.Groups[$group].Value } }
        $attributes[$name] = [System.Net.WebUtility]::HtmlDecode($value)
    }
    return $attributes
}

function Get-BenchForm {
    # The fields a browser submits for one form of a page, in document order: named inputs
    # (checkboxes and radio buttons only when checked; no buttons or file inputs), the
    # selected options of each select (the first option when none is selected), and each
    # textarea. Disabled controls are left out. The form is the first whose start tag
    # matches -FormPattern (a regex over the tag, e.g. 'id="product-details-form"').
    # Buttons are left out on purpose: which submit button was "pressed" is the caller's
    # decision (Add-BenchFormField).
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Html,
        [Parameter(Mandatory = $true)][string] $FormPattern
    )
    $start = [regex]::Match($Html, ('(?is)<form\b(?=[^>]*{0})[^>]*>' -f $FormPattern))
    if (-not $start.Success) { throw ('No form matching {0} on the page.' -f $FormPattern) }
    $end = $Html.IndexOf('</form>', $start.Index + $start.Length, [System.StringComparison]::OrdinalIgnoreCase)
    if ($end -lt 0) { $end = $Html.Length }
    $form = $Html.Substring($start.Index + $start.Length, $end - $start.Index - $start.Length)

    $fields = New-BenchFormFieldList
    $controls = '(?is)<input\b(?<a>[^>]*)>|<select\b(?<a>[^>]*)>(?<inner>.*?)</select>|<textarea\b(?<a>[^>]*)>(?<inner>.*?)</textarea>'
    foreach ($control in [regex]::Matches($form, $controls)) {
        $attributes = Get-BenchTagAttribute -Tag $control.Groups['a'].Value
        $name = $attributes['name']
        if (-not $name -or $attributes.ContainsKey('disabled')) { continue }
        $tagName = [regex]::Match($control.Value, '^<(\w+)').Groups[1].Value.ToLowerInvariant()
        if ($tagName -eq 'input') {
            $type = 'text'
            if ($attributes['type']) { $type = $attributes['type'].ToLowerInvariant() }
            if (@('submit', 'button', 'image', 'reset', 'file') -contains $type) { continue }
            $value = ''
            if ($attributes.ContainsKey('value')) { $value = $attributes['value'] }
            elseif (@('checkbox', 'radio') -contains $type) { $value = 'on' }
            if (@('checkbox', 'radio') -contains $type -and -not $attributes.ContainsKey('checked')) { continue }
            $fields.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList $name, $value))
        }
        elseif ($tagName -eq 'select') {
            $options = @([regex]::Matches($control.Groups['inner'].Value, '(?is)<option\b(?<a>[^>]*)>(?<text>.*?)(?=</option>|<option\b|$)'))
            $chosen = @()
            $first = $null
            for ($i = 0; $i -lt $options.Count; $i++) {
                $optionAttributes = Get-BenchTagAttribute -Tag $options[$i].Groups['a'].Value
                if ($optionAttributes.ContainsKey('value')) { $optionValue = $optionAttributes['value'] }
                else { $optionValue = [System.Net.WebUtility]::HtmlDecode(($options[$i].Groups['text'].Value -replace '<[^>]+>', '')).Trim() }
                if ($optionAttributes.ContainsKey('selected')) { $chosen += , $optionValue }
                if ($i -eq 0) { $first = $optionValue }
            }
            if ($chosen.Count -eq 0 -and -not $attributes.ContainsKey('multiple') -and $options.Count -gt 0) { $chosen = @($first) }
            foreach ($value in $chosen) { $fields.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList $name, $value)) }
        }
        else {
            # A newline right after <textarea> is not part of its value.
            $text = [System.Net.WebUtility]::HtmlDecode(($control.Groups['inner'].Value -replace '^\r?\n', ''))
            $fields.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList $name, $text))
        }
    }
    return , $fields
}

function Set-BenchFormField {
    # Gives a field one value: its first occurrence is replaced (later ones removed), or the
    # field is appended when the form did not have it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory list of form fields; no system state.')]
    param(
        [Parameter(Mandatory = $true)] $Fields,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value
    )
    $index = -1
    for ($i = $Fields.Count - 1; $i -ge 0; $i--) {
        if ($Fields[$i].Key -ceq $Name) {
            if ($index -ge 0) { $Fields.RemoveAt($index) }
            $index = $i
        }
    }
    $pair = New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList $Name, $Value
    if ($index -ge 0) { $Fields[$index] = $pair } else { $Fields.Add($pair) }
}

function Add-BenchFormField {
    # Appends a field, e.g. the submit button a browser would send.
    param(
        [Parameter(Mandatory = $true)] $Fields,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value
    )
    $Fields.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList $Name, $Value))
}

function Remove-BenchFormField {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory list of form fields; no system state.')]
    param(
        [Parameter(Mandatory = $true)] $Fields,
        [Parameter(Mandatory = $true)][string] $Name
    )
    for ($i = $Fields.Count - 1; $i -ge 0; $i--) { if ($Fields[$i].Key -ceq $Name) { $Fields.RemoveAt($i) } }
}

function Get-BenchFormField {
    # The first value of a field, or $null.
    param(
        [Parameter(Mandatory = $true)] $Fields,
        [Parameter(Mandatory = $true)][string] $Name
    )
    foreach ($pair in $Fields) { if ($pair.Key -ceq $Name) { return $pair.Value } }
    return $null
}
