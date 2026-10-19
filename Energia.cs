// Plano de energia ativo do Windows (API powrprof): GUID e nome, lidos sem abrir processo.
using System;
using System.Runtime.InteropServices;

namespace MonitorHW
{
    public static class Energia
    {
        [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr raiz, out IntPtr guid);
        [DllImport("powrprof.dll")] static extern uint PowerReadFriendlyName(IntPtr raiz, ref Guid esquema, IntPtr sub, IntPtr ajuste, IntPtr buffer, ref uint tamanho);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);

        // "guid|nome", ou "" se não der para ler
        public static string PlanoAtivo()
        {
            IntPtr p;
            if (PowerGetActiveScheme(IntPtr.Zero, out p) != 0 || p == IntPtr.Zero) return "";
            Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
            LocalFree(p);
            string nome = "";
            uint tam = 0;
            PowerReadFriendlyName(IntPtr.Zero, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref tam);
            if (tam > 0)
            {
                IntPtr b = Marshal.AllocHGlobal((int)tam);
                try { if (PowerReadFriendlyName(IntPtr.Zero, ref g, IntPtr.Zero, IntPtr.Zero, b, ref tam) == 0) nome = Marshal.PtrToStringUni(b); }
                finally { Marshal.FreeHGlobal(b); }
            }
            return g.ToString() + "|" + nome;
        }
    }
}
