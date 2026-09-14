using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;

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
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) => Fatal(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Fatal(e.ExceptionObject as Exception ?? new Exception("Unknown fatal error"));
        Application.Run(new MainForm());
    }

    private static void Fatal(Exception ex)
    {
        try { File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "PikminPilotSetup.log"), $"{DateTime.Now:O} FATAL {ex}\r\n"); } catch { }
        try { MessageBox.Show(ex.ToString(), "Pikmin Pilot Setup — Fatal Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
    }
}

internal sealed class MainForm : Form
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };
    private static string BaseDir => AppContext.BaseDirectory;
    private static string ToolsDir => Path.Combine(BaseDir, "tools");
    private static string LogPath => Path.Combine(BaseDir, "PikminPilotSetup.log");

    private readonly Label _title = new();
    private readonly Label _status = new();
    private readonly TextBox _udid = new();
    private readonly Button _setup = new();
    private readonly Button _refresh = new();
    private readonly Button _pairing = new();
    private readonly Button _openLog = new();
    private readonly TextBox _log = new();
    private string? _currentUdid;

    public MainForm()
    {
        Text = "Pikmin Pilot Setup v2.3";
        Width = 820;
        Height = 650;
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new System.Drawing.Size(720, 540);

        _title.Text = "Pikmin Pilot — Windows One-Time Setup";
        _title.Font = new System.Drawing.Font(System.Drawing.SystemFonts.DefaultFont.FontFamily, 16, System.Drawing.FontStyle.Bold);
        _title.AutoSize = true;
        _title.Left = 20;
        _title.Top = 18;

        _status.Text = "正在檢查 iPhone / iPad…";
        _status.AutoSize = true;
        _status.Left = 22;
        _status.Top = 58;

        var udidLabel = new Label { Text = "Detected UDID", AutoSize = true, Left = 22, Top = 93 };
        _udid.Left = 22;
        _udid.Top = 114;
        _udid.Width = 610;
        _udid.ReadOnly = true;

        _refresh.Text = "重新偵測";
        _refresh.Left = 646;
        _refresh.Top = 112;
        _refresh.Width = 125;
        _refresh.Click += async (_, _) => await RefreshDeviceAsync();

        _setup.Text = "SET UP THIS IPHONE / IPAD";
        _setup.Left = 22;
        _setup.Top = 158;
        _setup.Width = 310;
        _setup.Height = 48;
        _setup.Enabled = false;
        _setup.Click += async (_, _) => await SetupAsync();

        _pairing.Text = "開啟 Pairing 視窗";
        _pairing.Left = 344;
        _pairing.Top = 158;
        _pairing.Width = 180;
        _pairing.Height = 48;
        _pairing.Click += async (_, _) => await LaunchPairingHelperAsync(waitForExit: false);

        _openLog.Text = "開啟 Log";
        _openLog.Left = 536;
        _openLog.Top = 158;
        _openLog.Width = 120;
        _openLog.Height = 48;
        _openLog.Click += (_, _) => OpenLog();

        _log.Left = 22;
        _log.Top = 224;
        _log.Width = 750;
        _log.Height = 365;
        _log.Multiline = true;
        _log.ReadOnly = true;
        _log.ScrollBars = ScrollBars.Vertical;
        _log.Font = new System.Drawing.Font("Consolas", 9);
        _log.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;

        Controls.AddRange(new Control[] { _title, _status, udidLabel, _udid, _refresh, _setup, _pairing, _openLog, _log });
        Shown += async (_, _) => await RefreshDeviceAsync();
    }

    private async Task RefreshDeviceAsync()
    {
        // Do not lock the entire window during USB discovery. The user must always
        // be able to move the window and open the log even if a USB backend stalls.
        _refresh.Enabled = false;
        _setup.Enabled = false;
        _status.Text = "正在偵測 USB 裝置…（每個偵測器最多 8–10 秒）";
        Cursor = Cursors.Default;
        try
        {
            var udids = await DetectDevices();
            if (udids.Count == 0)
            {
                _currentUdid = null;
                _udid.Text = "";
                _status.Text = "找不到裝置 — USB 偵測已停止，不會繼續轉圈";
                Log("找不到 iPhone / iPad。請確認：USB 已連線、手機解鎖並按『信任』、Apple Mobile Device/iTunes 驅動正常。可按『開啟 Log』查看 idevice_id / pymobiledevice3 的實際結果。", error: true);
                MessageBox.Show(
                    "8–10 秒內沒有偵測到 iPhone / iPad。\n\n請確認：\n1. 手機已解鎖並按『信任』\n2. Apple Mobile Device / iTunes USB driver 正常\n3. 重新插拔 USB 後按『重新偵測』\n\nSetup 不會再無限轉圈。詳細資料請看 Log。",
                    "USB device not detected", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (udids.Count > 1)
            {
                _currentUdid = null;
                _udid.Text = string.Join(", ", udids);
                _status.Text = "偵測到多台裝置；請只留下要設定的那一台 USB 裝置";
                Log("偵測到多台裝置，為避免把 IPA / pairing 寫到錯的裝置，本版要求一次只接一台。", error: true);
                return;
            }
            _currentUdid = udids[0];
            _udid.Text = _currentUdid;
            _status.Text = "裝置已就緒。按下 SET UP THIS IPHONE / IPAD。";
            Log($"Detected device: {_currentUdid}");
        }
        catch (Exception ex)
        {
            _currentUdid = null;
            _status.Text = "裝置偵測失敗";
            Log(ex.Message, error: true);
            MessageBox.Show(ex.Message, "Device detection failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            _refresh.Enabled = true;
            _pairing.Enabled = true;
            _openLog.Enabled = true;
            _setup.Enabled = !string.IsNullOrWhiteSpace(_currentUdid);
            Cursor = Cursors.Default;
        }
    }

    private async Task SetupAsync()
    {
        if (string.IsNullOrWhiteSpace(_currentUdid))
        {
            await RefreshDeviceAsync();
            if (string.IsNullOrWhiteSpace(_currentUdid)) return;
        }

        SetBusy(true, "設定中…請保持 iPhone / iPad 解鎖並連著 USB");
        try
        {
            string udid = _currentUdid!;
            var config = LoadConfig();
            string deviceName = $"Pikmin-{udid[^Math.Min(8, udid.Length)..]}";

            Log("STEP 1/3 — resolving signed Pikmin Pilot IPA");
            string ipa = await ResolveIpa(config, udid, deviceName);
            Log($"IPA ready: {ipa}");

            Log("STEP 2/3 — installing Pikmin Pilot");
            await InstallIpa(udid, ipa);
            Log("Pikmin Pilot install/upgrade completed.");

            Log("STEP 3/3 — opening Remote Pairing GUI");
            MessageBox.Show(
                "Pikmin Pilot 已安裝。接下來會開啟 Pairing 視窗。\n\n請選：\n1. 你的 iPhone / iPad\n2. Remote pairing\n3. Create\n4. Pikmin Pilot\n\n完成後關閉 Pairing 視窗。",
                "Remote Pairing",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);

            await LaunchPairingHelperAsync(waitForExit: true);
            _status.Text = "Setup 完成 — 拔掉 USB，開 Pikmin Pilot → START PILOT";
            Log("SETUP COMPLETE");
            MessageBox.Show(
                "Setup 完成。\n\n拔掉 USB，打開 Pikmin Pilot，按 START PILOT。",
                "Pikmin Pilot Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            _status.Text = "Setup 失敗 — 詳細原因已寫入 Log";
            Log(ex.ToString(), error: true);
            MessageBox.Show(ex.Message + "\n\n詳細資料：PikminPilotSetup.log", "Setup failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            SetBusy(false);
        }
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

    private async Task<List<string>> DetectDevices()
    {
        // v2.3: prefer pymobiledevice3 when it is already installed. On the
        // reference Windows machine this responds immediately while the bundled
        // idevice_id backend can block in usbmuxd. Users without Python still
        // fall back to the self-contained bundled detector.
        foreach (var python in new[] { "python.exe", "python", "py.exe", "py" })
        {
            try
            {
                string[] args = (python.Equals("py.exe", StringComparison.OrdinalIgnoreCase) || python.Equals("py", StringComparison.OrdinalIgnoreCase))
                    ? new[] { "-3", "-m", "pymobiledevice3", "usbmux", "list" }
                    : new[] { "-m", "pymobiledevice3", "usbmux", "list" };
                Log($"USB primary probe: {python} {string.Join(" ", args)} (6s timeout)");
                var result = await RunCapture(python, args, allowFailure: true, timeout: TimeSpan.FromSeconds(6), searchPath: true);
                if (result.ExitCode == 0)
                {
                    var ids = ParsePymobiledeviceJson(result.Output);
                    if (ids.Count > 0)
                    {
                        Log("USB device detected through pymobiledevice3.");
                        return ids;
                    }
                }
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // Python launcher not installed; try the next candidate.
            }
            catch (TimeoutException ex)
            {
                Log(ex.Message, error: true);
            }
            catch (Exception ex)
            {
                Log($"pymobiledevice3 probe failed via {python}: {ex.Message}", error: true);
            }
        }

        string exe = Tool("idevice_id.exe");
        Log($"USB fallback probe: {Path.GetFileName(exe)} -l (6s timeout)");
        try
        {
            var result = await RunCapture(exe, new[] { "-l" }, allowFailure: true, timeout: TimeSpan.FromSeconds(6));
            Log($"idevice_id exit={result.ExitCode} output={Compact(result.Output)}");
            var ids = ParseUdidLines(result.Output);
            if (ids.Count > 0) return ids;
        }
        catch (TimeoutException ex)
        {
            Log(ex.Message, error: true);
        }
        catch (Exception ex)
        {
            Log($"Bundled idevice_id failed: {ex.Message}", error: true);
        }

        return new List<string>();
    }

    private static List<string> ParseUdidLines(string output)
    {
        return output
            .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim())
            .Where(x => Regex.IsMatch(x, "^[A-Za-z0-9-]{20,64}$"))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static List<string> ParsePymobiledeviceJson(string output)
    {
        try
        {
            int start = output.IndexOf('[');
            int end = output.LastIndexOf(']');
            if (start < 0 || end <= start) return new List<string>();
            using var doc = JsonDocument.Parse(output.Substring(start, end - start + 1));
            var ids = new List<string>();
            foreach (var item in doc.RootElement.EnumerateArray())
            {
                foreach (string key in new[] { "UniqueDeviceID", "Identifier", "UDID" })
                {
                    if (item.TryGetProperty(key, out var value))
                    {
                        string? id = value.GetString();
                        if (!string.IsNullOrWhiteSpace(id) && Regex.IsMatch(id, "^[A-Za-z0-9-]{20,64}$"))
                        {
                            ids.Add(id);
                            break;
                        }
                    }
                }
            }
            return ids.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        }
        catch
        {
            return new List<string>();
        }
    }

    private static string Compact(string text)
    {
        string oneLine = Regex.Replace(text ?? string.Empty, "\\s+", " ").Trim();
        return oneLine.Length <= 500 ? oneLine : oneLine[..500] + "…";
    }

    private static async Task<string> ResolveIpa(SetupConfig cfg, string udid, string deviceName)
    {
        string local = Path.Combine(BaseDir, string.IsNullOrWhiteSpace(cfg.LocalIpaFile) ? "PikminPilot.ipa" : cfg.LocalIpaFile);
        if (File.Exists(local) && new FileInfo(local).Length > 100 * 1024)
        {
            ValidateHostIpa(local);
            return local;
        }

        if (!string.IsNullOrWhiteSpace(cfg.IpaUrl))
        {
            string downloaded = await DownloadIpa(cfg.IpaUrl!);
            ValidateHostIpa(downloaded);
            return downloaded;
        }

        if (!string.IsNullOrWhiteSpace(cfg.BootstrapApiBase))
        {
            string registered = await RequestRegisteredIpa(cfg, udid, deviceName);
            ValidateHostIpa(registered);
            return registered;
        }

        string requestPath = Path.Combine(BaseDir, "device-request.txt");
        File.WriteAllText(requestPath, $"UDID={udid}{Environment.NewLine}NAME={deviceName}{Environment.NewLine}");
        throw new InvalidOperationException(
            "Setup 包裡沒有 PikminPilot.ipa，而且尚未設定 registration backend。\n\n" +
            $"此裝置 UDID 已寫入：{requestPath}\n\n" +
            "如果這是你自己測試，請先讓 GitHub build-ios.yml 成功一次，再重新 build Full Windows Setup v2.3。"
        );
    }

    private static void ValidateHostIpa(string ipa)
    {
        if (!File.Exists(ipa)) throw new FileNotFoundException("IPA not found", ipa);
        using var zip = ZipFile.OpenRead(ipa);
        bool hasHost = zip.Entries.Any(e => string.Equals(e.FullName, "Payload/PikminPilot.app/Info.plist", StringComparison.Ordinal));
        bool runnerAtPayloadRoot = zip.Entries.Any(e => e.FullName.StartsWith("Payload/PikminPilotRunnerUITests-Runner.app/", StringComparison.Ordinal));
        bool hasEmbeddedRunner = zip.Entries.Any(e => e.FullName.StartsWith("Payload/PikminPilot.app/", StringComparison.Ordinal)
            && e.FullName.EndsWith("PikminPilotEmbeddedRunner.ipa", StringComparison.Ordinal));

        if (!hasHost || runnerAtPayloadRoot)
        {
            throw new InvalidOperationException(
                "Setup 取得的不是 Pikmin Pilot 主 IPA，而是 Runner-only / 錯誤 IPA。\n\n" +
                "正確 IPA 必須包含 Payload/PikminPilot.app。請用 Full Windows Setup v2.3 重新打包。"
            );
        }
        if (!hasEmbeddedRunner)
        {
            throw new InvalidOperationException("Pikmin Pilot 主 IPA 缺少 PikminPilotEmbeddedRunner.ipa；拒絕安裝不完整 package。");
        }
    }

    private static async Task<string> RequestRegisteredIpa(SetupConfig cfg, string udid, string deviceName)
    {
        string api = cfg.BootstrapApiBase!.TrimEnd('/');
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
            if (!statusResp.IsSuccessStatusCode) continue;
            var status = JsonSerializer.Deserialize<BootstrapReply>(statusBody, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (status is not null && string.Equals(status.status, "ready", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(status.ipaUrl))
                return await DownloadIpa(status.ipaUrl!);
            if (status is not null && string.Equals(status.status, "failed", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(status.message ?? "Registration/build failed");
        }
        throw new TimeoutException("等待註冊 / GitHub build 超時。請檢查 Register Device + Build Pilot workflow。");
    }

    private static async Task<string> DownloadIpa(string url)
    {
        string path = Path.Combine(Path.GetTempPath(), "PikminPilot-bootstrap.ipa");
        using var resp = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        resp.EnsureSuccessStatusCode();
        await using var input = await resp.Content.ReadAsStreamAsync();
        await using var output = File.Create(path);
        await input.CopyToAsync(output);
        if (new FileInfo(path).Length < 100 * 1024) throw new InvalidOperationException("Downloaded IPA is unexpectedly small");
        return path;
    }

    private static async Task InstallIpa(string udid, string ipa)
    {
        string tools = Tool("idevice-tools.exe");
        var install = await RunCapture(tools, new[] { "--udid", udid, "ideviceinstaller", "install", ipa }, allowFailure: true, timeout: TimeSpan.FromMinutes(15));
        if (install.ExitCode == 0 && install.Output.Contains("install success", StringComparison.OrdinalIgnoreCase)) return;

        var upgrade = await RunCapture(tools, new[] { "--udid", udid, "ideviceinstaller", "upgrade", ipa }, allowFailure: true, timeout: TimeSpan.FromMinutes(15));
        if (upgrade.ExitCode == 0 && upgrade.Output.Contains("upgrade success", StringComparison.OrdinalIgnoreCase)) return;

        string combined = install.Output + Environment.NewLine + upgrade.Output;
        if (combined.Contains("provision", StringComparison.OrdinalIgnoreCase) || combined.Contains("verification", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("IPA 被 iOS 拒絕。主 IPA 結構已驗證正確；如果錯誤仍是 0xe8008015，才表示目前簽名用的 App / Tunnel / XCTRunner provisioning profile 至少有一個不包含這台 UDID。\n\n" + combined);
        throw new InvalidOperationException("Pikmin Pilot IPA 安裝失敗。確認手機已解鎖、已 Trust、Apple Mobile Device 驅動可用。\n\n" + combined);
    }

    private async Task LaunchPairingHelperAsync(bool waitForExit)
    {
        try
        {
            string helper = Tool("PikminPilotPairingSetup.exe");
            var sw = Stopwatch.StartNew();
            var psi = new ProcessStartInfo(helper)
            {
                WorkingDirectory = ToolsDir,
                UseShellExecute = true
            };
            var p = Process.Start(psi) ?? throw new InvalidOperationException("Windows 無法啟動 Pairing helper");
            Log($"Pairing helper started, PID={p.Id}");
            if (!waitForExit) return;
            await p.WaitForExitAsync();
            sw.Stop();
            Log($"Pairing helper exited code={p.ExitCode}, runtime={sw.Elapsed.TotalSeconds:F1}s");
            if (sw.Elapsed < TimeSpan.FromSeconds(2))
                throw new InvalidOperationException(
                    "Pairing 視窗幾乎立刻關閉。這通常表示 Windows 執行環境 / Apple Mobile Device 支援有問題。\n\n" +
                    "v2.3 已把 Rust CRT 靜態連結；如果仍發生，請把 PikminPilotSetup.log 給我。"
                );
        }
        catch (Exception ex)
        {
            Log(ex.ToString(), error: true);
            if (!waitForExit)
                MessageBox.Show(ex.Message, "Pairing helper failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            else
                throw;
        }
    }

    private static string Tool(string name)
    {
        string path = Path.Combine(ToolsDir, name);
        if (!File.Exists(path)) throw new FileNotFoundException($"Setup package is incomplete. Missing bundled tool: {path}");
        return path;
    }

    private static async Task<(int ExitCode, string Output)> RunCapture(
        string exe,
        IEnumerable<string> args,
        bool allowFailure,
        TimeSpan? timeout = null,
        bool searchPath = false)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = searchPath ? BaseDir : (Path.GetDirectoryName(exe) ?? BaseDir)
        };
        foreach (string arg in args) psi.ArgumentList.Add(arg);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"Unable to launch {exe}");
        Task<string> stdoutTask = p.StandardOutput.ReadToEndAsync();
        Task<string> stderrTask = p.StandardError.ReadToEndAsync();
        TimeSpan limit = timeout ?? TimeSpan.FromMinutes(2);
        using var cts = new CancellationTokenSource(limit);
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException)
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            throw new TimeoutException($"{Path.GetFileName(exe)} did not return within {limit.TotalSeconds:F0}s and was stopped. This usually means the Apple USB/usbmuxd backend is not responding.");
        }
        string output = (await stdoutTask) + Environment.NewLine + (await stderrTask);
        if (!allowFailure && p.ExitCode != 0) throw new InvalidOperationException(output);
        return (p.ExitCode, output);
    }

    private void SetBusy(bool busy, string? status = null)
    {
        _setup.Enabled = !busy && !string.IsNullOrWhiteSpace(_currentUdid);
        _refresh.Enabled = !busy;
        _pairing.Enabled = !busy;
        if (!string.IsNullOrWhiteSpace(status)) _status.Text = status;
        Cursor = busy ? Cursors.WaitCursor : Cursors.Default;
    }

    private void Log(string text, bool error = false)
    {
        string line = $"[{DateTime.Now:HH:mm:ss}] {(error ? "ERROR " : "")}{text}";
        if (InvokeRequired) { BeginInvoke((MethodInvoker)(() => Log(text, error))); return; }
        _log.AppendText(line + Environment.NewLine);
        try { File.AppendAllText(LogPath, $"{DateTime.Now:O} {(error ? "ERROR " : "")}{text}{Environment.NewLine}"); } catch { }
    }

    private void OpenLog()
    {
        try
        {
            if (!File.Exists(LogPath)) File.WriteAllText(LogPath, "Pikmin Pilot Setup log\r\n");
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{LogPath}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Unable to open log", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
