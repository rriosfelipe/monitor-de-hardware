# Monitor de Hardware - servidor local com ícone na bandeja
# Serve o painel (index.html), repassa as leituras do LibreHardwareMonitor em /dados
# e mostra a temperatura da CPU num ícone ao lado do relógio.
# Escuta apenas em localhost: nada fica exposto na rede.

param(
    [int]$Porta = 8099,
    # URL do servidor web do LibreHardwareMonitor ou caminho de um arquivo JSON (para testes).
    [string]$Fonte = 'http://localhost:8085/data.json',
    [switch]$NaoAbrirNavegador,
    # Não abrir o LibreHardwareMonitor (usado na inicialização do Windows, onde ele já sobe sozinho).
    [switch]$SemLHM,
    # Executável do LibreHardwareMonitor, aberto como administrador se não estiver rodando.
    [string]$CaminhoLHM = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe\LibreHardwareMonitor.exe",
    # Relatório do CrystalDiskInfo, regravado pela tarefa agendada de instalar-smart.ps1.
    [string]$RelatorioSmart = "$env:ProgramFiles\CrystalDiskInfo\DiskInfo.txt"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace MonitorHW -Name Nativo -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);'

$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$pagina = Join-Path $raiz 'index.html'
$iconeArquivo = Join-Path $raiz 'monitor.ico'
$endereco = "http://localhost:$Porta/"
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Uso de CPU e GPU por programa (Processos.cs). Só é amostrado enquanto o painel estiver pedindo.
$script:processos = $null
$script:procJson = '{"cpu":[],"gpu":[]}'
$script:procPedido = [datetime]::MinValue
try {
    Add-Type -Path (Join-Path $raiz 'Processos.cs')
    $script:processos = New-Object MonitorHW.Processos
} catch {
    $script:procJson = '{"cpu":[],"gpu":[],"erro":"Leitura por programa indisponível"}'
}
$arquivoConfig = Join-Path $raiz 'config.json'

# Redimensionar a janela do painel no modo compacto (Janela.cs).
$script:janelaOk = $false
try { Add-Type -Path (Join-Path $raiz 'Janela.cs'); $script:janelaOk = $true } catch { }

# Registro de longo prazo (Registro.cs): uma linha por minuto em registros\AAAA-MM-DD.csv, guardada por 30 dias.
$pastaRegistros = Join-Path $raiz 'registros'
$script:registro = $null
try {
    Add-Type -Path (Join-Path $raiz 'Registro.cs') -ReferencedAssemblies System.Core
    $script:registro = New-Object MonitorHW.Registro($pastaRegistros, 30)
} catch { }

# Cores e faixas de temperatura editáveis pelo painel (botão Cores). Só aceita valores conhecidos.
$padraoConfig = [ordered]@{
    fundo = '#0D1014'; painel = '#151A20'; texto = '#E6EAF0'; secundario = '#8B95A3'; destaque = '#56C2E6'
    normal = '#4FD1A5'; morno = '#F2B33D'; quente = '#FF6B4A'; limiteMorno = 65; limiteQuente = 80
    alertas = $true; limiteDisco = 60; iconeModo = 'quente'
}
function Validar-Config($obj) {
    $c = [ordered]@{}
    foreach ($k in $padraoConfig.Keys) { $c[$k] = $padraoConfig[$k] }
    if ($null -eq $obj) { return $c }
    foreach ($k in 'fundo', 'painel', 'texto', 'secundario', 'destaque', 'normal', 'morno', 'quente') {
        $v = $obj.$k
        if ($v -is [string] -and $v -match '^#[0-9a-fA-F]{6}$') { $c[$k] = $v.ToUpper() }
    }
    foreach ($k in 'limiteMorno', 'limiteQuente') {
        $v = $obj.$k
        if ($v -is [ValueType] -and $v -ge 30 -and $v -le 110) { $c[$k] = [int]$v }
    }
    if ($obj.alertas -is [bool]) { $c.alertas = $obj.alertas }
    if ($obj.iconeModo -in 'quente', 'cpu', 'gpu', 'alternar') { $c.iconeModo = [string]$obj.iconeModo }
    $v = $obj.limiteDisco
    if ($v -is [ValueType] -and $v -ge 40 -and $v -le 80) { $c.limiteDisco = [int]$v }
    if ($c.limiteQuente -le $c.limiteMorno) { $c.limiteMorno = $padraoConfig.limiteMorno; $c.limiteQuente = $padraoConfig.limiteQuente }
    return $c
}
$script:config = $null
$script:configHora = [datetime]::MinValue
function Ler-Config {
    $hora = if (Test-Path -LiteralPath $arquivoConfig) { (Get-Item -LiteralPath $arquivoConfig).LastWriteTime } else { [datetime]::MinValue }
    if ($script:config -and $hora -eq $script:configHora) { return $script:config }
    $obj = $null
    if (Test-Path -LiteralPath $arquivoConfig) {
        try { $obj = [System.IO.File]::ReadAllText($arquivoConfig, $utf8) | ConvertFrom-Json } catch { }
    }
    $script:config = Validar-Config $obj
    $script:configHora = $hora
    return $script:config
}

function Salvar-Config($c) {
    [System.IO.File]::WriteAllText($arquivoConfig, ((Validar-Config $c) | ConvertTo-Json), $utf8)
    $script:config = $null
}

# Abre o painel numa janela própria (modo aplicativo do Edge), ou traz para frente a que já está aberta.
# Tamanho e posição da janela do painel: guardados quando mudam e reaplicados quando ela abre,
# porque o Edge abre a janela de aplicativo sempre no tamanho pedido na linha de comando.
$arquivoJanela = Join-Path $raiz 'janela.json'
$script:janelaUltima = ''
if (Test-Path -LiteralPath $arquivoJanela) {
    try { $script:janelaUltima = [string]([System.IO.File]::ReadAllText($arquivoJanela, $utf8) | ConvertFrom-Json).posicao } catch { }
}
$script:janelaAbrindo = [datetime]::MinValue
$script:janelaVezes = 0
function Janela-Tick {
    if (-not $script:janelaOk) { return }
    $prefixo = 'Monitor de Hardware · '
    if (((Get-Date) - $script:janelaAbrindo).TotalSeconds -lt 45) {
        # janela recém-aberta: aplica o último tamanho assim que ela aparece (duas vezes, porque o Edge
        # ainda ajusta a janela logo depois de criá-la); até lá não guarda nada
        $c = @($script:janelaUltima -split ',')
        if ($c.Count -ne 5) { $script:janelaAbrindo = [datetime]::MinValue; return }
        try {
            if ([MonitorHW.Janela]::Colocar($prefixo, [int]$c[0], [int]$c[1], [int]$c[2], [int]$c[3], ($c[4] -eq '1'))) {
                $script:janelaVezes++
                if ($script:janelaVezes -ge 2) { $script:janelaAbrindo = [datetime]::MinValue }
            }
        } catch { $script:janelaAbrindo = [datetime]::MinValue }
        return
    }
    try {
        $cmd = '"' + (Join-Path $PSHOME 'powershell.exe') + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $raiz 'servidor.ps1') + '"'
        [void][MonitorHW.Janela]::Identificar($prefixo, 'FelipeRocesRios.MonitorDeHardware', "$iconeArquivo,0", $cmd, 'Monitor de Hardware')
    } catch { }
    try { $p = [MonitorHW.Janela]::Posicao($prefixo) } catch { return }
    if ($p -and $p -ne $script:janelaUltima) {
        $script:janelaUltima = $p
        try { [System.IO.File]::WriteAllText($arquivoJanela, (ConvertTo-Json -InputObject @{ posicao = $p } -Compress), $utf8) } catch { }
    }
}
function Janela-Abrindo { $script:janelaAbrindo = Get-Date; $script:janelaVezes = 0 }
# A página da janela nova pediu para encolher (abriu no modo compacto): aplica antes o tamanho guardado,
# para que "Completo" volte a ele, e deixa a janela por conta da página dali em diante.
function Janela-PaginaAssumiu {
    if (((Get-Date) - $script:janelaAbrindo).TotalSeconds -ge 45) { return }
    $script:janelaAbrindo = [datetime]::MinValue
    $c = @($script:janelaUltima -split ',')
    if ($c.Count -ne 5) { return }
    try { [void][MonitorHW.Janela]::Colocar('Monitor de Hardware · ', [int]$c[0], [int]$c[1], [int]$c[2], [int]$c[3], ($c[4] -eq '1')) } catch { }
}

