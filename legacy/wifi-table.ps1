param(
    [switch]$NoPrompt
)

function Test-IsNetshPermissionError {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return (
        $Text -match 'location permission' -or
        $Text -match 'Location services' -or
        $Text -match 'requires elevation' -or
        $Text -match 'administrator' -or
        $Text -match '位置情報' -or
        $Text -match '位置情報サービス' -or
        $Text -match '管理者' -or
        $Text -match '昇格'
    )
}

function Show-NetshPermissionError {
    param(
        [string]$RawText
    )

    Write-Error @"
Wi-Fi の詳細を取得できませんでした。

Windows 側で WLAN の詳細表示が制限されています。次の 2 点を確認してください。
- 位置情報サービスを有効にする
- PowerShell を管理者として実行する

設定画面を開くコマンド:
  start ms-settings:privacy-location

netsh の応答:
$RawText
"@
    exit 1
}

function Get-BandFromChannel {
    param(
        [int]$channel
    )

    if ($channel -ge 1 -and $channel -le 14) {
        return '2.4GHz'
    }

    if ($channel -ge 15 -and $channel -le 177) {
        return '5GHz'
    }

    if ($channel -ge 178) {
        return '6GHz'
    }

    return $null
}

function Get-RadioTypeWeight {
    param(
        [string]$radioType
    )

    switch ($radioType) {
        '802.11be' { return 25 }
        '802.11ax' { return 20 }
        '802.11ac' { return 14 }
        '802.11n' { return 8 }
        '802.11g' { return 3 }
        '802.11a' { return 2 }
        '802.11b' { return 0 }
        default { return 0 }
    }
}

function Get-BandWeight {
    param(
        [string]$band
    )

    switch ($band) {
        '6GHz' { return 12 }
        '5GHz' { return 8 }
        '2.4GHz' { return 0 }
        default { return 0 }
    }
}

