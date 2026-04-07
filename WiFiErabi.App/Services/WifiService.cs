using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using WiFiErabi.App.Models;

namespace WiFiErabi.App.Services;

public sealed class WifiService
{
    private static readonly Regex SsidHeaderRegex = new(@"^SSID\s+\d+\s*:\s*(.*)$", RegexOptions.Compiled);
    private static readonly Regex BssidHeaderRegex = new(@"^BSSID\s+\d+\s*:\s*(.*)$", RegexOptions.Compiled);
    private static readonly Regex KeyValueRegex = new(@"^[^:]+:\s*(.+)$", RegexOptions.Compiled);
    private static readonly Regex InterfaceNameRegex = new(@"^(?:Name|名前)\s*:\s*(.+)$", RegexOptions.Compiled);
    private static readonly Regex StateRegex = new(@"^(?:State|状態)\s*:\s*(.+)$", RegexOptions.Compiled);
    private static readonly Regex ProfileRegex = new(@"^(?:All User Profile|Current User Profile|すべてのユーザー プロファイル|現在のユーザー プロファイル)\s*:\s*(.+)$", RegexOptions.Compiled);
    private static readonly string[] PermissionKeywords =
    [
        "location permission",
        "Location services",
        "requires elevation",
        "administrator",
        "位置情報",
        "位置情報サービス",
        "管理者",
        "昇格"
    ];
    private static readonly string[] ConnectFailureKeywords =
    [
        "not found",
        "failed",
        "cannot",
        "見つかりません",
        "失敗",
        "できません",
        "ありません"
    ];

