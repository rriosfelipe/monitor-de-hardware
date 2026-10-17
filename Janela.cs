// Redimensiona a janela do painel (modo compacto) pela API do Windows,
// guardando o tamanho anterior para restaurar ao voltar ao modo completo.
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace MonitorHW
{
    public static class Janela
    {
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int L, T, R, B; }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr depois, int x, int y, int w, int alt, uint flags);

        const uint SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
        static RECT salvo;
        static bool temSalvo, salvoMax;

        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

        [StructLayout(LayoutKind.Sequential)]
        struct MONITORINFO { public int Tam; public RECT Monitor, Trabalho; public uint Flags; }
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO i);

        // Move e redimensiona sem deixar a janela maior que a área de trabalho do monitor nem fora dela.
        static void Posicionar(IntPtr h, int x, int y, int largura, int altura)
        {
            var i = new MONITORINFO();
            i.Tam = Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(MonitorFromWindow(h, 2), ref i))   // MONITOR_DEFAULTTONEAREST
            {
                RECT t = i.Trabalho;
                largura = Math.Min(largura, t.R - t.L);
                altura = Math.Min(altura, t.B - t.T);
                x = Math.Max(t.L, Math.Min(x, t.R - largura));
                y = Math.Max(t.T, Math.Min(y, t.B - altura));
            }
            SetWindowPos(h, IntPtr.Zero, x, y, largura, altura, SWP_NOZORDER | SWP_NOACTIVATE);
        }

        // Só a janela ativa, e só se o título for exatamente o do painel: o clique veio dela mesma.
        // (Uma aba comum do navegador com o painel aberto tem outra janela ativa e não mexe em nada.)
        static IntPtr Achar(string titulo)
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero || !IsWindowVisible(h)) return IntPtr.Zero;
            var sb = new StringBuilder(256);
            GetWindowText(h, sb, 256);
            return sb.ToString() == titulo ? h : IntPtr.Zero;
        }

        // largura/altura: tamanho externo desejado, em pixels físicos. Mantém o canto superior direito no lugar.
        public static string Ajustar(string titulo, int largura, int altura, bool guardar)
        {
            IntPtr h = Achar(titulo);
            if (h == IntPtr.Zero) return "janela não encontrada";
            bool max = IsZoomed(h);
            if (max) ShowWindow(h, 9);   // SW_RESTORE
            RECT r;
            GetWindowRect(h, out r);
            if (guardar && !temSalvo) { salvo = r; salvoMax = max; temSalvo = true; }
            Posicionar(h, r.R - largura, r.T, largura, altura);
            return "ok";
        }

        // dLargura/dAltura: quanto somar ao tamanho atual, em pixels físicos. Mantém o canto superior direito no lugar.
        public static string AjustarDelta(string titulo, int dLargura, int dAltura, bool guardar)
        {
            IntPtr h = Achar(titulo);
            if (h == IntPtr.Zero) return "janela não encontrada";
            bool max = IsZoomed(h);
            if (max) ShowWindow(h, 9);   // SW_RESTORE
            RECT r;
            GetWindowRect(h, out r);
            if (guardar && !temSalvo) { salvo = r; salvoMax = max; temSalvo = true; }
            int largura = Math.Max(200, r.R - r.L + dLargura), altura = Math.Max(150, r.B - r.T + dAltura);
            Posicionar(h, r.R - largura, r.T, largura, altura);
            return "ok";
        }

        // ---- Tamanho e posição guardados entre aberturas ----
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [StructLayout(LayoutKind.Sequential)]
        struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        struct WINDOWPLACEMENT { public int Tam, Flags, Mostrar; public POINT Min, Max; public RECT Normal; }
        [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);

        // A janela própria do painel (Edge em modo aplicativo): o título é só o da página.
        // Abas comuns de navegador levam o nome do navegador no título e ficam de fora.
        static IntPtr AcharApp(string prefixo)
        {
            IntPtr achada = IntPtr.Zero;
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                if (!IsWindowVisible(h)) return true;
                var sb = new StringBuilder(256);
                GetWindowText(h, sb, 256);
                string t = sb.ToString();
                if (t.StartsWith(prefixo) && t.IndexOf(" - ") < 0 && t.IndexOf(" — ") < 0) { achada = h; return false; }
                return true;
            }, IntPtr.Zero);
            return achada;
        }

        // "x,y,largura,altura,max" com o tamanho normal (o de antes de maximizar); "" se minimizada ou no modo compacto.
        public static string Posicao(string prefixo)
        {
            IntPtr h = AcharApp(prefixo);
            if (h == IntPtr.Zero || IsIconic(h) || temSalvo) return "";
            var p = new WINDOWPLACEMENT();
            p.Tam = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (!GetWindowPlacement(h, ref p)) return "";
            RECT r = p.Normal;
            if (r.R - r.L < 700) return "";      // tamanho do modo compacto: não serve para reabrir
            return r.L + "," + r.T + "," + (r.R - r.L) + "," + (r.B - r.T) + "," + (IsZoomed(h) ? 1 : 0);
        }

        public static bool Colocar(string prefixo, int x, int y, int largura, int altura, bool max)
        {
            IntPtr h = AcharApp(prefixo);
            if (h == IntPtr.Zero) return false;
            if (IsZoomed(h)) ShowWindow(h, 9);   // SW_RESTORE
            Posicionar(h, x, y, largura, altura);
            if (max) ShowWindow(h, 3);           // SW_MAXIMIZE
            return true;
        }

        public static string Restaurar(string titulo)
        {
            if (!temSalvo) return "nada";
            IntPtr h = Achar(titulo);
            if (h == IntPtr.Zero) return "janela não encontrada";
            Posicionar(h, salvo.L, salvo.T, salvo.R - salvo.L, salvo.B - salvo.T);
            if (salvoMax) ShowWindow(h, 3);   // SW_MAXIMIZE
            temSalvo = false;
            return "ok";
        }
    }
}
