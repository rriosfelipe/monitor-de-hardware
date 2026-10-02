# Monitor de Hardware — versão local

*English version: [README.md](README.md).*

Painel com as leituras reais dos sensores do PC (CPU, GPU, RAM, discos, ventoinhas, rede, tensões e a lista completa de sensores), aberto numa janela própria, e um ícone na bandeja com a temperatura do componente mais quente (CPU ou GPU).

## Como funciona

- O **LibreHardwareMonitor** lê os sensores e publica em `http://localhost:8085/data.json`. Ele inicia com o Windows, minimizado.
- O `servidor.ps1` roda escondido, serve o painel em `http://localhost:8099/`, repassa as leituras em `/dados` e mantém o ícone na bandeja.
- O painel abre no **modo aplicativo do Edge**: janela própria, sem abas nem barra de endereço (perfil separado em `%LOCALAPPDATA%\MonitorHardware\navegador`).
- Tudo fica restrito a `localhost`: nada é exposto na rede.

## Uso

- **Atalho "Monitor de Hardware"** na área de trabalho: inicia o monitor e abre a janela. Se ele já estiver rodando, só traz a janela para frente.
- **Ícone na bandeja** (ao lado do relógio): mostra a temperatura mais alta entre CPU e GPU, na cor da faixa de temperatura. A faixinha embaixo indica de quem é o número: azul = CPU, roxa = GPU. No menu, **Ícone mostra** troca para só CPU, só GPU ou alternar entre as duas a cada 4 s.
  - Clique: abre a janela do painel.
  - Botão direito: CPU, GPU e RAM resumidos, abrir o LibreHardwareMonitor ou **Encerrar monitor**.
- Fechar a janela do painel não encerra o monitor; o ícone continua na bandeja.

## O painel

- **Faixa de resumo no topo:** CPU e GPU (temperatura, uso e mini-gráfico), RAM, VRAM, energia (CPU + GPU, em W), disco mais quente e rede.
- **Medidores de anel duplo:** anel externo = temperatura, anel interno = uso.
- **Histórico:** temperatura (linha, escala em °C à esquerda) e uso (área, % à direita), com as faixas de morno e quente tracejadas. Períodos de 1, 5 ou 15 min; passe o mouse para ver o valor de cada momento. O servidor guarda os últimos 15 min, então o gráfico já abre preenchido.
- **Todos os sensores:** busca por nome, filtro por tipo (temperaturas, clocks, uso, ventoinhas…), resumo de cada componente na linha recolhida, e uma barra por sensor com a faixa mínimo–máximo e um ponto no valor atual. Expandir/Recolher tudo; o painel lembra quais componentes ficaram abertos.
- **Modo compacto:** botão **Compacto** no topo, mostra só a faixa de resumo, para deixar a janela pequena num canto ou num segundo monitor. **Completo** volta ao painel inteiro.

## Alertas

O ícone da bandeja avalia os sensores a cada 2 s e mostra uma notificação do Windows quando:

| Alerta | Quando | Repete |
|---|---|---|
| CPU ou GPU quente | acima do limite "quente" por 10 s | a cada 30 min por episódio; 1 h se persistir |
| Disco quente | acima do limite de disco por 30 s (NVMe: limite gravado pelo fabricante) | 6 h por episódio; 1 dia se persistir |
| Vida útil do SSD | abaixo de 70 % | 1 vez por semana |
| Reserva do SSD esgotada | no mínimo do fabricante | 1 vez por dia |
| HD antigo | mais de 40 mil horas ligado | 1 vez por semana |
| Memória confirmada | acima de 90 % do limite por 30 s | 30 min |
| Monitor sem leituras | LibreHardwareMonitor parado por 1 min | 1 h |

- Vários alertas ao mesmo tempo viram uma notificação só. Clicar nela abre o painel.
- Os alertas ativos também aparecem em faixas no topo do painel (inclusive no modo compacto). O **×** dispensa um aviso, e **Dispensar todos** limpa a faixa, até a próxima vez que o painel for aberto; um alerta novo aparece mesmo assim.
- Ligar/desligar: menu do ícone da bandeja (**Notificações de alerta**) ou **Ajustes** no painel, onde também fica o limite de temperatura dos discos.
- `alertas-estado.json` guarda quando cada alerta foi mostrado, para não repetir a cada inicialização. Apagar o arquivo zera esse controle.

