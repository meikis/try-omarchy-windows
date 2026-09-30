using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.IO;

// Disposable Windows lab helper. No driver installation or adapter configuration.
public static class NpcapFramePump
{
    public sealed class Result
    {
        public int GuestOut;
        public int PeerIn;
        public int Raw;
        public int Segmented;
    }

    static int active;
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeLibrary(IntPtr library);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int LinkType(IntPtr cap);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate IntPtr Version();
    static LinkType linkType;
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr lib, string name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate IntPtr Open(string dev, int snap, int promisc, int ms, StringBuilder err);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Next(IntPtr cap, out IntPtr header, out IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Send(IntPtr cap, byte[] data, int size);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Nonblock(IntPtr cap, int value, StringBuilder err);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Compile(IntPtr cap, ref Program filter, string expression, int optimize, uint mask);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Setfilter(IntPtr cap, ref Program filter);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void Freecode(ref Program filter);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void Close(IntPtr cap);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate IntPtr Error(IntPtr cap);
    [StructLayout(LayoutKind.Sequential)]
    struct Program
    {
        public uint length;
        public IntPtr instructions;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Mode(IntPtr cap, int mode);
    static Mode mode;
    static Open open;
    static Next next;
    static Send send;
    static Nonblock nonblock;
    static Compile compile;
    static Setfilter setfilter;
    static Freecode freecode;
    static Close close;
    static Error error;
    static T Function<T>(IntPtr lib, string name)
    {
        IntPtr p = GetProcAddress(lib, name);
        if (p == IntPtr.Zero)
            throw new Exception("Missing Npcap export: " + name);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
    }

    static IntPtr Capture(string guid, string filter, bool reading)
    {
        StringBuilder err = new StringBuilder(512);
        IntPtr cap = open(@"\Device\NPF_{" + new Guid(guid).ToString().ToUpperInvariant() + "}", 262144, 1, 100, err);
        if (cap == IntPtr.Zero)
            throw new Exception("Npcap open failed: " + err);
        try
        {
            if (linkType(cap) != 1)
                throw new Exception("Selected adapter is not Ethernet");
            if (!reading)
            {
                if (mode(cap, 0x200) != 0)
                    throw new Exception("Cannot force transmit injection");
                return cap;
            }

            Program bpf = new Program();
            if (compile(cap, ref bpf, filter, reading ? 1 : 0, 0xffffffff) != 0)
                throw new Exception("Filter compile: " + Marshal.PtrToStringAnsi(error(cap)));
            try
            {
                if (setfilter(cap, ref bpf) != 0)
                    throw new Exception("Filter install: " + Marshal.PtrToStringAnsi(error(cap)));
            }
            finally
            {
                freecode(ref bpf);
            }

            if (reading && nonblock(cap, 1, err) != 0)
                throw new Exception("Nonblocking capture failed: " + err);
            return cap;
        }
        catch
        {
            close(cap);
            throw;
        }
    }

    public static Result Run(string wired, string tap, string guestMac, string wiredMac, int seconds, Action guard)
    {
        if (seconds < 1 || seconds > 600)
            throw new ArgumentException("Duration must be 1 to 600 seconds");
        if (new Guid(wired) == new Guid(tap))
            throw new ArgumentException("Select two distinct adapters");
        byte[] mac = ParseMac(guestMac), host = ParseMac(wiredMac);
        if (guestMac.Equals(wiredMac, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Guest and wired MACs must differ");
        if (guard == null)
            throw new ArgumentNullException("guard");
        guard();
        if (Interlocked.CompareExchange(ref active, 1, 0) != 0)
            throw new InvalidOperationException("A pump is already running in this process");
        IntPtr library = IntPtr.Zero;
        try
        {
            library = LoadLibraryEx(Path.Combine(Environment.SystemDirectory, @"Npcap\wpcap.dll"), IntPtr.Zero, 0x100 | 0x800);
            if (library == IntPtr.Zero)
                throw new Exception("Trusted Npcap DLL load failed: " + Marshal.GetLastWin32Error());
            linkType = Function<LinkType>(library, "pcap_datalink");
            string version = Marshal.PtrToStringAnsi(Function<Version>(library, "pcap_lib_version")());
            if (version == null || !version.StartsWith("Npcap version 1.89,"))
                throw new Exception("Pinned Npcap 1.89 runtime required");
            mode = Function<Mode>(library, "pcap_setmode");
            open = Function<Open>(library, "pcap_open_live");
            next = Function<Next>(library, "pcap_next_ex");
            send = Function<Send>(library, "pcap_sendpacket");
            nonblock = Function<Nonblock>(library, "pcap_setnonblock");
            compile = Function<Compile>(library, "pcap_compile");
            setfilter = Function<Setfilter>(library, "pcap_setfilter");
            freecode = Function<Freecode>(library, "pcap_freecode");
            close = Function<Close>(library, "pcap_close");
            error = Function<Error>(library, "pcap_geterr");
            string text = BitConverter.ToString(mac).Replace('-', ':');
            IntPtr[] h = new IntPtr[5];
            int[] count = new int[2];
            int raw = 0, stop = 0, segmented = 0;
            HostTcpSegmentation tcp = new HostTcpSegmentation();
            Exception failure = null;
            Thread[] threads = new Thread[2];
            Stopwatch timer = Stopwatch.StartNew();
            try
            {
                h[0] = Capture(tap, "ether src " + text, true);
                h[1] = Capture(wired, "0 = 1", false);
                h[2] = Capture(wired, "(ether dst " + text + " or ether multicast) and not ether src " + text, true);
                h[3] = Capture(tap, "0 = 1", false);
                h[4] = Capture(wired, "0 = 1", false);
                if (mode(h[4], 0x100) != 0)
                    throw new Exception("Receive-path injection unavailable");
                for (int direction = 0; direction < 2; direction++)
                {
                    int d = direction;
                    threads[d] = new Thread(delegate ()
                    {
                        try
                        {
                            while (Volatile.Read(ref stop) == 0 && Volatile.Read(ref failure) == null)
                            {
                                IntPtr header, data;
                                int n = next(h[d * 2], out header, out data);
                                if (n == 0)
                                {
                                    Thread.Sleep(5);
                                    continue;
                                }

                                if (n < 0)
                                    throw new Exception("Capture terminated: " + n);
                                int captured = Marshal.ReadInt32(header, 8), length = Marshal.ReadInt32(header, 12);
                                if (captured != length || length < 14 || length > (d == 1 ? 262144 : 9022))
                                    throw new Exception("Truncated or oversized Ethernet frame");
                                byte[] frame = new byte[length];
                                Marshal.Copy(data, frame, 0, length);
                                if (d == 0)
                                {
                                    for (int m = 0; m < 6; m++)
                                        if (frame[6 + m] != mac[m])
                                            throw new Exception("Unexpected guest source MAC");
                                    tcp.ObserveGuest(frame);
                                }

                                byte[][] frames = new byte[][] { frame };
                                if (d == 1)
                                {
                                    bool fromHost = true;
                                    for (int m = 0; m < 6; m++)
                                        if (frame[6 + m] != host[m])
                                            fromHost = false;
                                    if (fromHost)
                                        frames = tcp.NormalizeHost(frame);
                                    else if (length > 9022)
                                        throw new Exception("Oversized peer Ethernet frame");
                                    if (frames.Length > 1)
                                        Interlocked.Increment(ref segmented);
                                }

                                bool toHost = d == 0;
                                for (int m = 0; m < 6 && toHost; m++)
                                    if (frame[m] != host[m])
                                        toHost = false;
                                foreach (byte[] output in frames)
                                    if (!toHost && send(h[d * 2 + 1], output, output.Length) != 0)
                                        throw new Exception("Transmit injection failed: " + Marshal.PtrToStringAnsi(error(h[d * 2 + 1])));
                                if (d == 0 && (toHost || (frame[0] & 1) != 0) && send(h[4], frame, length) != 0)
                                    throw new Exception("Host receive injection failed: " + Marshal.PtrToStringAnsi(error(h[4])));
                                Interlocked.Increment(ref count[d]);
                                if (frame[12] == 0x88 && frame[13] == 0xb5)
                                    Interlocked.Increment(ref raw);
                            }
                        }
                        catch (Exception e)
                        {
                            Interlocked.CompareExchange(ref failure, e, null);
                        }
                    });
                    threads[d].IsBackground = true;
                    threads[d].Start();
                }

                while (timer.Elapsed.TotalSeconds < seconds && Volatile.Read(ref failure) == null)
                {
                    guard();
                    Thread.Sleep(250);
                }

            }
            finally
            {
                Interlocked.Exchange(ref stop, 1);
                // Never close a native handle while its worker may still be using it.
                foreach (Thread thread in threads)
                    if (thread != null && !thread.Join(5000))
                        Environment.FailFast("Npcap worker did not stop; terminating the lab process to release driver handles");
                foreach (IntPtr p in h)
                    if (p != IntPtr.Zero)
                        close(p);
            }
            if (failure != null)
                throw failure;
            return new Result { GuestOut = count[0], PeerIn = count[1], Raw = raw, Segmented = segmented };
        }
        finally
        {
            if (library != IntPtr.Zero)
                FreeLibrary(library);
            Interlocked.Exchange(ref active, 0);
        }
    }

    public static byte[] ParseMac(string text)
    {
        if (text == null)
            throw new ArgumentException("Missing MAC");
        string[] parts = text.Split(':');
        if (parts.Length != 6)
            throw new ArgumentException("MAC must have six colon-separated bytes");
        byte[] mac = new byte[6];
        bool zero = true;
        for (int i = 0; i < 6; i++)
        {
            if (parts[i].Length != 2 || !Byte.TryParse(parts[i], System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out mac[i]))
                throw new ArgumentException("Invalid MAC");
            if (mac[i] != 0)
                zero = false;
        }

        if (zero || (mac[0] & 1) != 0)
            throw new ArgumentException("MAC must be nonzero and unicast");
        return mac;
    }

    public static void CompleteHostChecksums(byte[] frame)
    {
        if (frame == null || frame.Length < 14)
            throw new ArgumentException("Short Ethernet frame");
        int offset = 14, type = Read16(frame, 12);
        for (int tags = 0; type == 0x8100 || type == 0x88a8; tags++)
        {
            if (tags == 2 || frame.Length < offset + 4)
                throw new ArgumentException("Invalid VLAN header");
            type = Read16(frame, offset + 2);
            offset += 4;
        }

        int protocol, start, length;
        uint pseudo = 0;
        if (type == 0x0800)
        {
            if (frame.Length < offset + 20 || (frame[offset] >> 4) != 4)
                throw new ArgumentException("Invalid IPv4 header");
            int header = (frame[offset] & 15) * 4, total = Read16(frame, offset + 2);
            if (header < 20 || total < header || offset + total > frame.Length)
                throw new ArgumentException("Unsupported host segmentation or truncated IPv4 packet");
            if ((Read16(frame, offset + 6) & 0x3fff) != 0)
                throw new ArgumentException("Fragmented host packet is unsupported in this lab");
            Write16(frame, offset + 10, 0);
            Write16(frame, offset + 10, Checksum(frame, offset, header, 0));
            protocol = frame[offset + 9];
            start = offset + header;
            length = total - header;
            if (protocol == 6 || protocol == 17)
                pseudo = Sum(frame, offset + 12, 8) + (uint)protocol + (uint)length;
        }
        else if (type == 0x86dd)
        {
            if (frame.Length < offset + 40 || (frame[offset] >> 4) != 6)
                throw new ArgumentException("Invalid IPv6 header");
            length = Read16(frame, offset + 4);
            protocol = frame[offset + 6];
            start = offset + 40;
            if (length == 0 || start + length > frame.Length)
                throw new ArgumentException("Unsupported host segmentation or truncated IPv6 packet");
            int count = 0;
            while (protocol == 0 || protocol == 60)
            {
                if (++count > 8 || length < 8)
                    throw new ArgumentException("Invalid IPv6 extension header");
                int extension = (frame[start + 1] + 1) * 8;
                if (extension > length)
                    throw new ArgumentException("Truncated IPv6 extension header");
                protocol = frame[start];
                start += extension;
                length -= extension;
            }

            if (protocol == 43 || protocol == 44 || protocol == 51 || protocol == 50)
                throw new ArgumentException("Host IPv6 routing, fragment and IPsec headers are unsupported in this lab");
            pseudo = Sum(frame, offset + 8, 32) + (uint)protocol + (uint)length;
        }
        else
            return;
        int checksum;
        if (protocol == 6)
        {
            if (length < 20 || (frame[start + 12] >> 4) * 4 < 20 || (frame[start + 12] >> 4) * 4 > length)
                throw new ArgumentException("Invalid host TCP segment");
            checksum = start + 16;
        }
        else if (protocol == 17)
        {
            if (length < 8 || Read16(frame, start + 4) != length)
                throw new ArgumentException("Invalid host UDP datagram");
            checksum = start + 6;
        }
        else if ((type == 0x0800 && protocol == 1) || (type == 0x86dd && protocol == 58))
        {
            if (length < 4)
                throw new ArgumentException("Invalid host ICMP message");
            checksum = start + 2;
        }
        else
            return;
        Write16(frame, checksum, 0);
        ushort result = Checksum(frame, start, length, pseudo);
        if (protocol == 17 && result == 0)
            result = 0xffff;
        Write16(frame, checksum, result);
    }

    static int Read16(byte[] bytes, int offset)
    {
        return (bytes[offset] << 8) | bytes[offset + 1];
    }

    static void Write16(byte[] bytes, int offset, int value)
    {
        bytes[offset] = (byte)(value >> 8);
        bytes[offset + 1] = (byte)value;
    }

    static uint Sum(byte[] bytes, int offset, int length)
    {
        uint sum = 0;
        for (int i = 0; i < length; i += 2)
            sum += (uint)(bytes[offset + i] << 8) + (uint)(i + 1 < length ? bytes[offset + i + 1] : 0);
        return sum;
    }

    static ushort Checksum(byte[] bytes, int offset, int length, uint seed)
    {
        uint sum = seed + Sum(bytes, offset, length);
        while ((sum >> 16) != 0)
            sum = (sum & 0xffff) + (sum >> 16);
        return (ushort)~sum;
    }
}
