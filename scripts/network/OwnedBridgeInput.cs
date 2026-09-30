using System;
using System.Collections.Concurrent;
using System.Threading;

// Console.In.ReadLineAsync on .NET Framework can synchronously block the
// caller. Keep pipe reads off the PowerShell runspace and frame-pump guard.
public sealed class OwnedBridgeInput
{
    private readonly ConcurrentQueue<string> commands = new ConcurrentQueue<string>();
    private int ended;
    private Exception failure;
    public Exception Failure { get { return Volatile.Read(ref failure); } }
    public bool Ended { get { return Volatile.Read(ref ended) != 0; } }
    public OwnedBridgeInput()
    {
        Thread input = new Thread(delegate ()
        {
            try
            {
                string line;
                while ((line = Console.ReadLine()) != null)
                {
                    if (line.Length > 8192 || commands.Count >= 8)
                        throw new InvalidOperationException("Bridge command limit exceeded");
                    commands.Enqueue(line);
                }
            }
            catch (Exception e) { Interlocked.CompareExchange(ref failure, e, null); }
            finally { Interlocked.Exchange(ref ended, 1); }
        });
        input.IsBackground = true;
        input.Start();
    }
    public string Next()
    {
        string line;
        return commands.TryDequeue(out line) ? line : null;
    }
}