## Registro de longo prazo

O ícone da bandeja grava **uma linha por minuto** (média e máximo do minuto) enquanto o PC está ligado, mesmo com o painel fechado. A gravação é feita pelo `Registro.cs`.

- Arquivos na pasta `registros`, um por dia, mantidos por **30 dias** (os mais antigos são apagados sozinhos):
  - `AAAA-MM-DD.csv`: temperatura média e máxima de CPU e GPU, uso, potência (W) e RAM usada.
  - `discos-AAAA-MM-DD.csv`: temperatura de cada disco.
- Formato do Excel brasileiro: separador `;` e vírgula decimal. Abrem direto com dois cliques.
- Tamanho: cerca de 0,8 MB por dia (uns 25 MB por mês).
- No painel, a seção **Registro de longo prazo** mostra 24 horas, 7 dias ou 30 dias: temperatura e uso de CPU e GPU, temperatura dos discos escolhidos, picos do período (com dia e hora) e a energia gasta por CPU e GPU. Nos períodos longos cada ponto é a média de 10 min (7 dias) ou 30 min (30 dias). O botão **Abrir arquivos CSV** abre a pasta.

## Saúde dos discos

O cartão **Armazenamento** mostra, para cada disco: a letra da unidade (C:, D:…; consultada no Windows a cada 10 min, em segundo plano), tipo (HD, SSD, NVMe), vida útil restante (SSD), tempo ligado e, quando há algo a fazer, uma nota em destaque (desgaste, idade, reserva, temperatura).

## Desativar e ativar HDs externos

Nos discos USB, o cartão **Armazenamento** tem um botão **Desativar** / **Ativar**. Desativar coloca o disco *offline* no Windows: a letra some e nenhum programa acessa os arquivos; **nada é apagado**. Ativar devolve tudo como estava.

- Antes de desativar, o painel mostra quem está usando o disco: programas abertos a partir dele e **torrents do qBittorrent** salvos nele.
- Antes de desativar, as gravações pendentes vão para o disco (`Write-VolumeCache`). Depois o Windows pede confirmação de administrador.
- O disco continua desativado depois de reiniciar o PC, até ser ativado.
- Sem acesso, a maioria dos cases USB para o motor em alguns minutos (dá para conferir pela temperatura caindo). Alguns cases não param; nesses, só desligando o case.
- Proteções: só aparece para discos USB, e o servidor recusa disco do sistema, disco com arquivo de paginação e pedidos de fora do painel.

## Programas usando CPU e GPU

Os cartões do processador e da placa de vídeo listam os programas que mais usam cada um, agrupados pelo nome (×N = número de processos), atualizados a cada 2 s:

- **CPU:** percentual do processador inteiro e memória RAM de cada programa.
- **GPU:** percentual do motor mais usado (3D, codificação/decodificação de vídeo, computação/CUDA, cópia) e VRAM dedicada.

A leitura (`Processos.cs`) usa as mesmas fontes do Gerenciador de Tarefas e só roda enquanto o painel estiver aberto. Processos protegidos do sistema podem não aparecer na lista de CPU.

## Ajustes (cores e alertas)

Botão **Ajustes** no topo do painel: temas prontos (Padrão, Grafite, Âmbar, Alto contraste, Claro), cada cor da interface e das faixas de temperatura, e os limites de "morno" e "quente". A pré-visualização é ao vivo; **Salvar** grava em `config.json` e vale também para o ícone da bandeja. Para voltar ao original, use **Restaurar padrão** ou apague o `config.json`.

## Opções (rodando o `servidor.ps1` manualmente)

- Outra porta: `-Porta 8100`
- LibreHardwareMonitor em outra porta: `-Fonte http://localhost:9000/data.json`
- Não abrir a janela ao iniciar: `-NaoAbrirNavegador`
- Não abrir o LibreHardwareMonitor (usado na inicialização do Windows): `-SemLHM`
