using System;
using System.Collections.Generic;
using System.Diagnostics;

// pcap exposes frame bytes, not the NDIS out-of-band LSO MSS. Only segment
// host sends after observing this guest connection's advertised receive MSS.
public sealed class HostTcpSegmentation
{
    const int MaxFlows = 4096;
    const long LifetimeMs = 600000;
    readonly Dictionary<string, Flow> flows = new Dictionary<string, Flow>();
    readonly Func<long> now;
    readonly object gate = new object();

    sealed class Flow
    {
        public int Mss;
        public long Seen;
    }

    sealed class Packet
    {
        public int Ip, Tcp, End, Header, Version;
        public bool Offload;
    }

    public HostTcpSegmentation()
    {
        Stopwatch clock = Stopwatch.StartNew();
        now = delegate { return clock.ElapsedMilliseconds; };
    }

    // A monotonic clock is injectable for deterministic expiry checks.
    public HostTcpSegmentation(Func<long> clock)
    {
        if (clock == null) throw new ArgumentNullException("clock");
        now = clock;
    }

    public void ObserveGuest(byte[] frame)
    {
        Packet p = Parse(frame, false);
        if (p == null) return;
        int flags = frame[p.Tcp + 13];
        string key = Key(frame, p, true);
        lock (gate)
        {
            if ((flags & 4) != 0) { flows.Remove(key); return; }
            if ((flags & 2) == 0)
            {
                long activeTick = now();
                Expire(activeTick);
                Flow existing;
                if (flows.TryGetValue(key, out existing)) existing.Seen = activeTick;
                return;
            }
            int mss = p.Version == 4 ? 536 : 1220;
            bool found = false;
            for (int i = p.Tcp + 20; i < p.Tcp + p.Header; )
            {
                int kind = frame[i];
                if (kind == 0) break;
                if (kind == 1) { i++; continue; }
                if (i + 2 > p.Tcp + p.Header || frame[i + 1] < 2 || i + frame[i + 1] > p.Tcp + p.Header)
                    throw new ArgumentException("Malformed guest TCP option");
                if (kind == 2)
                {
                    if (found || frame[i + 1] != 4 || Read16(frame, i + 2) == 0)
                        throw new ArgumentException("Invalid guest receive MSS");
                    mss = Read16(frame, i + 2);
                    found = true;
                }
                i += frame[i + 1];
            }
            long tick = now();
            Expire(tick);
            if (!flows.ContainsKey(key) && flows.Count == MaxFlows)
                throw new InvalidOperationException("Guest TCP tracking limit reached");
            flows[key] = new Flow { Mss = mss, Seen = tick };
        }
    }

