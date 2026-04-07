namespace WiFiErabi.App.Models;

public sealed class WifiConnectionInfo
{
    public string? InterfaceName { get; init; }

    public string? State { get; init; }

    public string? SSID { get; init; }

    public string? BSSID { get; init; }
}