function Get-CurrentConnection {
    $interfaceRaw = netsh wlan show interfaces 2>&1

    if (-not $interfaceRaw) {
        return $null
    }

    $interfaceName = $null
    $state = $null
    $connectedSsid = $null
    $connectedBssid = $null

    foreach ($line in $interfaceRaw) {
        $trimmed = ([string]$line).Trim()

        if (-not $trimmed) {
            continue
        }

        if ($null -eq $interfaceName -and $trimmed -match '^(?:Name|名前)\s*:\s*(.+)$') {
            $interfaceName = $matches[1].Trim()
            continue
        }

        if ($null -eq $state -and $trimmed -match '^(?:State|状態)\s*:\s*(.+)$') {
            $state = $matches[1].Trim()
            continue
        }

        if ($null -eq $connectedBssid -and $trimmed -match '^BSSID\s*:\s*(.+)$') {
            $connectedBssid = $matches[1].Trim()
            continue
        }

        if ($null -eq $connectedSsid -and
            $trimmed -match '^SSID\s*:\s*(.+)$' -and
            $trimmed -notmatch '^BSSID\s*:') {
            $connectedSsid = $matches[1].Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($connectedSsid) -and
        [string]::IsNullOrWhiteSpace($connectedBssid) -and
        [string]::IsNullOrWhiteSpace($state)) {
        return $null
    }

    return [PSCustomObject]@{
        InterfaceName = $interfaceName
        State         = $state
        SSID          = $connectedSsid
        BSSID         = $connectedBssid
    }
}

function Get-SavedProfiles {
    $profilesRaw = netsh wlan show profiles 2>&1

    if (-not $profilesRaw) {
        return @()
    }

    return @(
        foreach ($line in $profilesRaw) {
            $trimmed = ([string]$line).Trim()

            if ($trimmed -match '^(?:All User Profile|Current User Profile|すべてのユーザー プロファイル|現在のユーザー プロファイル)\s*:\s*(.+)$') {
                $matches[1].Trim()
            }
        }
    )
}

function Connect-ToWifiSsid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSsid,
        [string[]]$AvailableSsids = @(),
        [string[]]$SavedProfiles = @()
    )

    if ([string]::IsNullOrWhiteSpace($TargetSsid)) {
        throw '接続先の SSID が空です。'
    }

    $matchingProfile = $SavedProfiles | Where-Object { $_ -eq $TargetSsid } | Select-Object -First 1
    $usedFallbackProfileName = $false

    if (-not $matchingProfile) {
        $matchingProfile = $TargetSsid
        $usedFallbackProfileName = $true
    }

    if ($AvailableSsids.Count -gt 0 -and ($AvailableSsids -notcontains $TargetSsid)) {
        Write-Warning "SSID '$TargetSsid' は今回のスキャン結果には見えていません。保存済みプロファイルで接続を試みます。"
    }

    $connectOutput = netsh wlan connect name="$matchingProfile" ssid="$TargetSsid" 2>&1
    $connectText = ($connectOutput | Out-String).Trim()

    if ($LASTEXITCODE -ne 0 -or
        $connectText -match 'not found' -or
        $connectText -match 'failed' -or
        $connectText -match 'cannot' -or
        $connectText -match '見つかりません' -or
        $connectText -match '失敗' -or
        $connectText -match 'できません' -or
        $connectText -match 'ありません') {
        $savedList = if ($SavedProfiles.Count -gt 0) {
            ($SavedProfiles | Sort-Object | ForEach-Object { "- $_" }) -join [Environment]::NewLine
        }
        else {
            '保存済みプロファイルは見つかりませんでした。'
        }

        $profileNote = if ($usedFallbackProfileName) {
            "保存済みプロファイル一覧から一致が取れなかったため、name='$TargetSsid' を仮のプロファイル名として試しました。"
        }
        else {
            "使用したプロファイル名: $matchingProfile"
        }

        throw @"
SSID '$TargetSsid' への接続に失敗しました。

netsh の応答:
$connectText

$profileNote

保存済みプロファイル:
$savedList
"@
    }

    $verifiedConnection = $null

    foreach ($attempt in 1..5) {
        Start-Sleep -Seconds 2
        $verifiedConnection = Get-CurrentConnection

        if ($null -ne $verifiedConnection -and $verifiedConnection.SSID -eq $TargetSsid) {
            return [PSCustomObject]@{
                Message    = "接続要求を送信し、接続完了を確認しました。"
                RawMessage = $connectText
                Connection = $verifiedConnection
            }
        }
    }

    $stateLabel = if ($null -eq $verifiedConnection) {
        '接続状態を取得できませんでした。'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($verifiedConnection.SSID)) {
        "現在は '$($verifiedConnection.SSID)' に接続しています。"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($verifiedConnection.State)) {
        "現在の状態: $($verifiedConnection.State)"
    }
    else {
        '現在は未接続です。'
    }

    throw @"
SSID '$TargetSsid' への接続要求は受け付けられましたが、接続完了は確認できませんでした。

netsh の応答:
$connectText

確認結果:
$stateLabel
"@
}

function Resolve-SelectedSsid {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [AllowNull()]
        [string]$InputText
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return $null
    }

    $trimmed = $InputText.Trim()

    if ($trimmed -match '^\d+$') {
        $index = [int]$trimmed

        if ($index -lt 1 -or $index -gt $Items.Count) {
            throw "番号 '$index' は一覧の範囲外です。"
        }

        return [string]$Items[$index - 1].SSID
    }

    $exactMatch = $Items | Where-Object { $_.SSID -eq $trimmed } | Select-Object -First 1

    if ($exactMatch) {
        return [string]$exactMatch.SSID
    }

    throw "SSID '$trimmed' は一覧に見つかりませんでした。"
}

function Get-ChannelOverlapCount {
    param(
        [object[]]$allRows,
        [object]$row
    )

    if ($null -eq $row.Channel -or [string]::IsNullOrWhiteSpace($row.Band)) {
        return 0
    }

    if ($row.Band -eq '2.4GHz') {
        return @(
            $allRows | Where-Object {
                $_.BSSID -ne $row.BSSID -and
                $_.Band -eq $row.Band -and
                $null -ne $_.Channel -and
                [Math]::Abs([int]$_.Channel - [int]$row.Channel) -le 4
            }
        ).Count
    }

    return @(
        $allRows | Where-Object {
            $_.BSSID -ne $row.BSSID -and
            $_.Band -eq $row.Band -and
            $_.Channel -eq $row.Channel
        }
    ).Count
}

