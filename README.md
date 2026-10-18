# Monitor de Hardware

*Read in English: [README.en.md](README.en.md).*

Monitor de hardware local para Windows. Ele mostra, ao vivo, todos os sensores do PC (CPU, GPU, RAM, discos, ventoinhas, rede e tensões) num painel com janela própria, e mantém um ícone na bandeja com a temperatura do componente mais quente. Também avisa por notificação do Windows quando algo precisa de atenção e guarda um histórico de 30 dias.

Quem lê os sensores é o [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor). Este projeto acrescenta o painel, o ícone da bandeja, os alertas, o uso por programa, a saúde dos discos e o registro de longo prazo. Usa só PowerShell 5.1, um pouco de C# compilado na hora e HTML/JS simples. Não há nada para compilar nem instalar além do LibreHardwareMonitor.

## Funcionalidades

- **Painel em janela própria.** Modo aplicativo do Edge, sem abas nem barra de endereço.
  - Faixa de resumo no topo: CPU, GPU, RAM, VRAM, energia, disco mais quente e rede.
  - Medidores de anel duplo: o anel externo é a temperatura, o interno é o uso.
  - Gráficos de histórico com temperatura e uso, em períodos de 1, 5 ou 15 minutos, com o valor de cada momento ao passar o mouse. O servidor guarda os últimos 15 minutos, então o gráfico já abre preenchido.
  - Clock e uso por núcleo, em seção recolhível.
  - **Todos os sensores** (seção recolhível): busca por nome, filtro por tipo e, em cada sensor, uma barra com a faixa mínimo–máximo e um ponto no valor atual.
  - **Modo compacto:** só a faixa de resumo, em duas colunas. A janela encolhe sozinha para caber os indicadores e volta ao tamanho anterior (inclusive maximizada) ao sair do modo.
  - **Janela lembrada:** o painel reabre no tamanho e na posição em que foi deixado (maximizado, inclusive).
  - **Ícone próprio na barra de tarefas:** a janela não é agrupada com o Edge; fixada na barra, reabre o monitor.
- **Várias placas de vídeo.** Com mais de uma GPU, o cartão ganha um seletor de placa; a faixa de resumo, o histórico, a VRAM, os alertas e o registro tratam cada placa separadamente. A VRAM total de cada uma é lida do Windows.
- **Placas NVIDIA lidas também pelo driver.** O LibreHardwareMonitor mostra 0 MHz com a placa em repouso; nesse caso o painel usa o clock informado pelo `nvidia-smi`. O cartão mostra ainda a ligação PCIe (largura e geração, em destaque quando a placa está num slot ou riser mais estreito do que suporta) e o estado de energia (P0 a P8). Uma potência incompatível com a placa parada e fria é marcada com ⚠ e fica fora do indicador de Energia e do registro.
- **Ícone na bandeja.** Mostra a temperatura mais alta entre CPU e GPU (a mais quente, se houver várias), na cor da faixa de temperatura. Uma faixinha embaixo do número indica de quem ele é: azul para CPU, roxa para GPU. Dá para trocar para só CPU, só GPU ou alternar entre as duas.
- **Uso por programa.** Os programas que mais usam a CPU (com a RAM de cada um) e a GPU (com o tipo de trabalho e a VRAM). As fontes são as mesmas do Gerenciador de Tarefas.
- **Programas por placa.** Com mais de uma GPU, a lista mostra só os programas da placa escolhida no seletor (o Windows informa em qual placa cada programa está).
- **Gravar sessão.** O botão "Gravar" no cartão da GPU registra clock, potência, tensão, uso, temperatura e VRAM da placa selecionada a cada segundo, num CSV em `registros/sessoes/`. Para sozinho 90 s depois que a carga termina (ou pelo botão) e mostra o resumo: tempo em carga, clock médio, mínimo e máximo, quanto tempo ficou abaixo de 75 % do pico, potência, tensão, temperatura e VRAM.
- **Alertas** por notificação do Windows:

  | Alerta | Quando | Repete |
  |---|---|---|
  | CPU ou GPU quente | acima do limite "quente" por 10 s | a cada 30 min por episódio; 1 h se persistir |
  | Disco quente | acima do limite de disco por 30 s (nos NVMe, vale o limite gravado pelo fabricante) | 6 h por episódio; 1 dia se persistir |
  | Vida útil do SSD | abaixo de 70 % | 1 vez por semana |
  | Reserva do SSD esgotada | chegou ao mínimo do fabricante | 1 vez por dia |
  | HD antigo | mais de 40 mil horas ligado | 1 vez por semana |
  | Memória quase no limite | memória confirmada acima de 90 % do limite por 30 s | 30 min |
  | Monitor sem leituras | LibreHardwareMonitor parado por 1 min | 1 h |

  Vários alertas ao mesmo tempo viram uma notificação só, e clicar nela abre o painel. Todos os alertas ativos ficam no **sino** do cabeçalho, com um contador (vermelho quando há algum urgente) e a lista ao clicar. Os do momento (temperatura, memória, reserva do SSD, leituras paradas) também aparecem em faixa no topo do painel e podem ser dispensados até a próxima abertura; os crônicos (desgaste do SSD, idade do HD) ficam só no sino.
