# Monitor de Hardware - instalação (ou remoção, com -Remover)
# Faz o que o README descreve à mão: LibreHardwareMonitor com o servidor web ligado e iniciando com o Windows,
# atalho na área de trabalho, ícone na bandeja ao entrar no Windows e, se o CrystalDiskInfo estiver instalado,
# a leitura SMART dos discos. Pede administrador uma vez. -Simular só mostra o que faria.

param(
    [switch]$Remover,
    [switch]$Simular
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$servidor = Join-Path $raiz 'servidor.ps1'
$icone = Join-Path $raiz 'monitor.ico'
$ps = Join-Path $PSHOME 'powershell.exe'
$tarefaLhm = 'LibreHardwareMonitor'   # o mesmo nome que o próprio LibreHardwareMonitor usa para "Run On Windows Startup"

function Passo([string]$texto) { Write-Host ''; Write-Host "> $texto" -ForegroundColor Cyan }
function Feito([string]$texto) { Write-Host "  $texto" -ForegroundColor Green }
function Aviso([string]$texto) { Write-Host "  $texto" -ForegroundColor Yellow }
function Fazer([string]$descricao, [scriptblock]$acao) {
    if ($Simular) { Write-Host "  [simulação] $descricao" -ForegroundColor DarkGray; return }
    & $acao
    Feito $descricao
}
function Perguntar([string]$pergunta) {
    if ($Simular) { Write-Host "  [simulação] $pergunta (S/N) -> S" -ForegroundColor DarkGray; return $true }
    return (Read-Host "  $pergunta (S/N)") -match '^\s*[sSyY]'
}

# ---- administrador (tarefas agendadas e driver do LibreHardwareMonitor exigem)
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and -not $Simular) {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remover) { $argumentos += '-Remover' }
    Start-Process $ps -ArgumentList $argumentos -Verb RunAs
    exit
}

$desktop = [Environment]::GetFolderPath('Desktop')
$startup = [Environment]::GetFolderPath('Startup')
$atalhoPainel = Join-Path $desktop 'Monitor de Hardware.lnk'
$atalhoBandeja = Join-Path $startup 'Monitor de Hardware (bandeja).lnk'

function Criar-Atalho([string]$caminho, [string]$argumentos) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($caminho)
    $s.TargetPath = $ps
    $s.Arguments = $argumentos
    $s.WorkingDirectory = $raiz
    $s.IconLocation = "$icone,0"
    $s.WindowStyle = 7   # minimizado: a janela do PowerShell não pisca
    $s.Save()
}

# ===================================================================== remoção
if ($Remover) {
    Write-Host 'Monitor de Hardware - remoção' -ForegroundColor White
    Passo 'Atalhos'
    foreach ($a in $atalhoPainel, $atalhoBandeja) {
        if (Test-Path -LiteralPath $a) { Fazer "removido $a" { Remove-Item -LiteralPath $a -Force } } else { Feito "não existe: $a" }
    }
    Passo 'Programa da bandeja em execução'
    $nome = 'servidor' + '.ps1'
    $proc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$raiz*$nome*" })
    if ($proc.Count) { Fazer 'monitor encerrado' { $proc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } } } else { Feito 'não estava rodando' }
    Passo 'Leitura SMART pelo CrystalDiskInfo'
    $smart = Join-Path $raiz 'instalar-smart.ps1'
    Fazer 'tarefa "Monitor de Hardware - SMART" removida (se existia)' { & $smart -Remover }
    Write-Host ''
    Write-Host 'Pronto. O LibreHardwareMonitor e os registros em "registros\" foram mantidos.' -ForegroundColor White
    Write-Host 'Para remover o LibreHardwareMonitor: winget uninstall LibreHardwareMonitor.LibreHardwareMonitor' -ForegroundColor Gray
    exit
}

# ===================================================================== instalação
Write-Host 'Monitor de Hardware - instalação' -ForegroundColor White

# ---- 1. LibreHardwareMonitor
Passo 'LibreHardwareMonitor'
$lhm = $null
$candidatos = @(
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe\LibreHardwareMonitor.exe",
    "$env:ProgramFiles\LibreHardwareMonitor\LibreHardwareMonitor.exe"
)
$rodando = Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue | Select-Object -First 1
if ($rodando -and $rodando.Path) { $candidatos = @($rodando.Path) + $candidatos }
$lhm = $candidatos | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $lhm) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (Perguntar 'O LibreHardwareMonitor não está instalado. Instalar agora pelo winget?') {
            Fazer 'LibreHardwareMonitor instalado' { winget install --id LibreHardwareMonitor.LibreHardwareMonitor -e --accept-source-agreements --accept-package-agreements }
            $lhm = $candidatos | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }
    } else {
        Aviso 'winget não encontrado. Instale o LibreHardwareMonitor por https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases e rode este instalador de novo.'
    }
}
if (-not $lhm -and -not $Simular) { Aviso 'Sem o LibreHardwareMonitor o painel não tem sensores. Continuando com o resto.' }
elseif ($lhm) { Feito "encontrado: $lhm" }

