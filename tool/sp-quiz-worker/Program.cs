using System.Diagnostics;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.NetworkInformation;
using System.Net.WebSockets;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.EventLog;

var builder = Host.CreateApplicationBuilder();
builder.Services.AddWindowsService(options => options.ServiceName = "SpQuizWorker");
builder.Logging.AddEventLog(options => options.SourceName = "SP Quiz Worker");
builder.Logging.AddFilter<EventLogLoggerProvider>(null, LogLevel.Information);
builder.Services.AddSingleton(WorkerConfiguration.Load(
    args.SingleOrDefault() ?? Path.Combine(AppContext.BaseDirectory, "worker.private.json")));
builder.Services.AddHostedService<QuizWorker>();
await builder.Build().RunAsync();

internal sealed record WorkerConfiguration(
    Uri SupabaseUrl, string SupabaseKey, string WorkerToken,
    string OllamaExecutable, string OllamaModels, int OllamaPort, string Model)
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
    };

    public static WorkerConfiguration Load(string path)
    {
        var result = JsonSerializer.Deserialize<WorkerConfiguration>(File.ReadAllText(path), Json)
            ?? throw new InvalidDataException("Missing worker configuration.");
        if (result.SupabaseUrl.Scheme != Uri.UriSchemeHttps && !result.SupabaseUrl.IsLoopback)
            throw new InvalidDataException("Remote Supabase requires HTTPS.");
        if (!Path.IsPathFullyQualified(result.OllamaExecutable) || !File.Exists(result.OllamaExecutable)
            || !Path.IsPathFullyQualified(result.OllamaModels) || !Directory.Exists(result.OllamaModels)
            || result.OllamaPort is < 1024 or > 65535
            || string.IsNullOrWhiteSpace(result.WorkerToken) || string.IsNullOrWhiteSpace(result.SupabaseKey)
            || string.IsNullOrWhiteSpace(result.Model))
            throw new InvalidDataException("Missing model, absolute runtime path, port, or Supabase credential.");
        return result;
    }
}

