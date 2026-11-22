// Persistent PowerShell terminal for the sbx guest agent. One runspace lives for the whole session, so the
// working directory, variables, functions and imported modules carry over between commands. A custom host
// captures everything PowerShell would print to a console (output, Write-Host, warnings, errors, Read-Host
// prompts) into a buffer that the host side drains with termread. Compiled by Windows PowerShell 5.1 (C# 5).
using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Security;
using System.Text;
using System.Threading;

public class SbxTerminal : IDisposable
{
    readonly object gate = new object();
    readonly StringBuilder buffer = new StringBuilder();
    readonly ManualResetEvent signal = new ManualResetEvent(false);
    readonly AutoResetEvent inputReady = new AutoResetEvent(false);
    readonly SbxTermHost host;
    readonly Runspace runspace;
    PowerShell current;
    string pendingInput;
    bool awaitingInput, secretInput, stopping, promptDue, exited;
    int inputSeq; // bumped per prompt, so the host can tell two Read-Hosts in a row apart
    public int Columns = 120;
    public string LastPrompt = "PS> ";
    DateTime runStarted;

    public SbxTerminal(int columns)
    {
        if (columns >= 40) Columns = columns;
        host = new SbxTermHost(this);
        runspace = RunspaceFactory.CreateRunspace(host);
        runspace.ApartmentState = ApartmentState.STA;
        runspace.ThreadOptions = PSThreadOptions.ReuseThread;
        runspace.Open();
        LastPrompt = EvalPrompt();
    }

    public bool Busy { get { lock (gate) { return current != null; } } }

    internal void Emit(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        lock (gate) { buffer.Append(text); }
        signal.Set();
    }

    internal void OnExit() { lock (gate) { exited = true; } }

    public void Run(string script, int columns)
    {
        if (columns >= 40) Columns = columns;
        PowerShell ps;
        lock (gate)
        {
            if (current != null) throw new InvalidOperationException("A command is already running (send termbreak to stop it)");
            ps = PowerShell.Create();
            ps.Runspace = runspace;
            current = ps; stopping = false; promptDue = false; runStarted = DateTime.Now;
        }
        // Out-String rather than Out-Default: in front of Out-Default PowerShell lets native programs write
        // straight to the (hidden) console; any other downstream command makes it capture their output.
        ps.AddScript(script).AddCommand("Out-String").AddParameter("Stream").AddParameter("Width", Columns);
        PSDataCollection<PSObject> output = new PSDataCollection<PSObject>();
        output.DataAdded += delegate(object s, DataAddedEventArgs e) { Emit(output[e.Index] + "\n"); };
        ps.Streams.Error.DataAdded += delegate(object s, DataAddedEventArgs e) { Emit(FormatError(ps.Streams.Error[e.Index])); };
        ps.InvocationStateChanged += OnStateChanged;
        try { ps.BeginInvoke<PSObject, PSObject>(null, output); }
        catch (Exception e) { Finish(ps, e); }
    }

    void OnStateChanged(object sender, PSInvocationStateChangedEventArgs e)
    {
        PSInvocationState st = e.InvocationStateInfo.State;
        if (st == PSInvocationState.Completed || st == PSInvocationState.Failed || st == PSInvocationState.Stopped)
            Finish((PowerShell)sender, st == PSInvocationState.Failed ? e.InvocationStateInfo.Reason : null);
    }

    void Finish(PowerShell ps, Exception reason)
    {
        if (reason != null) Emit(FormatException(reason));
        lock (gate)
        {
            if (current != ps) return;
            if (stopping) buffer.Append("\n");
            current = null; promptDue = true; awaitingInput = false;
        }
        signal.Set();
        ThreadPool.QueueUserWorkItem(delegate { try { ps.Dispose(); } catch { } });
    }

    static string FormatException(Exception e)
    {
        IContainsErrorRecord c = e as IContainsErrorRecord;
        if (e is PipelineStoppedException) return "";
        if (c != null && c.ErrorRecord != null) return FormatError(c.ErrorRecord);
        return e.Message + "\n";
    }

    // Close to Windows PowerShell's NormalView, minus the noise native-command stderr gets.
    internal static string FormatError(ErrorRecord r)
    {
        string id = r.FullyQualifiedErrorId ?? "";
        if (id.StartsWith("NativeCommandError")) return (r.Exception != null ? r.Exception.Message : r.ToString()) + "\n";
        StringBuilder sb = new StringBuilder();
        string cmd = r.InvocationInfo != null && r.InvocationInfo.MyCommand != null ? r.InvocationInfo.MyCommand.Name : null;
        sb.Append(string.IsNullOrEmpty(cmd) ? r.ToString() : cmd + " : " + r.ToString()).Append('\n');
        if (r.InvocationInfo != null && !string.IsNullOrEmpty(r.InvocationInfo.PositionMessage))
            sb.Append(r.InvocationInfo.PositionMessage.TrimEnd()).Append('\n');
        sb.Append("    + CategoryInfo          : ").Append(r.CategoryInfo).Append('\n');
        sb.Append("    + FullyQualifiedErrorId : ").Append(id).Append('\n');
        return sb.ToString();
    }