- **Tendência de saúde dos discos.** Cada cartão de SSD mostra o ritmo de desgaste (% de vida perdida por mês nos últimos meses, a média de todo o histórico e o prazo estimado até 10 %), e cada HD mostra os setores realocados, pendentes e ilegíveis. O monitor avisa quando o desgaste de um SSD acelera ou o prazo fica curto, e quando um HD ganha setores com defeito. Usa o histórico que o CrystalDiskInfo guarda por disco e um retrato diário gravado em `registros/saude-discos.csv`; os setores dos HDs exigem a leitura SMART pelo CrystalDiskInfo (`instalar-smart.ps1`).
- **Saúde dos discos.** Para cada disco: letra da unidade (C:, D:…), tipo (HD, SSD ou NVMe), vida útil restante, tempo ligado e uma nota em destaque quando há algo a fazer.
- **Desativar e ativar HDs externos.** Coloca um disco USB *offline* no Windows, ou de volta online, com um clique. O Windows para de acessá-lo sem precisar desconectar o cabo, e **nada é apagado**. Antes de desativar, o painel avisa sobre programas usando o disco e **torrents do qBittorrent** salvos nele, e grava o que estiver pendente. Exige a confirmação de administrador do Windows.
- **Registro de 30 dias** (seção recolhível, com resumo do período quando fechada). Uma linha por minuto (média e pico) em arquivos CSV diários, que abrem direto no Excel. O painel mostra gráficos de 24 horas, 7 dias e 30 dias, os picos do período com dia e hora, e a energia gasta por CPU e GPU.
- **Ajustes:** temas de cores, cada cor da interface, as faixas de temperatura, o limite de temperatura dos discos e as notificações ligadas ou desligadas.

## Requisitos

- Windows 10 ou 11, com Windows PowerShell 5.1 e Microsoft Edge (ambos já vêm no Windows).
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor), testado com a 0.9.6, **rodando como administrador**. Sem isso, faltam os sensores de CPU, placa-mãe e ventoinhas.

## Instalação

1. **Instale o LibreHardwareMonitor:**
   ```powershell
   winget install LibreHardwareMonitor.LibreHardwareMonitor
   ```
2. **Abra-o como administrador** e aceite a instalação do driver PawnIO na primeira vez.
3. **No LibreHardwareMonitor, em Options**, ative:
   - **Remote Web Server › Run** (porta padrão 8085). Se o Firewall do Windows perguntar, pode negar: o painel lê os dados pelo `localhost`.
   - **Run On Windows Startup**, **Start Minimized** e **Minimize To Tray** (recomendado).
   - Depois, feche-o uma vez por **File › Exit**, para que essas opções sejam gravadas.
4. **Clone este repositório** e dê dois cliques em `Iniciar monitor.bat`. O ícone aparece na bandeja e o painel abre.

### Atalho na área de trabalho e início com o Windows (opcional)

Para um atalho sem janela de console, aponte-o para:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<pasta do repositório>\servidor.ps1"
```

e use o `monitor.ico` como ícone.

Para o ícone da bandeja iniciar ao entrar no Windows, sem abrir a janela, coloque um atalho em `shell:startup` com:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<pasta do repositório>\servidor.ps1" -NaoAbrirNavegador -SemLHM
```