# Devolve $true quando abriu uma janela nova (e não só trouxe a existente para a frente).
function Abrir-Janela {
    $shell = New-Object -ComObject WScript.Shell
    if ($shell.AppActivate('Monitor de Hardware · ')) { return $false }
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
              "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($edge) {
        $perfil = Join-Path $env:LOCALAPPDATA 'MonitorHardware\navegador'
        Start-Process -FilePath $edge -ArgumentList @("--app=$endereco", "--user-data-dir=`"$perfil`"",
            '--no-first-run', '--no-default-browser-check', '--window-size=1440,960')
        Janela-Abrindo
        return $true
    } else {
        Start-Process $endereco
        return $false
    }
}

# Já existe um monitor rodando? Só abre a janela e sai.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($endereco)
try {
    $listener.Start()
} catch {
    # A janela é aberta por aqui (este processo foi iniciado pelo clique, então pode trazê-la para a frente);
    # o monitor que já está rodando só recebe o aviso para aplicar o tamanho guardado.
    if (-not $NaoAbrirNavegador -and (Abrir-Janela)) {
        try { Invoke-WebRequest "$($endereco)janela-aberta" -Method Post -UseBasicParsing -TimeoutSec 3 | Out-Null } catch { }
    }
    exit 0
}

if (-not $SemLHM -and -not (Test-Path -LiteralPath $Fonte) -and -not (Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath $CaminhoLHM) {
        try { Start-Process -FilePath $CaminhoLHM -Verb RunAs } catch { }
    }
}

# Leituras do LibreHardwareMonitor, com cache curto para o painel e o ícone não buscarem em dobro.
$script:cacheBytes = $null
$script:cacheHora = [datetime]::MinValue
function Obter-Dados {
    if ($script:cacheBytes -and ((Get-Date) - $script:cacheHora).TotalMilliseconds -lt 800) { return $script:cacheBytes }
    if (Test-Path -LiteralPath $Fonte) {
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Fonte))
    } else {
        $req = [System.Net.HttpWebRequest]::Create($Fonte)
        $req.Timeout = 1500
        $req.ReadWriteTimeout = 1500
        $resp = $req.GetResponse()
        try {
            $ms = New-Object System.IO.MemoryStream
            $resp.GetResponseStream().CopyTo($ms)
            $bytes = $ms.ToArray()
        } finally { $resp.Close() }
    }
    $script:cacheBytes = $bytes
    $script:cacheHora = Get-Date
    return $bytes
}

function Responder($res, [int]$status, [string]$tipo, [byte[]]$corpo) {
    $res.StatusCode = $status
    $res.ContentType = $tipo
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.ContentLength64 = $corpo.Length
    $res.OutputStream.Write($corpo, 0, $corpo.Length)
}

function Atender($ctx) {
    $res = $ctx.Response
    try {
        switch ($ctx.Request.Url.AbsolutePath) {
            '/' { Responder $res 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes($pagina)) }
            '/config' {
                $req = $ctx.Request
                if ($req.HttpMethod -eq 'POST') {
                    # Só o próprio painel pode salvar: mesma origem, JSON e corpo pequeno.
                    $origem = $req.Headers['Origin']
                    if (($origem -and $origem -ne "http://localhost:$Porta") -or $req.ContentType -notlike 'application/json*' -or $req.ContentLength64 -gt 8192) {
                        Responder $res 403 'text/plain; charset=utf-8' ($utf8.GetBytes('Recusado'))
                        return
                    }
                    $leitor = New-Object System.IO.StreamReader($req.InputStream, $utf8)
                    $corpo = $leitor.ReadToEnd(); $leitor.Close()
                    try { $obj = $corpo | ConvertFrom-Json } catch {
                        Responder $res 400 'text/plain; charset=utf-8' ($utf8.GetBytes('JSON inválido'))
                        return
                    }
                    Salvar-Config $obj
                }
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((Ler-Config | ConvertTo-Json -Compress)))
            }
            '/registro' {
                $dias = 1
                [void][int]::TryParse($ctx.Request.QueryString['dias'], [ref]$dias)
                $dias = [math]::Max(1, [math]::Min(30, $dias))
                $json = if ($script:registro) { $script:registro.Serie($dias) } else { '{"erro":"Registro indisponível"}' }
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes($json))
            }
            '/sessao' {
                $req = $ctx.Request
                if ($req.HttpMethod -eq 'POST') {
                    # Só o próprio painel: mesma origem, JSON e corpo pequeno.
                    if ($req.Headers['Origin'] -ne "http://localhost:$Porta" -or $req.ContentType -notlike 'application/json*' -or $req.ContentLength64 -gt 512) {
                        Responder $res 403 'text/plain; charset=utf-8' ($utf8.GetBytes('Recusado'))
                        return
                    }
                    $leitor = New-Object System.IO.StreamReader($req.InputStream, $utf8)
                    $corpo = $leitor.ReadToEnd(); $leitor.Close()
                    $r = 'inválido'
                    try {
                        $o = $corpo | ConvertFrom-Json
                        if ($o.acao -eq 'parar') { Sessao-Parar 'parada por você'; $r = 'ok' }
                        elseif ($o.acao -eq 'iniciar' -and [string]$o.hw -match '^/gpu-(nvidia|amd|intel)/\d+$') {
                            $nm = [string]$o.nome
                            if ($nm.Length -gt 80) { $nm = $nm.Substring(0, 80) }
                            $r = Sessao-Iniciar ([string]$o.hw) $nm
                        }
                    } catch { $r = 'erro: ' + $_.Exception.Message }
                    Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((ConvertTo-Json -InputObject @{ resultado = $r } -Compress)))
                    return
                }
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((Json-Sessao)))
            }
            '/abrir-sessoes' {
                if ($ctx.Request.HttpMethod -ne 'POST' -or $ctx.Request.Headers['Origin'] -ne "http://localhost:$Porta") {
                    Responder $res 403 'text/plain; charset=utf-8' ($utf8.GetBytes('Recusado'))
                    return
                }
                if (-not (Test-Path -LiteralPath $pastaSessoes)) { [void](New-Item -ItemType Directory -Path $pastaSessoes) }
                Start-Process explorer.exe $pastaSessoes
                Responder $res 200 'text/plain; charset=utf-8' ($utf8.GetBytes('ok'))
            }
            '/abrir-registros' {
                # Só o próprio painel: POST da mesma origem.
                if ($ctx.Request.HttpMethod -ne 'POST' -or $ctx.Request.Headers['Origin'] -ne "http://localhost:$Porta") {
                    Responder $res 403 'text/plain; charset=utf-8' ($utf8.GetBytes('Recusado'))
                    return
                }
                Start-Process explorer.exe $pastaRegistros
                Responder $res 200 'text/plain; charset=utf-8' ($utf8.GetBytes('ok'))
            }
            '/discos-estado' {
                $req = $ctx.Request
                if ($req.HttpMethod -eq 'POST') {
                    if ($req.Headers['Origin'] -ne "http://localhost:$Porta" -or $req.ContentType -notlike 'application/json*' -or $req.ContentLength64 -gt 1024) {
                        Responder $res 403 'text/plain; charset=utf-8' ($utf8.GetBytes('Recusado'))
                        return
                    }
                    $leitor = New-Object System.IO.StreamReader($req.InputStream, $utf8)
                    $corpo = $leitor.ReadToEnd(); $leitor.Close()
                    $erro = $null
                    try {
                        $o = $corpo | ConvertFrom-Json
                        if (-not ($o.n -is [ValueType]) -or -not ($o.offline -is [bool])) { throw 'pedido inválido' }
                        $erro = Iniciar-Acao ([int]$o.n) ([bool]$o.offline)
                    } catch { $erro = 'Pedido inválido.' }
                    if ($erro) {
                        $script:acao = [ordered]@{ n = $o.n; offline = $o.offline; letras = ''; estado = 'erro'; msg = $erro; t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                    }
                }
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((Json-Discos)))
            }
            '/disco-uso' {
                $n = -1
                [void][int]::TryParse($ctx.Request.QueryString['n'], [ref]$n)
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((ConvertTo-Json -InputObject (Uso-Disco $n) -Compress)))
            }
            '/janela-aberta' {
                if ($ctx.Request.HttpMethod -ne 'POST') { Responder $res 405 'text/plain; charset=utf-8' ($utf8.GetBytes('Use POST')); return }
                Janela-Abrindo
                Responder $res 204 'text/plain; charset=utf-8' ([byte[]]@())
            }
            '/janela' {
                # Só o próprio painel; e só a janela cujo título é exatamente o do painel.
                $req = $ctx.Request
                if ($req.HttpMethod -ne 'POST' -or $req.Headers['Origin'] -ne "http://localhost:$Porta" -or $req.ContentType -notlike 'application/json*' -or $req.ContentLength64 -gt 1024) {
                    Responder $res 403 'text/plain; charset=utf-8' ($utf8.GetBytes('Recusado'))
                    return
                }
                $leitor = New-Object System.IO.StreamReader($req.InputStream, $utf8)
                $corpo = $leitor.ReadToEnd(); $leitor.Close()
                $r = 'indisponível'
                try {
                    $o = $corpo | ConvertFrom-Json
                    $titulo = [string]$o.titulo
                    if (-not $script:janelaOk -or -not $titulo.StartsWith('Monitor de Hardware · ')) { throw 'recusado' }
                    if ($o.restaurar -ne $true) { Janela-PaginaAssumiu }
                    if ($o.restaurar -eq $true) {
                        $r = [MonitorHW.Janela]::Restaurar($titulo)
                    } elseif ($null -ne $o.dAltura) {
                        $dl = [int]$o.dLargura; $da = [int]$o.dAltura
                        if ([math]::Abs($dl) -gt 8000 -or [math]::Abs($da) -gt 8000) { throw 'tamanho inválido' }
                        $r = [MonitorHW.Janela]::AjustarDelta($titulo, $dl, $da, ($o.naoGuardar -ne $true))
                    } else {
                        $l = [int]$o.largura; $a = [int]$o.altura
                        if ($l -lt 200 -or $l -gt 8000 -or $a -lt 150 -or $a -gt 8000) { throw 'tamanho inválido' }
                        $r = [MonitorHW.Janela]::Ajustar($titulo, $l, $a, ($o.naoGuardar -ne $true))
                    }
                } catch { $r = 'recusado' }
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((ConvertTo-Json -InputObject @{ resultado = $r } -Compress)))
            }
            '/gpus' {
                $lista = @()
                try {
                    $lista = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object {
                        $pr = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                        if ($pr.DriverDesc -and $pr.'HardwareInformation.qwMemorySize') {
                            [ordered]@{ nome = [string]$pr.DriverDesc; vramGB = [math]::Round($pr.'HardwareInformation.qwMemorySize' / 1GB, 1) }
                        }
                    })
                } catch { }
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((ConvertTo-Json -InputObject $lista -Compress)))
            }
            '/nvidia' {
                $script:nvidiaPedido = Get-Date
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes($script:nvidiaJson))
            }
            '/letras' {
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes($script:letrasJson))
            }
            '/memoria' {
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes("{""freq"":$($script:ramFreq)}"))
            }
            '/smart' {
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((Json-Smart)))
            }
            '/alertas' {
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes((Json-Alertas)))
            }
            '/historico' {
                $ids = ConvertTo-Json -InputObject @($script:histGpus.ToArray()) -Compress
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes('{"gpus":' + $ids + ',"pontos":[' + ($script:historico.ToArray() -join ',') + ']}'))
            }
            '/processos' {
                $script:procPedido = Get-Date
                Responder $res 200 'application/json; charset=utf-8' ($utf8.GetBytes($script:procJson))
            }
            '/favicon.ico' { Responder $res 200 'image/x-icon' ([System.IO.File]::ReadAllBytes($iconeArquivo)) }
            '/dados' {
                try {
                    Responder $res 200 'application/json; charset=utf-8' (Obter-Dados)
                } catch {
                    $msg = ($_.Exception.Message -replace '[\\"]', "'") -replace '\s+', ' '
                    Responder $res 502 'application/json; charset=utf-8' ($utf8.GetBytes("{""erro"":""$msg""}"))
                }
            }
            default { Responder $res 404 'text/plain; charset=utf-8' ($utf8.GetBytes('Não encontrado')) }
        }
    } catch {
        # O navegador fechou a conexão no meio da resposta: ignorar.
    } finally {
        $res.Close()
    }
}

# Extrai os sensores do JSON sem montar a árvore inteira (mais leve para rodar a cada 2 s).
$padrao = [regex]'"Text":"([^"]*)","Min":"[^"]*","Value":"([^"]*)","Max":"[^"]*","SensorId":"([^"]*)","Type":"([^"]*)"'
function Numero([string]$s) {
    $m = [regex]::Match($s, '-?\d+(?:[.,]\d+)?')
    if (-not $m.Success) { return [double]::NaN }
    return [double]::Parse($m.Value.Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
}
$padraoHw = [regex]'"Text":"([^"]*)","Min":"","Value":"","Max":"","HardwareId":"([^"]*)"'
$NaN = [double]::NaN

# SMART lido pelo CrystalDiskInfo, por número de disco. Cobre NVMe cujo SMART o LibreHardwareMonitor
# devolve zerado (disco atrás do Intel RST VMD). Só vale enquanto o relatório for recente.
$script:smart = @{}
$script:smartChave = ''
function Ler-Smart {
    if (-not (Test-Path -LiteralPath $RelatorioSmart)) { return @{} }
    $hora = (Get-Item -LiteralPath $RelatorioSmart).LastWriteTime
    if (((Get-Date) - $hora).TotalMinutes -gt 30) { return @{} }
    $chave = "$($hora.Ticks)|$($script:letrasJson)"
    if ($chave -eq $script:smartChave) { return $script:smart }
    try { $linhas = [System.IO.File]::ReadAllLines($RelatorioSmart) } catch { return $script:smart }
    $novo = @{}
    $nvme = $false; $n = $null; $d = $null
    foreach ($l in $linhas) {
        if ($l -match '^\s*Model : ') { $nvme = $false; $n = $null; $d = $null; continue }
        if ($l -match '^\s*Interface : NVM Express') { $nvme = $true; continue }
        $m = [regex]::Match($l, '^\s*Drive Letter : ([A-Za-z]:)')
        if ($m.Success -and $nvme) {
            $n = $script:letrasMapa.Keys | Where-Object { ($script:letrasMapa[$_] -split ' ') -contains $m.Groups[1].Value.ToUpper() } | Select-Object -First 1
            if ($null -ne $n) {
                $d = @{ temp = $NaN; vida = $NaN; reserva = $NaN; reservaMin = $NaN; horas = $NaN; hora = $hora.ToString('HH:mm') }
                $novo[[string]$n] = $d
            }
            continue
        }
        # Atributos do log de saúde NVMe: identificador e valor bruto em hexadecimal.
        $m = [regex]::Match($l, '^([0-9A-F]{2}) ([0-9A-F]{12}) ')
        if ($m.Success -and $d) {
            $v = [double][Convert]::ToInt64($m.Groups[2].Value, 16)
            switch ($m.Groups[1].Value) {
                '02' { if ($v -gt 273 -and $v -lt 400) { $d.temp = $v - 273 } }
                '03' { $d.reserva = $v }
                '04' { $d.reservaMin = $v }
                '05' { $d.vida = [math]::Max(0, 100 - $v) }
                '0C' { $d.horas = $v }
            }
        }
    }
    $script:smart = $novo
    $script:smartChave = $chave
    return $novo
}
function Json-Smart {
    $s = Ler-Smart
    $itens = foreach ($n in $s.Keys) {
        $d = $s[$n]
        """$n"":{""temp"":$(Json-Num $d.temp),""vida"":$(Json-Num $d.vida),""reserva"":$(Json-Num $d.reserva),""reservaMin"":$(Json-Num $d.reservaMin),""horas"":$(Json-Num $d.horas),""hora"":""$($d.hora)""}"
    }
    return '{' + (@($itens) -join ',') + '}'
}
function Ler-Resumo {
    $texto = $utf8.GetString((Obter-Dados))
    $r = @{ cpu = $NaN; cpuUso = $NaN; cpuW = $NaN; gpuW = $NaN; gpu = $NaN; gpuUso = $NaN; gpuNome = ''; ramUsada = $NaN; ramLivre = $NaN; virtUsada = $NaN; virtLivre = $NaN; discos = @{}; gpus = [ordered]@{} }
    $nomesHw = @{}
    foreach ($m in $padraoHw.Matches($texto)) { $nomesHw[$m.Groups[2].Value] = $m.Groups[1].Value.Trim() }
    $cpuTemps = @()
    foreach ($m in $padrao.Matches($texto)) {
        $nome = $m.Groups[1].Value; $valor = $m.Groups[2].Value; $id = $m.Groups[3].Value; $tipo = $m.Groups[4].Value
        if ($id -match '^/(amd|intel)cpu/\d+/temperature/') {
            if ($nome -match 'Tctl|Package') { $r.cpu = Numero $valor } else { $cpuTemps += (Numero $valor) }
        } elseif ($id -match '^/(amd|intel)cpu/\d+/power/' -and $nome -match '^(CPU )?Package$') {
            $r.cpuW = Numero $valor
        } elseif ($id -match '^/(amd|intel)cpu/\d+/load/' -and $nome -eq 'CPU Total') {
            $r.cpuUso = Numero $valor
        } elseif ($id -match '^/gpu-') {
            # uma entrada por placa de vídeo (pode haver várias)
            $mg = [regex]::Match($id, '^(/gpu-(?:nvidia|amd|intel)/\d+)/(temperature|load|power)/')
            if ($mg.Success) {
                $hw = $mg.Groups[1].Value
                $g = $r.gpus[$hw]
                if (-not $g) {
                    $g = @{ nome = $nomesHw[$hw]; temp = $NaN; uso = $NaN; w = $NaN }
                    if (-not $g.nome) { $g.nome = $hw }
                    $r.gpus[$hw] = $g
                }
                switch ($mg.Groups[2].Value) {
                    'temperature' { if ([double]::IsNaN($g.temp) -or $nome -eq 'GPU Core') { $g.temp = Numero $valor } }
                    'load' { if ($nome -eq 'GPU Core' -or ([double]::IsNaN($g.uso) -and $nome -eq 'D3D 3D')) { $g.uso = Numero $valor } }
                    'power' { if ([double]::IsNaN($g.w) -or $nome -eq 'GPU Package') { $g.w = Numero $valor } }
                }
            }
        } elseif ($id -match '^/ram/data/') {
            if ($nome -eq 'Memory Used') { $r.ramUsada = Numero $valor }
            if ($nome -eq 'Memory Available') { $r.ramLivre = Numero $valor }
        } elseif ($id -match '^/vram/data/') {
            if ($nome -eq 'Memory Used') { $r.virtUsada = Numero $valor }
            if ($nome -eq 'Memory Available') { $r.virtLivre = Numero $valor }
        } else {
            $md = [regex]::Match($id, '^(/(hdd|nvme|ssd)/\d+)/')
            if ($md.Success) {
                $hw = $md.Groups[1].Value
                $d = $r.discos[$hw]
                if (-not $d) {
                    $d = @{ nome = $nomesHw[$hw]; hdd = ($md.Groups[2].Value -eq 'hdd'); temp = $NaN; aviso = $NaN; vida = $NaN; reserva = $NaN; reservaMin = $NaN; horas = $NaN }
                    if (-not $d.nome) { $d.nome = $hw }
                    $r.discos[$hw] = $d
                }
                switch ($nome) {
                    'Temperature' { if ([double]::IsNaN($d.temp)) { $d.temp = Numero $valor } }
                    'Composite Temperature' { $d.temp = Numero $valor }
                    'Warning Temperature' { $d.aviso = Numero $valor }
                    'Life' { $d.vida = Numero $valor }
                    'Percentage Used' { if ([double]::IsNaN($d.vida)) { $d.vida = 100 - (Numero $valor) } }
                    'Available Spare' { $d.reserva = Numero $valor }
                    'Available Spare Threshold' { $d.reservaMin = Numero $valor }
                    'Power On Hours' { $d.horas = Numero $valor }
                }
            }
        }
    }
    if ([double]::IsNaN($r.cpu) -and $cpuTemps.Count) { $r.cpu = ($cpuTemps | Measure-Object -Maximum).Maximum }
    # SMART zerado no LibreHardwareMonitor (0 °C e 0 h juntos): usa a leitura do CrystalDiskInfo, se houver.
    $smart = Ler-Smart
    foreach ($hw in $r.discos.Keys) {
        $d = $r.discos[$hw]
        $s = $smart[($hw -replace '^.*/', '')]
        if ($s -and $d.temp -eq 0 -and $d.horas -eq 0) { foreach ($k in 'temp', 'vida', 'reserva', 'reservaMin', 'horas') { $d[$k] = $s[$k] } }
    }
    # resumo das GPUs: a mais quente representa "a GPU"; a potência é a soma
    $somaW = 0.0; $temW = $false
    foreach ($hw in $r.gpus.Keys) {
        $g = $r.gpus[$hw]
        # potência alta com a placa parada e fria é leitura errada do sensor da placa: fica fora da soma
        $suspeita = $g.w -gt 60 -and $g.uso -lt 3 -and $g.temp -lt 45
        if (-not [double]::IsNaN($g.w) -and -not $suspeita) { $somaW += $g.w; $temW = $true }
        if (-not [double]::IsNaN($g.temp) -and ([double]::IsNaN($r.gpu) -or $g.temp -gt $r.gpu)) { $r.gpu = $g.temp; $r.gpuUso = $g.uso; $r.gpuNome = $g.nome }
    }
    if ($temW) { $r.gpuW = $somaW }
    $script:discosVistos = @($r.discos.Keys)
    return $r
}

# Ícone da bandeja: a temperatura da CPU, na cor da faixa (normal, morno, quente).
function Novo-Icone([string]$texto, [System.Drawing.Color]$cor, [System.Drawing.Color]$marca) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $caminho = New-Object System.Drawing.Drawing2D.GraphicsPath
    $caminho.AddArc(0, 0, 12, 12, 180, 90); $caminho.AddArc(19, 0, 12, 12, 270, 90)
    $caminho.AddArc(19, 19, 12, 12, 0, 90); $caminho.AddArc(0, 19, 12, 12, 90, 90)
    $caminho.CloseFigure()
    $fundo = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml((Ler-Config).painel))
    $g.FillPath($fundo, $caminho)
    $tamanho = if ($texto.Length -ge 3) { 14 } else { 19 }
    $fonte = New-Object System.Drawing.Font('Segoe UI', $tamanho, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $formato = New-Object System.Drawing.StringFormat
    $formato.Alignment = 'Center'; $formato.LineAlignment = 'Center'
    $pincel = New-Object System.Drawing.SolidBrush $cor
    $g.DrawString($texto, $fonte, $pincel, (New-Object System.Drawing.RectangleF(0, -1, 32, 30)), $formato)
    $pMarca = New-Object System.Drawing.SolidBrush $marca
    $g.FillRectangle($pMarca, 7, 27, 18, 3)
    $pMarca.Dispose()
    $g.Dispose(); $fonte.Dispose(); $pincel.Dispose(); $fundo.Dispose(); $caminho.Dispose()
    $h = $bmp.GetHicon()
    $icone = [System.Drawing.Icon]::FromHandle($h).Clone()
    [MonitorHW.Nativo]::DestroyIcon($h) | Out-Null
    $bmp.Dispose()
    return $icone
}
function Cor([double]$c) {
    $cfg = Ler-Config
    $hex = if ([double]::IsNaN($c)) { $cfg.secundario } elseif ($c -ge $cfg.limiteQuente) { $cfg.quente } elseif ($c -ge $cfg.limiteMorno) { $cfg.morno } else { $cfg.normal }
    return [System.Drawing.ColorTranslator]::FromHtml($hex)
}
function Cores-Marca {
    $cfg = Ler-Config
    $cpu = [System.Drawing.ColorTranslator]::FromHtml($cfg.destaque)
    $claro = ([System.Drawing.ColorTranslator]::FromHtml($cfg.painel)).GetBrightness() -gt 0.5
    $gpu = [System.Drawing.ColorTranslator]::FromHtml($(if ($claro) { '#7B4FBF' } else { '#C792EA' }))
    return @($cpu, $gpu)
}
function Fmt([double]$v, [int]$casas = 0) {
    if ([double]::IsNaN($v)) { return '—' }
    return $v.ToString("N$casas", [System.Globalization.CultureInfo]'pt-BR')
}

$bandeja = New-Object System.Windows.Forms.NotifyIcon
$bandeja.Icon = New-Object System.Drawing.Icon $iconeArquivo
$bandeja.Text = 'Monitor de Hardware'
$bandeja.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemAbrir = $menu.Items.Add('Abrir monitor')
$itemAbrir.Font = New-Object System.Drawing.Font($itemAbrir.Font, [System.Drawing.FontStyle]::Bold)
$itemCpu = $menu.Items.Add('CPU —'); $itemCpu.Enabled = $false
$itemGpu = $menu.Items.Add('GPU —'); $itemGpu.Enabled = $false
$itemRam = $menu.Items.Add('RAM —'); $itemRam.Enabled = $false
$itemAtivos = $menu.Items.Add('⚠ alertas'); $itemAtivos.Visible = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemAlertas = New-Object System.Windows.Forms.ToolStripMenuItem 'Notificações de alerta'
$itemAlertas.CheckOnClick = $true
$itemAlertas.Checked = [bool](Ler-Config).alertas
[void]$menu.Items.Add($itemAlertas)
# Submenu "Ícone mostra": qual temperatura aparece no ícone.
$itemModo = New-Object System.Windows.Forms.ToolStripMenuItem 'Ícone mostra'
$modosIcone = [ordered]@{ quente = 'A mais quente (CPU ou GPU)'; cpu = 'Só a CPU'; gpu = 'Só a GPU'; alternar = 'Alternar CPU e GPU' }
$script:itensModo = @{}
foreach ($k in $modosIcone.Keys) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $modosIcone[$k]
    $it.Tag = $k
    $it.Add_Click({
        param($origem, $ev)
        $c = [ordered]@{}
        $atual = Ler-Config
        foreach ($chave in $atual.Keys) { $c[$chave] = $atual[$chave] }
        $c.iconeModo = $origem.Tag
        Salvar-Config $c
    })
    [void]$itemModo.DropDownItems.Add($it)
    $script:itensModo[$k] = $it
}
[void]$menu.Items.Add($itemModo)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemLhm = $menu.Items.Add('Abrir LibreHardwareMonitor')
$itemSair = $menu.Items.Add('Encerrar monitor')
$bandeja.ContextMenuStrip = $menu

$itemAbrir.Add_Click({ Abrir-Janela })
$itemAtivos.Add_Click({ Abrir-Janela })
$bandeja.Add_BalloonTipClicked({ Abrir-Janela })
$itemAlertas.Add_Click({
    $c = [ordered]@{}
    $atual = Ler-Config
    foreach ($k in $atual.Keys) { $c[$k] = $atual[$k] }
    $c.alertas = $itemAlertas.Checked
    Salvar-Config $c
})
$bandeja.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Abrir-Janela } })

$itemLhm.Add_Click({
    if (Test-Path -LiteralPath $CaminhoLHM) { try { Start-Process -FilePath $CaminhoLHM -Verb RunAs } catch { } }
})

# Atende o navegador sem travar a bandeja: confere a cada 30 ms se chegou pedido.
$script:pedido = $listener.GetContextAsync()
$timerHttp = New-Object System.Windows.Forms.Timer
$timerHttp.Interval = 30
$timerHttp.Add_Tick({
    try {
        while ($script:pedido.IsCompleted) {
            $ctx = $script:pedido.Result
            $script:pedido = $listener.GetContextAsync()
            Atender $ctx
        }
    } catch { }
})

# Histórico curto (15 min, uma leitura a cada 2 s) para o painel abrir com os gráficos preenchidos.
$script:historico = New-Object System.Collections.Generic.Queue[string]
function Json-Num([double]$v) {
    if ([double]::IsNaN($v)) { return 'null' }
    return $v.ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture)
}
$script:histGpus = New-Object System.Collections.Generic.List[string]
function Guardar-Historico($r) {
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($hw in $r.gpus.Keys) { if (-not $script:histGpus.Contains($hw)) { $script:histGpus.Add($hw) } }
    $cols = ''
    foreach ($hw in $script:histGpus) {
        $g = $r.gpus[$hw]
        $cols += if ($g) { ",$(Json-Num $g.temp),$(Json-Num $g.uso)" } else { ',null,null' }
    }
    $script:historico.Enqueue("[$t,$(Json-Num $r.cpu),$(Json-Num $r.cpuUso)$cols]")
    while ($script:historico.Count -gt 450) { [void]$script:historico.Dequeue() }
}

# Letras das unidades (C:, D:...) por número de disco. A consulta do Windows leva alguns segundos,
# então roda em segundo plano: na abertura e a cada 10 min (HDs externos podem mudar).
$script:letrasJson = '{}'
$script:discosEstado = @()
$script:paginacao = @()
# Velocidade configurada dos pentes de memória (MT/s), para quando o LibreHardwareMonitor não informa o clock.
$script:ramFreq = 0
$arquivoUltimas = Join-Path $raiz 'letras-ultimas.json'
$script:letrasUltimas = @{}
if (Test-Path -LiteralPath $arquivoUltimas) {
    try { foreach ($p in ([System.IO.File]::ReadAllText($arquivoUltimas, $utf8) | ConvertFrom-Json).PSObject.Properties) { $script:letrasUltimas[$p.Name] = [string]$p.Value } } catch { }
}
$script:letrasMapa = @{}
$script:letrasTarefa = $null
$script:letrasHora = [datetime]::MinValue
$script:discosVistos = @()
$script:letrasPedidas = New-Object 'System.Collections.Generic.HashSet[string]'
function Letras-Tick {
    $t = $script:letrasTarefa
    if ($t) {
        if (-not $t.Handle.IsCompleted) { return }
        try {
            $res = $t.PS.EndInvoke($t.Handle)
            if ($res -and $res.Count) {
                $o = [string]$res[0] | ConvertFrom-Json
                $script:letrasJson = $o.letras | ConvertTo-Json -Compress
                $mapa = @{}
                foreach ($p in $o.letras.PSObject.Properties) { $mapa[$p.Name] = (@($p.Value) -join ' ') }
                $script:letrasMapa = $mapa
                $mudou = $false
                foreach ($k in $mapa.Keys) { if ($script:letrasUltimas[$k] -ne $mapa[$k]) { $script:letrasUltimas[$k] = $mapa[$k]; $mudou = $true } }
                if ($mudou) { try { [System.IO.File]::WriteAllText($arquivoUltimas, ($script:letrasUltimas | ConvertTo-Json -Compress), $utf8) } catch { } }
                $script:discosEstado = @($o.discos)
                $script:paginacao = @($o.paginacao)
                $script:ramFreq = [int]$o.ramFreq
            }
        } catch { }
        $t.PS.Dispose()
        $script:letrasTarefa = $null
        return
    }
    # disco que apareceu depois da última consulta (HD externo ligado agora): consulta de novo já,
    # uma vez por disco, em vez de esperar os 10 minutos
    $novo = $false
    foreach ($hw in $script:discosVistos) {
        $m = [regex]::Match([string]$hw, '/(\d+)$')
        if ($m.Success -and -not $script:letrasMapa.ContainsKey($m.Groups[1].Value) -and $script:letrasPedidas.Add($m.Groups[1].Value)) { $novo = $true }
    }
    if (-not $novo -and ((Get-Date) - $script:letrasHora).TotalMinutes -lt 10) { return }
    $script:letrasHora = Get-Date
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        $m = @{}
        foreach ($x in (Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
            $k = [string]$x.DiskNumber
            if (-not $m.ContainsKey($k)) { $m[$k] = @() }
            $m[$k] += "$($x.DriveLetter):"
        }
        $discos = @(Get-Disk -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{ n = [int]$_.Number; nome = ($_.FriendlyName -replace '\s+', ' ').Trim(); usb = ($_.BusType -eq 'USB')
                        offline = [bool]$_.IsOffline; sistema = ([bool]$_.IsSystem -or [bool]$_.IsBoot) }
        })
        $pag = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Substring(0, 2).ToUpper() })
        $ram = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
        ConvertTo-Json -InputObject ([ordered]@{ letras = $m; discos = $discos; paginacao = $pag; ramFreq = [int]$ram }) -Compress -Depth 4
    })
    $script:letrasTarefa = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}
# "/hdd/9" -> "J:" (o número do LibreHardwareMonitor é o número do disco no Windows)
function Letras-De([string]$hw) {
    $m = [regex]::Match($hw, '/(\d+)$')
    if ($m.Success -and $script:letrasMapa.ContainsKey($m.Groups[1].Value)) { return $script:letrasMapa[$m.Groups[1].Value] + ' ' }
    if ($m.Success -and $script:letrasUltimas.ContainsKey($m.Groups[1].Value)) { return $script:letrasUltimas[$m.Groups[1].Value] + ' ' }
    return ''
}

# Desativar/ativar HD externo: coloca o disco offline/online no Windows (Set-Disk).
# Precisa de administrador: abre o aviso do Windows; o resultado volta por um arquivo temporário.
$script:acao = $null
function Letras-Do-Disco([int]$n) {
    $v = $script:letrasMapa[[string]$n]
    if (-not $v) { return @() }
    return @($v -split ' ' | Where-Object { $_ -match '^[A-Za-z]:$' } | ForEach-Object { $_.ToUpper() })
}
function Uso-Disco([int]$n) {
    $avisos = New-Object System.Collections.Generic.List[string]
    $lts = Letras-Do-Disco $n
    foreach ($lt in $lts) {
        # programas abertos a partir da unidade ou com arquivos dela na linha de comando
        $usando = @(Get-CimInstance Win32_Process -Property Name, ExecutablePath, CommandLine -ErrorAction SilentlyContinue | Where-Object {
            ($_.ExecutablePath -and $_.ExecutablePath -like "$lt\*") -or ($_.CommandLine -and $_.CommandLine -like "*$lt\*")
        } | ForEach-Object { $_.Name } | Sort-Object -Unique)
        if ($usando.Count) { $avisos.Add("Programas usando $($lt): $($usando -join ', '). Feche-os antes.") }
        # torrents do qBittorrent salvos na unidade
        $bt = Join-Path $env:LOCALAPPDATA 'qBittorrent\BT_backup'
        $qtd = 0
        foreach ($f in (Get-ChildItem -LiteralPath $bt -Filter *.fastresume -ErrorAction SilentlyContinue)) {
            try {
                $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
                $m = [regex]::Match($txt, 'save_path(\d+):')
                if ($m.Success -and $txt.Substring($m.Index + $m.Length, 2).ToUpper() -eq $lt) { $qtd++ }
            } catch { }
        }
        if ($qtd) {
            if (Get-Process qbittorrent -ErrorAction SilentlyContinue) {
                $avisos.Add("O qBittorrent está aberto e tem $qtd torrent(s) salvos em $($lt). Pause-os ou feche o qBittorrent antes, senão eles vão dar erro.")
            } else {
                $avisos.Add("O qBittorrent tem $qtd torrent(s) salvos em $($lt). Se ele abrir com o disco desativado, esses torrents vão dar erro até você reativá-lo.")
            }
        }
    }
    return [ordered]@{ letras = ($lts -join ' '); avisos = @($avisos) }
}
function Iniciar-Acao([int]$n, [bool]$offline) {
    $disco = @($script:discosEstado | Where-Object { $_.n -eq $n })[0]
    $lts = Letras-Do-Disco $n
    # só HD externo (USB), nunca o disco do sistema nem um com arquivo de paginação
    if (-not $disco -or -not $disco.usb -or $disco.sistema) { return 'Só discos externos (USB) podem ser desativados por aqui.' }
    if (@($lts | Where-Object { $_ -in @($script:paginacao) -or $_ -eq 'C:' }).Count) { return 'Esse disco tem arquivo de paginação ou é o disco do sistema.' }
    if ($script:acao -and $script:acao.estado -eq 'aguardando') { return 'Já há uma operação em andamento.' }
    $dir = Join-Path $env:TEMP 'MonitorHardware'
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $arq = Join-Path $dir "disco-$n.txt"
    Remove-Item -LiteralPath $arq -ErrorAction SilentlyContinue
    $flush = ''
    if ($offline -and $lts.Count) { $flush = 'Write-VolumeCache -DriveLetter ' + (($lts | ForEach-Object { $_.Substring(0, 1) }) -join ',') + ' -ErrorAction SilentlyContinue; ' }
    $valor = if ($offline) { '$true' } else { '$false' }
    $cmd = "try { $flush Set-Disk -Number $n -IsOffline $valor -ErrorAction Stop; 'ok' | Set-Content -LiteralPath '$arq' -Encoding UTF8 } catch { `$_.Exception.Message | Set-Content -LiteralPath '$arq' -Encoding UTF8 }"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $base = @{ n = $n; offline = $offline; letras = ($lts -join ' '); t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    try {
        $proc = Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc -Verb RunAs -WindowStyle Hidden -PassThru
    } catch {
        $script:acao = $base + @{ estado = 'erro'; msg = 'A confirmação de administrador foi cancelada.' }
        return $null
    }
    $script:acao = $base + @{ estado = 'aguardando'; msg = ''; proc = $proc; arquivo = $arq; inicio = Get-Date }
    return $null
}
function Acao-Tick {
    $a = $script:acao
    if (-not $a -or $a.estado -ne 'aguardando') { return }
    $terminou = $false
    try { $terminou = $a.proc.HasExited } catch { $terminou = Test-Path -LiteralPath $a.arquivo }
    if (-not $terminou -and ((Get-Date) - $a.inicio).TotalMinutes -lt 2) { return }
    $r = if (Test-Path -LiteralPath $a.arquivo) { (Get-Content -LiteralPath $a.arquivo -Raw -Encoding UTF8).Trim() } else { 'Sem resposta do Windows.' }
    $a.estado = if ($r -eq 'ok') { 'ok' } else { 'erro' }
    $a.msg = if ($r -eq 'ok') { '' } else { $r }
    $a.t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $script:letrasHora = [datetime]::MinValue   # atualiza letras e estado dos discos já
}
function Json-Discos {
    $acao = $null
    if ($script:acao) { $acao = [ordered]@{ n = $script:acao.n; offline = $script:acao.offline; letras = $script:acao.letras; estado = $script:acao.estado; msg = $script:acao.msg; t = $script:acao.t } }
    return ConvertTo-Json -InputObject ([ordered]@{ discos = @($script:discosEstado); acao = $acao; ultimas = $script:letrasUltimas }) -Compress -Depth 4
}

