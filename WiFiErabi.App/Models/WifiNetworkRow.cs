namespace WiFiErabi.App.Models;

public sealed class WifiNetworkRow
{
    public bool Current { get; init; }

    public string CurrentMark => Current ? "*" : string.Empty;

    public int Rank { get; init; }

    public string SSID { get; init; } = string.Empty;

    public string BSSID { get; init; } = string.Empty;

    public int? Signal { get; init; }

    public string SignalBar => BuildSignalBar(Signal);

    public int? Channel { get; init; }

    public string Band { get; init; } = string.Empty;

    public string RadioType { get; init; } = string.Empty;

    public int ChannelUse { get; init; }

    public string Congestion { get; init; } = string.Empty;

    private static string BuildSignalBar(int? signal)
    {
        if (signal is null)
        {
            return "----------";
        }

        var filled = Math.Clamp((int)Math.Round(signal.Value / 10.0, MidpointRounding.AwayFromZero), 0, 10);
        return new string('#', filled) + new string('-', 10 - filled);
    }
}