function Get-ChannelCongestionPenalty {
    param(
        [string]$band,
        [int]$sameChannelCount,
        [int]$overlapCount
    )

    switch ($band) {
        '2.4GHz' {
            $sameChannelPenalty = $sameChannelCount * 8
            $adjacentPenalty = [Math]::Max($overlapCount - $sameChannelCount, 0) * 3
            return $sameChannelPenalty + $adjacentPenalty
        }
        '5GHz' {
            return $sameChannelCount * 5
        }
        '6GHz' {
            return $sameChannelCount * 3
        }
        default {
            return 0
        }
    }
}

function Get-SignalBar {
    param(
        [int]$signal
    )

    if ($null -eq $signal) {
        return '----------'
    }

    $filled = [Math]::Min([Math]::Max([Math]::Ceiling($signal / 10), 0), 10)
    return ('#' * $filled).PadRight(10, '-')
}

function Get-CongestionLabel {
    param(
        [int]$penalty
    )

    if ($penalty -ge 18) {
        return '混雑'
    }

    if ($penalty -ge 8) {
        return 'やや混雑'
    }

    if ($penalty -ge 3) {
        return '普通'
    }

    return '良好'
}

function Get-RankColor {
    param(
        [bool]$isConnected = $false
    )

    if ($isConnected) {
        return 'Magenta'
    }

    return 'Gray'
}

function Get-CongestionColor {
    param(
        [int]$penalty
    )

    if ($penalty -ge 18) {
        return 'Red'
    }

    if ($penalty -ge 8) {
        return 'Yellow'
    }

    if ($penalty -ge 3) {
        return 'DarkYellow'
    }

    return 'Green'
}

function Get-DisplayWidth {
    param(
        [AllowNull()]
        [string]$text
    )

    if ($null -eq $text) {
        return 0
    }

    $width = 0

    foreach ($char in $text.ToCharArray()) {
        if ([int][char]$char -le 255) {
            $width += 1
        }
        else {
            $width += 2
        }
    }

    return $width
}

function Pad-DisplayText {
    param(
        [AllowNull()]
        [string]$text,
        [int]$width,
        [ValidateSet('Left', 'Right')]
        [string]$align = 'Left'
    )

    if ($null -eq $text) {
        $text = ''
    }

    $padding = [Math]::Max($width - (Get-DisplayWidth $text), 0)

    if ($align -eq 'Right') {
        return (' ' * $padding) + $text
    }

    return $text + (' ' * $padding)
}

