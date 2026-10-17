// Uso de CPU e GPU por programa, nas mesmas fontes do Gerenciador de Tarefas:
// tempo de CPU de cada processo e contadores "GPU Engine" / "GPU Process Memory" (API nativa PDH).
// Get-Counter é lento demais com centenas de instâncias de GPU; aqui cada amostra leva poucos ms.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace MonitorHW
{
    public class Processos : IDisposable
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PDH_FMT_COUNTERVALUE_ITEM_DOUBLE
        {
            public IntPtr szName;
            public uint CStatus;
            public double doubleValue;
        }

        const uint PDH_FMT_DOUBLE = 0x00000200;
        const uint PDH_FMT_NOCAP100 = 0x00008000;
        const uint PDH_MORE_DATA = 0x800007D2;

        [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
        static extern uint PdhOpenQuery(string src, IntPtr user, out IntPtr query);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
        static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr user, out IntPtr counter);
        [DllImport("pdh.dll")]
        static extern uint PdhCollectQueryData(IntPtr query);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
        static extern uint PdhGetFormattedCounterArray(IntPtr counter, uint format, ref uint bufferSize, out uint itemCount, IntPtr items);
        [DllImport("pdh.dll")]
        static extern uint PdhCloseQuery(IntPtr query);

        class Grupo
        {
            public string Nome;
            public int Qtd;
            public double Pct;
            public double MemMB;
            public string Motor;
            public double MotorPct;
            public string Placa;
        }

        // ---- Placas de vídeo pelo LUID (o mesmo que aparece nos contadores de GPU), via DXGI ----
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DXGI_ADAPTER_DESC1
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId, DeviceId, SubSysId, Revision;
            public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
            public uint LuidLow;
            public int LuidHigh;
            public uint Flags;
        }
        [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IDXGIAdapter1
        {
            void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
            void EnumOutputs(); void GetDesc(); void CheckInterfaceSupport();
            [PreserveSig] int GetDesc1(out DXGI_ADAPTER_DESC1 d);
        }
        [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IDXGIFactory1
        {
            void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
            void EnumAdapters(); void MakeWindowAssociation(); void GetWindowAssociation(); void CreateSwapChain(); void CreateSoftwareAdapter();
            [PreserveSig] int EnumAdapters1(uint i, out IDXGIAdapter1 a);
        }
        [DllImport("dxgi.dll")]
        static extern int CreateDXGIFactory1([In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 f);

        Dictionary<long, string> placas = new Dictionary<long, string>();
        DateTime placasHora = DateTime.MinValue;

        void LerPlacas()
        {
            placasHora = DateTime.UtcNow;
            var d = new Dictionary<long, string>();
            try
            {
                Guid iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
                IDXGIFactory1 f;
                if (CreateDXGIFactory1(ref iid, out f) != 0) return;
                for (uint i = 0; i < 16; i++)
                {
                    IDXGIAdapter1 a;
                    if (f.EnumAdapters1(i, out a) != 0) break;
                    DXGI_ADAPTER_DESC1 desc;
                    if (a.GetDesc1(out desc) == 0) d[((long)desc.LuidHigh << 32) | desc.LuidLow] = (desc.Description ?? "").Trim();
                    Marshal.ReleaseComObject(a);
                }
                Marshal.ReleaseComObject(f);
            }
            catch { }
            placas = d;
        }

        // "luid_0x00000000_0x0000D1B5" -> nome da placa ("" se não souber)
        string Placa(string luid)
        {
            var m = reLuidPartes.Match(luid);
            if (!m.Success) return "";
            long chave = ((long)Convert.ToUInt32(m.Groups[1].Value, 16) << 32) | Convert.ToUInt32(m.Groups[2].Value, 16);
            string nome;
            if (placas.TryGetValue(chave, out nome)) return nome;
            if ((DateTime.UtcNow - placasHora).TotalSeconds > 30) { LerPlacas(); if (placas.TryGetValue(chave, out nome)) return nome; }
            return "";
        }

        static readonly Regex rePid = new Regex(@"^pid_(\d+)_");
        static readonly Regex reLuid = new Regex(@"luid_0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+");
        static readonly Regex reLuidPartes = new Regex(@"luid_0x([0-9A-Fa-f]+)_0x([0-9A-Fa-f]+)");
        static readonly Regex reMotor = new Regex(@"engtype_(.+)$");
        static readonly CultureInfo inv = CultureInfo.InvariantCulture;

        IntPtr query, cUso, cMem;
        Dictionary<int, double> cpuAnterior = new Dictionary<int, double>();
        DateTime horaAnterior = DateTime.MinValue;
        readonly int nucleos = Environment.ProcessorCount;

        public Processos()
        {
            PdhOpenQuery(null, IntPtr.Zero, out query);
            PdhAddEnglishCounter(query, @"\GPU Engine(*)\Utilization Percentage", IntPtr.Zero, out cUso);
            PdhAddEnglishCounter(query, @"\GPU Process Memory(*)\Dedicated Usage", IntPtr.Zero, out cMem);
            PdhCollectQueryData(query);
            LerPlacas();
        }

        List<KeyValuePair<string, double>> Ler(IntPtr counter, uint formato)
        {
            var r = new List<KeyValuePair<string, double>>();
            uint tamanho = 0, n;
            if (PdhGetFormattedCounterArray(counter, formato, ref tamanho, out n, IntPtr.Zero) != PDH_MORE_DATA || tamanho == 0) return r;
            IntPtr buf = Marshal.AllocHGlobal((int)tamanho);
            try
            {
                if (PdhGetFormattedCounterArray(counter, formato, ref tamanho, out n, buf) != 0) return r;
                int passo = Marshal.SizeOf(typeof(PDH_FMT_COUNTERVALUE_ITEM_DOUBLE));
                for (int i = 0; i < n; i++)
                {
                    var item = (PDH_FMT_COUNTERVALUE_ITEM_DOUBLE)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + i * passo), typeof(PDH_FMT_COUNTERVALUE_ITEM_DOUBLE));
                    if (item.CStatus > 1) continue;
                    r.Add(new KeyValuePair<string, double>(Marshal.PtrToStringUni(item.szName), item.doubleValue));
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return r;
        }

        static Grupo Pegar(Dictionary<string, Grupo> d, string nome)
        {
            Grupo g;
            if (!d.TryGetValue(nome, out g)) { g = new Grupo { Nome = nome }; d[nome] = g; }
            return g;
        }

        // Devolve JSON: {"cpu":[...],"gpu":[...]} com os programas agrupados pelo nome, do maior para o menor.
        public string Amostrar(int limite)
        {
            var agora = DateTime.UtcNow;
            double dt = horaAnterior == DateTime.MinValue ? 0 : (agora - horaAnterior).TotalMilliseconds;
            horaAnterior = agora;

            // CPU: diferença do tempo de processador de cada processo desde a última amostra.
            var nomes = new Dictionary<int, string>();
            var cpu = new Dictionary<string, Grupo>(StringComparer.OrdinalIgnoreCase);
            var atual = new Dictionary<int, double>();
            foreach (var p in Process.GetProcesses())
            {
                try
                {
                    if (p.Id == 0) continue;
                    nomes[p.Id] = p.ProcessName;
                    var g = Pegar(cpu, p.ProcessName);
                    g.Qtd++;
                    try { g.MemMB += p.WorkingSet64 / 1048576.0; } catch { }
                    double ms;
                    try { ms = p.TotalProcessorTime.TotalMilliseconds; } catch { continue; }
                    atual[p.Id] = ms;
                    double antes;
                    if (dt > 0 && cpuAnterior.TryGetValue(p.Id, out antes))
                        g.Pct += Math.Max(0, ms - antes) / dt / nucleos * 100.0;
                }
                finally { p.Dispose(); }
            }
            cpuAnterior = atual;

            // GPU: maior uso entre os motores de cada processo (3D, cópia, vídeo, computação) e VRAM dedicada,
            // separados por placa (o LUID do contador diz em qual placa o processo está).
            PdhCollectQueryData(query);
            var motores = new Dictionary<string, double>();
            foreach (var kv in Ler(cUso, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100))
            {
                var mp = rePid.Match(kv.Key); var mm = reMotor.Match(kv.Key); var ml = reLuid.Match(kv.Key);
                if (!mp.Success || !mm.Success) continue;
                string chave = mp.Groups[1].Value + "|" + (ml.Success ? ml.Value : "") + "|" + mm.Groups[1].Value;
                double v;
                motores[chave] = (motores.TryGetValue(chave, out v) ? v : 0) + kv.Value;
            }
            var gpu = new Dictionary<string, Grupo>(StringComparer.OrdinalIgnoreCase);
            var pidsGpu = new Dictionary<string, Grupo>();
            Func<int, string, Grupo> grupoGpu = (pid, luid) =>
            {
                Grupo g;
                string chavePid = pid + "|" + luid;
                if (pidsGpu.TryGetValue(chavePid, out g)) return g;
                string nome;
                if (!nomes.TryGetValue(pid, out nome)) nome = "PID " + pid;
                string placa = Placa(luid);
                if (!gpu.TryGetValue(nome + "|" + placa, out g)) { g = new Grupo { Nome = nome, Placa = placa }; gpu[nome + "|" + placa] = g; }
                g.Qtd++;
                pidsGpu[chavePid] = g;
                return g;
            };
            var motorPorPid = new Dictionary<string, KeyValuePair<string, double>>();
            foreach (var kv in motores)
            {
                var partes = kv.Key.Split('|');
                string chavePid = partes[0] + "|" + partes[1];
                KeyValuePair<string, double> m;
                if (!motorPorPid.TryGetValue(chavePid, out m) || kv.Value > m.Value) motorPorPid[chavePid] = new KeyValuePair<string, double>(partes[2], kv.Value);
            }
            foreach (var kv in motorPorPid)
            {
                var partes = kv.Key.Split('|');
                var g = grupoGpu(int.Parse(partes[0]), partes[1]);
                g.Pct += kv.Value.Value;
                if (kv.Value.Value > g.MotorPct) { g.MotorPct = kv.Value.Value; g.Motor = kv.Value.Key; }
            }
            foreach (var kv in Ler(cMem, PDH_FMT_DOUBLE))
            {
                var mp = rePid.Match(kv.Key); var ml = reLuid.Match(kv.Key);
                if (!mp.Success) continue;
                grupoGpu(int.Parse(mp.Groups[1].Value), ml.Success ? ml.Value : "").MemMB += kv.Value / 1048576.0;
            }

            var sb = new StringBuilder();
            sb.Append("{\"cpu\":");
            Escrever(sb, cpu.Values, limite, false);
            sb.Append(",\"gpu\":");
            Escrever(sb, gpu.Values, limite, true);
            sb.Append(",\"nucleos\":").Append(nucleos).Append('}');
            return sb.ToString();
        }

        static void Escrever(StringBuilder sb, IEnumerable<Grupo> grupos, int limite, bool ehGpu)
        {
            var lista = new List<Grupo>(grupos);
            lista.RemoveAll(g => ehGpu ? (g.Pct < 0.1 && g.MemMB < 50) : g.Nome.Equals("Idle", StringComparison.OrdinalIgnoreCase));
            lista.Sort((a, b) => b.Pct != a.Pct ? b.Pct.CompareTo(a.Pct) : b.MemMB.CompareTo(a.MemMB));
            sb.Append('[');
            var porPlaca = new Dictionary<string, int>();
            bool primeiro = true;
            for (int i = 0; i < lista.Count; i++)
            {
                var g = lista[i];
                string pl = g.Placa ?? "";
                int n;
                porPlaca.TryGetValue(pl, out n);
                if (n >= limite) continue;   // o limite vale para cada placa
                porPlaca[pl] = n + 1;
                if (!primeiro) sb.Append(',');
                primeiro = false;
                sb.Append("{\"nome\":\"").Append(Escapar(g.Nome)).Append("\",\"qtd\":").Append(g.Qtd)
                  .Append(",\"pct\":").Append(Math.Min(100, g.Pct).ToString("0.0", inv))
                  .Append(",\"memMB\":").Append(g.MemMB.ToString("0", inv));
                if (ehGpu) sb.Append(",\"motor\":\"").Append(Escapar(g.Motor ?? "")).Append("\",\"placa\":\"").Append(Escapar(g.Placa ?? "")).Append('"');
                sb.Append('}');
            }
            sb.Append(']');
        }

        static string Escapar(string s)
        {
            var sb = new StringBuilder();
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c < 32) sb.Append("\\u").Append(((int)c).ToString("x4"));
                else sb.Append(c);
            }
            return sb.ToString();
        }

        public void Dispose() { if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; } }
    }
}
