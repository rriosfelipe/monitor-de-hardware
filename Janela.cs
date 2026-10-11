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