function Write-RichTable {
    param(
        [object[]]$items,
        [object]$currentConnection = $null
    )

    $displayRows = @(
        $items | ForEach-Object {
            $isConnected = $false

            if ($null -ne $currentConnection) {
                $isConnected = (
                    (-not [string]::IsNullOrWhiteSpace($currentConnection.BSSID) -and $currentConnection.BSSID -eq $_.BSSID) -or
                    ([string]::IsNullOrWhiteSpace($currentConnection.BSSID) -and
                        -not [string]::IsNullOrWhiteSpace($currentConnection.SSID) -and
                        $currentConnection.SSID -eq $_.SSID)
                )
            }

            [PSCustomObject]@{
                RowNumber   = [string]$_.RowNumber
                Marker     = if ($isConnected) { '*' } else { ' ' }
                Rank       = [string]$_.Rank
                SSID       = [string]$_.SSID
                SignalBar  = Get-SignalBar $_.Signal
                Signal     = if ($null -eq $_.Signal) { '-' } else { [string]$_.Signal }
                Channel    = if ($null -eq $_.Channel) { '-' } else { [string]$_.Channel }
                Band       = [string]$_.Band
                RadioType  = [string]$_.RadioType
                ChannelUse = [string]$_.ChannelUse
                Congestion = Get-CongestionLabel $_.CongestionPenalty
            }
        }
    )

    $columns = @(
        @{ Name = 'No'; Width = [Math]::Max(2, ($displayRows | ForEach-Object { Get-DisplayWidth $_.RowNumber } | Measure-Object -Maximum).Maximum) }
        @{ Name = ''; Width = 1 }
        @{ Name = '評価'; Width = [Math]::Max(4, ($displayRows | ForEach-Object { Get-DisplayWidth $_.Rank } | Measure-Object -Maximum).Maximum) }
        @{ Name = 'SSID'; Width = [Math]::Max(18, ($displayRows | ForEach-Object { Get-DisplayWidth $_.SSID } | Measure-Object -Maximum).Maximum) }
        @{ Name = '電波'; Width = 10 }
        @{ Name = '強度'; Width = 6 }
        @{ Name = 'Ch'; Width = 7 }
        @{ Name = '帯域'; Width = 6 }
        @{ Name = '規格'; Width = 9 }
        @{ Name = '数'; Width = 3 }
        @{ Name = '混雑度'; Width = 9 }
    )

    $header = (
        Pad-DisplayText -text $columns[0].Name -width $columns[0].Width -align Right
    ) + ' ' + (
        Pad-DisplayText -text $columns[1].Name -width $columns[1].Width
    ) + ' ' + (
        Pad-DisplayText -text $columns[2].Name -width $columns[2].Width -align Right
    ) + ' ' + (
        Pad-DisplayText -text $columns[3].Name -width $columns[3].Width
    ) + ' ' + (
        Pad-DisplayText -text $columns[4].Name -width $columns[4].Width
    ) + ' ' + (
        Pad-DisplayText -text $columns[5].Name -width $columns[5].Width -align Right
    ) + ' ' + (
        Pad-DisplayText -text $columns[6].Name -width $columns[6].Width -align Right
    ) + ' ' + (
        Pad-DisplayText -text $columns[7].Name -width $columns[7].Width
    ) + ' ' + (
        Pad-DisplayText -text $columns[8].Name -width $columns[8].Width
    ) + ' ' + (
        Pad-DisplayText -text $columns[9].Name -width $columns[9].Width -align Right
    ) + ' ' + (
        Pad-DisplayText -text $columns[10].Name -width $columns[10].Width
    )

    Write-Host $header -ForegroundColor White
    Write-Host ('-' * $header.Length) -ForegroundColor DarkGray

    foreach ($row in $items) {
        $isConnected = $false

        if ($null -ne $currentConnection) {
            $isConnected = (
                (-not [string]::IsNullOrWhiteSpace($currentConnection.BSSID) -and $currentConnection.BSSID -eq $row.BSSID) -or
                ([string]::IsNullOrWhiteSpace($currentConnection.BSSID) -and
                    -not [string]::IsNullOrWhiteSpace($currentConnection.SSID) -and
                    $currentConnection.SSID -eq $row.SSID)
            )
        }

        $rowColor = Get-RankColor -isConnected $isConnected
        $signalText = (Get-SignalBar $row.Signal)
        $signalValueText = if ($null -eq $row.Signal) { '-' } else { [string]$row.Signal }
        $channelText = if ($null -eq $row.Channel) { '-' } else { [string]$row.Channel }
        $congestionText = Get-CongestionLabel $row.CongestionPenalty

        $line = (
            Pad-DisplayText -text ([string]$row.RowNumber) -width $columns[0].Width -align Right
        ) + ' ' + (
            Pad-DisplayText -text $(if ($isConnected) { '*' } else { ' ' }) -width $columns[1].Width
        ) + ' ' + (
            Pad-DisplayText -text ([string]$row.Rank) -width $columns[2].Width -align Right
        ) + ' ' + (
            Pad-DisplayText -text ([string]$row.SSID) -width $columns[3].Width
        ) + ' ' + (
            Pad-DisplayText -text $signalText -width $columns[4].Width
        ) + ' ' + (
            Pad-DisplayText -text $signalValueText -width $columns[5].Width -align Right
        ) + ' ' + (
            Pad-DisplayText -text $channelText -width $columns[6].Width -align Right
        ) + ' ' + (
            Pad-DisplayText -text ([string]$row.Band) -width $columns[7].Width
        ) + ' ' + (
            Pad-DisplayText -text ([string]$row.RadioType) -width $columns[8].Width
        ) + ' ' + (
            Pad-DisplayText -text ([string]$row.ChannelUse) -width $columns[9].Width -align Right
        )

        Write-Host $line -ForegroundColor $rowColor -NoNewline
        Write-Host (' ' + (Pad-DisplayText -text $congestionText -width $columns[10].Width)) -ForegroundColor (Get-CongestionColor $row.CongestionPenalty)
    }
}