internal sealed class QuizWorker(WorkerConfiguration config, ILogger<QuizWorker> logger) : BackgroundService
{
    private static readonly JsonSerializerOptions Json = WorkerConfiguration.Json;
    private static readonly object OutputSchema = new
    {
        type = "object",
        properties = new { statement = new { type = "string" }, answer = new { type = "boolean" } },
        required = new[] { "statement", "answer" },
        additionalProperties = false
    };
    private readonly SemaphoreSlim pending = new(0, 1);
    private readonly HttpClient supabase = new() { BaseAddress = config.SupabaseUrl, Timeout = TimeSpan.FromSeconds(6) };
    private readonly HttpClient ollama = new()
    {
        BaseAddress = new Uri($"http://127.0.0.1:{config.OllamaPort}"),
        Timeout = TimeSpan.FromSeconds(15)
    };
    private Process? process;
    private SafeFileHandle? processGroup;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        supabase.DefaultRequestHeaders.Add("apikey", config.SupabaseKey);
        supabase.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", config.WorkerToken);
        using var stopping = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        var connection = Listen(stopping.Token);
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await EnsureModel(stoppingToken);
                    // Notification normally wakes this immediately. The timeout
                    // recovers missed notifications and expired database leases.
                    await pending.WaitAsync(TimeSpan.FromSeconds(3), stoppingToken);
                    while (await Claim(stoppingToken) is { } job)
                        await Generate(job, stoppingToken);
                }
                catch (Exception failure) when (!stoppingToken.IsCancellationRequested &&
                    failure is HttpRequestException or TimeoutException or TaskCanceledException)
                {
                    logger.LogWarning("Quiz worker will retry after {Type}.", failure.GetType().Name);
                    await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        catch (Exception failure)
        {
            logger.LogError("Quiz worker exhausted recovery after {Type}.", failure.GetType().Name);
            StopOllama();
            Environment.Exit(1); // Enable configured SCM recovery.
        }
        finally
        {
            await stopping.CancelAsync();
            try { await connection; }
            finally { StopOllama(); }
        }
    }

    private void Wake()
    {
        if (pending.CurrentCount == 0) pending.Release();
    }

    private async Task Listen(CancellationToken token)
    {
        var endpoint = new UriBuilder(config.SupabaseUrl)
        {
            Scheme = config.SupabaseUrl.Scheme == "https" ? "wss" : "ws",
            Path = "/realtime/v1/websocket",
            Query = "apikey=" + Uri.EscapeDataString(config.SupabaseKey) + "&vsn=1.0.0"
        }.Uri;
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var socket = new ClientWebSocket();
                using var session = CancellationTokenSource.CreateLinkedTokenSource(token);
                using var connect = CancellationTokenSource.CreateLinkedTokenSource(session.Token);
                connect.CancelAfter(TimeSpan.FromSeconds(8));
                await socket.ConnectAsync(endpoint, connect.Token);
                await Send(socket, "realtime:sp-quiz-worker", "phx_join", new
                {
                    config = new
                    {
                        broadcast = new { self = false, ack = false },
                        presence = new { enabled = false },
                        postgres_changes = Array.Empty<object>(),
                        @private = true
                    },
                    access_token = config.WorkerToken
                }, "join", connect.Token);
                var heartbeat = Heartbeat(socket, session.Token);
                try
                {
                    bool joined = false;
                    while (!token.IsCancellationRequested)
                    {
                        using var messageTimeout = CancellationTokenSource.CreateLinkedTokenSource(session.Token);
                        messageTimeout.CancelAfter(joined ? TimeSpan.FromSeconds(35) : TimeSpan.FromSeconds(8));
                        using var message = await Receive(socket, messageTimeout.Token);
                        var frame = message.RootElement;
                        string? kind = frame.GetProperty("event").GetString();
                        if (kind is "phx_error" or "phx_close")
                            throw new WebSocketException("Realtime channel closed.");
                        if (kind == "phx_reply" && frame.GetProperty("ref").GetString() == "join")
                        {
                            joined = frame.GetProperty("payload").GetProperty("status").GetString() == "ok";
                            if (!joined) throw new WebSocketException("Realtime rejected the private worker channel.");
                            logger.LogInformation("Subscribed to the private quiz worker channel.");
                            Wake();
                        }
                        if (kind == "broadcast" && joined
                            && frame.GetProperty("payload").GetProperty("event").GetString() == "quiz-request")
                            Wake();
                    }
                }
                finally
                {
                    await session.CancelAsync();
                    socket.Abort();
                    try { await heartbeat; }
                    catch (OperationCanceledException) when (session.IsCancellationRequested) { }
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (Exception failure) when (failure is WebSocketException or HttpRequestException
                or OperationCanceledException or JsonException or KeyNotFoundException or InvalidOperationException)
            {
                logger.LogWarning("Realtime disconnected ({Type}); reconnecting.", failure.GetType().Name);
            }
            try { await Task.Delay(TimeSpan.FromSeconds(2), token); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
        }
    }

    private static async Task Heartbeat(ClientWebSocket socket, CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
        int sequence = 0;
        try
        {
            while (await timer.WaitForNextTickAsync(token))
                await Send(socket, "phoenix", "heartbeat", new { }, $"h{++sequence}", token);
        }
        catch (WebSocketException) { socket.Abort(); }
    }

    private static Task Send(ClientWebSocket socket, string topic, string kind, object payload, string reference,
        CancellationToken token) => socket.SendAsync(
            new ArraySegment<byte>(JsonSerializer.SerializeToUtf8Bytes(
                new { topic, @event = kind, payload, @ref = reference }, Json)),
            WebSocketMessageType.Text, true, token);

    private static async Task<JsonDocument> Receive(ClientWebSocket socket, CancellationToken token)
    {
        using var frame = new MemoryStream();
        var buffer = new byte[4096];
        WebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
            if (result.MessageType != WebSocketMessageType.Text || frame.Length + result.Count > 65536)
                throw new WebSocketException("Invalid realtime frame.");
            frame.Write(buffer, 0, result.Count);
        } while (!result.EndOfMessage);
        return JsonDocument.Parse(frame.ToArray());
    }

    private async Task EnsureModel(CancellationToken token)
    {
        if (process is null || process.HasExited)
        {
            process?.Dispose();
            if (IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners()
                .Any(address => address.Port == config.OllamaPort))
                throw new InvalidOperationException("The configured Ollama port is occupied.");
            var start = new ProcessStartInfo(config.OllamaExecutable, "serve")
            {
                UseShellExecute = false, CreateNoWindow = true
            };
            start.Environment["OLLAMA_HOST"] = $"127.0.0.1:{config.OllamaPort}";
            start.Environment["OLLAMA_MODELS"] = config.OllamaModels;
            start.Environment["OLLAMA_NO_CLOUD"] = "1";
            start.Environment["OLLAMA_KEEP_ALIVE"] = "-1";
            process = Process.Start(start) ?? throw new InvalidOperationException("Ollama did not start.");
            processGroup ??= OllamaProcessGroup.Create();
            OllamaProcessGroup.Add(processGroup, process);
            logger.LogInformation("Started the dedicated Ollama process with PID {Pid}.", process.Id);
            for (int check = 0; check < 40; ++check)
            {
                try { await Loaded(token); break; }
                catch (HttpRequestException) when (!process.HasExited)
                { await Task.Delay(150, token); }
            }
        }
        if (await Loaded(token)) return;
        using var warm = await ollama.PostAsJsonAsync("/api/generate",
            new { model = config.Model, keep_alive = -1, options = new { num_ctx = 4096 } }, Json, token);
        warm.EnsureSuccessStatusCode();
        if (!await Loaded(token)) throw new InvalidOperationException("The model did not remain loaded.");
        logger.LogInformation("Model {Model} is resident and ready.", config.Model);
    }

    private async Task<bool> Loaded(CancellationToken token)
    {
        using var state = await ollama.GetFromJsonAsync<JsonDocument>("/api/ps", Json, token);
        return state!.RootElement.GetProperty("models").EnumerateArray()
            .Any(entry => entry.GetProperty("name").GetString() == config.Model);
    }

    private void StopOllama()
    {
        processGroup?.Dispose();
        processGroup = null;
        if (process is null) return;
        if (!process.HasExited)
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit(3000);
        }
        process.Dispose();
        process = null;
    }

    private async Task<T?> Rpc<T>(string action, object body, CancellationToken token)
    {
        using var response = await supabase.PostAsJsonAsync("/rest/v1/rpc/" + action, body, Json, token);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<T>(Json, token);
    }

    private Task<QuizJob?> Claim(CancellationToken token) =>
        Rpc<QuizJob>("sp_quiz_generation_claim", new { }, token);

    private Task<bool> Finish(QuizJob job, QuizOutput? output, CancellationToken token) =>
        Rpc<bool>("sp_quiz_generation_finish",
            new { attempt_id = job.Id, claim_token = job.Token, statement = output?.Statement, expected = output?.Answer }, token);

    private async Task Generate(QuizJob job, CancellationToken token)
    {
        var clock = Stopwatch.StartNew();
        for (int retry = 0; retry < 3 && job.Topic != null; ++retry)
        {
            var challenge = QuizChallenge.FromTopic(job.Topic);
            using var response = await ollama.PostAsJsonAsync("/api/chat", new
            {
                model = config.Model, think = false, stream = false, keep_alive = -1,
                format = OutputSchema, options = new { num_ctx = 4096, num_predict = 96, temperature = 0.55 },
                messages = new[]
                {
                    new { role = "system", content = "Write one short True/False statement and its boolean answer. Use only the supplied claim and wording." },
                    new { role = "user", content = challenge.Prompt }
                }
            }, Json, token);
            response.EnsureSuccessStatusCode();
            using var envelope = await response.Content.ReadFromJsonAsync<JsonDocument>(Json, token);
            QuizOutput? output;
            try
            {
                output = JsonSerializer.Deserialize<QuizOutput>(
                    envelope!.RootElement.GetProperty("message").GetProperty("content").GetString() ?? "", Json);
            }
            catch (JsonException) { continue; }
            if (!challenge.Accepts(output)) continue;
            if (await Finish(job, output, token))
            {
                logger.LogInformation("Published quiz {Attempt} in {Elapsed} ms after {Calls} Ollama call(s).",
                    job.Id, clock.ElapsedMilliseconds, retry + 1);
                return;
            }
        }
        await Finish(job, null, token);
        logger.LogWarning("Quiz {Attempt} had no supported generated statement.", job.Id);
    }
}

