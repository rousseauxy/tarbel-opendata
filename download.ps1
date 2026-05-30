# XML Downloader for Belgian Tariff Browser (TARBEL)
# Downloads XML tariff extractions from the Federal Public Service Finance website
# This site uses JavaServer Faces (JSF), requiring stateful form submissions

param(
  [string]$BaseUrl = "https://eservices.minfin.fgov.be/extTariffBrowser",
  [string]$OutputFolder = ".\Downloads",
  [string[]]$SkipFiles = @(),
  [switch]$DownloadDocumentation,
  [switch]$DownloadCurrencies,
  [switch]$Force,
  [switch]$Debug
)

# TLS 1.2+ is the default on .NET Core / PowerShell 7 — no explicit override needed
# [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Create output folder if it doesn't exist
if (-not (Test-Path $OutputFolder))
{
  New-Item -Path $OutputFolder -ItemType Directory | Out-Null
  Write-Host "Created output folder: $OutputFolder" -ForegroundColor Green
}

Write-Host "=== TARBEL XML Downloader ===" -ForegroundColor Cyan
Write-Host "Target: $BaseUrl/XmlExtractions`n" -ForegroundColor Gray

# Function to extract ViewState from JSF page (handles both full HTML and AJAX partial responses)
# Optionally scoped to a specific form ID to get that form's ViewState
function Get-JSFViewState
{
  param([string]$HtmlContent, [string]$FormId = $null)
    
  if ($FormId)
  {
    # Extract ViewState from a specific form by finding the form element first
    $escapedFormId = [regex]::Escape($FormId)
    if ($HtmlContent -match "(?s)<form[^>]*id=`"$escapedFormId`"[^>]*>.*?<input[^>]*name=`"javax\.faces\.ViewState`"[^>]*value=`"([^`"]+)`"[^>]*/>")
    {
      return $matches[1]
    }
  }
    
  # Standard HTML form input (full page response) - first match
  if ($HtmlContent -match 'javax\.faces\.ViewState[^>]*value="([^"]+)"')
  {
    return $matches[1]
  }
  # AJAX partial response: <update id="j_id1:javax.faces.ViewState:0"><![CDATA[...]]>
  if ($HtmlContent -match '(?s)javax\.faces\.ViewState[^>]*>\s*<!\[CDATA\[(.+?)\]\]>')
  {
    return $matches[1]
  }
  return $null
}

try
{
  $webClient = New-Object System.Net.WebClient
  $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    
  # Step 1a: Download static XML documentation if requested
  if ($DownloadDocumentation)
  {
    Write-Host "[1/1] Downloading XML documentation..." -ForegroundColor Cyan
    $docUrl = "$BaseUrl/FileResourceForHomePageServlet?fname=XML-Document.zip"
    $docPath = Join-Path $OutputFolder "XML-Document.zip"
        
    if ((Test-Path $docPath) -and -not $Force)
    {
      Write-Host "  Documentation already exists. Use -Force to overwrite." -ForegroundColor Yellow
    }
    else
    {
      try
      {
        Invoke-WebRequest -Uri $docUrl -OutFile $docPath -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -ErrorAction Stop
        $fileSize = (Get-Item $docPath).Length / 1KB
        Write-Host "  Downloaded: $([math]::Round($fileSize, 2)) KB" -ForegroundColor Green
      }
      catch
      {
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
      }
    }
    Write-Host "`nComplete!" -ForegroundColor Green
    return
  }

  # Step 1b: Download listed_currencies.xlsx if requested
  if ($DownloadCurrencies)
  {
    Write-Host "[1/1] Downloading listed_currencies.xlsx..." -ForegroundColor Cyan
    $xlsxUrl = "$BaseUrl/FileResourceForHomePageServlet?fname=listed_currencies.xlsx&lang=EN"
    $xlsxPath = Join-Path $OutputFolder "listed_currencies.xlsx"

    if ((Test-Path $xlsxPath) -and -not $Force)
    {
      Write-Host "  listed_currencies.xlsx already exists. Use -Force to overwrite." -ForegroundColor Yellow
    }
    else
    {
      try
      {
        Invoke-WebRequest -Uri $xlsxUrl -OutFile $xlsxPath -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -ErrorAction Stop
        $fileSize = (Get-Item $xlsxPath).Length / 1KB
        Write-Host "  Downloaded: $([math]::Round($fileSize, 2)) KB" -ForegroundColor Green
      }
      catch
      {
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
      }
    }
    Write-Host "`nComplete!" -ForegroundColor Green
    return
  }
    
  # Step 2: Get initial page to extract ViewState
  Write-Host "[1/3] Loading initial page and extracting form data..." -ForegroundColor Cyan
  $currentDate = Get-Date -Format "yyyyMMdd"
  $response = Invoke-WebRequest -Uri "$BaseUrl/XmlExtractions?date=$currentDate&lang=EN" -UseBasicParsing -SessionVariable session -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36" -ErrorAction Stop
    
  if ($Debug)
  {
    $response.Content | Out-File "$env:TEMP\initial-page.html" -Encoding UTF8
    Write-Host "  DEBUG: Initial page saved to $env:TEMP\initial-page.html" -ForegroundColor Magenta
  }
    
  $viewState = Get-JSFViewState -HtmlContent $response.Content
  if (-not $viewState)
  {
    throw "Could not extract JSF ViewState from page"
  }
    
  # Extract jsessionid from form action URL - required for correct server-side routing
  $formActionUrl = $null
  if ($response.Content -match 'action="(/extTariffBrowser/XmlExtractions;jsessionid=[^"]+)"')
  {
    $formActionUrl = "https://eservices.minfin.fgov.be$($matches[1])"
  }
  if (-not $formActionUrl)
  {
    $formActionUrl = "$BaseUrl/XmlExtractions"
  }
  if ($Debug)
  {
    Write-Host "  DEBUG: Form action URL: $formActionUrl" -ForegroundColor Magenta
  }
    
  Write-Host "  Successfully extracted form state" -ForegroundColor Green
  Write-Host "  Session established" -ForegroundColor Green
    
  # Step 3: Search for this month's available files
  $searchYear = (Get-Date).Year
  $searchMonth = (Get-Date).Month
  $monthStr = $searchMonth.ToString('00')

  Write-Host "`n[2/3] Searching for Year: $searchYear, Month: $monthStr..." -ForegroundColor Cyan

  $allDownloadLinks = @()

  try
  {
    Write-Host "  Searching: $searchYear-$monthStr..." -NoNewline

    # Access the page with URL parameters
    $searchUrl = "$BaseUrl/XmlExtractions?date=$currentDate&lang=EN&page=1&searchMonth=$monthStr&searchYear=$searchYear"
    $searchResponse = Invoke-WebRequest -Uri $searchUrl `
      -WebSession $session `
      -UseBasicParsing `
      -ErrorAction Stop
                
    # Update form action URL from this page (ensures jsessionid is current)
    if ($searchResponse.Content -match 'action="(/extTariffBrowser/XmlExtractions;jsessionid=[^"]+)"')
    {
      $formActionUrl = "https://eservices.minfin.fgov.be$($matches[1])"
    }
                
    # Extract ViewState and AJAX status form ID from the page
    $viewState = Get-JSFViewState -HtmlContent $searchResponse.Content
                
    # Look for the AJAX status form trigger (e.g., j_idt204:ajaxStatusForm:j_idt205)
    $ajaxSourceId = $null
    if ($searchResponse.Content -match '(j_idt\d+):ajaxStatusForm:(j_idt\d+)')
    {
      $ajaxSourceId = "$($matches[1]):ajaxStatusForm:$($matches[2])"
      $ajaxFormId = "$($matches[1]):ajaxStatusForm"
                    
      if ($Debug)
      {
        Write-Host "`n    DEBUG: Found AJAX source: $ajaxSourceId" -ForegroundColor Magenta
      }
                    
      # Step 2: Submit the AJAX POST to load the results
      # IMPORTANT: Only submit the ajaxStatusForm fields (NOT xmlExtractionsControllerForm)
      # The browser's PrimeFaces.ab({f:"ajaxStatusForm"}) only submits the ajaxStatusForm
      # Year/month come from the ViewState (stored in @ViewScoped bean state)
      # Use the ajaxStatusForm's own ViewState for authenticity
      $ajaxFormViewState = Get-JSFViewState -HtmlContent $searchResponse.Content -FormId $ajaxFormId
      if (-not $ajaxFormViewState)
      {
        $ajaxFormViewState = $viewState  # fallback to first ViewState
      }
                    
      $ajaxBody = @{
        'javax.faces.partial.ajax'    = 'true'
        'javax.faces.source'          = $ajaxSourceId
        'javax.faces.partial.execute' = $ajaxSourceId
        'javax.faces.partial.render'  = 'xmlExtractionsControllerForm:resultsContainer xmlExtractionsControllerForm:downloadBtn'
        $ajaxSourceId                 = $ajaxSourceId
        $ajaxFormId                   = $ajaxFormId
        'javax.faces.ViewState'       = $ajaxFormViewState
      }
                    
      $ajaxHeaders = @{
        'Faces-Request'    = 'partial/ajax'
        'X-Requested-With' = 'XMLHttpRequest'
      }
                    
      $ajaxResponse = Invoke-WebRequest -Uri $formActionUrl `
        -Method Post `
        -Body $ajaxBody `
        -Headers $ajaxHeaders `
        -ContentType "application/x-www-form-urlencoded; charset=UTF-8" `
        -WebSession $session `
        -UseBasicParsing `
        -ErrorAction Stop
                    
      # Use AJAX response for parsing results and updated ViewState
      $searchResponse = $ajaxResponse
                    
      if ($Debug)
      {
        Write-Host "    DEBUG: AJAX sent to: $formActionUrl" -ForegroundColor Magenta
        Write-Host "    DEBUG: AJAX ViewState used: $($ajaxFormViewState.Substring(0,20))..." -ForegroundColor Magenta
      }
                    
    }
                
    # Debug: Save response to file if Debug flag is set
    if ($Debug)
    {
      $debugFile = "$env:TEMP\ajax-response-$searchYear-$monthStr.html"
      $searchResponse.Content | Out-File $debugFile -Encoding UTF8
      Write-Host "`n    DEBUG: Response saved to $debugFile" -ForegroundColor Magenta
      Write-Host "    DEBUG: Has ui-datatable: $($searchResponse.Content -match 'ui-datatable')" -ForegroundColor Magenta
      Write-Host "    DEBUG: Has 'No search results': $($searchResponse.Content -match 'No search results')" -ForegroundColor Magenta
    }
                
    # Check if search returned actual results
    # Look for the datatable which appears when results exist
    if ($searchResponse.Content -notmatch 'ui-datatable' -or $searchResponse.Content -match 'No search results')
    {
      Write-Host " No files found" -ForegroundColor Gray
    }
    else
    {
      # Extract download button IDs and filenames from the datatable
      # Pattern: <a id="...downloadXmlBtn"...>filename.zip</a>
      $pattern = '<a\s+id="(xmlExtractionsControllerForm:j_idt\d+:\d+:downloadXmlBtn)"[^>]*>([^<]+\.zip)</a>'
      $matches = [regex]::Matches($searchResponse.Content, $pattern)
                    
      if ($Debug -and $matches.Count -gt 0)
      {
        Write-Host "`n    DEBUG: Found $($matches.Count) matches with pattern" -ForegroundColor Magenta
        Write-Host "    DEBUG: First match: $($matches[0].Groups[2].Value)" -ForegroundColor Magenta
      }
                    
      if ($matches.Count -gt 0)
      {
        Write-Host " Found $($matches.Count) file(s)" -ForegroundColor Green
        foreach ($match in $matches)
        {
          $buttonId = $match.Groups[1].Value
          $fileName = $match.Groups[2].Value
          $allDownloadLinks += @{
            FileName = $fileName
            ButtonId = $buttonId
            Year     = $searchYear
            Month    = $monthStr
          }
        }
      }
      else
      {
        Write-Host " No extraction files found" -ForegroundColor Gray
      }
    }
                
    # Update ViewState for next request
    $newViewState = Get-JSFViewState -HtmlContent $searchResponse.Content
    if ($newViewState)
    {
      $viewState = $newViewState
    }

  }
  catch
  {
    Write-Host " Error: $($_.Exception.Message)" -ForegroundColor Red
  }

  if ($allDownloadLinks.Count -eq 0)
  {
    Write-Host "`nNo download links found for $searchYear-$monthStr." -ForegroundColor Yellow
    Write-Host "The minfin portal may not have published a new extraction for this month yet." -ForegroundColor Yellow
    return
  }
    
  if ($Debug)
  {
    Write-Host "`nDEBUG: Session cookies after search:" -ForegroundColor Magenta
    $session.Cookies.GetCookies("https://eservices.minfin.fgov.be") | ForEach-Object {
      Write-Host "  Cookie: $($_.Name) = $($_.Value)" -ForegroundColor Magenta
    }
  }
    
  # Step 4: Download all found files
  Write-Host "`n[3/3] Downloading $($allDownloadLinks.Count) file(s)..." -ForegroundColor Cyan
  $downloaded = 0
  $skipped = 0
  $failed = 0
    
  foreach ($link in $allDownloadLinks)
  {
    $outputPath = Join-Path $OutputFolder $link.FileName
        
    Write-Host "`n  [$($link.Year)-$($link.Month)] $($link.FileName)" -ForegroundColor Cyan
        
    if (-not $Force -and ($SkipFiles -contains $link.FileName))
    {
      Write-Host "    Already uploaded to release, skipping" -ForegroundColor Gray
      $skipped++
    }
    elseif ((Test-Path $outputPath) -and -not $Force)
    {
      Write-Host "    Already exists locally (use -Force to overwrite)" -ForegroundColor Yellow
      $skipped++
    }
    else
    {
      try
      {
        # PrimeFaces monitorDownload sets primefaces.download cookie before submitting form
        $session.Cookies.Add((New-Object System.Net.Cookie("primefaces.download", "null", "/", "eservices.minfin.fgov.be")))
                
        # Download POST must mimic a full browser navigation (not AJAX)
        # Form body must include yearField, monthField, button name=value
        $encodedButtonId = [uri]::EscapeDataString($link.ButtonId)
        $encodedViewState = [uri]::EscapeDataString($viewState)
        $formBody = "xmlExtractionsControllerForm=xmlExtractionsControllerForm" `
          + "&xmlExtractionsControllerForm%3AyearField=$($link.Year)" `
          + "&xmlExtractionsControllerForm%3AmonthField=$($link.Month)" `
          + "&javax.faces.partial.ajax=false" `
          + "&javax.faces.ViewState=$encodedViewState" `
          + "&$encodedButtonId=$encodedButtonId"
                
        # Navigation headers (not AJAX) - critical for getting file download instead of XML partial response
        $downloadHeaders = @{
          'Accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7'
          'Cache-Control'             = 'max-age=0'
          'Origin'                    = 'https://eservices.minfin.fgov.be'
          'Referer'                   = "$BaseUrl/XmlExtractions?date=$currentDate&lang=EN&page=1&searchMonth=$($link.Month)&searchYear=$($link.Year)"
          'Sec-Fetch-Dest'            = 'document'
          'Sec-Fetch-Mode'            = 'navigate'
          'Sec-Fetch-Site'            = 'same-origin'
          'Sec-Fetch-User'            = '?1'
          'Upgrade-Insecure-Requests' = '1'
        }
        # REMOVE any AJAX-related headers that might be inherited
        $session.Headers.Remove('X-Requested-With') | Out-Null
        $session.Headers.Remove('Faces-Request') | Out-Null
                
        # POST to the form action URL with jsessionid (exactly as the browser does)
        if ($Debug)
        {
          Write-Host "    DEBUG: ViewState prefix: $($viewState.Substring(0,30))..." -ForegroundColor Magenta
          Write-Host "    DEBUG: Form action URL: $formActionUrl" -ForegroundColor Magenta
          Write-Host "    DEBUG: Button ID: $($link.ButtonId)" -ForegroundColor Magenta
        }
        $tempResponse = Invoke-WebRequest -Uri $formActionUrl `
          -Method Post `
          -Headers $downloadHeaders `
          -ContentType 'application/x-www-form-urlencoded' `
          -Body $formBody `
          -WebSession $session `
          -UseBasicParsing `
          -MaximumRedirection 0 `
          -ErrorAction SilentlyContinue
                
        # Check Content-Type to see if we got a file download
        $contentType = $tempResponse.Headers['Content-Type']
        if ($Debug)
        {
          Write-Host "    DEBUG: Status: $($tempResponse.StatusCode)" -ForegroundColor Magenta
          Write-Host "    DEBUG: Content-Type: $contentType" -ForegroundColor Magenta
          Write-Host "    DEBUG: All response headers:" -ForegroundColor Magenta
          $tempResponse.Headers | ForEach-Object { $_.GetEnumerator() | ForEach-Object { Write-Host "      $($_.Key): $($_.Value)" -ForegroundColor Magenta } }
        }
                
        if ($contentType -like '*application/zip*' -or $contentType -like '*application/octet-stream*')
        {
          # We got a file! Save it
          [System.IO.File]::WriteAllBytes($outputPath, $tempResponse.Content)
                    
          $fileSize = (Get-Item $outputPath).Length / 1KB
          Write-Host "    Downloaded: $([math]::Round($fileSize, 2)) KB" -ForegroundColor Green
          $downloaded++
          # Reset MaximumRedirection so subsequent GET requests can follow redirects normally
          $session.MaximumRedirection = -1
        }
        else
        {
          # Not a file download
          if ($Debug)
          {
            $debugDownloadFile = "$env:TEMP\download-response-$($link.FileName).html"
            $tempResponse.Content | Out-File $debugDownloadFile -Encoding UTF8
            Write-Host "    DEBUG: Non-file response saved to $debugDownloadFile" -ForegroundColor Magenta
          }
          throw "Received $contentType instead of file download"
        }
      }
      catch
      {
        Write-Host "    Failed: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
      }
    }
  }  # end foreach (individual downloads)
    
  # Summary
  Write-Host "`n=== Summary ===" -ForegroundColor Cyan
  Write-Host "Downloaded: $downloaded file(s)" -ForegroundColor Green
  if ($skipped -gt 0) { Write-Host "Skipped: $skipped file(s)" -ForegroundColor Yellow }
  if ($failed -gt 0) { Write-Host "Failed: $failed file(s)" -ForegroundColor Red }
  Write-Host "Location: $OutputFolder" -ForegroundColor Gray
    
}
catch
{
  Write-Host "`nError:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
    
  if ($_.Exception.Response)
  {
    Write-Host "Status Code: $($_.Exception.Response.StatusCode.Value__)" -ForegroundColor Red
  }
}

# Script usage information
<#
.SYNOPSIS
    Downloads XML tariff extractions from Belgian Federal Public Service Finance

.DESCRIPTION
    This script interacts with the TARBEL (Tariff Browser Belgium) JSF application
    to search and download XML tariff data for specified year/month periods.

.PARAMETER BaseUrl
    The base URL of the tariff browser (default: https://eservices.minfin.fgov.be/extTariffBrowser)

.PARAMETER OutputFolder
    Directory to save downloaded files (default: .\Downloads)

.PARAMETER DownloadDocumentation
    Download only the static XML documentation file

.PARAMETER Force
    Overwrite existing files

.EXAMPLE
    .\xml-downloader.ps1
    Downloads XML files for current year and month

.EXAMPLE
    .\xml-downloader.ps1 -DownloadDocumentation
    Downloads only the XML documentation file
#>