    public byte[][] NormalizeHost(byte[] frame)
    {
        Packet p = Parse(frame, true);
        if (p != null && frame.Length > Math.Max(p.End, 60 + p.Ip - 14))
            throw new ArgumentException("Host TCP capture has an unsupported trailing payload");
        if (p == null || (!p.Offload && p.End - p.Ip <= 1500))
        {
            if (p != null)
                lock (gate)
                {
                    long tick = now();
                    Expire(tick);
                    Flow existing;
                    if (flows.TryGetValue(Key(frame, p, false), out existing)) existing.Seen = tick;
                }
            if (p == null && frame.Length > 9022)
                throw new ArgumentException("Oversized non-TCP host Ethernet frame");
            byte[] single = (byte[])frame.Clone();
            NpcapFramePump.CompleteHostChecksums(single);
            return new byte[][] { single };
        }
        // LSO permits ACK/ECE/CWR, FIN and PSH, but never SYN/RST/URG.
        int flags = frame[p.Tcp + 13];
        if ((flags & 0x26) != 0 || (frame[p.Tcp + 12] & 15) != 0 || Read16(frame, p.Tcp + 18) != 0)
            throw new ArgumentException("Unsupported host TCP segmentation flags");
        for (int i = p.Tcp + 20; i < p.Tcp + p.Header; )
        {
            int kind = frame[i];
            if (kind == 0) break;
            if (kind == 1) { i++; continue; }
            if (i + 2 > p.Tcp + p.Header || frame[i + 1] < 2 || i + frame[i + 1] > p.Tcp + p.Header)
                throw new ArgumentException("Malformed host TCP option");
            if (kind == 19 || kind == 29)
                throw new ArgumentException("Authenticated host TCP segmentation is unsupported");
            i += frame[i + 1];
        }
        int mss;
        lock (gate)
        {
            long tick = now();
            Expire(tick);
            Flow flow;
            if (!flows.TryGetValue(Key(frame, p, false), out flow))
                throw new InvalidOperationException("Host segmentation requires the guest TCP handshake; reconnect the application");
            flow.Seen = tick;
            // RFC 6691 MSS excludes the fixed IP/TCP headers. Account for
            // options/extensions, and never inject beyond standard Ethernet MTU.
            mss = Math.Min(flow.Mss - (p.Tcp - p.Ip - (p.Version == 4 ? 20 : 40)) - (p.Header - 20),
                1500 - (p.Tcp - p.Ip) - p.Header);
        }
        int dataStart = p.Tcp + p.Header, payload = p.End - dataStart;
        if (mss <= 0 || payload <= 0 || (payload + mss - 1) / mss > 4096)
            throw new ArgumentException("Host TCP segmentation size is unsupported");
        int count = (payload + mss - 1) / mss;
        byte[][] output = new byte[count][];
        uint sequence = Read32(frame, p.Tcp + 4);
        int id = p.Version == 4 ? Read16(frame, p.Ip + 4) : 0;
        for (int i = 0, consumed = 0; i < count; i++)
        {
            int size = Math.Min(mss, payload - consumed);
            byte[] segment = new byte[dataStart + size];
            Buffer.BlockCopy(frame, 0, segment, 0, dataStart);
            Buffer.BlockCopy(frame, dataStart + consumed, segment, dataStart, size);
            Write32(segment, p.Tcp + 4, unchecked(sequence + (uint)consumed));
            segment[p.Tcp + 13] = (byte)(flags & (i == count - 1 ? 0xff : ~0x09));
            if (i != 0) segment[p.Tcp + 13] &= 0x7f; // CWR only on first.
            if (p.Version == 4)
            {
                Write16(segment, p.Ip + 2, segment.Length - p.Ip);
                Write16(segment, p.Ip + 4, p.Offload ? (id + i) & 0x7fff : (id + i) & 0xffff);
            }
            else Write16(segment, p.Ip + 4, segment.Length - p.Ip - 40);
            NpcapFramePump.CompleteHostChecksums(segment);
            output[i] = segment;
            consumed += size;
        }
        return output;
    }

    void Expire(long tick)
    {
        List<string> expired = new List<string>();
        foreach (KeyValuePair<string, Flow> entry in flows)
            if (tick - entry.Value.Seen >= LifetimeMs) expired.Add(entry.Key);
        foreach (string key in expired) flows.Remove(key);
    }

    static string Key(byte[] f, Packet p, bool guest)
    {
        int address = p.Ip + (p.Version == 4 ? 12 : 8), size = p.Version == 4 ? 4 : 16;
        int source = guest ? address + size : address, destination = guest ? address : address + size;
        int sourcePort = guest ? p.Tcp + 2 : p.Tcp, destinationPort = guest ? p.Tcp : p.Tcp + 2;
        return BitConverter.ToString(f, 12, p.Ip - 12) + ":" + BitConverter.ToString(f, source, size) + ":" +
            BitConverter.ToString(f, destination, size) + ":" + Read16(f, sourcePort) + ":" + Read16(f, destinationPort);
    }