# Alertas: notificação do Windows quando algo passa do limite por algumas leituras seguidas.
# Cada alerta tem um intervalo mínimo entre avisos; a hora do último aviso fica em alertas-estado.json
# para não repetir a cada vez que o Windows inicia.
$arquivoEstado = Join-Path $raiz 'alertas-estado.json'
$script:estado = @{}
if (Test-Path -LiteralPath $arquivoEstado) {
    try {
        $o = [System.IO.File]::ReadAllText($arquivoEstado, $utf8) | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) { $script:estado[$p.Name] = [datetime]$p.Value }
    } catch { }
}
$script:seguidas = @{}
$script:ativos = [ordered]@{}
function Salvar-Estado {
    $o = [ordered]@{}
    foreach ($k in $script:estado.Keys) { $o[$k] = $script:estado[$k].ToString('o') }
    try { [System.IO.File]::WriteAllText($arquivoEstado, ($o | ConvertTo-Json), $utf8) } catch { }
}
# $leituras: quantas leituras seguidas (a cada 2 s) confirmam o problema.
# $minEntre: intervalo mínimo entre avisos de um novo episódio; $minRepetir: se o problema persistir.
function Avaliar([string]$chave, [bool]$cond, [int]$leituras, [double]$minEntre, [double]$minRepetir, [string]$nivel, [string]$titulo, [string]$texto) {
    if (-not $cond) { $script:seguidas[$chave] = 0; $script:ativos.Remove($chave); return }
    $n = 1 + [int]$script:seguidas[$chave]
    $script:seguidas[$chave] = $n
    if ($n -lt $leituras) { return }
    $desde = if ($script:ativos[$chave]) { $script:ativos[$chave].desde } else { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    $script:ativos[$chave] = [ordered]@{ chave = $chave; nivel = $nivel; titulo = $titulo; texto = $texto; desde = $desde }
    $ultimo = $script:estado[$chave]
    $espera = if ($n -eq $leituras) { $minEntre } else { $minRepetir }
    if ($ultimo -and ((Get-Date) - $ultimo).TotalMinutes -lt $espera) { return }
    $script:estado[$chave] = Get-Date
    Salvar-Estado
    $script:fila.Add([ordered]@{ nivel = $nivel; titulo = $titulo; texto = $texto })
}
# O Windows mostra uma notificação por vez: vários alertas na mesma leitura viram um aviso só.
$script:fila = New-Object System.Collections.Generic.List[object]
function Notificar-Fila {
    if (-not $script:fila.Count) { return }
    $itens = $script:fila.ToArray(); $script:fila.Clear()
    if (-not (Ler-Config).alertas) { return }
    $grave = @($itens | Where-Object { $_.nivel -eq 'quente' }).Count -gt 0
    $icone = if ($grave) { [System.Windows.Forms.ToolTipIcon]::Error } else { [System.Windows.Forms.ToolTipIcon]::Warning }
    if ($itens.Count -eq 1) {
        $bandeja.ShowBalloonTip(10000, $itens[0].titulo, $itens[0].texto, $icone)
    } else {
        $txt = ($itens | ForEach-Object { '• ' + $_.titulo }) -join "`n"
        if ($txt.Length -gt 240) { $txt = $txt.Substring(0, 237) + '...' }
        $bandeja.ShowBalloonTip(10000, "$($itens.Count) alertas do monitor", $txt + "`nClique para ver os detalhes.", $icone)
    }
}
# Histerese: depois de disparar, só sai do alerta quando cai 3 graus abaixo do limite.
function Acima([string]$chave, [double]$v, [double]$limite) {
    if ([double]::IsNaN($v)) { return $false }
    if ($script:ativos.Contains($chave)) { return $v -ge ($limite - 3) }
    return $v -ge $limite
}
function Verificar-Alertas($r) {
    $cfg = Ler-Config
    Avaliar 'lhm' $false 0 0 0 '' '' ''
    Avaliar 'cpu-temp' (Acima 'cpu-temp' $r.cpu $cfg.limiteQuente) 5 30 60 'quente' `
        "Processador a $(Fmt $r.cpu) °C" "Acima de $($cfg.limiteQuente) °C há mais de 10 segundos. Uso: $(Fmt $r.cpuUso) %."
    foreach ($hw in $r.gpus.Keys) {
        $g = $r.gpus[$hw]
        Avaliar "gpu-temp$hw" (Acima "gpu-temp$hw" $g.temp $cfg.limiteQuente) 5 30 60 'quente' `
            "$($g.nome) a $(Fmt $g.temp) °C" "Placa de vídeo acima de $($cfg.limiteQuente) °C há mais de 10 segundos. Uso: $(Fmt $g.uso) %."
    }
    $limVirt = $r.virtUsada + $r.virtLivre
    $pctVirt = if ($limVirt -gt 0) { $r.virtUsada / $limVirt * 100 } else { $NaN }
    Avaliar 'memoria' (Acima 'memoria' $pctVirt 90) 15 30 60 'quente' `
        "Memória quase no limite ($(Fmt $pctVirt) %)" "$(Fmt $r.virtUsada 1) de $(Fmt $limVirt 0) GB confirmados. Feche programas para evitar travamentos."
    foreach ($hw in $r.discos.Keys) {
        $d = $r.discos[$hw]
        # NVMe informa o próprio limite de aviso; nos demais vale o limite configurado.
        $lim = if (-not [double]::IsNaN($d.aviso) -and $d.aviso -gt 0) { [math]::Min($d.aviso, 90) } else { $cfg.limiteDisco }
        $lt = Letras-De $hw
        Avaliar "disco-temp$hw" (Acima "disco-temp$hw" $d.temp $lim) 15 360 1440 'morno' `
            "Disco $lt$($d.nome) a $(Fmt $d.temp) °C" "Acima de $(Fmt $lim) °C. Calor constante encurta a vida útil: melhore a ventilação desse disco."
        $semana = 7 * 24 * 60
        # 0 °C e 0 h juntos: a leitura SMART veio zerada, então vida e reserva não valem.
        $semSmart = $d.temp -eq 0 -and $d.horas -eq 0
        Avaliar "disco-vida$hw" (-not $semSmart -and -not [double]::IsNaN($d.vida) -and $d.vida -lt 70) 1 $semana $semana 'morno' `
            "SSD $lt$($d.nome): $(Fmt $d.vida) % de vida útil" "O desgaste está avançado. Mantenha backup do que estiver nele e planeje a troca."
        Avaliar "disco-reserva$hw" (-not $semSmart -and -not [double]::IsNaN($d.reserva) -and -not [double]::IsNaN($d.reservaMin) -and $d.reserva -le $d.reservaMin) 1 1440 1440 'quente' `
            "SSD $lt$($d.nome): reserva esgotada" "A área reserva ($(Fmt $d.reserva) %) chegou ao mínimo do fabricante. Faça backup agora."
        Avaliar "disco-idade$hw" ($d.hdd -and $d.horas -ge 40000) 1 $semana $semana 'morno' `
            "HD $lt$($d.nome): $(Fmt ($d.horas / 8760) 1) anos ligado" "$(Fmt $d.horas) horas de uso. HDs nessa idade falham com mais frequência: mantenha backup do que estiver nele."
    }
}
function Json-Alertas {
    if (-not $script:ativos.Count) { return '[]' }
    return ConvertTo-Json -InputObject @($script:ativos.Values) -Compress
}

$script:iconeAtual = $null
$script:alterna = $false
$script:vezGpu = $false
$timerIcone = New-Object System.Windows.Forms.Timer
$timerIcone.Interval = 2000
$timerIcone.Add_Tick({
    try {
        $r = Ler-Resumo
        Guardar-Historico $r
        Verificar-Alertas $r
        if ($script:registro) {
            $ids = @($r.discos.Keys)
            $nomesDisp = @($ids | ForEach-Object { $r.discos[$_].nome })
            $tempsDisp = @($ids | ForEach-Object { $r.discos[$_].temp })
            foreach ($hw in $r.gpus.Keys) { $ids += $hw; $nomesDisp += $r.gpus[$hw].nome; $tempsDisp += $r.gpus[$hw].temp }
            $usoGpu = $NaN
            foreach ($hw in $r.gpus.Keys) { $u = $r.gpus[$hw].uso; if (-not [double]::IsNaN($u) -and ([double]::IsNaN($usoGpu) -or $u -gt $usoGpu)) { $usoGpu = $u } }
            try {
                $script:registro.Amostra($r.cpu, $r.cpuUso, $r.gpu, $usoGpu, $r.cpuW, $r.gpuW, $r.ramUsada,
                    [string[]]$ids, [string[]]$nomesDisp, [double[]]$tempsDisp)
            } catch { }
        }
        Notificar-Fila
        $texto = if ([double]::IsNaN($r.cpu)) { '--' } else { [string][math]::Round($r.cpu) }
        $total = $r.ramUsada + $r.ramLivre
        $itemCpu.Text = "CPU  $(Fmt $r.cpu) °C · $(Fmt $r.cpuUso) %"
        $curtas = @($r.gpus.Keys | ForEach-Object { $g = $r.gpus[$_]; (($g.nome -replace '^(NVIDIA|AMD|Intel\(R\)|Intel)\s+', '') -replace '^(GeForce|Radeon)\s+', '') + " $(Fmt $g.temp) °C" })
        $itemGpu.Text = if ($curtas.Count -gt 1) { 'GPU  ' + ($curtas -join ' · ') } else { "GPU  $(Fmt $r.gpu) °C · $(Fmt $r.gpuUso) %" }
        $itemRam.Text = "RAM  $(Fmt $r.ramUsada 1) de $(Fmt $total 0) GB"
        $tempsGpu = @($r.gpus.Keys | ForEach-Object { Fmt $r.gpus[$_].temp }) -join '/'
        if (-not $tempsGpu) { $tempsGpu = Fmt $r.gpu }
        $dica = "CPU $(Fmt $r.cpu) °C · GPU $tempsGpu °C`nRAM $(Fmt $r.ramUsada 1)/$(Fmt $total 0) GB"
        if ($script:ativos.Count) { $dica = "⚠ $($script:ativos.Count) alerta(s) · " + $dica }
    } catch {
        # 30 leituras sem resposta (1 min): o LibreHardwareMonitor parou.
        Avaliar 'lhm' $true 30 60 240 'quente' 'Monitor sem leituras' 'O LibreHardwareMonitor não responde há 1 minuto. Clique para abrir o monitor.'
        Notificar-Fila
        $texto = '--'
        $r = @{ cpu = [double]::NaN }
        $dica = "Monitor de Hardware`nSem leituras do LibreHardwareMonitor"
        $itemCpu.Text = 'Sem leituras do LibreHardwareMonitor'
        $itemGpu.Text = 'GPU —'; $itemRam.Text = 'RAM —'
    }
    $itemAtivos.Visible = $script:ativos.Count -gt 0
    $itemAtivos.Text = "⚠ $($script:ativos.Count) alerta(s) ativo(s)"
    $itemAlertas.Checked = [bool](Ler-Config).alertas
    $marcas = Cores-Marca
    $modo = (Ler-Config).iconeModo
    foreach ($k in $script:itensModo.Keys) { $script:itensModo[$k].Checked = ($k -eq $modo) }
    $ct = if ($null -eq $r.cpu) { [double]::NaN } else { [double]$r.cpu }
    $gt = if ($null -eq $r.gpu) { [double]::NaN } else { [double]$r.gpu }
    $script:alterna = -not $script:alterna
    if ($script:alterna) { $script:vezGpu = -not $script:vezGpu }   # alterna a cada 2 leituras (4 s)
    $usarGpu = switch ($modo) {
        'gpu' { $true }
        'cpu' { $false }
        'alternar' { $script:vezGpu }
        default { -not [double]::IsNaN($gt) -and ([double]::IsNaN($ct) -or $gt -gt $ct) }
    }
    $valorIcone = if ($usarGpu) { $gt } else { $ct }
    $texto = if ([double]::IsNaN($valorIcone)) { '--' } else { [string][math]::Round($valorIcone) }
    $novo = Novo-Icone $texto (Cor $valorIcone) $marcas[$(if ($usarGpu) { 1 } else { 0 })]
    $bandeja.Icon = $novo
    if ($script:iconeAtual) { $script:iconeAtual.Dispose() }
    $script:iconeAtual = $novo
    $bandeja.Text = if ($dica.Length -gt 63) { $dica.Substring(0, 63) } else { $dica }

})