function Test-IsCurrentConnectionRow {
    param(
        [object]$Row,
        [object]$CurrentConnection
    )

    if ($null -eq $Row -or $null -eq $CurrentConnection) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentConnection.BSSID) -and $CurrentConnection.BSSID -eq $Row.BSSID) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($CurrentConnection.BSSID) -and
        -not [string]::IsNullOrWhiteSpace($CurrentConnection.SSID) -and
        $CurrentConnection.SSID -eq $Row.SSID) {
        return $true
    }

    return $false
}

function Get-ScannedWifiRows {
    $raw = netsh wlan show networks mode=bssid 2>&1

    if (-not $raw) {
        throw "netsh wlan show networks mode=bssid returned no output."
    }

    $rawText = ($raw | Out-String).Trim()

    if (Test-IsNetshPermissionError -Text $rawText) {
        Show-NetshPermissionError -RawText $rawText
    }

    $rows = @()
    $currentSsid = $null

    foreach ($line in $raw) {
        $trimmed = ([string]$line).Trim()

        if (-not $trimmed) {
            continue
        }

        if ($trimmed -match '^SSID\s+\d+\s*:\s*(.*)$') {
            $currentSsid = $matches[1].Trim()
            continue
        }

        if ($trimmed -match '^BSSID\s+\d+\s*:\s*(.*)$') {
            $rows += [PSCustomObject]@{
                SSID      = $currentSsid
                BSSID     = $matches[1].Trim()
                Signal    = $null
                Channel   = $null
                Band      = $null
                RadioType = $null
            }
            continue
        }

        if ($rows.Count -eq 0) {
            continue
        }

        if ($trimmed -notmatch '^[^:]+:\s*(.+)$') {
            continue
        }

        $value = $matches[1].Trim()

        if ($null -eq $rows[-1].Signal -and $value -match '^(\d+)\s*%$') {
            $rows[-1].Signal = [int]$matches[1]
            continue
        }

        if ($null -eq $rows[-1].RadioType -and $value -match '^802\.11') {
            $rows[-1].RadioType = $value
            continue
        }

        if ($null -eq $rows[-1].Channel -and $value -match '^\d+$') {
            $channel = [int]$value
            $rows[-1].Channel = $channel
            $rows[-1].Band = Get-BandFromChannel $channel
            continue
        }
    }

    if (-not $rows) {
        Write-Warning "No BSSID rows were parsed from netsh output."
        $raw
        exit 1
    }

    $rankedRows = $rows | ForEach-Object {
        $currentRow = $_
        $signalScore = if ($null -eq $currentRow.Signal) { 0 } else { [int]$currentRow.Signal }
        $bandWeight = Get-BandWeight $currentRow.Band
        $radioTypeWeight = Get-RadioTypeWeight $currentRow.RadioType
        $sameChannelCount = @(
            $rows | Where-Object {
                $_.BSSID -ne $currentRow.BSSID -and
                $_.Band -eq $currentRow.Band -and
                $_.Channel -eq $currentRow.Channel
            }
        ).Count
        $overlapCount = Get-ChannelOverlapCount -allRows $rows -row $currentRow
        $congestionPenalty = Get-ChannelCongestionPenalty -band $currentRow.Band -sameChannelCount $sameChannelCount -overlapCount $overlapCount
        $rank = $signalScore + $bandWeight + $radioTypeWeight - $congestionPenalty

        [PSCustomObject]@{
            Rank              = $rank
            SSID              = $currentRow.SSID
            BSSID             = $currentRow.BSSID
            Signal            = $currentRow.Signal
            Channel           = $currentRow.Channel
            Band              = $currentRow.Band
            RadioType         = $currentRow.RadioType
            ChannelUse        = $sameChannelCount + 1
            OverlapUse        = $overlapCount + 1
            CongestionPenalty = $congestionPenalty
        }
    }

    $currentConnection = Get-CurrentConnection
    $filteredRows = $rankedRows | Where-Object {
        $_.Rank -ge 80 -or (Test-IsCurrentConnectionRow -Row $_ -CurrentConnection $currentConnection)
    }

    if (-not $filteredRows) {
        return [PSCustomObject]@{
            CurrentConnection = $currentConnection
            SortedRows        = @()
            RankedRows        = $rankedRows
        }
    }

    $sortedRows = $filteredRows |
        Sort-Object `
            @{ Expression = { $_.Rank }; Descending = $true }, `
            @{ Expression = { if ($null -eq $_.Signal) { -1 } else { $_.Signal } }; Descending = $true }

    $sortedRows = @(
        $sortedRows | ForEach-Object -Begin { $rowNumber = 1 } {
            [PSCustomObject]@{
                RowNumber         = $rowNumber++
                Rank              = $_.Rank
                SSID              = $_.SSID
                BSSID             = $_.BSSID
                Signal            = $_.Signal
                Channel           = $_.Channel
                Band              = $_.Band
                RadioType         = $_.RadioType
                ChannelUse        = $_.ChannelUse
                OverlapUse        = $_.OverlapUse
                CongestionPenalty = $_.CongestionPenalty
            }
        }
    )

    return [PSCustomObject]@{
        CurrentConnection = $currentConnection
        SortedRows        = $sortedRows
        RankedRows        = $rankedRows
    }
}

