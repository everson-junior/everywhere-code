using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using EnvDTE;
using EnvDTE80;
using Microsoft.VisualStudio.Shell;
using Microsoft.VisualStudio.Shell.Interop;
using Process = System.Diagnostics.Process;

namespace Everywhere.Services
{
    public enum HarnessStatus
    {
        Stopped,
        Starting,
        Running,
        Error
    }

    public class DshManager : IDisposable
    {
        private static readonly Lazy<DshManager> _instance = new Lazy<DshManager>(() => new DshManager());
        public static DshManager Instance => _instance.Value;

        private Process? _currentProcess;
        private IVsOutputWindowPane? _outputPane;
        private readonly object _lock = new object();
        private int _installationInProgress;

        public HarnessStatus Status { get; private set; } = HarnessStatus.Stopped;
        public string? ActiveUrl { get; private set; }
        public int? ActivePort { get; private set; }
        public string? LastError { get; private set; }

        public event EventHandler<HarnessStatus>? StatusChanged;

        private DshManager() { }

        private void SetStatus(HarnessStatus newStatus, string? url = null, int? port = null, string? error = null)
        {
            Status = newStatus;
            ActiveUrl = url;
            ActivePort = port;
            LastError = error;
            StatusChanged?.Invoke(this, newStatus);
        }

        private void Log(string message)
        {
            ThreadHelper.ThrowIfNotOnUIThread();
            if (_outputPane == null)
            {
                var outWindow = Package.GetGlobalService(typeof(SVsOutputWindow)) as IVsOutputWindow;
                if (outWindow != null)
                {
                    Guid customGuid = new Guid("9694d93f-67a3-41bb-9467-f4e9a3bdf01a");
                    outWindow.CreatePane(ref customGuid, "EveryWhere Harness", 1, 1);
                    outWindow.GetPane(ref customGuid, out _outputPane);
                }
            }
            _outputPane?.OutputString($"[EveryWhere] {message}\n");
            _outputPane?.Activate();
        }

        public string ResolveWorkspaceDirectory()
        {
            ThreadHelper.ThrowIfNotOnUIThread();
            var dte = Package.GetGlobalService(typeof(DTE)) as DTE2;
            if (dte?.Solution != null && !string.IsNullOrEmpty(dte.Solution.FullName))
            {
                var dir = Path.GetDirectoryName(dte.Solution.FullName);
                if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
                {
                    return dir;
                }
            }
            return Environment.CurrentDirectory;
        }

        public string FindDshExecutable(string customPath)
        {
            if (!string.IsNullOrWhiteSpace(customPath) && File.Exists(customPath))
            {
                return customPath;
            }

            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var userHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

            string[] candidates = {
                Path.Combine(appData, "npm", "ewh.cmd"),
                Path.Combine(localAppData, "npm", "ewh.cmd"),
                Path.Combine(userHome, ".pnpm", "ewh.cmd"),
                Path.Combine(userHome, ".local", "share", "pnpm", "ewh.cmd"),
                Path.Combine(appData, "npm", "dsh.cmd"),
                Path.Combine(localAppData, "npm", "dsh.cmd"),
                Path.Combine(userHome, ".pnpm", "dsh.cmd"),
                Path.Combine(userHome, ".local", "share", "pnpm", "dsh.cmd"),
                "ewh.cmd",
                "ewh",
                "dsh.cmd",
                "dsh"
            };

            foreach (var path in candidates)
            {
                if (File.Exists(path))
                {
                    return path;
                }
            }

            return "ewh.cmd";
        }

        private string FindNpmExecutable()
        {
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var candidates = new[]
            {
                Path.Combine(programFiles, "nodejs", "npm.cmd"),
                Path.Combine(localAppData, "Programs", "nodejs", "npm.cmd")
            };
            foreach (var candidate in candidates)
            {
                if (File.Exists(candidate)) return candidate;
            }

            var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (var directory in path.Split(Path.PathSeparator))
            {
                if (string.IsNullOrWhiteSpace(directory)) continue;
                var candidate = Path.Combine(directory.Trim().Trim('"'), "npm.cmd");
                if (File.Exists(candidate)) return candidate;
            }
            return "npm.cmd";
        }