    public async Task<IReadOnlyList<WifiNetworkRow>> GetScannedWifiRowsAsync(CancellationToken cancellationToken = default)
    {
        var command = await RunNetshAsync("wlan show networks mode=bssid", cancellationToken);
        if (string.IsNullOrWhiteSpace(command.Text))
        {
            throw new InvalidOperationException("Wi-Fi 一覧を取得できませんでした。");
        }

        if (IsPermissionError(command.Text))
        {
            throw new InvalidOperationException(
                "Wi-Fi の詳細を取得できませんでした。\n\n" +
                "Windows 側で WLAN の詳細表示が制限されています。次の 2 点を確認してください。\n" +
                "- 位置情報サービスを有効にする\n" +
                "- このアプリを管理者として実行する\n\n" +
                "設定画面を開くコマンド:\n" +
                "  start ms-settings:privacy-location\n\n" +
                "netsh の応答:\n" +
                command.Text);
        }

        var parsedRows = ParseNetworks(command.Lines);
        if (parsedRows.Count == 0)
        {
            throw new InvalidOperationException("Wi-Fi 一覧を解析できませんでした。");
        }

        var currentConnection = await GetCurrentConnectionAsync(cancellationToken);

        var rankedRows = parsedRows
            .Select(row =>
            {
                var sameChannelCount = parsedRows.Count(candidate =>
                    !string.Equals(candidate.Bssid, row.Bssid, StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(candidate.Band, row.Band, StringComparison.OrdinalIgnoreCase) &&
                    candidate.Channel == row.Channel);

                var overlapCount = GetChannelOverlapCount(parsedRows, row);
                var congestionPenalty = GetChannelCongestionPenalty(row.Band, sameChannelCount, overlapCount);
                var current = IsCurrentConnectionRow(row, currentConnection);

                return new WifiNetworkRow
                {
                    Current = current,
                    Rank = (row.Signal ?? 0) + GetBandWeight(row.Band) + GetRadioTypeWeight(row.RadioType) - congestionPenalty,
                    SSID = row.Ssid,
                    BSSID = row.Bssid,
                    Signal = row.Signal,
                    Channel = row.Channel,
                    Band = row.Band ?? string.Empty,
                    RadioType = row.RadioType ?? string.Empty,
                    ChannelUse = sameChannelCount + 1,
                    Congestion = GetCongestionLabel(congestionPenalty)
                };
            })
            .Where(row => row.Rank >= 80 || row.Current)
            .OrderByDescending(row => row.Rank)
            .ThenByDescending(row => row.Signal ?? -1)
            .ToList();

        return rankedRows;
    }

    public async Task<IReadOnlyList<string>> GetSavedProfilesAsync(CancellationToken cancellationToken = default)
    {
        var result = await RunNetshAsync("wlan show profiles", cancellationToken);
        return result.Lines
            .Select(line => line.Trim())
            .Select(line => ProfileRegex.Match(line))
            .Where(match => match.Success)
            .Select(match => match.Groups[1].Value.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public async Task<WifiConnectionInfo?> GetCurrentConnectionAsync(CancellationToken cancellationToken = default)
    {
        var result = await RunNetshAsync("wlan show interfaces", cancellationToken);
        if (string.IsNullOrWhiteSpace(result.Text))
        {
            return null;
        }

        string? interfaceName = null;
        string? state = null;
        string? ssid = null;
        string? bssid = null;

        foreach (var rawLine in result.Lines)
        {
            var line = rawLine.Trim();
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var interfaceMatch = InterfaceNameRegex.Match(line);
            if (interfaceName is null && interfaceMatch.Success)
            {
                interfaceName = interfaceMatch.Groups[1].Value.Trim();
                continue;
            }

            var stateMatch = StateRegex.Match(line);
            if (state is null && stateMatch.Success)
            {
                state = stateMatch.Groups[1].Value.Trim();
                continue;
            }

            if (bssid is null && line.StartsWith("BSSID", StringComparison.OrdinalIgnoreCase))
            {
                bssid = GetValueAfterColon(line);
                continue;
            }

            if (ssid is null &&
                line.StartsWith("SSID", StringComparison.OrdinalIgnoreCase) &&
                !line.StartsWith("BSSID", StringComparison.OrdinalIgnoreCase))
            {
                ssid = GetValueAfterColon(line);
            }
        }

        if (string.IsNullOrWhiteSpace(interfaceName) &&
            string.IsNullOrWhiteSpace(state) &&
            string.IsNullOrWhiteSpace(ssid) &&
            string.IsNullOrWhiteSpace(bssid))
        {
            return null;
        }

        return new WifiConnectionInfo
        {
            InterfaceName = interfaceName,
            State = state,
            SSID = ssid,
            BSSID = bssid
        };
    }

    public async Task<(string Message, WifiConnectionInfo? Connection)> ConnectToWifiAsync(
        string targetSsid,
        IReadOnlyList<string> availableSsids,
        IReadOnlyList<string> savedProfiles,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(targetSsid))
        {
            throw new InvalidOperationException("接続先の Wi-Fi 名が空です。");
        }

        var matchingProfile = savedProfiles.FirstOrDefault(profile =>
            string.Equals(profile, targetSsid, StringComparison.OrdinalIgnoreCase));
        matchingProfile ??= targetSsid;

        var command = await RunNetshAsync(
            $"wlan connect name=\"{matchingProfile}\" ssid=\"{targetSsid}\"",
            cancellationToken);

        var text = command.Text.Trim();
        var hasImmediateFailure = command.ExitCode != 0 ||
            ConnectFailureKeywords.Any(keyword => text.Contains(keyword, StringComparison.OrdinalIgnoreCase));

        if (hasImmediateFailure)
        {
            throw new InvalidOperationException(
                $"Wi-Fi '{targetSsid}' への接続に失敗しました。\n\nnetsh の応答:\n{text}");
        }

        for (var attempt = 0; attempt < 5; attempt++)
        {
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            var currentConnection = await GetCurrentConnectionAsync(cancellationToken);
            if (string.Equals(currentConnection?.SSID, targetSsid, StringComparison.Ordinal))
            {
                return ("接続要求を送信し、接続完了を確認しました。", currentConnection);
            }
        }

        throw new InvalidOperationException(
            $"Wi-Fi '{targetSsid}' への接続要求は受け付けられましたが、接続完了は確認できませんでした。\n\nnetsh の応答:\n{text}");
    }

    private static bool IsPermissionError(string text)
    {
        return PermissionKeywords.Any(keyword => text.Contains(keyword, StringComparison.OrdinalIgnoreCase));
    }

    private static List<ParsedNetwork> ParseNetworks(IReadOnlyList<string> lines)
    {
        var rows = new List<ParsedNetwork>();
        string currentSsid = string.Empty;

        foreach (var rawLine in lines)
        {
            var line = rawLine.Trim();
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var ssidMatch = SsidHeaderRegex.Match(line);
            if (ssidMatch.Success)
            {
                currentSsid = ssidMatch.Groups[1].Value.Trim();
                continue;
            }

            var bssidMatch = BssidHeaderRegex.Match(line);
            if (bssidMatch.Success)
            {
                rows.Add(new ParsedNetwork
                {
                    Ssid = currentSsid,
                    Bssid = bssidMatch.Groups[1].Value.Trim()
                });
                continue;
            }

            if (rows.Count == 0)
            {
                continue;
            }

            var valueMatch = KeyValueRegex.Match(line);
            if (!valueMatch.Success)
            {
                continue;
            }

            var value = valueMatch.Groups[1].Value.Trim();
            var current = rows[^1];

            if (current.Signal is null && value.EndsWith('%') && int.TryParse(value.TrimEnd('%', ' '), out var signal))
            {
                current.Signal = signal;
                continue;
            }

            if (string.IsNullOrWhiteSpace(current.RadioType) && value.StartsWith("802.11", StringComparison.OrdinalIgnoreCase))
            {
                current.RadioType = value;
                continue;
            }

            if (current.Channel is null && int.TryParse(value, out var channel))
            {
                current.Channel = channel;
                current.Band = GetBandFromChannel(channel);
            }
        }

        return rows;
    }

    private static bool IsCurrentConnectionRow(ParsedNetwork row, WifiConnectionInfo? connection)
    {
        if (connection is null)
        {
            return false;
        }

        if (!string.IsNullOrWhiteSpace(connection.BSSID))
        {
            return string.Equals(connection.BSSID, row.Bssid, StringComparison.OrdinalIgnoreCase);
        }

        return !string.IsNullOrWhiteSpace(connection.SSID) &&
               string.Equals(connection.SSID, row.Ssid, StringComparison.Ordinal);
    }

    private static int GetChannelOverlapCount(IReadOnlyList<ParsedNetwork> allRows, ParsedNetwork row)
    {
        if (row.Channel is null || string.IsNullOrWhiteSpace(row.Band))
        {
            return 0;
        }

        if (string.Equals(row.Band, "2.4GHz", StringComparison.OrdinalIgnoreCase))
        {
            return allRows.Count(candidate =>
                !string.Equals(candidate.Bssid, row.Bssid, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(candidate.Band, row.Band, StringComparison.OrdinalIgnoreCase) &&
                candidate.Channel is not null &&
                Math.Abs(candidate.Channel.Value - row.Channel.Value) <= 4);
        }

        return allRows.Count(candidate =>
            !string.Equals(candidate.Bssid, row.Bssid, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(candidate.Band, row.Band, StringComparison.OrdinalIgnoreCase) &&
            candidate.Channel == row.Channel);
    }

    private static int GetChannelCongestionPenalty(string? band, int sameChannelCount, int overlapCount)
    {
        return band switch
        {
            "2.4GHz" => (sameChannelCount * 8) + (Math.Max(overlapCount - sameChannelCount, 0) * 3),
            "5GHz" => sameChannelCount * 5,
            "6GHz" => sameChannelCount * 3,
            _ => 0
        };
    }

    private static string GetCongestionLabel(int penalty)
    {
        if (penalty >= 18)
        {
            return "混雑";
        }

        if (penalty >= 8)
        {
            return "やや混雑";
        }

        if (penalty >= 3)
        {
            return "普通";
        }

        return "良好";
    }

    private static int GetBandWeight(string? band)
    {
        return band switch
        {
            "6GHz" => 12,
            "5GHz" => 8,
            "2.4GHz" => 0,
            _ => 0
        };
    }

    private static int GetRadioTypeWeight(string? radioType)
    {
        return radioType switch
        {
            "802.11be" => 25,
            "802.11ax" => 20,
            "802.11ac" => 14,
            "802.11n" => 8,
            "802.11g" => 3,
            "802.11a" => 2,
            "802.11b" => 0,
            _ => 0
        };
    }

    private static string? GetBandFromChannel(int channel)
    {
        if (channel is >= 1 and <= 14)
        {
            return "2.4GHz";
        }

        if (channel is >= 15 and <= 177)
        {
            return "5GHz";
        }

        if (channel >= 178)
        {
            return "6GHz";
        }

        return null;
    }

    private static string? GetValueAfterColon(string line)
    {
        var index = line.IndexOf(':');
        return index >= 0 && index < line.Length - 1
            ? line[(index + 1)..].Trim()
            : null;
    }

    private static async Task<NetshCommandResult> RunNetshAsync(string arguments, CancellationToken cancellationToken)
    {
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = "netsh",
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();

        process.Start();

        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);

        outputBuilder.Append(await outputTask);
        errorBuilder.Append(await errorTask);

        var combinedText = string.Join(
            Environment.NewLine,
            new[] { outputBuilder.ToString().Trim(), errorBuilder.ToString().Trim() }
                .Where(text => !string.IsNullOrWhiteSpace(text)));

        var lines = combinedText
            .Split(["\r\n", "\n"], StringSplitOptions.None)
            .ToList();

        return new NetshCommandResult
        {
            ExitCode = process.ExitCode,
            Text = combinedText,
            Lines = lines
        };
    }

    private sealed class ParsedNetwork
    {
        public string Ssid { get; init; } = string.Empty;

        public string Bssid { get; init; } = string.Empty;

        public int? Signal { get; set; }

        public int? Channel { get; set; }

        public string? Band { get; set; }

        public string? RadioType { get; set; }
    }
}
