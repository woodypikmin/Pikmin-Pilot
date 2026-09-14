using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

internal sealed class SetupConfig
{
    public string? BootstrapApiBase { get; set; }
    public string? RegistrationToken { get; set; }
    public string? IpaUrl { get; set; }
    public string LocalIpaFile { get; set; } = "PikminPilot.ipa";
    public int PollSeconds { get; set; } = 12;
    public int MaxWaitMinutes { get; set; } = 35;
}

internal sealed record BootstrapReply(string? status, string? requestId, string? ipaUrl, string? message);

internal static class Program
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };
    private static string BaseDir => AppContext.BaseDirectory;
    private static string ToolsDir => Path.Combine(BaseDir, "tools");

    public static async Task<int> Main()
    {
        Console.OutputEncoding = Encoding.UTF8;
        Console.Title = "Pikmin Pilot Setup";
        Banner();

        try
        {
            var config = LoadConfig();
            var udids = await DetectDevices();
            if (udids.Count == 0)
            {
                Fail("找不到 iPhone / iPad。請安裝 Apple iTunes / Apple Mobile Device USB driver，解鎖裝置、USB 連線並按『信任』後再試一次。");
                return 2;
            }

            string udid = ChooseDevice(udids);
            string deviceName = $"Pikmin-{udid[^Math.Min(8, udid.Length)..]}";
            Console.WriteLine($"\n✓ 已偵測裝置 UDID: {udid}");

            string ipa = await ResolveIpa(config, udid, deviceName);
            Console.WriteLine($"\n✓ IPA ready: {ipa}");

            await InstallIpa(udid, ipa);
            Console.WriteLine("\n✓ Pikmin Pilot 安裝完成");

            await RunPairingHelper();

            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("\n==============================================");
            Console.WriteLine("SETUP COMPLETE");
            Console.WriteLine("拔掉 USB，開 Pikmin Pilot → START PILOT。");
            Console.WriteLine("==============================================");
            Console.ResetColor();
            Console.WriteLine("\n按 Enter 關閉。");
            Console.ReadLine();
            return 0;
        }
        catch (Exception ex)
        {
            Fail(ex.Message);
            Console.WriteLine("\n按 Enter 關閉。");
            Console.ReadLine();
            return 1;
        }
    }

    private static void Banner()
    {
        Console.ForegroundColor = ConsoleColor.Cyan;
        Console.WriteLine("Pikmin Pilot Setup — Windows Bootstrap v2.0");
        Console.ResetColor();
        Console.WriteLine("USB → UDID → IPA → Install → RPPairing\n");
    }

    private static SetupConfig LoadConfig()
    {
        string path = Path.Combine(BaseDir, "setup-config.json");
        if (!File.Exists(path)) return new SetupConfig();
        return JsonSerializer.Deserialize<SetupConfig>(File.ReadAllText(path), new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? new SetupConfig();
    }

    private static async Task<List<string>> DetectDevices()
    {
        string exe = Tool("idevice_id.exe");
        foreach (var args in new[] { Array.Empty<string>(), new[] { "-l" } })
        {
            var result = await RunCapture(exe, args, allowFailure: true);
            var ids = result.Output
                .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(x => x.Trim())
                .Where(x => Regex.IsMatch(x, "^[A-Za-z0-9-]{20,64}$"))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (ids.Count > 0) return ids;
        }
        return new List<string>();
    }

    private static string ChooseDevice(List<string> udids)
    {
        if (udids.Count == 1) return udids[0];
        Console.WriteLine("偵測到多台裝置：");
        for (int i = 0; i < udids.Count; i++) Console.WriteLine($"  {i + 1}. {udids[i]}");
        while (true)
        {
            Console.Write("選擇裝置編號: ");
            if (int.TryParse(Console.ReadLine(), out int index) && index >= 1 && index <= udids.Count)
                return udids[index - 1];
        }
    }

    private static async Task<string> ResolveIpa(SetupConfig cfg, string udid, string deviceName)
    {
        string local = Path.Combine(BaseDir, cfg.LocalIpaFile ?? "PikminPilot.ipa");
        if (File.Exists(local) && new FileInfo(local).Length > 1024 * 100)
        {
            Console.WriteLine("✓ 使用 Setup 資料夾內現有 PikminPilot.ipa（local mode）");
            return local;
        }

        if (!string.IsNullOrWhiteSpace(cfg.IpaUrl))
        {
            Console.WriteLine("下載設定中的 IPA…");
            return await DownloadIpa(cfg.IpaUrl!);
        }

        if (!string.IsNullOrWhiteSpace(cfg.BootstrapApiBase))
        {
            return await RequestRegisteredIpa(cfg, udid, deviceName);
        }

        string requestPath = Path.Combine(BaseDir, "device-request.txt");
        File.WriteAllText(requestPath, $"UDID={udid}{Environment.NewLine}NAME={deviceName}{Environment.NewLine}");
        throw new InvalidOperationException(
            "這台裝置目前沒有可安裝的 IPA，而且 setup-config.json 尚未設定 bootstrapApiBase。\n" +
            $"UDID 已寫入：{requestPath}\n" +
            "你可以先到 GitHub Actions 執行 Register Device + Build Pilot，或部署 Toolkit 內的 BootstrapBackend 後再重跑 Setup。"
        );
    }

    private static async Task<string> RequestRegisteredIpa(SetupConfig cfg, string udid, string deviceName)
    {
        string api = cfg.BootstrapApiBase!.TrimEnd('/');
        Console.WriteLine("這台裝置需要註冊 / 重新簽名，正在送出 UDID…");

        using var req = new HttpRequestMessage(HttpMethod.Post, api + "/register");
        if (!string.IsNullOrWhiteSpace(cfg.RegistrationToken))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", cfg.RegistrationToken);
        req.Content = new StringContent(JsonSerializer.Serialize(new { udid, name = deviceName }), Encoding.UTF8, "application/json");
        using var resp = await Http.SendAsync(req);
        string body = await resp.Content.ReadAsStringAsync();
        if (!resp.IsSuccessStatusCode) throw new InvalidOperationException($"Registration backend failed: {(int)resp.StatusCode} {body}");
        var reply = JsonSerializer.Deserialize<BootstrapReply>(body, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                    ?? throw new InvalidOperationException("Registration backend returned invalid JSON");

        if (string.Equals(reply.status, "ready", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(reply.ipaUrl))
            return await DownloadIpa(reply.ipaUrl!);

        if (string.IsNullOrWhiteSpace(reply.requestId))
            throw new InvalidOperationException(reply.message ?? "Registration backend did not return requestId");

        Console.WriteLine($"✓ 註冊工作已送出 request={reply.requestId}");
        Console.WriteLine("等待 Apple device registration → profiles → GitHub build → release…");
        DateTime deadline = DateTime.UtcNow.AddMinutes(Math.Max(5, cfg.MaxWaitMinutes));
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(5, cfg.PollSeconds)));
            string statusUrl = api + "/status?requestId=" + Uri.EscapeDataString(reply.requestId!);
            using var statusReq = new HttpRequestMessage(HttpMethod.Get, statusUrl);
            if (!string.IsNullOrWhiteSpace(cfg.RegistrationToken))
                statusReq.Headers.Authorization = new AuthenticationHeaderValue("Bearer", cfg.RegistrationToken);
            using var statusResp = await Http.SendAsync(statusReq);
            string statusBody = await statusResp.Content.ReadAsStringAsync();
            if (!statusResp.IsSuccessStatusCode)
            {
                Console.Write(".");
                continue;
            }
            var status = JsonSerializer.Deserialize<BootstrapReply>(statusBody, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (status is not null && string.Equals(status.status, "ready", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(status.ipaUrl))
            {
                Console.WriteLine("\n✓ 專屬 provisioning build ready");
                return await DownloadIpa(status.ipaUrl!);
            }
            if (status is not null && string.Equals(status.status, "failed", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(status.message ?? "Registration/build failed");
            Console.Write(".");
        }
        throw new TimeoutException("等待註冊 / GitHub build 超時。請檢查 Register Device + Build Pilot workflow。 ");
    }

    private static async Task<string> DownloadIpa(string url)
    {
        string path = Path.Combine(Path.GetTempPath(), "PikminPilot-bootstrap.ipa");
        using var resp = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        resp.EnsureSuccessStatusCode();
        await using var input = await resp.Content.ReadAsStreamAsync();
        await using var output = File.Create(path);
        await input.CopyToAsync(output);
        if (new FileInfo(path).Length < 1024 * 100) throw new InvalidOperationException("Downloaded IPA is unexpectedly small");
        return path;
    }

    private static async Task InstallIpa(string udid, string ipa)
    {
        string tools = Tool("idevice-tools.exe");
        Console.WriteLine("\n安裝 Pikmin Pilot…");
        string[] installArgs = { "--udid", udid, "ideviceinstaller", "install", ipa };
        var install = await RunStreaming(tools, installArgs, allowFailure: true);
        if (install.ExitCode == 0) return;

        Console.WriteLine("Install 未成功，嘗試 upgrade…");
        string[] upgradeArgs = { "--udid", udid, "ideviceinstaller", "upgrade", ipa };
        var upgrade = await RunStreaming(tools, upgradeArgs, allowFailure: true);
        if (upgrade.ExitCode != 0)
            throw new InvalidOperationException("IPA 安裝失敗。最常見原因是：這台 UDID 尚未包含在 provisioning profile、尚未 Trust、或 Apple Mobile Device service 不可用。\n" + upgrade.Output);
    }

    private static async Task RunPairingHelper()
    {
        string helper = Tool("PikminPilotPairingSetup.exe");
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine("\n下一步：建立 Remote Pairing");
        Console.WriteLine("Pairing Setup 會自動開啟。請：Remote pairing → Create → Pikmin Pilot。");
        Console.WriteLine("完成後關閉 Pairing Setup，本程式會繼續。");
        Console.ResetColor();
        var p = Process.Start(new ProcessStartInfo(helper) { UseShellExecute = true })
                ?? throw new InvalidOperationException("Unable to launch pairing helper");
        await p.WaitForExitAsync();
    }

    private static string Tool(string name)
    {
        string path = Path.Combine(ToolsDir, name);
        if (!File.Exists(path)) throw new FileNotFoundException($"Missing bundled tool: {path}");
        return path;
    }

    private static async Task<(int ExitCode, string Output)> RunCapture(string exe, IEnumerable<string> args, bool allowFailure)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (string arg in args) psi.ArgumentList.Add(arg);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"Unable to launch {exe}");
        string stdout = await p.StandardOutput.ReadToEndAsync();
        string stderr = await p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        string output = stdout + Environment.NewLine + stderr;
        if (!allowFailure && p.ExitCode != 0) throw new InvalidOperationException(output);
        return (p.ExitCode, output);
    }

    private static async Task<(int ExitCode, string Output)> RunStreaming(string exe, IEnumerable<string> args, bool allowFailure)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (string arg in args) psi.ArgumentList.Add(arg);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"Unable to launch {exe}");
        var sb = new StringBuilder();
        p.OutputDataReceived += (_, e) => { if (e.Data is not null) { Console.WriteLine(e.Data); sb.AppendLine(e.Data); } };
        p.ErrorDataReceived += (_, e) => { if (e.Data is not null) { Console.WriteLine(e.Data); sb.AppendLine(e.Data); } };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        await p.WaitForExitAsync();
        if (!allowFailure && p.ExitCode != 0) throw new InvalidOperationException(sb.ToString());
        return (p.ExitCode, sb.ToString());
    }

    private static void Fail(string message)
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine("\nSETUP FAILED");
        Console.ResetColor();
        Console.WriteLine(message);
    }
}