        private static string QuoteCmdArgument(string value)
        {
            if (!Regex.IsMatch(value, "[\\s&|<>()^\"%!]")) return value;
            return "\"" + Regex.Replace(value, "([\"^&|<>()%!])", "^$1") + "\"";
        }

        private static ProcessStartInfo CreateCommandStartInfo(string executable, string arguments, string? workingDirectory = null)
        {
            var isBatch = executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)
                || executable.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);
            var info = new ProcessStartInfo
            {
                FileName = isBatch ? Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe" : executable,
                Arguments = isBatch ? $"/d /s /c {QuoteCmdArgument(executable)} {arguments}" : arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            if (!string.IsNullOrWhiteSpace(workingDirectory)) info.WorkingDirectory = workingDirectory;
            return info;
        }

        private async System.Threading.Tasks.Task<int> RunNpmInstallAsync(string npmExecutable, string packageName)
        {
            Log($"Executing: {npmExecutable} install -g {packageName}");
            using var process = Process.Start(CreateCommandStartInfo(npmExecutable, $"install -g {packageName}"));
            if (process == null) return -1;

            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            await System.Threading.Tasks.Task.Run(() => process.WaitForExit());
            var output = await System.Threading.Tasks.Task.WhenAll(stdoutTask, stderrTask);
            await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
            foreach (var line in (output[0] + Environment.NewLine + output[1]).Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
            {
                Log(line);
            }
            return process.ExitCode;
        }

        public async System.Threading.Tasks.Task<bool> InstallHarnessAsync()
        {
            await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
            if (Interlocked.Exchange(ref _installationInProgress, 1) != 0)
            {
                return false;
            }

            try
            {
                var npmExecutable = FindNpmExecutable();
                Log("Installing pnpm (required by the Harness plugin installer)...");
                var pnpmExitCode = await RunNpmInstallAsync(npmExecutable, "pnpm");
                if (pnpmExitCode != 0)
                {
                    Log($"Warning: pnpm installation exited with code {pnpmExitCode}. Continuing...");
                }

                Log("Installing @everywhere-harness/ewh with npm...");
                var harnessExitCode = await RunNpmInstallAsync(npmExecutable, "@everywhere-harness/ewh");
                if (harnessExitCode == 0)
                {
                    Log("EveryWhere Code installed successfully.");
                    return true;
                }

                Log("Installation failed. Run `npm install -g @everywhere-harness/ewh` in a terminal.");
                return false;
            }
            catch (Exception ex)
            {
                await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                Log($"Installation failed: {ex.Message}. Run `npm install -g @everywhere-harness/ewh` in a terminal.");
                return false;
            }
            finally
            {
                Interlocked.Exchange(ref _installationInProgress, 0);
            }
        }

        public class RunningServiceInfo
        {
            public int Port { get; set; }
            public string Url { get; set; } = string.Empty;
        }

        public static string GetSavedSessionFile()
        {
            var userHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var ewhFile = Path.Combine(userHome, ".ewh", "last-session.json");
            if (File.Exists(ewhFile)) return ewhFile;
            var dshFile = Path.Combine(userHome, ".dsh", "last-session.json");
            if (File.Exists(dshFile)) return dshFile;
            return ewhFile;
        }

        public static void SaveSession(string rawUrl, int port, string token)
        {
            try
            {
                var file = GetSavedSessionFile();
                var dir = Path.GetDirectoryName(file);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                {
                    Directory.CreateDirectory(dir);
                }
                var escapedUrl = rawUrl.Replace("\\", "\\\\").Replace("\"", "\\\"");
                var escapedToken = (token ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"");
                var epoch = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                var json = $"{{\n  \"rawUrl\": \"{escapedUrl}\",\n  \"port\": {port},\n  \"token\": \"{escapedToken}\",\n  \"updatedAt\": {epoch}\n}}";
                File.WriteAllText(file, json);
            }
            catch { }
        }

        public static string? LoadSavedUrl(int port)
        {
            try
            {
                var file = GetSavedSessionFile();
                if (File.Exists(file))
                {
                    var content = File.ReadAllText(file);
                    var portMatch = Regex.Match(content, @"""port""\s*:\s*(\d+)");
                    var urlMatch = Regex.Match(content, @"""rawUrl""\s*:\s*""([^""]+)""");
                    if (urlMatch.Success)
                    {
                        if (portMatch.Success && int.TryParse(portMatch.Groups[1].Value, out var savedPort))
                        {
                            if (savedPort == port) return urlMatch.Groups[1].Value;
                        }
                        else
                        {
                            return urlMatch.Groups[1].Value;
                        }
                    }
                }
            }
            catch { }
            return null;
        }

        public static async Task<bool> ProbeDshPortAsync(int port)
        {
            try
            {
                using var client = new HttpClient { Timeout = TimeSpan.FromMilliseconds(1500) };
                var response = await client.GetAsync($"http://127.0.0.1:{port}/");
                int code = (int)response.StatusCode;
                if (code >= 200 && code < 400)
                {
                    return true;
                }
                if (code == 401)
                {
                    var body = await response.Content.ReadAsStringAsync();
                    if (body != null && body.IndexOf("dsh web authentication required", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        return true;
                    }
                }
            }
            catch { }
            return false;
        }

        public static async Task<RunningServiceInfo?> FindRunningDshAsync(int targetPort)
        {
            var portsToTry = new List<int>();
            if (targetPort > 0) portsToTry.Add(targetPort);
            if (!portsToTry.Contains(3080)) portsToTry.Add(3080);
            if (!portsToTry.Contains(3000)) portsToTry.Add(3000);

            foreach (var p in portsToTry)
            {
                if (await ProbeDshPortAsync(p))
                {
                    var saved = LoadSavedUrl(p);
                    var url = !string.IsNullOrEmpty(saved) ? saved! : $"http://127.0.0.1:{p}/";
                    return new RunningServiceInfo { Port = p, Url = url };
                }
            }
            return null;
        }

        public async Task<string> StartAsync(bool isRetry = false)
        {
            await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();

            if (Status == HarnessStatus.Running && !string.IsNullOrEmpty(ActiveUrl))
            {
                return ActiveUrl ?? string.Empty;
            }

            var options = EverywherePackage.Instance?.Options;
            var port = options?.Port ?? 0;

            var checkPort = port > 0 ? port : 3080;

            // Check if DSH is already running before spawning a new process
            var existing = await FindRunningDshAsync(checkPort);
            if (existing != null)
            {
                Log($"[EveryWhere Harness] Backend ready at:\n{existing.Url}");
                SetStatus(HarnessStatus.Running, existing.Url, existing.Port);
                return existing.Url;
            }

            SetStatus(HarnessStatus.Starting);
            Log("Starting EveryWhere Harness runtime...");

            var executable = FindDshExecutable(options?.CustomDshPath ?? "");
            var cwd = ResolveWorkspaceDirectory();
            var portArg = port > 0 ? $" --port {port}" : "";
            var profileArg = !string.IsNullOrWhiteSpace(options?.Profile) ? options.Profile : "web";
            var arguments = $"--profile {profileArg} --no-open{portArg}";

            var tcs = new TaskCompletionSource<string>();
            var cts = new CancellationTokenSource(TimeSpan.FromSeconds(65));

            cts.Token.Register(() =>
            {
                if (!tcs.Task.IsCompleted)
                {
                    SetStatus(HarnessStatus.Error, error: "Timeout waiting for EveryWhere Harness to start.");
                    tcs.TrySetException(new TimeoutException("Timeout waiting for EveryWhere Harness to start."));
                }
            });

            // Concurrently poll for active server
            _ = Task.Run(async () =>
            {
                for (int i = 0; i < 40; i++)
                {
                    if (tcs.Task.IsCompleted) return;
                    await Task.Delay(500);
                    if (tcs.Task.IsCompleted) return;

                    var runInfo = await FindRunningDshAsync(checkPort);
                    if (runInfo != null && !tcs.Task.IsCompleted)
                    {
                        await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                        Log($"[EveryWhere Harness] Backend ready at:\n{runInfo.Url}");
                        SetStatus(HarnessStatus.Running, runInfo.Url, runInfo.Port);
                        tcs.TrySetResult(runInfo.Url);
                        return;
                    }
                }
            });

            try
            {
                var startInfo = CreateCommandStartInfo(executable, arguments, cwd);

                if (!string.IsNullOrWhiteSpace(options?.ApiKey))
                {
                    startInfo.EnvironmentVariables["EVERYWHERE_API_KEY"] = options.ApiKey!;
                    startInfo.EnvironmentVariables["DEEPSEEK_API_KEY"] = options.ApiKey!;
                }
                if (!string.IsNullOrWhiteSpace(options?.BaseUrl))
                {
                    startInfo.EnvironmentVariables["EVERYWHERE_BASE_URL"] = options.BaseUrl!;
                    startInfo.EnvironmentVariables["DEEPSEEK_BASE_URL"] = options.BaseUrl!;
                }

                _currentProcess = new Process { StartInfo = startInfo };
                var urlRegex = new Regex(@"(?:ewh|dsh) web:\s+(https?://[^\s\)]+)", RegexOptions.IgnoreCase);

                _currentProcess.OutputDataReceived += async (s, e) =>
                {
                    if (string.IsNullOrEmpty(e.Data)) return;
                    await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                    Log(e.Data);

                    var match = urlRegex.Match(e.Data);
                    if (match.Success)
                    {
                        var url = match.Groups[1].Value;
                        int detectedPort = 3080;
                        try
                        {
                            var uri = new Uri(url);
                            detectedPort = uri.Port;
                            var tokenMatch = Regex.Match(url, @"[?&]token=([^&#]+)");
                            var token = tokenMatch.Success ? tokenMatch.Groups[1].Value : "";
                            SaveSession(url, detectedPort, token);
                        }
                        catch { }

                        Log($"[EveryWhere Harness] Backend ready at:\n{url}");

                        if (!tcs.Task.IsCompleted)
                        {
                            SetStatus(HarnessStatus.Running, url, detectedPort);
                            tcs.TrySetResult(url);
                        }
                    }
                };

                _currentProcess.ErrorDataReceived += async (s, e) =>
                {
                    if (string.IsNullOrEmpty(e.Data)) return;
                    await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                    Log(e.Data);
                };

                _currentProcess.EnableRaisingEvents = true;
                _currentProcess.Exited += async (s, e) =>
                {
                    await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                    int exitCode = _currentProcess?.ExitCode ?? -1;
                    Log($"Process exited with code {exitCode}");

                    if (!tcs.Task.IsCompleted)
                    {
                        // Check if an existing service was already running on this port
                        var runningExisting = await FindRunningDshAsync(checkPort);
                        if (runningExisting != null)
                        {
                            Log($"[EveryWhere Harness] Backend ready at:\n{runningExisting.Url}");
                            SetStatus(HarnessStatus.Running, runningExisting.Url, runningExisting.Port);
                            tcs.TrySetResult(runningExisting.Url);
                            return;
                        }

                        // Auto-retry on Exit Code 1 only if NOT already running
                        if (!isRetry && exitCode == 1)
                        {
                            Log("Startup failed with exit code 1. Stopping orphan services and retrying start...");
                            try
                            {
                                await StopAsync();
                                await Task.Delay(1000);
                                var retryUrl = await StartAsync(isRetry: true);
                                tcs.TrySetResult(retryUrl);
                                return;
                            }
                            catch (Exception retryEx)
                            {
                                var retryErrMsg = $"Automatic restart failed: {retryEx.Message}";
                                SetStatus(HarnessStatus.Error, error: retryErrMsg);
                                tcs.TrySetException(new Exception(retryErrMsg));
                                return;
                            }
                        }

                        var errMsg = $"EveryWhere Harness exited with code {exitCode}";
                        SetStatus(HarnessStatus.Error, error: errMsg);
                        tcs.TrySetException(new Exception(errMsg));
                    }
                    else
                    {
                        SetStatus(HarnessStatus.Stopped);
                    }
                };

                _currentProcess.Start();
                _currentProcess.BeginOutputReadLine();
                _currentProcess.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                SetStatus(HarnessStatus.Error, error: ex.Message);
                tcs.TrySetException(ex);
            }

            return await tcs.Task;
        }

        public async Task StopAsync()
        {
            await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
            Log("Stopping EveryWhere Harness and cleaning orphan processes...");

            lock (_lock)
            {
                if (_currentProcess != null && !_currentProcess.HasExited)
                {
                    try
                    {
                        _currentProcess.Kill();
                    }
                    catch { }
                }
                _currentProcess = null;
            }

            // Terminate orphan processes on known DSH ports (3080, 3000 or custom)
            await KillOrphanProcessesAsync();
            SetStatus(HarnessStatus.Stopped);
            Log("EveryWhere Harness stopped.");
        }

        public async Task RestartAsync()
        {
            await StopAsync();
            await Task.Delay(1000);
            await StartAsync();
        }

        private async Task KillOrphanProcessesAsync()
        {
            await Task.Run(() =>
            {
                try
                {
                    // Kill any orphan ewh or dsh processes on Windows
                    foreach (var exeName in new[] { "ewh.exe", "dsh.exe" })
                    {
                        var killProc = new ProcessStartInfo
                        {
                            FileName = "taskkill.exe",
                            Arguments = $"/F /IM {exeName} /T",
                            CreateNoWindow = true,
                            UseShellExecute = false
                        };
                        using (var p = Process.Start(killProc))
                        {
                            p?.WaitForExit(2000);
                        }
                    }
                }
                catch { }

                int[] targetPorts = { ActivePort ?? 3080, 3080, 3000 };
                foreach (var port in targetPorts)
                {
                    if (port > 0)
                    {
                        KillProcessOnPort(port);
                    }
                }
            });
        }

        private void KillProcessOnPort(int port)
        {
            try
            {
                var netstat = new ProcessStartInfo
                {
                    FileName = "netstat.exe",
                    Arguments = "-ano",
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    RedirectStandardOutput = true
                };

                using var p = Process.Start(netstat);
                if (p == null) return;
                var output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(2000);

                var regex = new Regex($@"(?:127\.0\.0\.1|0\.0\.0\.0):{port}\s+.*LISTENING\s+(\d+)", RegexOptions.IgnoreCase);
                var match = regex.Match(output);
                if (match.Success)
                {
                    var pid = match.Groups[1].Value;
                    var kill = new ProcessStartInfo
                    {
                        FileName = "taskkill.exe",
                        Arguments = $"/PID {pid} /T /F",
                        CreateNoWindow = true,
                        UseShellExecute = false
                    };
                    using var killProc = Process.Start(kill);
                    killProc?.WaitForExit(2000);
                }
            }
            catch { }
        }

        public void Dispose()
        {
            lock (_lock)
            {
                if (_currentProcess != null && !_currentProcess.HasExited)
                {
                    try
                    {
                        _currentProcess.Kill();
                    }
                    catch { }
                }
                _currentProcess = null;
            }
        }
    }
}
