# Monitor de Hardware - leitura SMART pelo CrystalDiskInfo
# Cria (ou remove, com -Remover) a tarefa agendada que faz o CrystalDiskInfo gravar o relatório
# DiskInfo.txt, lido pelo painel quando o LibreHardwareMonitor devolve o SMART zerado
# (acontece com NVMe atrás do controlador Intel RST VMD). Pede administrador uma única vez.

param(
    [string]$CaminhoCDI = "$env:ProgramFiles\CrystalDiskInfo\DiskInfo64.exe",
    [int]$Minutos = 360,   # cada leitura acorda os HDs e faz barulho; setores mudam devagar
    [switch]$Remover
)

$ErrorActionPreference = 'Stop'
$tarefa = 'Monitor de Hardware - SMART'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-CaminhoCDI', "`"$CaminhoCDI`"", '-Minutos', $Minutos)
    if ($Remover) { $argumentos += '-Remover' }
    Start-Process powershell.exe -ArgumentList $argumentos -Verb RunAs -Wait
    exit
}

if ($Remover) {
    Unregister-ScheduledTask -TaskName $tarefa -Confirm:$false -ErrorAction SilentlyContinue
    exit
}
if (-not (Test-Path -LiteralPath $CaminhoCDI)) { throw "CrystalDiskInfo não encontrado em $CaminhoCDI" }

# Roda como SYSTEM: tem o privilégio que a leitura exige e não abre janela na sessão do usuário.
$acao = New-ScheduledTaskAction -Execute $CaminhoCDI -Argument '/CopyExit'
$gatilhos = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutos))
)
$conta = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName $tarefa -Action $acao -Trigger $gatilhos -Principal $conta -Settings $ajustes -Force `
    -Description 'Grava o relatório SMART do CrystalDiskInfo para o Monitor de Hardware.' | Out-Null
Start-ScheduledTask -TaskName $tarefa