$timerProc = New-Object System.Windows.Forms.Timer
$timerProc.Interval = 2000
$timerProc.Add_Tick({
    if (-not $script:processos) { return }
    if (((Get-Date) - $script:procPedido).TotalSeconds -gt 10) { return }
    try { $script:procJson = $script:processos.Amostrar(8) } catch { }
})

# Placas NVIDIA direto do driver (nvidia-smi): clock em repouso, estado de energia e ligação PCIe,
# que o LibreHardwareMonitor não informa ou informa zerado. A consulta leva ~200 ms, então roda como
# processo à parte, a cada 4 s e só enquanto o painel está pedindo.
$script:nvidiaJson = '[]'
$script:nvidiaExe = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if (-not (Test-Path -LiteralPath $script:nvidiaExe)) { $script:nvidiaExe = $null }
$script:nvidiaProc = $null
$script:nvidiaHora = [datetime]::MinValue
$script:nvidiaPedido = [datetime]::MinValue
function Nvidia-Num([string]$s) {
    $v = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$v)) { return [int][math]::Round($v) }
    return $null
}
function Nvidia-Tick {
    if (-not $script:nvidiaExe) { return }
    $p = $script:nvidiaProc
    if ($p) {
        if (-not $p.HasExited) {
            if (((Get-Date) - $script:nvidiaHora).TotalSeconds -gt 20) { try { $p.Kill() } catch { }; $p.Dispose(); $script:nvidiaProc = $null }
            return
        }
        try {
            $lista = @()
            foreach ($linha in ($p.StandardOutput.ReadToEnd() -split "`n")) {
                $c = @($linha.Trim() -split '\s*,\s*')
                if ($c.Count -lt 9) { continue }
                $lista += [ordered]@{ nome = $c[0]; clk = Nvidia-Num $c[1]; mem = Nvidia-Num $c[2]; pstate = $c[3]
                                      gen = Nvidia-Num $c[4]; genMax = Nvidia-Num $c[5]; larg = Nvidia-Num $c[6]; largMax = Nvidia-Num $c[7]; limiteW = Nvidia-Num $c[8] }
            }
            $script:nvidiaJson = ConvertTo-Json -InputObject @($lista) -Compress
        } catch { }
        $p.Dispose(); $script:nvidiaProc = $null
        return
    }
    if (((Get-Date) - $script:nvidiaPedido).TotalSeconds -gt 15) { return }
    if (((Get-Date) - $script:nvidiaHora).TotalSeconds -lt 4) { return }
    $script:nvidiaHora = Get-Date
    try {
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName = $script:nvidiaExe
        $si.Arguments = '--query-gpu=name,clocks.gr,clocks.mem,pstate,pcie.link.gen.gpucurrent,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,power.limit --format=csv,noheader,nounits'
        $si.UseShellExecute = $false; $si.RedirectStandardOutput = $true; $si.CreateNoWindow = $true
        $script:nvidiaProc = [System.Diagnostics.Process]::Start($si)
    } catch { $script:nvidiaProc = $null }
}