# ---- 2. opções do LibreHardwareMonitor: servidor web na porta 8085, minimizado na bandeja
if ($lhm) {
    Passo 'Opções do LibreHardwareMonitor (servidor web, iniciar minimizado)'
    $arqCfg = Join-Path (Split-Path -Parent $lhm) 'LibreHardwareMonitor.config'
    $proc = Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue
    if ($proc) {
        # ele regrava o arquivo de opções ao fechar: precisa estar fechado antes da edição
        Fazer 'LibreHardwareMonitor fechado para gravar as opções' { $proc | Stop-Process -Force; Start-Sleep -Seconds 2 }
    }
    Fazer "opções gravadas em $arqCfg" {
        $xml = New-Object System.Xml.XmlDocument
        if (Test-Path -LiteralPath $arqCfg) { $xml.Load($arqCfg) } else { $xml.LoadXml('<?xml version="1.0" encoding="utf-8"?><configuration><appSettings /></configuration>') }
        $app = $xml.SelectSingleNode('/configuration/appSettings')
        if (-not $app) { $app = $xml.DocumentElement.AppendChild($xml.CreateElement('appSettings')) }
        $valores = [ordered]@{ runWebServerMenuItem = 'true'; startMinMenuItem = 'true'; minTrayMenuItem = 'true'; minCloseMenuItem = 'true' }
        if (-not $app.SelectSingleNode("add[@key='listenerPort']")) { $valores.listenerPort = '8085' }
        foreach ($k in $valores.Keys) {
            $n = $app.SelectSingleNode("add[@key='$k']")
            if (-not $n) { $n = $app.AppendChild($xml.CreateElement('add')); $n.SetAttribute('key', $k) }
            $n.SetAttribute('value', $valores[$k])
        }
        $xml.Save($arqCfg)
    }
    Fazer "LibreHardwareMonitor iniciando com o Windows (tarefa agendada ""$tarefaLhm"", como administrador)" {
        $acao = New-ScheduledTaskAction -Execute $lhm
        $gatilho = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $conta = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $tarefaLhm -Action $acao -Trigger $gatilho -Principal $conta -Settings $ajustes -Force | Out-Null
    }
    Fazer 'LibreHardwareMonitor aberto' { Start-Process -FilePath $lhm }
    if (-not $Simular) { Aviso 'Na primeira vez ele pede para instalar o driver PawnIO: aceite, sem ele CPU e placa-mãe ficam sem sensores.' }
}

# ---- 3. atalhos
Passo 'Atalhos'
Fazer "área de trabalho: $atalhoPainel" { Criar-Atalho $atalhoPainel "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$servidor`"" }
Fazer "ícone na bandeja ao entrar no Windows: $atalhoBandeja" { Criar-Atalho $atalhoBandeja "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$servidor`" -NaoAbrirNavegador -SemLHM" }

# ---- 4. SMART pelo CrystalDiskInfo (opcional)
Passo 'Leitura SMART pelo CrystalDiskInfo (opcional)'
$cdi = "$env:ProgramFiles\CrystalDiskInfo\DiskInfo64.exe"
if (Test-Path -LiteralPath $cdi) {
    if (Perguntar 'Ativar a leitura SMART (setores dos HDs e tendência dos discos), a cada 6 horas?') {
        Fazer 'tarefa "Monitor de Hardware - SMART" criada' { & (Join-Path $raiz 'instalar-smart.ps1') }
    }
} else {
    Feito 'CrystalDiskInfo não instalado; pulando. Para ter os setores dos HDs: winget install CrystalDewWorld.CrystalDiskInfo e rode este instalador de novo.'
}

# ---- 5. abre o painel
Passo 'Monitor'
Fazer 'monitor iniciado' { Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$servidor`"", '-SemLHM') -WorkingDirectory $raiz }
Write-Host ''
Write-Host 'Pronto. O ícone aparece na bandeja e o painel abre em seguida.' -ForegroundColor White
Write-Host 'Para desfazer: Desinstalar.bat (ou instalar.ps1 -Remover).' -ForegroundColor Gray