    static Packet Parse(byte[] f, bool host)
    {
        if (f == null || f.Length < 14 || f.Length > 262144)
            throw new ArgumentException("Invalid captured Ethernet length");
        int ip = 14, type = Read16(f, 12);
        for (int tags = 0; type == 0x8100 || type == 0x88a8; tags++)
        {
            if (tags == 2 || f.Length < ip + 4) throw new ArgumentException("Invalid VLAN header");
            type = Read16(f, ip + 2); ip += 4;
        }
        int tcp, end, version, protocol;
        bool offload;
        if (type == 0x0800)
        {
            if (f.Length < ip + 20 || f[ip] >> 4 != 4) throw new ArgumentException("Invalid IPv4 header");
            int header = (f[ip] & 15) * 4, total = Read16(f, ip + 2);
            if (header < 20 || ip + header > f.Length) throw new ArgumentException("Invalid IPv4 options");
            for (int i = ip + 20; i < ip + header; )
            {
                int kind = f[i];
                if (kind == 0) break;
                if (kind == 1) { i++; continue; }
                if (i + 2 > ip + header || f[i + 1] < 2 || i + f[i + 1] > ip + header)
                    throw new ArgumentException("Malformed IPv4 option");
                if (kind == 131 || kind == 137)
                    throw new ArgumentException("IPv4 source routing is unsupported");
                i += f[i + 1];
            }
            protocol = f[ip + 9];
            if ((Read16(f, ip + 6) & 0x3fff) != 0) return null;
            offload = host && protocol == 6 && total == 0;
            end = offload ? f.Length : ip + total;
            if ((!offload && total < header) || end > f.Length) throw new ArgumentException("Truncated IPv4 packet");
            tcp = ip + header; version = 4;
        }
        else if (type == 0x86dd)
        {
            if (f.Length < ip + 40 || f[ip] >> 4 != 6) throw new ArgumentException("Invalid IPv6 header");
            int length = Read16(f, ip + 4);
            protocol = f[ip + 6]; tcp = ip + 40; version = 6;
            offload = host && length == 0;
            end = offload ? f.Length : tcp + length;
            if (end > f.Length) throw new ArgumentException("Truncated IPv6 packet");
            for (int count = 0; protocol == 0 || protocol == 60; count++)
            {
                if (count == 8 || tcp + 8 > end) throw new ArgumentException("Invalid IPv6 extension header");
                int extension = (f[tcp + 1] + 1) * 8;
                if (tcp + extension > end) throw new ArgumentException("Truncated IPv6 extension header");
                for (int i = tcp + 2; i < tcp + extension; )
                {
                    int kind = f[i];
                    if (kind == 0) { i++; continue; }
                    if (i + 2 > tcp + extension || i + 2 + f[i + 1] > tcp + extension)
                        throw new ArgumentException("Malformed IPv6 option");
                    if (kind == 0xc2 || kind == 0xc9)
                        throw new ArgumentException("IPv6 jumbo and home-address options are unsupported");
                    i += 2 + f[i + 1];
                }
                protocol = f[tcp]; tcp += extension;
            }
        }
        else return null;
        if (protocol != 6)
        {
            if (offload) throw new ArgumentException("Non-TCP host segmentation is unsupported");
            return null;
        }
        if (tcp + 20 > end) throw new ArgumentException("Short TCP header");
        int tcpHeader = (f[tcp + 12] >> 4) * 4;
        if (tcpHeader < 20 || tcp + tcpHeader > end) throw new ArgumentException("Invalid TCP options");
        return new Packet { Ip = ip, Tcp = tcp, End = end, Header = tcpHeader, Version = version, Offload = offload };
    }

    static int Read16(byte[] b, int o) { return (b[o] << 8) | b[o + 1]; }
    static uint Read32(byte[] b, int o) { return ((uint)Read16(b, o) << 16) | (uint)Read16(b, o + 2); }
    static void Write16(byte[] b, int o, int v) { b[o] = (byte)(v >> 8); b[o + 1] = (byte)v; }
    static void Write32(byte[] b, int o, uint v) { Write16(b, o, (int)(v >> 16)); Write16(b, o + 2, (int)v); }
}