$scanResult = Get-ScannedWifiRows
$currentConnection = $scanResult.CurrentConnection
$sortedRows = $scanResult.SortedRows
$rankedRows = $scanResult.RankedRows

if (-not $sortedRows) {
    Write-Warning "No Wi-Fi networks met the minimum rank threshold of 80."
    exit 0
}

$savedProfiles = Get-SavedProfiles

Write-RichTable -items $sortedRows -currentConnection $currentConnection

if ($null -ne $currentConnection) {
    $currentLabel = if (-not [string]::IsNullOrWhiteSpace($currentConnection.BSSID)) {
        "$($currentConnection.SSID) / $($currentConnection.BSSID)"
    }
    else {
        $currentConnection.SSID
    }

    Write-Host ""
    Write-Host "* 現在の接続先: $currentLabel" -ForegroundColor Magenta
}

Write-Host "混雑度の色: 良好=Green, 普通=DarkYellow, やや混雑=Yellow, 混雑=Red" -ForegroundColor Gray

if (-not $NoPrompt) {
    Write-Host ""
    Write-Host "切り替える SSID を入力してください。番号または SSID 名、Enter で終了します。" -ForegroundColor Cyan
    $selectionInput = Read-Host '接続先'

    if (-not [string]::IsNullOrWhiteSpace($selectionInput)) {
        $selectedSsid = Resolve-SelectedSsid -Items $sortedRows -InputText $selectionInput
        $availableSsids = @($rankedRows | ForEach-Object { $_.SSID } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $connectResult = Connect-ToWifiSsid -TargetSsid $selectedSsid -AvailableSsids $availableSsids -SavedProfiles $savedProfiles
        $scanResult = Get-ScannedWifiRows
        $currentConnection = $scanResult.CurrentConnection
        $sortedRows = $scanResult.SortedRows
        $rankedRows = $scanResult.RankedRows

        Write-Host ""
        Write-Host "接続を試行しました: $selectedSsid" -ForegroundColor Cyan
        Write-Host $connectResult.Message -ForegroundColor DarkGray

        if ($null -ne $connectResult.Connection) {
            Write-Host "接続確認: $($connectResult.Connection.SSID) / $($connectResult.Connection.BSSID)" -ForegroundColor Green
        }

        Write-Host ""
        Write-RichTable -items $sortedRows -currentConnection $currentConnection

        if ($null -ne $currentConnection) {
            $currentLabel = if (-not [string]::IsNullOrWhiteSpace($currentConnection.BSSID)) {
                "$($currentConnection.SSID) / $($currentConnection.BSSID)"
            }
            else {
                $currentConnection.SSID
            }

            Write-Host ""
            Write-Host "* 現在の接続先: $currentLabel" -ForegroundColor Magenta
        }
    }
}
