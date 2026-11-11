# Reads/writes OneShot's Data\xScripts.rxdata (a Ruby Marshal array of
# [id, name, zlib(code)]) and builds the RayTrace2D loader. Used by install/uninstall.

$LoaderName = 'RayTrace2D Loader'

if (-not ('RtxRx' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

public class RtxEntry { public int Id; public string Name; public byte[] NameBytes; public byte[] Code; }

public static class RtxRx {
    static byte[] b; static int p; static List<byte[]> syms;

    static int Fix() {
        int c = (sbyte)b[p++];
        if (c == 0) return 0;
        if (c > 5) return c - 5;
        if (c < -5) return c + 5;
        int n = Math.Abs(c); long v = 0;
        for (int k = 0; k < n; k++) v |= ((long)b[p++]) << (8 * k);
        if (c < 0) v -= (1L << (8 * n));
        return (int)v;
    }
    static byte[] Raw() { int n = Fix(); byte[] r = new byte[n]; Array.Copy(b, p, r, 0, n); p += n; return r; }

    static object Obj() {
        char t = (char)b[p++];
        switch (t) {
            case '[': { int n = Fix(); var l = new List<object>(); for (int i = 0; i < n; i++) l.Add(Obj()); return l; }
            case 'i': return Fix();
            case '"': return Raw();
            case 'I': { object v = Obj(); int n = Fix(); for (int i = 0; i < n; i++) { Obj(); Obj(); } return v; }
            case ':': { byte[] s = Raw(); syms.Add(s); return s; }
            case ';': return syms[Fix()];
            case '@': Fix(); return null;
            case 'T': return true;
            case 'F': return false;
            case '0': return null;
        }
        throw new Exception("unsupported marshal type '" + t + "' at " + (p - 1));
    }

    public static RtxEntry[] Load(string path) {
        b = File.ReadAllBytes(path); p = 2; syms = new List<byte[]>();
        if (b.Length < 3 || b[0] != 4 || b[1] != 8) throw new Exception("not a Ruby Marshal file");
        var top = (List<object>)Obj();
        var res = new List<RtxEntry>();
        foreach (object o in top) {
            var e = (List<object>)o;
            var nb = (byte[])e[1];
            res.Add(new RtxEntry { Id = (int)e[0], NameBytes = nb, Name = Encoding.UTF8.GetString(nb), Code = (byte[])e[2] });
        }
        return res.ToArray();
    }

    static void W(Stream m, int v) {
        if (v == 0) { m.WriteByte(0); return; }
        if (v > 0 && v < 123) { m.WriteByte((byte)(v + 5)); return; }
        if (v < 0 && v > -124) { m.WriteByte((byte)((v - 5) & 0xff)); return; }
        for (int n = 1; n <= 4; n++) {
            long max = 1L << (8 * n);
            if ((v >= 0 && v < max) || (v < 0 && v >= -max)) {
                m.WriteByte((byte)(v >= 0 ? n : 256 - n));
                long u = v & (max - 1);
                for (int k = 0; k < n; k++) m.WriteByte((byte)((u >> (8 * k)) & 0xff));
                return;
            }
        }
        throw new Exception("fixnum too large");
    }

    public static void Save(RtxEntry[] list, string path) {
        var m = new MemoryStream();
        m.WriteByte(4); m.WriteByte(8); m.WriteByte((byte)'['); W(m, list.Length);
        bool first = true;
        foreach (var e in list) {
            m.WriteByte((byte)'['); W(m, 3);
            m.WriteByte((byte)'i'); W(m, e.Id);
            // name: UTF-8 string with encoding ivar (E = true)
            m.WriteByte((byte)'I'); m.WriteByte((byte)'"'); W(m, e.NameBytes.Length); m.Write(e.NameBytes, 0, e.NameBytes.Length);
            W(m, 1);
            if (first) { m.WriteByte((byte)':'); W(m, 1); m.WriteByte((byte)'E'); first = false; }
            else { m.WriteByte((byte)';'); W(m, 0); }
            m.WriteByte((byte)'T');
            m.WriteByte((byte)'"'); W(m, e.Code.Length); m.Write(e.Code, 0, e.Code.Length);
        }
        File.WriteAllBytes(path, m.ToArray());
    }

    public static byte[] Zlib(byte[] data) {
        var o = new MemoryStream();
        o.WriteByte(0x78); o.WriteByte(0x9C);
        using (var d = new DeflateStream(o, CompressionMode.Compress, true)) d.Write(data, 0, data.Length);
        uint a = 1, s2 = 0;
        foreach (byte x in data) { a = (a + x) % 65521; s2 = (s2 + a) % 65521; }
        uint ad = (s2 << 16) | a;
        o.WriteByte((byte)(ad >> 24)); o.WriteByte((byte)(ad >> 16)); o.WriteByte((byte)(ad >> 8)); o.WriteByte((byte)ad);
        return o.ToArray();
    }

    public static byte[] Unzlib(byte[] data) {
        var i = new MemoryStream(data, 2, data.Length - 6);
        var o = new MemoryStream();
        using (var d = new DeflateStream(i, CompressionMode.Decompress)) d.CopyTo(o);
        return o.ToArray();
    }
}
'@
}

function Read-RxScripts([string]$path) {
    [RtxRx]::Load($path) | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; NameBytes = $_.NameBytes; Code = $_.Code }
    }
}

function Write-RxScripts($list, [string]$path) {
    $arr = foreach ($s in $list) {
        $e = New-Object RtxEntry
        $e.Id = $s.Id; $e.Name = $s.Name; $e.NameBytes = $s.NameBytes; $e.Code = $s.Code
        $e
    }
    [RtxRx]::Save([RtxEntry[]]$arr, $path)
}

function Compress-Zlib([byte[]]$data) { return [RtxRx]::Zlib($data) }

function Get-LoaderCode([string]$gameDirForRuby) {
@"
# RayTrace2D loader (OneShot RTX). Safe to remove: run uninstall.bat.
# Looks for the mod next to the game, so it works however the game is started.
begin
  rt2d_dir = ["Mods", "$gameDirForRuby/Mods"].find { |d| File.exist?(d + "/RayTrace2D.rb") }
  if rt2d_dir
    `$RT2D_DIR = rt2d_dir
    eval(File.read(rt2d_dir + "/RayTrace2D.rb"), TOPLEVEL_BINDING, rt2d_dir + "/RayTrace2D.rb")
  end
rescue Exception => e
  raise if e.is_a?(SystemExit)
  begin
    File.open((`$RT2D_DIR || "$gameDirForRuby/Mods") + "/RayTrace2D.log", "a") { |f| f.puts("loader error: #{e.class}: #{e.message}") }
  rescue Exception
  end
end
"@
}
