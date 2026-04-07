using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using WiFiErabi.App.Models;
using WiFiErabi.App.Services;

namespace WiFiErabi.App;

public partial class MainWindow : Window
{
    private readonly WifiService _wifiService = new();
    private readonly ObservableCollection<WifiNetworkRow> _rows = [];
    private IReadOnlyList<string> _savedProfiles = Array.Empty<string>();
    private bool _isBusy;

    public MainWindow()
    {
        InitializeComponent();
        WifiDataGrid.ItemsSource = _rows;
        Loaded += MainWindow_Loaded;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        await LoadInitialDataAsync();
    }

    private async Task LoadInitialDataAsync()
    {
        try
        {
            await SetBusyAsync(true, "Wi-Fi 一覧を読み込んでいます...");
            _savedProfiles = await _wifiService.GetSavedProfilesAsync();
            await RefreshRowsAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Wi-Fi 候補一覧", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            await SetBusyAsync(false, "現在の接続先には * が付きます。");
        }
    }

    private async Task RefreshRowsAsync(string? preferredSsid = null)
    {
        var rows = await _wifiService.GetScannedWifiRowsAsync();

        _rows.Clear();
        foreach (var row in rows)
        {
            _rows.Add(row);
        }

        if (_rows.Count == 0)
        {
            StatusTextBlock.Text = "評価 80 以上の Wi-Fi が見つかりませんでした。";
            ConnectButton.IsEnabled = false;
            return;
        }

        var rowToSelect = !string.IsNullOrWhiteSpace(preferredSsid)
            ? _rows.FirstOrDefault(row => string.Equals(row.SSID, preferredSsid, StringComparison.Ordinal))
            : null;
        rowToSelect ??= _rows[0];

        WifiDataGrid.SelectedItem = rowToSelect;
        WifiDataGrid.ScrollIntoView(rowToSelect);
        UpdateStatusForSelection();
    }

    private async Task ConnectSelectedNetworkAsync()
    {
        if (_isBusy || WifiDataGrid.SelectedItem is not WifiNetworkRow selectedRow)
        {
            return;
        }

        try
        {
            await SetBusyAsync(true, $"'{selectedRow.SSID}' に接続しています...");

            var availableSsids = _rows
                .Select(row => row.SSID)
                .Where(ssid => !string.IsNullOrWhiteSpace(ssid))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

            var result = await _wifiService.ConnectToWifiAsync(selectedRow.SSID, availableSsids, _savedProfiles);

            var connectionLabel = !string.IsNullOrWhiteSpace(result.Connection?.BSSID)
                ? $"{result.Connection?.SSID} / {result.Connection?.BSSID}"
                : result.Connection?.SSID ?? selectedRow.SSID;

            MessageBox.Show(
                this,
                $"{result.Message}\n接続確認: {connectionLabel}",
                "Wi-Fi 接続",
                MessageBoxButton.OK,
                MessageBoxImage.Information);

            await RefreshRowsAsync(selectedRow.SSID);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Wi-Fi 接続", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            await SetBusyAsync(false, "現在の接続先には * が付きます。");
        }
    }

    private Task SetBusyAsync(bool isBusy, string statusText)
    {
        _isBusy = isBusy;
        Cursor = isBusy ? Cursors.Wait : Cursors.Arrow;
        RefreshButton.IsEnabled = !isBusy;
        ConnectButton.IsEnabled = !isBusy && WifiDataGrid.SelectedItem is WifiNetworkRow;
        WifiDataGrid.IsEnabled = !isBusy;
        StatusTextBlock.Text = statusText;
        return Task.CompletedTask;
    }

    private void UpdateStatusForSelection()
    {
        if (_isBusy)
        {
            return;
        }

        if (WifiDataGrid.SelectedItem is WifiNetworkRow row)
        {
            StatusTextBlock.Text = $"選択中: {row.SSID} / 評価 {row.Rank} / 混雑度 {row.Congestion}";
            ConnectButton.IsEnabled = true;
            return;
        }

        StatusTextBlock.Text = "現在の接続先には * が付きます。";
        ConnectButton.IsEnabled = false;
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy)
        {
            return;
        }

        try
        {
            await SetBusyAsync(true, "Wi-Fi 一覧を更新しています...");
            _savedProfiles = await _wifiService.GetSavedProfilesAsync();
            await RefreshRowsAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Wi-Fi 再読込", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            await SetBusyAsync(false, "現在の接続先には * が付きます。");
        }
    }

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        await ConnectSelectedNetworkAsync();
    }

    private async void WifiDataGrid_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (WifiDataGrid.SelectedItem is WifiNetworkRow)
        {
            await ConnectSelectedNetworkAsync();
        }
    }

    private void WifiDataGrid_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        UpdateStatusForSelection();
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }
}
