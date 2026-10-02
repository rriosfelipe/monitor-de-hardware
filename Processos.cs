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
        }

        static readonly Regex rePid = new Regex(@"^pid_(\d+)_");
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

            // GPU: maior uso entre os motores de cada processo (3D, cópia, vídeo, computação) e VRAM dedicada.
            PdhCollectQueryData(query);
            var motores = new Dictionary<string, double>();
            foreach (var kv in Ler(cUso, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100))
            {
                var mp = rePid.Match(kv.Key); var mm = reMotor.Match(kv.Key);
                if (!mp.Success || !mm.Success) continue;
                string chave = mp.Groups[1].Value + "|" + mm.Groups[1].Value;
                double v;
                motores[chave] = (motores.TryGetValue(chave, out v) ? v : 0) + kv.Value;
            }
            var gpu = new Dictionary<string, Grupo>(StringComparer.OrdinalIgnoreCase);
            var pidsGpu = new Dictionary<int, Grupo>();
            Func<int, Grupo> grupoGpu = pid =>
            {
                Grupo g;
                if (pidsGpu.TryGetValue(pid, out g)) return g;
                string nome;
                if (!nomes.TryGetValue(pid, out nome)) nome = "PID " + pid;
                g = Pegar(gpu, nome);
                g.Qtd++;
                pidsGpu[pid] = g;
                return g;
            };
            var porPid = new Dictionary<int, double>();
            var motorPorPid = new Dictionary<int, KeyValuePair<string, double>>();
            foreach (var kv in motores)
            {
                var partes = kv.Key.Split('|');
                int pid = int.Parse(partes[0]);
                KeyValuePair<string, double> m;
                if (!motorPorPid.TryGetValue(pid, out m) || kv.Value > m.Value) motorPorPid[pid] = new KeyValuePair<string, double>(partes[1], kv.Value);
            }
            foreach (var kv in motorPorPid)
            {
                var g = grupoGpu(kv.Key);
                g.Pct += kv.Value.Value;
                if (kv.Value.Value > g.MotorPct) { g.MotorPct = kv.Value.Value; g.Motor = kv.Value.Key; }
            }
            foreach (var kv in Ler(cMem, PDH_FMT_DOUBLE))
            {
                var mp = rePid.Match(kv.Key);
                if (!mp.Success) continue;
                grupoGpu(int.Parse(mp.Groups[1].Value)).MemMB += kv.Value / 1048576.0;
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
            for (int i = 0; i < lista.Count && i < limite; i++)
            {
                var g = lista[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"nome\":\"").Append(Escapar(g.Nome)).Append("\",\"qtd\":").Append(g.Qtd)
                  .Append(",\"pct\":").Append(Math.Min(100, g.Pct).ToString("0.0", inv))
                  .Append(",\"memMB\":").Append(g.MemMB.ToString("0", inv));
                if (ehGpu) sb.Append(",\"motor\":\"").Append(Escapar(g.Motor ?? "")).Append('"');
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
