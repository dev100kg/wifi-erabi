param(
    [switch]$ViewOnly
)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw "WPF 版は STA モードで実行してください。例: powershell -STA -File .\wifi-wpf.ps1"
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

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

    throw @"
Wi-Fi の詳細を取得できませんでした。

Windows 側で WLAN の詳細表示が制限されています。次の 2 点を確認してください。
- 位置情報サービスを有効にする
- PowerShell を管理者として実行する

設定画面を開くコマンド:
  start ms-settings:privacy-location

netsh の応答:
$RawText
"@
}

function Get-BandFromChannel {
    param(
        [int]$Channel
    )

    if ($Channel -ge 1 -and $Channel -le 14) { return '2.4GHz' }
    if ($Channel -ge 15 -and $Channel -le 177) { return '5GHz' }
    if ($Channel -ge 178) { return '6GHz' }
    return $null
}

function Get-RadioTypeWeight {
    param(
        [string]$RadioType
    )

    switch ($RadioType) {
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
        [string]$Band
    )

    switch ($Band) {
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

        if (-not $trimmed) { continue }

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

    [PSCustomObject]@{
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

    @(
        foreach ($line in $profilesRaw) {
            $trimmed = ([string]$line).Trim()

            if ($trimmed -match '^(?:All User Profile|Current User Profile|すべてのユーザー プロファイル|現在のユーザー プロファイル)\s*:\s*(.+)$') {
                $matches[1].Trim()
            }
        }
    )
}

function Get-ChannelOverlapCount {
    param(
        [object[]]$AllRows,
        [object]$Row
    )

    if ($null -eq $Row.Channel -or [string]::IsNullOrWhiteSpace($Row.Band)) {
        return 0
    }

    if ($Row.Band -eq '2.4GHz') {
        return @(
            $AllRows | Where-Object {
                $_.BSSID -ne $Row.BSSID -and
                $_.Band -eq $Row.Band -and
                $null -ne $_.Channel -and
                [Math]::Abs([int]$_.Channel - [int]$Row.Channel) -le 4
            }
        ).Count
    }

    @(
        $AllRows | Where-Object {
            $_.BSSID -ne $Row.BSSID -and
            $_.Band -eq $Row.Band -and
            $_.Channel -eq $Row.Channel
        }
    ).Count
}

function Get-ChannelCongestionPenalty {
    param(
        [string]$Band,
        [int]$SameChannelCount,
        [int]$OverlapCount
    )

    switch ($Band) {
        '2.4GHz' {
            $sameChannelPenalty = $SameChannelCount * 8
            $adjacentPenalty = [Math]::Max($OverlapCount - $SameChannelCount, 0) * 3
            return $sameChannelPenalty + $adjacentPenalty
        }
        '5GHz' { return $SameChannelCount * 5 }
        '6GHz' { return $SameChannelCount * 3 }
        default { return 0 }
    }
}

function Get-CongestionLabel {
    param(
        [int]$Penalty
    )

    if ($Penalty -ge 18) { return '混雑' }
    if ($Penalty -ge 8) { return 'やや混雑' }
    if ($Penalty -ge 3) { return '普通' }
    return '良好'
}

function Test-IsCurrentConnectionRow {
    param(
        [object]$Row,
        [object]$CurrentConnection
    )

    if ($null -eq $Row -or $null -eq $CurrentConnection) { return $false }

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
    if (-not $matchingProfile) {
        $matchingProfile = $TargetSsid
    }

    if ($AvailableSsids.Count -gt 0 -and ($AvailableSsids -notcontains $TargetSsid)) {
        [System.Windows.MessageBox]::Show(
            "SSID '$TargetSsid' は今回のスキャン結果には見えていません。保存済みプロファイルで接続を試みます。",
            'Wi-Fi 接続'
        ) | Out-Null
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
        throw @"
SSID '$TargetSsid' への接続に失敗しました。

netsh の応答:
$connectText
"@
    }

    foreach ($attempt in 1..5) {
        Start-Sleep -Seconds 2
        $verifiedConnection = Get-CurrentConnection
        if ($null -ne $verifiedConnection -and $verifiedConnection.SSID -eq $TargetSsid) {
            return [PSCustomObject]@{
                Message    = '接続要求を送信し、接続完了を確認しました。'
                Connection = $verifiedConnection
            }
        }
    }

    throw @"
SSID '$TargetSsid' への接続要求は受け付けられましたが、接続完了は確認できませんでした。

netsh の応答:
$connectText
"@
}

function Get-ScannedWifiRows {
    $raw = netsh wlan show networks mode=bssid 2>&1
    if (-not $raw) {
        throw 'netsh wlan show networks mode=bssid returned no output.'
    }

    $rawText = ($raw | Out-String).Trim()
    if (Test-IsNetshPermissionError -Text $rawText) {
        Show-NetshPermissionError -RawText $rawText
    }

    $rows = @()
    $currentSsid = $null

    foreach ($line in $raw) {
        $trimmed = ([string]$line).Trim()
        if (-not $trimmed) { continue }

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

        if ($rows.Count -eq 0) { continue }
        if ($trimmed -notmatch '^[^:]+:\s*(.+)$') { continue }

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
        }
    }

    if (-not $rows) {
        throw 'Wi-Fi 一覧を解析できませんでした。'
    }

    $currentConnection = Get-CurrentConnection

    @(
        $rows | ForEach-Object {
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
            $overlapCount = Get-ChannelOverlapCount -AllRows $rows -Row $currentRow
            $congestionPenalty = Get-ChannelCongestionPenalty -Band $currentRow.Band -SameChannelCount $sameChannelCount -OverlapCount $overlapCount

            [PSCustomObject]@{
                Current    = Test-IsCurrentConnectionRow -Row $currentRow -CurrentConnection $currentConnection
                CurrentMark= if (Test-IsCurrentConnectionRow -Row $currentRow -CurrentConnection $currentConnection) { '*' } else { '' }
                Rank       = $signalScore + $bandWeight + $radioTypeWeight - $congestionPenalty
                SSID       = $currentRow.SSID
                BSSID      = $currentRow.BSSID
                Signal     = $currentRow.Signal
                Channel    = $currentRow.Channel
                Band       = $currentRow.Band
                RadioType  = $currentRow.RadioType
                ChannelUse = $sameChannelCount + 1
                Congestion = Get-CongestionLabel -Penalty $congestionPenalty
            }
        } |
        Where-Object { $_.Rank -ge 80 -or $_.Current } |
        Sort-Object `
            @{ Expression = { $_.Rank }; Descending = $true }, `
            @{ Expression = { if ($null -eq $_.Signal) { -1 } else { $_.Signal } }; Descending = $true }
    )
}

function Show-WifiWpfPicker {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Wi-Fi 候補一覧"
        Width="880"
        Height="460"
        MinWidth="760"
        MinHeight="360"
        WindowStartupLocation="CenterScreen"
        Background="#F6F7FB">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="White" CornerRadius="10" Padding="14" Margin="0,0,0,10">
      <StackPanel>
        <TextBlock Text="Wi-Fi 候補一覧" FontSize="20" FontWeight="SemiBold" Foreground="#1F2937"/>
        <TextBlock x:Name="InfoText" Margin="0,6,0,0" Text="おすすめ順に並んでいます。行を選んで [接続]、閉じると終了します。" Foreground="#4B5563"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="1" Background="White" CornerRadius="10" Padding="10">
      <DataGrid x:Name="WifiGrid"
                AutoGenerateColumns="False"
                CanUserAddRows="False"
                CanUserDeleteRows="False"
                CanUserResizeRows="False"
                SelectionMode="Single"
                SelectionUnit="FullRow"
                IsReadOnly="True"
                GridLinesVisibility="Horizontal"
                HeadersVisibility="Column"
                RowHeaderWidth="0">
        <DataGrid.Columns>
          <DataGridTextColumn Header="現在" Binding="{Binding CurrentMark}" Width="48"/>
          <DataGridTextColumn Header="評価" Binding="{Binding Rank}" Width="60"/>
          <DataGridTextColumn Header="Wi-Fi 名" Binding="{Binding SSID}" Width="220"/>
          <DataGridTextColumn Header="強度" Binding="{Binding Signal}" Width="60"/>
          <DataGridTextColumn Header="Ch" Binding="{Binding Channel}" Width="50"/>
          <DataGridTextColumn Header="帯域" Binding="{Binding Band}" Width="70"/>
          <DataGridTextColumn Header="規格" Binding="{Binding RadioType}" Width="90"/>
          <DataGridTextColumn Header="使用数" Binding="{Binding ChannelUse}" Width="60"/>
          <DataGridTextColumn Header="混雑度" Binding="{Binding Congestion}" Width="92"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>

    <Grid Grid.Row="2" Margin="0,10,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <TextBlock x:Name="StatusText"
                 Grid.Column="0"
                 VerticalAlignment="Center"
                 Foreground="#4B5563"
                 Text="現在の接続先には * が付きます。"/>

      <Button x:Name="RefreshButton"
              Grid.Column="1"
              Width="92"
              Height="32"
              Margin="8,0,0,0"
              Content="再読込"/>

      <Button x:Name="ConnectButton"
              Grid.Column="2"
              Width="110"
              Height="32"
              Margin="8,0,0,0"
              Content="接続"
              IsEnabled="False"/>

      <Button x:Name="CloseButton"
              Grid.Column="3"
              Width="110"
              Height="32"
              Margin="8,0,0,0"
              Content="閉じる"
              IsCancel="True"/>
    </Grid>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $wifiGrid = $window.FindName('WifiGrid')
    $infoText = $window.FindName('InfoText')
    $statusText = $window.FindName('StatusText')
    $refreshButton = $window.FindName('RefreshButton')
    $connectButton = $window.FindName('ConnectButton')
    $closeButton = $window.FindName('CloseButton')

    if ($ViewOnly) {
        $connectButton.Content = '詳細表示'
        $infoText.Text = 'おすすめ順に並んでいます。行を選んで [詳細表示]、閉じると終了します。'
    }

    $rowsCollection = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    foreach ($row in $Rows) {
        [void]$rowsCollection.Add($row)
    }
    $wifiGrid.ItemsSource = $rowsCollection

    $selectedRow = $null

    $updateStatus = {
        $selectedItem = $wifiGrid.SelectedItem
        $connectButton.IsEnabled = $null -ne $selectedItem

        if ($null -ne $selectedItem) {
            $statusText.Text = "選択中: $($selectedItem.SSID) / 評価 $($selectedItem.Rank) / 混雑度 $($selectedItem.Congestion)"
        }
        else {
            $statusText.Text = '現在の接続先には * が付きます。'
        }
    }

    $selectTopRow = {
        if ($wifiGrid.Items.Count -gt 0) {
            $wifiGrid.SelectedIndex = 0
            $wifiGrid.ScrollIntoView($wifiGrid.SelectedItem)
            & $updateStatus
        }
    }

    $refreshGrid = {
        try {
            $latestRows = Get-ScannedWifiRows
            $rowsCollection.Clear()
            foreach ($row in $latestRows) {
                [void]$rowsCollection.Add($row)
            }
            & $selectTopRow
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Wi-Fi 再読込') | Out-Null
        }
    }

    $wifiGrid.add_SelectionChanged({ & $updateStatus })
    $wifiGrid.add_MouseDoubleClick({
        if ($null -ne $wifiGrid.SelectedItem) {
            $connectButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
    })

    $refreshButton.add_Click({ & $refreshGrid })
    $connectButton.add_Click({
        if ($null -eq $wifiGrid.SelectedItem) { return }
        $script:selectedRow = $wifiGrid.SelectedItem
        $window.DialogResult = $true
        $window.Close()
    })
    $closeButton.add_Click({
        $window.DialogResult = $false
        $window.Close()
    })
    $window.add_ContentRendered({ & $selectTopRow })

    $result = $window.ShowDialog()
    if ($result) {
        return $script:selectedRow
    }

    return $null
}

try {
    $savedProfiles = Get-SavedProfiles

    while ($true) {
        $rows = Get-ScannedWifiRows
        if (-not $rows) {
            [System.Windows.MessageBox]::Show('評価 80 以上の Wi-Fi が見つかりませんでした。', 'Wi-Fi 候補一覧') | Out-Null
            exit 0
        }

        $selectedRow = Show-WifiWpfPicker -Rows $rows
        if ($null -eq $selectedRow) {
            exit 0
        }

        if ($ViewOnly) {
            $selectedRow | Format-List
            exit 0
        }

        $availableSsids = @($rows | ForEach-Object { $_.SSID } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $connectResult = Connect-ToWifiSsid -TargetSsid $selectedRow.SSID -AvailableSsids $availableSsids -SavedProfiles $savedProfiles

        $connectionLabel = if ($null -ne $connectResult.Connection) {
            "$($connectResult.Connection.SSID) / $($connectResult.Connection.BSSID)"
        }
        else {
            $selectedRow.SSID
        }

        [System.Windows.MessageBox]::Show(
            "$($connectResult.Message)`r`n接続確認: $connectionLabel",
            'Wi-Fi 接続'
        ) | Out-Null
    }
}
catch {
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'Wi-Fi 候補一覧') | Out-Null
    exit 1
}