    string EvalPrompt()
    {
        try
        {
            using (PowerShell ps = PowerShell.Create())
            {
                ps.Runspace = runspace;
                Collection<PSObject> r = ps.AddCommand("prompt").Invoke();
                if (r.Count > 0 && r[0] != null) return r[0].ToString();
            }
        }
        catch { }
        return "PS> ";
    }

    // Waits up to waitMs for output or a state change, then hands back everything buffered.
    public Hashtable Read(int waitMs)
    {
        lock (gate) { if (buffer.Length == 0 && current != null && !awaitingInput) signal.Reset(); }
        if (waitMs > 0) signal.WaitOne(Math.Min(waitMs, 2000));
        Thread.Sleep(15); // let a burst of output land in one read
        Hashtable h = new Hashtable();
        bool computePrompt;
        lock (gate)
        {
            int n = Math.Min(buffer.Length, 262144);
            h["output"] = buffer.ToString(0, n);
            buffer.Remove(0, n);
            h["more"] = buffer.Length > 0;
            h["busy"] = current != null;
            h["awaitingInput"] = awaitingInput;
            h["secret"] = secretInput;
            h["inputSeq"] = inputSeq;
            h["exited"] = exited;
            computePrompt = promptDue && current == null && buffer.Length == 0;
            if (computePrompt) promptDue = false;
            exited = false;
        }
        if (computePrompt) { LastPrompt = EvalPrompt(); h["prompt"] = LastPrompt; }
        return h;
    }

    public void Input(string line)
    {
        lock (gate)
        {
            if (!awaitingInput) throw new InvalidOperationException("The terminal is not waiting for input");
            pendingInput = line ?? ""; awaitingInput = false;
        }
        inputReady.Set();
    }

    public void Break()
    {
        PowerShell ps;
        lock (gate) { ps = current; if (ps == null) return; stopping = true; awaitingInput = false; }
        inputReady.Set();
        // Native programs the command started (ping -t, a hung installer) are children of this process.
        try
        {
            using (PowerShell k = PowerShell.Create())
            {
                k.AddScript("param($p, $t) Get-CimInstance Win32_Process -Filter \"ParentProcessId=$p\" | " +
                            "Where-Object { $_.Name -ne 'conhost.exe' -and $_.CreationDate -ge $t } | " +
                            "ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }")
                 .AddArgument(System.Diagnostics.Process.GetCurrentProcess().Id).AddArgument(runStarted).Invoke();
            }
        }
        catch { }
        ps.BeginStop(null, null);
    }

    // Tab completion through the same engine the console uses, against the live session state.
    public Hashtable Complete(string input, int cursor)
    {
        Hashtable h = new Hashtable();
        if (Busy) { h["matches"] = new string[0]; return h; }
        using (PowerShell ps = PowerShell.Create())
        {
            ps.Runspace = runspace;
            CommandCompletion c = CommandCompletion.CompleteInput(input, Math.Max(0, Math.Min(cursor, input.Length)), null, ps);
            List<string> m = new List<string>();
            foreach (CompletionResult r in c.CompletionMatches) m.Add(r.CompletionText);
            h["matches"] = m.ToArray();
            h["replacementIndex"] = c.ReplacementIndex;
            h["replacementLength"] = c.ReplacementLength;
        }
        return h;
    }

    internal string ReadLine(bool secret)
    {
        lock (gate)
        {
            if (stopping) throw new PipelineStoppedException();
            awaitingInput = true; secretInput = secret; pendingInput = null; inputSeq++;
            inputReady.Reset(); // a Break with nobody waiting must not answer this prompt
        }
        signal.Set();
        inputReady.WaitOne();
        lock (gate)
        {
            awaitingInput = false;
            if (stopping || pendingInput == null) throw new PipelineStoppedException();
            return pendingInput;
        }
    }

    public void Dispose()
    {
        try { Break(); } catch { }
        try { runspace.Dispose(); } catch { }
    }
}

public class SbxTermHost : PSHost
{
    readonly SbxTerminal term;
    readonly SbxTermUI ui;
    readonly Guid id = Guid.NewGuid();
    public SbxTermHost(SbxTerminal t) { term = t; ui = new SbxTermUI(t); }
    public override string Name { get { return "SbxTerminal"; } }
    public override Version Version { get { return new Version(1, 0); } }
    public override Guid InstanceId { get { return id; } }
    public override PSHostUserInterface UI { get { return ui; } }
    public override CultureInfo CurrentCulture { get { return Thread.CurrentThread.CurrentCulture; } }
    public override CultureInfo CurrentUICulture { get { return Thread.CurrentThread.CurrentUICulture; } }
    public override void EnterNestedPrompt() { throw new NotSupportedException("Nested prompts are not supported in the sbx terminal"); }
    public override void ExitNestedPrompt() { }
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
    public override void SetShouldExit(int exitCode) { term.OnExit(); }
}