internal sealed record QuizJob(Guid Id, Guid Token, string TeamId, QuizTopic? Topic);
internal sealed record QuizTopic(string Evidence, QuizRules Rules);
internal sealed record QuizRules(string Form, string Wording, string Pattern, string? Correct, string? Decoy);
internal sealed record QuizOutput(string Statement, bool Answer);

internal sealed record QuizChallenge(string Prompt, string Pattern, bool Answer)
{
    public static QuizChallenge FromTopic(QuizTopic topic)
    {
        var rules = topic.Rules;
        bool answer = Random.Shared.Next(2) == 0;
        string input = "";
        string correct = rules.Correct ?? "";
        string decoy = rules.Decoy ?? "";
        if (rules.Form == "binary")
        {
            int number = Random.Shared.Next(16, 256);
            input = Convert.ToString(number, 2);
            correct = number.ToString(System.Globalization.CultureInfo.InvariantCulture);
            decoy = (number + Random.Shared.Next(1, 8)).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        else if (rules.Form != "fact" || correct.Length == 0 || decoy.Length == 0 || correct == decoy)
            throw new InvalidDataException("Invalid quiz topic rules.");
        string value = answer ? correct : decoy;
        string wording = rules.Wording.Replace("{input}", input).Replace("{value}", value);
        string pattern = rules.Pattern.Replace("{input}", Regex.Escape(input)).Replace("{value}", Regex.Escape(value));
        return new QuizChallenge(
            $"{topic.Evidence} State the proposed claim in the specified form: {wording} Answer: {answer}.",
            pattern, answer);
    }

    public bool Accepts(QuizOutput? output) => output is { Statement.Length: >= 5 and <= 200 }
        && output.Answer == Answer
        && Regex.IsMatch(output.Statement.Trim(), $"\\A(?:{Pattern})\\z",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
}
