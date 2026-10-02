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
            int x = r.R - largura;
            SetWindowPos(h, IntPtr.Zero, Math.Max(0, x), r.T, largura, altura, SWP_NOZORDER | SWP_NOACTIVATE);
            return "ok";
        }

        public static string Restaurar(string titulo)
        {
            if (!temSalvo) return "nada";
            IntPtr h = Achar(titulo);
            if (h == IntPtr.Zero) return "janela não encontrada";
            SetWindowPos(h, IntPtr.Zero, salvo.L, salvo.T, salvo.R - salvo.L, salvo.B - salvo.T, SWP_NOZORDER | SWP_NOACTIVATE);
            if (salvoMax) ShowWindow(h, 3);   // SW_MAXIMIZE
            temSalvo = false;
            return "ok";
        }
    }
}