# ---- Gravar sessão (cartão da GPU): uma placa, uma linha por segundo em registros\sessoes, e um resumo no fim.
# Para sozinha 90 s depois que a carga termina, pelo botão, ou com 4 h.
$pastaSessoes = Join-Path $pastaRegistros 'sessoes'
$ptbr = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')
$script:sessao = $null
$script:sessaoResumo = $null
function Sessao-Leitura([string]$hw) {
    $v = @{ clock = $NaN; mem = $NaN; w = $NaN; volt = $NaN; uso = $NaN; temp = $NaN; vram = $NaN; vramLhm = $NaN }
    try { $texto = $utf8.GetString((Obter-Dados)) } catch { return $v }
    foreach ($m in $padrao.Matches($texto)) {
        $id = $m.Groups[3].Value
        if (-not $id.StartsWith($hw + '/')) { continue }
        $nome = $m.Groups[1].Value; $x = Numero $m.Groups[2].Value
        switch ($id.Substring($hw.Length + 1) -replace '/.*$', '') {
            'clock' { if ($nome -eq 'GPU Core') { $v.clock = $x } elseif ($nome -eq 'GPU Memory') { $v.mem = $x } }
            'power' { if ([double]::IsNaN($v.w) -or $nome -eq 'GPU Package') { $v.w = $x } }
            'voltage' { if ([double]::IsNaN($v.volt)) { $v.volt = $x } }
            'load' { if ($nome -eq 'GPU Core') { $v.uso = $x } }
            'temperature' { if ($nome -eq 'GPU Core' -or [double]::IsNaN($v.temp)) { $v.temp = $x } }
            default { if ($nome -eq 'D3D Dedicated Memory Used') { $v.vram = $x } elseif ($nome -eq 'GPU Memory Used') { $v.vramLhm = $x } }
        }
    }
    # com várias placas o LibreHardwareMonitor repete a VRAM da primeira; o contador do Windows é por placa
    if ([double]::IsNaN($v.vram)) { $v.vram = $v.vramLhm }
    return $v
}
function Sessao-Iniciar([string]$hw, [string]$nome) {
    if ($script:sessao) { return 'já existe uma gravação em andamento' }
    if (-not (Test-Path -LiteralPath $pastaSessoes)) { [void](New-Item -ItemType Directory -Path $pastaSessoes) }
    $inicio = Get-Date
    $curto = ((($nome -replace '^(NVIDIA|AMD|Intel\(R\)|Intel)\s+', '') -replace '^(GeForce|Radeon)\s+', '') -replace '[^\w]+', '-').Trim('-')
    if (-not $curto) { $curto = 'gpu' }
    $arq = Join-Path $pastaSessoes ($inicio.ToString('yyyy-MM-dd_HHmmss') + '_' + $curto + '.csv')
    [System.IO.File]::WriteAllText($arq, "hora;clock_mhz;memoria_mhz;potencia_w;tensao_v;uso_pct;temp_c;vram_mb`r`n", $utf8)
    $script:sessao = @{ hw = $hw; nome = $nome; inicio = $inicio; arquivo = $arq; amostras = (New-Object System.Collections.Generic.List[object]); viuCarga = $false; parado = 0 }
    $script:sessaoResumo = $null
    $timerSessao.Start()
    return 'ok'
}
function Sessao-Num([double]$x, [string]$f) { if ([double]::IsNaN($x)) { return '' } return $x.ToString($f, $ptbr) }
function Sessao-Tick {
    $s = $script:sessao
    if (-not $s) { $timerSessao.Stop(); return }
    $v = Sessao-Leitura $s.hw
    $s.amostras.Add($v)
    $linha = (Get-Date).ToString('HH:mm:ss') + ';' + (Sessao-Num $v.clock '0') + ';' + (Sessao-Num $v.mem '0') + ';' + (Sessao-Num $v.w '0.0') + ';' +
             (Sessao-Num $v.volt '0.000') + ';' + (Sessao-Num $v.uso '0') + ';' + (Sessao-Num $v.temp '0.0') + ';' + (Sessao-Num $v.vram '0')
    try { [System.IO.File]::AppendAllText($s.arquivo, $linha + "`r`n", $utf8) } catch { }
    if ($v.uso -ge 50) { $s.viuCarga = $true; $s.parado = 0 }
    elseif ($s.viuCarga -and -not ($v.uso -ge 5)) { $s.parado++ }
    else { $s.parado = 0 }
    if ($s.parado -ge 90) { Sessao-Parar 'a carga terminou' }
    elseif (((Get-Date) - $s.inicio).TotalHours -ge 4) { Sessao-Parar 'limite de 4 horas' }
}
# média, mínimo e máximo de um campo, ignorando leituras ausentes (e zeros, que são leituras vazias)
function Sessao-Estat($lista, [string]$campo, [double]$minimo = 0) {
    $x = @($lista | ForEach-Object { $_[$campo] } | Where-Object { -not [double]::IsNaN($_) -and $_ -gt $minimo })
    if (-not $x.Count) { return $null }
    return ($x | Measure-Object -Average -Minimum -Maximum)
}
function Sessao-Arred($x, [int]$casas = 0) { if ($null -eq $x) { return $null } return [math]::Round([double]$x, $casas) }
function Sessao-Parar([string]$motivo) {
    $s = $script:sessao
    if (-not $s) { return }
    $script:sessao = $null
    $timerSessao.Stop()
    $fim = Get-Date
    $carga = @($s.amostras | Where-Object { $_.uso -ge 90 })
    $ck = Sessao-Estat $carga 'clock'; $pw = Sessao-Estat $carga 'w'; $vt = Sessao-Estat $carga 'volt' 0.3
    $tp = Sessao-Estat $s.amostras 'temp'; $vr = Sessao-Estat $s.amostras 'vram'
    $abaixo = $null
    if ($ck -and $carga.Count) { $abaixo = 100.0 * @($carga | Where-Object { $_.clock -lt 0.75 * $ck.Maximum }).Count / $carga.Count }
    $resumo = [ordered]@{
        placa = $s.nome; inicio = $s.inicio.ToString('s'); fim = $fim.ToString('s'); motivo = $motivo
        segundos = [int]($fim - $s.inicio).TotalSeconds; amostras = $s.amostras.Count; emCarga = $carga.Count
        clockMedio = Sessao-Arred $(if ($ck) { $ck.Average }); clockMin = Sessao-Arred $(if ($ck) { $ck.Minimum }); clockMax = Sessao-Arred $(if ($ck) { $ck.Maximum })
        abaixoPct = Sessao-Arred $abaixo
        potMedia = Sessao-Arred $(if ($pw) { $pw.Average }); potMax = Sessao-Arred $(if ($pw) { $pw.Maximum })
        tensaoMedia = Sessao-Arred $(if ($vt) { $vt.Average }) 3
        tempMax = Sessao-Arred $(if ($tp) { $tp.Maximum }) 1; vramMax = Sessao-Arred $(if ($vr) { $vr.Maximum })
        arquivo = (Split-Path -Leaf $s.arquivo)
    }
    $script:sessaoResumo = $resumo
    try { [System.IO.File]::WriteAllText(($s.arquivo -replace '\.csv$', '.json'), (ConvertTo-Json -InputObject $resumo), $utf8) } catch { }
}
function Json-Sessao {
    $s = $script:sessao
    $o = [ordered]@{ gravando = [bool]$s; resumo = $script:sessaoResumo }
    if ($s) {
        $o.placa = $s.nome; $o.hw = $s.hw; $o.segundos = [int]((Get-Date) - $s.inicio).TotalSeconds
        $o.amostras = $s.amostras.Count; $o.emCarga = @($s.amostras | Where-Object { $_.uso -ge 90 }).Count
        $o.viuCarga = $s.viuCarga
    }
    return ConvertTo-Json -InputObject $o -Compress -Depth 3
}
$timerSessao = New-Object System.Windows.Forms.Timer
$timerSessao.Interval = 1000
$timerSessao.Add_Tick({ Sessao-Tick })

$timerLetras = New-Object System.Windows.Forms.Timer
$timerLetras.Interval = 1500
$timerLetras.Add_Tick({ Acao-Tick; Letras-Tick; Nvidia-Tick; Janela-Tick })

$contexto = New-Object System.Windows.Forms.ApplicationContext
$itemSair.Add_Click({
    Sessao-Parar 'monitor fechado'
    $timerHttp.Stop(); $timerIcone.Stop(); $timerProc.Stop(); $timerLetras.Stop(); $timerSessao.Stop()
    $bandeja.Visible = $false
    $bandeja.Dispose()

    try { $listener.Stop(); $listener.Close() } catch { }
    $contexto.ExitThread()
})

$timerHttp.Start()
$timerIcone.Start()
$timerProc.Start()
$timerLetras.Start()
Letras-Tick
if (-not $NaoAbrirNavegador) { Abrir-Janela }
[System.Windows.Forms.Application]::Run($contexto)