public class SbxTermUI : PSHostUserInterface
{
    readonly SbxTerminal term;
    readonly SbxTermRawUI raw;
    public SbxTermUI(SbxTerminal t) { term = t; raw = new SbxTermRawUI(t); }
    public override PSHostRawUserInterface RawUI { get { return raw; } }
    public override void Write(string value) { term.Emit(value); }
    public override void Write(ConsoleColor fg, ConsoleColor bg, string value) { term.Emit(value); }
    public override void WriteLine(string value) { term.Emit(value + "\n"); }
    public override void WriteErrorLine(string value) { term.Emit(value + "\n"); }
    public override void WriteDebugLine(string message) { term.Emit("DEBUG: " + message + "\n"); }
    public override void WriteVerboseLine(string message) { term.Emit("VERBOSE: " + message + "\n"); }
    public override void WriteWarningLine(string message) { term.Emit("WARNING: " + message + "\n"); }
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
    public override string ReadLine() { return term.ReadLine(false); }

    public override SecureString ReadLineAsSecureString()
    {
        SecureString s = new SecureString();
        foreach (char ch in term.ReadLine(true)) s.AppendChar(ch);
        s.MakeReadOnly();
        return s;
    }

    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions)
    {
        if (!string.IsNullOrEmpty(caption)) WriteLine(caption);
        if (!string.IsNullOrEmpty(message)) WriteLine(message);
        Dictionary<string, PSObject> result = new Dictionary<string, PSObject>();
        foreach (FieldDescription f in descriptions)
        {
            Write(f.Name + ": ");
            bool secret = f.ParameterTypeFullName != null && f.ParameterTypeFullName.EndsWith("SecureString");
            if (secret) result[f.Name] = PSObject.AsPSObject(ReadLineAsSecureString());
            else result[f.Name] = PSObject.AsPSObject(ReadLine());
        }
        return result;
    }

    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        if (!string.IsNullOrEmpty(caption)) WriteLine(caption);
        if (!string.IsNullOrEmpty(message)) WriteLine(message);
        while (true)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < choices.Count; i++)
                sb.Append(i == 0 ? "" : "  ").Append('[').Append(Hotkey(choices[i].Label)).Append("] ").Append(choices[i].Label.Replace("&", ""));
            if (defaultChoice >= 0) sb.Append("  (default is \"").Append(Hotkey(choices[defaultChoice].Label)).Append("\")");
            Write(sb.ToString() + ": ");
            string a = (ReadLine() ?? "").Trim();
            if (a.Length == 0 && defaultChoice >= 0) return defaultChoice;
            for (int i = 0; i < choices.Count; i++)
                if (string.Equals(a, Hotkey(choices[i].Label), StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(a, choices[i].Label.Replace("&", ""), StringComparison.OrdinalIgnoreCase)) return i;
        }
    }

    static string Hotkey(string label)
    {
        int i = label.IndexOf('&');
        return i >= 0 && i + 1 < label.Length ? label.Substring(i + 1, 1).ToUpperInvariant() : label;
    }

    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
    {
        return PromptForCredential(caption, message, userName, targetName, PSCredentialTypes.Default, PSCredentialUIOptions.Default);
    }

    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
        PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options)
    {
        if (!string.IsNullOrEmpty(caption)) WriteLine(caption);
        if (!string.IsNullOrEmpty(message)) WriteLine(message);
        if (string.IsNullOrEmpty(userName)) { Write("User: "); userName = ReadLine(); }
        Write("Password for " + userName + ": ");
        return new PSCredential(userName, ReadLineAsSecureString());
    }
}

public class SbxTermRawUI : PSHostRawUserInterface
{
    readonly SbxTerminal term;
    string title = "sbx";
    public SbxTermRawUI(SbxTerminal t) { term = t; }
    public override ConsoleColor ForegroundColor { get { return ConsoleColor.Gray; } set { } }
    public override ConsoleColor BackgroundColor { get { return ConsoleColor.Black; } set { } }
    public override Coordinates CursorPosition { get { return new Coordinates(0, 0); } set { } }
    public override int CursorSize { get { return 25; } set { } }
    public override Coordinates WindowPosition { get { return new Coordinates(0, 0); } set { } }
    public override Size WindowSize { get { return new Size(term.Columns, 50); } set { } }
    public override Size BufferSize { get { return new Size(term.Columns, 9001); } set { } }
    public override Size MaxWindowSize { get { return new Size(term.Columns, 50); } }
    public override Size MaxPhysicalWindowSize { get { return new Size(term.Columns, 50); } }
    public override bool KeyAvailable { get { return false; } }
    public override string WindowTitle { get { return title; } set { title = value; } }
    public override KeyInfo ReadKey(ReadKeyOptions options) { throw new NotSupportedException("ReadKey is not supported in the sbx terminal"); }
    public override void FlushInputBuffer() { }
    public override BufferCell[,] GetBufferContents(Rectangle rectangle) { return new BufferCell[0, 0]; }
    public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) { }
    public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { }
    // Clear-Host fills the whole buffer (rectangle -1,-1,-1,-1); the window side clears on this marker.
    public override void SetBufferContents(Rectangle rectangle, BufferCell fill)
    {
        if (rectangle.Left == -1 && rectangle.Right == -1) term.Emit("\u001b[2J");
    }
}
