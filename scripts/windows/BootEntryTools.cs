using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace NvUnlockBootRepair {
    public sealed class Variable {
        public byte[] Data;
        public uint Attributes;
    }
    public sealed class LoadOption {
        public string Description;
        public string FilePath;
        public int OptionalOffset;
        public int OptionalLength;
        public uint LoadAttributes;
        public bool HasGptPartition;
        public byte[] Prefix;
    }
    public static class Codec {
        public static bool Equal(byte[] a, byte[] b) {
            if (a == null || b == null || a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }
        public static LoadOption Parse(byte[] b) {
            if (b == null || b.Length < 12) throw new FormatException("Short EFI_LOAD_OPTION.");
            int pathSize = BitConverter.ToUInt16(b, 4);
            int endDescription = 6;
            while (endDescription + 1 < b.Length && (b[endDescription] != 0 || b[endDescription+1] != 0)) endDescription += 2;
            if (endDescription + 1 >= b.Length) throw new FormatException("Unterminated description.");
            int pathStart = endDescription + 2;
            int pathEnd = pathStart + pathSize;
            if (pathSize < 4 || pathEnd > b.Length) throw new FormatException("Invalid device path length.");
            var text = new UnicodeEncoding(false, false, true);
            string description = text.GetString(b, 6, endDescription - 6);
            var file = new StringBuilder();
            bool ended = false, partition = false;
            for (int p = pathStart; p < pathEnd;) {
                if (p + 4 > pathEnd) throw new FormatException("Short device path node.");
                int length = BitConverter.ToUInt16(b, p+2);
                if (length < 4 || p + length > pathEnd) throw new FormatException("Invalid device path node length.");
                if (b[p] == 0x7f) {
                    if (b[p+1] != 0xff || length != 4 || p + length != pathEnd)
                        throw new FormatException("Multiple/invalid device paths are not supported.");
                    ended = true;
                }
                if (b[p] == 4 && b[p+1] == 1 && length == 42 && b[p+40] == 2 && b[p+41] == 2) partition = true;
                if (b[p] == 4 && b[p+1] == 4) {
                    if (length < 6 || length % 2 != 0 || b[p+length-2] != 0 || b[p+length-1] != 0)
                        throw new FormatException("Invalid file path node.");
                    string part = text.GetString(b, p+4, length-6);
                    if (part.IndexOf('\0') >= 0) throw new FormatException("Embedded NUL in file path.");
                    file.Append(part);
                }
                p += length;
            }
            if (!ended) throw new FormatException("Missing device path terminator.");
            var prefix = new byte[pathEnd];
            Buffer.BlockCopy(b, 0, prefix, 0, pathEnd);
            return new LoadOption { Description=description, FilePath=file.ToString(), OptionalOffset=pathEnd,
                OptionalLength=b.Length-pathEnd, LoadAttributes=BitConverter.ToUInt32(b,0), HasGptPartition=partition, Prefix=prefix };
        }
        public static void RequireNvUnlock(LoadOption o) {
            if (!String.Equals(o.Description, "NV Unlock", StringComparison.Ordinal) ||
                !String.Equals(o.FilePath, @"\EFI\nvunlock\shimx64.efi", StringComparison.OrdinalIgnoreCase) ||
                !o.HasGptPartition || (o.LoadAttributes & 1) == 0)
                throw new InvalidOperationException("Not the expected active NV Unlock entry on a GPT partition.");
        }
    }
    public static class Firmware {
        const string GlobalGuid = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}";
        [StructLayout(LayoutKind.Sequential)] struct Luid { public uint LowPart; public int HighPart; }
        [StructLayout(LayoutKind.Sequential)] struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref TokenPrivileges state, uint size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        static extern uint GetFirmwareEnvironmentVariableExW(string name, string guid, [Out] byte[] data, uint size, out uint attributes);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        static extern bool SetFirmwareEnvironmentVariableExW(string name, string guid, byte[] data, uint size, uint attributes);
        public static void EnablePrivilege() {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                Luid luid;
                if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var state = new TokenPrivileges { Count=1, Luid=luid, Attributes=2 };
                bool ok = AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero);
                int error = Marshal.GetLastWin32Error();
                if (!ok || error != 0) throw new Win32Exception(error);
            } finally { CloseHandle(token); }
        }
        public static Variable Read(string name) {
            if (!Regex.IsMatch(name, @"\A(?:BootOrder|Boot[0-9A-F]{4})\z")) throw new ArgumentException("Unexpected variable name.");
            for (int size=4096; size<=1048576; size*=2) {
                var data = new byte[size]; uint attributes;
                uint count = GetFirmwareEnvironmentVariableExW(name, GlobalGuid, data, (uint)size, out attributes);
                if (count > 0) { Array.Resize(ref data, (int)count); return new Variable { Data=data, Attributes=attributes }; }
                int error=Marshal.GetLastWin32Error();
                if (error != 122) throw new Win32Exception(error, name + ": " + new Win32Exception(error).Message);
            }
            throw new InvalidOperationException("Firmware variable exceeds size limit.");
        }
        public static void WriteNvUnlock(string name, byte[] data, uint attributes) {
            if (!Regex.IsMatch(name, @"\ABoot[0-9A-F]{4}\z") || attributes != 7)
                throw new ArgumentException("Refusing unexpected name or variable attributes.");
            Codec.RequireNvUnlock(Codec.Parse(data));
            if (!SetFirmwareEnvironmentVariableExW(name, GlobalGuid, data, (uint)data.Length, attributes))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