O `-SemLHM` evita abrir o LibreHardwareMonitor, que já inicia sozinho. Sem ele, poderia aparecer um pedido de confirmação de administrador ao entrar no Windows.

### SMART pelo CrystalDiskInfo (opcional)

Em alguns notebooks o SSD NVMe fica atrás do controlador Intel RST VMD, e o LibreHardwareMonitor devolve o SMART zerado (0 °C, 0 h ligado). O card do disco mostra então **SMART indisponível**. Para ter os valores reais:

1. Instale o CrystalDiskInfo: `winget install CrystalDewWorld.CrystalDiskInfo`
2. Rode `instalar-smart.ps1` (pede administrador uma vez). Ele cria a tarefa agendada **Monitor de Hardware - SMART**, que roda o CrystalDiskInfo em segundo plano a cada 5 minutos e regrava o relatório `DiskInfo.txt`.

O painel passa a usar esse relatório só nos discos NVMe com leitura zerada, e marca o card com **via CDI**. Um relatório com mais de 30 minutos é ignorado. Para desfazer: `instalar-smart.ps1 -Remover`.

## Uso

- **Clique no ícone da bandeja** para abrir o painel. Se ele já estiver aberto, a janela vem para frente.
- **Botão direito no ícone** mostra um resumo de CPU, GPU e RAM e as opções:
  - **Notificações de alerta**: liga ou desliga os alertas.
  - **Ícone mostra**: o que aparece no ícone.
  - **Abrir LibreHardwareMonitor**.
  - **Encerrar monitor**.
- Fechar a janela do painel não encerra o monitor; ele continua na bandeja.

### Opções de linha de comando do `servidor.ps1`

| Opção | Para quê |
|---|---|
| `-Porta 8100` | Servir o painel em outra porta (padrão `8099`) |
| `-Fonte <url ou arquivo>` | Ler o LibreHardwareMonitor de outro endereço, ou de um arquivo JSON para testes |
| `-NaoAbrirNavegador` | Iniciar sem abrir a janela do painel |
| `-SemLHM` | Não abrir o LibreHardwareMonitor |
| `-CaminhoLHM <caminho>` | Caminho do `LibreHardwareMonitor.exe`, se não foi instalado pelo winget |
| `-RelatorioSmart <caminho>` | Caminho do `DiskInfo.txt` do CrystalDiskInfo, se ele não está em `Arquivos de Programas` |

## Como funciona

```text
LibreHardwareMonitor ──(localhost:8085/data.json)──► servidor.ps1 ──(localhost:8099)──► painel (janela do Edge)
   (administrador, sensores)                          │  ícone da bandeja, alertas, histórico
                                                      ├─ Processos.cs  CPU/GPU por programa (API PDH)
                                                      └─ Registro.cs   registro por minuto em CSV, 30 dias
```

| Arquivo | Papel |
|---|---|
| `servidor.ps1` | Programa da bandeja e servidor HTTP local. Repassa os dados dos sensores, avalia os alertas, guarda 15 minutos de histórico, consulta em segundo plano as letras e o estado dos discos, e ativa ou desativa discos externos com um `Set-Disk` elevado. |
| `index.html` | O painel inteiro (HTML, CSS e JS num arquivo só). |
| `Janela.cs` | Redimensiona a janela do painel no modo compacto (API do Windows). Só age na janela ativa com o título exato do painel. |
| `Processos.cs` | Tempo de CPU por programa e uso de GPU (motor e VRAM). Usa a API nativa PDH, porque o `Get-Counter` é lento demais com as centenas de instâncias dos contadores de GPU. |
| `Registro.cs` | Agregação por minuto, arquivos CSV diários, limpeza dos antigos e séries resumidas para os gráficos. |
| `Iniciar monitor.bat` | Inicia o `servidor.ps1` escondido. |
| `instalar-smart.ps1` | Cria ou remove a tarefa agendada que faz o CrystalDiskInfo gravar o relatório SMART (opcional). |

Arquivos criados durante o uso, deixados fora do git pelo `.gitignore`:

| Arquivo | Conteúdo |
|---|---|
| `config.json` | Cores, faixas de temperatura e opções de alertas e do ícone. Apagar volta ao padrão. |
| `alertas-estado.json` | Quando cada alerta foi mostrado, para não repetir a cada inicialização. Apagar zera esse controle. |
| `letras-ultimas.json` | Última letra conhecida de cada disco, mostrada enquanto ele estiver desativado. |
| `janela.json` | Último tamanho e posição da janela do painel, reaplicados quando ela abre. |
| `registros/` | Registros diários: `AAAA-MM-DD.csv` (CPU, GPU, uso, potência, RAM) e `discos-AAAA-MM-DD.csv` (temperatura de cada disco e de cada GPU). Separador `;` e vírgula decimal, como no Excel brasileiro. Cerca de 0,8 MB por dia; os arquivos com mais de 30 dias são apagados sozinhos. |
| `registros/sessoes/` | Sessões gravadas pelo botão "Gravar" do cartão da GPU: um CSV por sessão (uma linha por segundo) e um JSON com o resumo. |
| `registros/saude-discos.csv` | Retrato diário da saúde de cada disco (vida, setores, horas). Não é apagado com os registros de 30 dias. |

### Endereços HTTP (só no localhost)

| Endereço | Descrição |
|---|---|
| `GET /` | Painel |
| `GET /dados` | JSON do LibreHardwareMonitor, repassado com um cache curto |
| `GET /historico` | Últimos 15 minutos de temperatura e uso de CPU e GPU |
| `GET /registro?dias=1\|7\|30` | Série resumida do registro e o resumo do período |
| `GET /processos` | Programas que mais usam CPU e GPU |
| `GET /alertas` | Alertas ativos |
| `GET /memoria` | Velocidade configurada da RAM, informada pelo Windows |
| `GET /smart` | SMART lido pelo CrystalDiskInfo, por número de disco |
| `GET /gpus` | Placas de vídeo e o tamanho real da VRAM de cada uma |
| `GET /saude` | Tendência de saúde de cada disco: ritmo de desgaste dos SSDs e setores dos HDs |
| `GET/POST /sessao` | Estado da gravação de sessão e resumo da última; inicia ou para a gravação |
| `POST /abrir-sessoes` | Abre a pasta das sessões gravadas no Explorador |
| `GET /nvidia` | Placas NVIDIA pelo driver: clocks, estado de energia, ligação PCIe e limite de potência |
| `GET /letras`, `GET /discos-estado` | Letras das unidades, estado dos discos e a última ação de ativar ou desativar |
| `GET /disco-uso?n=<disco>` | O que está usando um disco (programas e torrents do qBittorrent) |
| `GET/POST /config` | Lê ou grava os ajustes |
| `POST /discos-estado` | Ativa ou desativa um disco externo |
| `POST /janela` | Encolhe ou restaura a janela do painel (modo compacto) |
| `POST /janela-aberta` | Avisa que uma janela nova do painel abriu, para aplicar o tamanho guardado |
| `POST /abrir-registros` | Abre a pasta dos CSV no Explorer |

## Segurança

- O servidor registra no Windows (HTTP.sys) apenas o endereço `http://localhost:8099/`, e o Firewall do Windows bloqueia conexões de entrada para ele por padrão. Ele não foi feito para ser acessado de outros aparelhos.
- Pedidos que mudam algo (`POST`) só são aceitos vindos do próprio painel e com corpo em JSON. Isso impede que outros sites os disparem pelo seu navegador.
- Ativar e desativar discos vale só para discos USB. O servidor recusa o disco do sistema e qualquer disco com arquivo de paginação, e toda ação ainda passa pela confirmação de administrador do Windows.
- O servidor web do próprio LibreHardwareMonitor aceita conexões da rede; é por isso que o Firewall do Windows pergunta sobre ele. Negue esse pedido (ou bloqueie a porta 8085) se não quiser que outros aparelhos leiam seus sensores. O painel continua funcionando, porque lê pelo `localhost`.

## Licença

[MIT](LICENSE). O LibreHardwareMonitor é um projeto à parte, com licença própria (MPL-2.0), e não faz parte deste repositório.
