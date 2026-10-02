// Registro de longo prazo: agrega as leituras de cada minuto, grava CSV diários (abrem no Excel)
// e devolve séries resumidas para os gráficos de 24 h, 7 dias e 30 dias.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace MonitorHW
{
    public class Registro
    {
        class Linha
        {
            public long T;   // início do minuto, em ms (Unix)
            public double CpuT, CpuTmax, CpuU, GpuT, GpuTmax, GpuU, CpuW, GpuW, Ram;
            public Dictionary<string, double> Discos = new Dictionary<string, double>();
        }

        class Acum
        {
            public int N;
            public double CpuT, CpuU, GpuT, GpuU, CpuW, GpuW, Ram;
            public int NCpuT, NCpuU, NGpuT, NGpuU, NCpuW, NGpuW, NRam;
            public double CpuTmax = double.NaN, GpuTmax = double.NaN;
            public Dictionary<string, double> DiscoMax = new Dictionary<string, double>();
        }

        static readonly CultureInfo br = new CultureInfo("pt-BR");
        static readonly CultureInfo inv = CultureInfo.InvariantCulture;
        static readonly UTF8Encoding utf8Bom = new UTF8Encoding(true);
        const string Cabecalho = "data_hora;cpu_temp_media;cpu_temp_max;cpu_uso;gpu_temp_media;gpu_temp_max;gpu_uso;cpu_w;gpu_w;ram_gb";
        const string CabecalhoDiscos = "data_hora;disco;id;temp";

        readonly string pasta;
        readonly int diasReter;
        readonly List<Linha> linhas = new List<Linha>();
        readonly Dictionary<string, string> nomes = new Dictionary<string, string>();
        long minutoAtual = -1;
        Acum acum = new Acum();

        public Registro(string pasta, int diasReter)
        {
            this.pasta = pasta;
            this.diasReter = diasReter;
            Directory.CreateDirectory(pasta);
            Limpar();
            Carregar();
        }

        static long MsLocal(DateTime local) { return new DateTimeOffset(local).ToUnixTimeMilliseconds(); }
        static DateTime Local(long ms) { return DateTimeOffset.FromUnixTimeMilliseconds(ms).LocalDateTime; }
        static void Somar(ref double soma, ref int n, double v) { if (!double.IsNaN(v)) { soma += v; n++; } }
        static double Media(double soma, int n) { return n > 0 ? soma / n : double.NaN; }
        static double Max(double a, double b) { return double.IsNaN(a) ? b : double.IsNaN(b) ? a : Math.Max(a, b); }
        static string Csv(double v) { return double.IsNaN(v) ? "" : v.ToString("0.#", br); }
        static double LerCsv(string s) { double v; return double.TryParse(s, NumberStyles.Float, br, out v) ? v : double.NaN; }

        // Chamado a cada leitura (2 s). Ao virar o minuto, fecha o anterior e grava.
        public void Amostra(double cpuT, double cpuU, double gpuT, double gpuU, double cpuW, double gpuW, double ram,
                            string[] discoIds, string[] discoNomes, double[] discoTemps)
        {
            var agora = DateTime.Now;
            long min = MsLocal(new DateTime(agora.Year, agora.Month, agora.Day, agora.Hour, agora.Minute, 0, DateTimeKind.Local));
            if (minutoAtual != min)
            {
                if (minutoAtual >= 0 && acum.N > 0) Fechar();
                minutoAtual = min;
                acum = new Acum();
            }
            acum.N++;
            Somar(ref acum.CpuT, ref acum.NCpuT, cpuT); Somar(ref acum.CpuU, ref acum.NCpuU, cpuU);
            Somar(ref acum.GpuT, ref acum.NGpuT, gpuT); Somar(ref acum.GpuU, ref acum.NGpuU, gpuU);
            Somar(ref acum.CpuW, ref acum.NCpuW, cpuW); Somar(ref acum.GpuW, ref acum.NGpuW, gpuW);
            Somar(ref acum.Ram, ref acum.NRam, ram);
            acum.CpuTmax = Max(acum.CpuTmax, cpuT);
            acum.GpuTmax = Max(acum.GpuTmax, gpuT);
            for (int i = 0; discoIds != null && i < discoIds.Length; i++)
            {
                nomes[discoIds[i]] = discoNomes[i];
                if (double.IsNaN(discoTemps[i])) continue;
                double m;
                acum.DiscoMax[discoIds[i]] = acum.DiscoMax.TryGetValue(discoIds[i], out m) ? Math.Max(m, discoTemps[i]) : discoTemps[i];
            }
        }

        void Fechar()
        {
            var l = new Linha
            {
                T = minutoAtual,
                CpuT = Media(acum.CpuT, acum.NCpuT), CpuTmax = acum.CpuTmax, CpuU = Media(acum.CpuU, acum.NCpuU),
                GpuT = Media(acum.GpuT, acum.NGpuT), GpuTmax = acum.GpuTmax, GpuU = Media(acum.GpuU, acum.NGpuU),
                CpuW = Media(acum.CpuW, acum.NCpuW), GpuW = Media(acum.GpuW, acum.NGpuW), Ram = Media(acum.Ram, acum.NRam),
                Discos = acum.DiscoMax
            };
            linhas.Add(l);
            long limite = MsLocal(DateTime.Now.AddDays(-diasReter));
            int velhas = 0;
            while (velhas < linhas.Count && linhas[velhas].T < limite) velhas++;
            if (velhas > 0) linhas.RemoveRange(0, velhas);

            var quando = Local(l.T);
            string hora = quando.ToString("yyyy-MM-dd HH:mm", inv);
            string dia = quando.ToString("yyyy-MM-dd", inv);
            try
            {
                Acrescentar(Path.Combine(pasta, dia + ".csv"), Cabecalho, string.Join(";", new[] {
                    hora, Csv(l.CpuT), Csv(l.CpuTmax), Csv(l.CpuU), Csv(l.GpuT), Csv(l.GpuTmax), Csv(l.GpuU), Csv(l.CpuW), Csv(l.GpuW), Csv(l.Ram) }));
                if (l.Discos.Count > 0)
                {
                    var sb = new StringBuilder();
                    foreach (var kv in l.Discos)
                    {
                        string nome;
                        nomes.TryGetValue(kv.Key, out nome);
                        sb.Append(hora).Append(';').Append((nome ?? kv.Key).Replace(";", ",")).Append(';').Append(kv.Key).Append(';').Append(Csv(kv.Value)).Append("\r\n");
                    }
                    Acrescentar(Path.Combine(pasta, "discos-" + dia + ".csv"), CabecalhoDiscos, sb.ToString().TrimEnd('\r', '\n'));
                }
            }
            catch { /* disco cheio ou arquivo aberto no Excel: tenta de novo no próximo minuto */ }
            if (quando.Hour == 0 && quando.Minute == 0) Limpar();
        }

        static void Acrescentar(string arquivo, string cabecalho, string texto)
        {
            bool novo = !File.Exists(arquivo);
            using (var w = new StreamWriter(arquivo, true, novo ? utf8Bom : new UTF8Encoding(false)))
            {
                if (novo) w.Write(cabecalho + "\r\n");
                w.Write(texto + "\r\n");
            }
        }

        void Limpar()
        {
            var limite = DateTime.Today.AddDays(-diasReter);
            foreach (var f in Directory.GetFiles(pasta, "*.csv"))
            {
                string n = Path.GetFileNameWithoutExtension(f);
                if (n.StartsWith("discos-")) n = n.Substring(7);
                DateTime d;
                if (DateTime.TryParseExact(n, "yyyy-MM-dd", inv, DateTimeStyles.None, out d) && d < limite)
                {
                    try { File.Delete(f); } catch { }
                }
            }
        }

        void Carregar()
        {
            var porMinuto = new Dictionary<long, Linha>();
            var limite = DateTime.Today.AddDays(-diasReter);
            foreach (var f in Directory.GetFiles(pasta, "*.csv").OrderBy(x => x))
            {
                string n = Path.GetFileNameWithoutExtension(f);
                bool discos = n.StartsWith("discos-");
                DateTime dia;
                if (!DateTime.TryParseExact(discos ? n.Substring(7) : n, "yyyy-MM-dd", inv, DateTimeStyles.None, out dia) || dia < limite) continue;
                string[] conteudo;
                try { conteudo = File.ReadAllLines(f, Encoding.UTF8); } catch { continue; }
                foreach (var linha in conteudo.Skip(1))
                {
                    var c = linha.Split(';');
                    DateTime h;
                    if (c.Length < 4 || !DateTime.TryParseExact(c[0], "yyyy-MM-dd HH:mm", inv, DateTimeStyles.AssumeLocal, out h)) continue;
                    long t = MsLocal(h);
                    Linha l;
                    if (!porMinuto.TryGetValue(t, out l))
                    {
                        l = new Linha { T = t, CpuT = double.NaN, CpuTmax = double.NaN, CpuU = double.NaN, GpuT = double.NaN, GpuTmax = double.NaN, GpuU = double.NaN, CpuW = double.NaN, GpuW = double.NaN, Ram = double.NaN };
                        porMinuto[t] = l;
                    }
                    if (discos)
                    {
                        nomes[c[2]] = c[1];
                        l.Discos[c[2]] = LerCsv(c[3]);
                    }
                    else if (c.Length >= 10)
                    {
                        l.CpuT = LerCsv(c[1]); l.CpuTmax = LerCsv(c[2]); l.CpuU = LerCsv(c[3]);
                        l.GpuT = LerCsv(c[4]); l.GpuTmax = LerCsv(c[5]); l.GpuU = LerCsv(c[6]);
                        l.CpuW = LerCsv(c[7]); l.GpuW = LerCsv(c[8]); l.Ram = LerCsv(c[9]);
                    }
                }
            }
            linhas.AddRange(porMinuto.Values.OrderBy(x => x.T));
        }

        static string J(double v) { return double.IsNaN(v) ? "null" : v.ToString("0.#", inv); }
        static string Esc(string s)
        {
            var sb = new StringBuilder();
            foreach (char ch in s ?? "")
            {
                if (ch == '"' || ch == '\\') sb.Append('\\').Append(ch);
                else if (ch < 32) sb.Append(' ');
                else sb.Append(ch);
            }
            return sb.ToString();
        }

        // Série para o painel: 24 h em passos de 1 min, 7 dias de 10 min, 30 dias de 30 min.
        public string Serie(int dias)
        {
            int passo = dias <= 1 ? 1 : dias <= 7 ? 10 : 30;
            long passoMs = passo * 60000L;
            long ini = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - dias * 86400000L;
            var sel = linhas.Where(l => l.T >= ini).ToList();

            var sb = new StringBuilder();
            sb.Append("{\"passoMin\":").Append(passo).Append(",\"inicio\":").Append(ini).Append(",\"pontos\":[");
            double cpuMax = double.NaN, gpuMax = double.NaN, kwh = 0; long cpuMaxT = 0, gpuMaxT = 0;
            var discoMax = new Dictionary<string, double>(); var discoMaxT = new Dictionary<string, long>();
            var discoSeries = new Dictionary<string, StringBuilder>();
            bool primeiro = true;
            int i = 0;
            while (i < sel.Count)
            {
                long b = sel[i].T - (sel[i].T % passoMs);
                var grupo = new List<Linha>();
                while (i < sel.Count && sel[i].T - (sel[i].T % passoMs) == b) grupo.Add(sel[i++]);
                Func<Func<Linha, double>, double> media = f =>
                {
                    var vs = grupo.Select(f).Where(v => !double.IsNaN(v)).ToList();
                    return vs.Count > 0 ? vs.Average() : double.NaN;
                };
                Func<Func<Linha, double>, double> maximo = f =>
                {
                    var vs = grupo.Select(f).Where(v => !double.IsNaN(v)).ToList();
                    return vs.Count > 0 ? vs.Max() : double.NaN;
                };
                double cT = media(l => l.CpuT), cTx = maximo(l => l.CpuTmax), gT = media(l => l.GpuT), gTx = maximo(l => l.GpuTmax);
                double cW = media(l => l.CpuW), gW = media(l => l.GpuW);
                if (!primeiro) sb.Append(',');
                primeiro = false;
                sb.Append('[').Append(b).Append(',').Append(J(cT)).Append(',').Append(J(cTx)).Append(',').Append(J(media(l => l.CpuU)))
                  .Append(',').Append(J(gT)).Append(',').Append(J(gTx)).Append(',').Append(J(media(l => l.GpuU)))
                  .Append(',').Append(J(cW)).Append(',').Append(J(gW)).Append(',').Append(J(media(l => l.Ram))).Append(']');
                foreach (var l in grupo)
                {
                    if (!double.IsNaN(l.CpuTmax) && (double.IsNaN(cpuMax) || l.CpuTmax > cpuMax)) { cpuMax = l.CpuTmax; cpuMaxT = l.T; }
                    if (!double.IsNaN(l.GpuTmax) && (double.IsNaN(gpuMax) || l.GpuTmax > gpuMax)) { gpuMax = l.GpuTmax; gpuMaxT = l.T; }
                    double w = (double.IsNaN(l.CpuW) ? 0 : l.CpuW) + (double.IsNaN(l.GpuW) ? 0 : l.GpuW);
                    kwh += w / 60.0 / 1000.0;   // cada linha é um minuto
                    foreach (var kv in l.Discos)
                    {
                        double m;
                        if (double.IsNaN(kv.Value)) continue;
                        if (!discoMax.TryGetValue(kv.Key, out m) || kv.Value > m) { discoMax[kv.Key] = kv.Value; discoMaxT[kv.Key] = l.T; }
                    }
                }
                var porDisco = new Dictionary<string, List<double>>();
                foreach (var l in grupo)
                    foreach (var kv in l.Discos)
                    {
                        if (double.IsNaN(kv.Value)) continue;
                        List<double> lista;
                        if (!porDisco.TryGetValue(kv.Key, out lista)) { lista = new List<double>(); porDisco[kv.Key] = lista; }
                        lista.Add(kv.Value);
                    }
                foreach (var kv in porDisco)
                {
                    StringBuilder ds;
                    if (!discoSeries.TryGetValue(kv.Key, out ds)) { ds = new StringBuilder(); discoSeries[kv.Key] = ds; }
                    if (ds.Length > 0) ds.Append(',');
                    ds.Append('[').Append(b).Append(',').Append(J(kv.Value.Average())).Append(']');
                }
            }
            sb.Append("],\"minutos\":").Append(sel.Count);
            sb.Append(",\"resumo\":{\"cpuMax\":").Append(J(cpuMax)).Append(",\"cpuMaxT\":").Append(cpuMaxT)
              .Append(",\"gpuMax\":").Append(J(gpuMax)).Append(",\"gpuMaxT\":").Append(gpuMaxT)
              .Append(",\"kwh\":").Append(kwh.ToString("0.###", inv)).Append("},\"discos\":[");
            bool pd = true;
            foreach (var kv in discoSeries.OrderByDescending(x => discoMax.ContainsKey(x.Key) ? discoMax[x.Key] : 0))
            {
                string nome;
                nomes.TryGetValue(kv.Key, out nome);
                if (!pd) sb.Append(',');
                pd = false;
                sb.Append("{\"id\":\"").Append(Esc(kv.Key)).Append("\",\"nome\":\"").Append(Esc(nome ?? kv.Key))
                  .Append("\",\"max\":").Append(J(discoMax[kv.Key])).Append(",\"maxT\":").Append(discoMaxT[kv.Key])
                  .Append(",\"pontos\":[").Append(kv.Value).Append("]}");
            }
            sb.Append("]}");
            return sb.ToString();
        }
    }
}
