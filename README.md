# AI Battery

Painel local de consumo de IA para Windows, com barra horizontal ou vertical, detecção de Codex, Claude e Gemini e alerta visual quando o saldo chega a 20%.

Este repositório contém somente o aplicativo AI Battery. Não inclui o Cérebro, servidores, dados de contas, sessões, chaves ou configurações pessoais. Não exige hospedagem, banco online ou API paga para iniciar.

## Requisitos

- Windows 10 ou 11 com interface gráfica.
- **Windows PowerShell 5.1** (`powershell.exe`, incluído no Windows). Use esse executável, e não `pwsh`/PowerShell 7.
- Codex CLI instalado e autenticado para consultar automaticamente a quota do Codex. Sem ele, o painel continua disponível com leituras indisponíveis ou manuais.
- Não é necessário instalar Node.js para o painel Windows em si. Cada CLI de IA tem seus próprios requisitos.

## Instalação passo a passo

1. Nesta página do GitHub, clique em **Code → Download ZIP**.
2. Extraia o ZIP para uma pasta permanente, por exemplo `C:\Apps\AI-Battery`. Não execute de dentro do ZIP.
3. Abra o Windows PowerShell nessa pasta: no Explorador, abra a pasta extraída, digite `powershell` na barra de endereço e pressione Enter.
4. Compile o pequeno executável localmente e crie os atalhos:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Launcher.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Desktop.ps1
```

5. Abra **AI Battery.exe** na pasta ou o atalho **AI Battery** na área de trabalho/menu Iniciar.
6. Abra o Codex desktop. A barra acompanha sua janela: fica oculta quando o Codex está minimizado ou fechado. Use o atalho para abrir/recolher o painel e o ícone da bandeja para acessar as configurações.
7. Na engrenagem, escolha cada provedor e ajuste o saldo manual de Claude/Gemini quando necessário. Configure um caminho adicional caso seu aplicativo não seja reconhecido.

Alternativa sem compilar o executável:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Start-AIBattery.ps1 -ShowPanel
```

Os comandos não exigem administrador. O Bypass vale somente para o processo; não muda a política global. Políticas corporativas podem impedir a execução. Se os arquivos baixados estiverem bloqueados pelo Windows, confira a origem antes de usar **Propriedades → Desbloquear** no ZIP e extraí-lo novamente.

## Iniciar com o Windows (opcional)

Na pasta do aplicativo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Startup.ps1
```

Para desativar:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Startup.ps1
```

Se mover a pasta, execute novamente os instaladores de atalhos e inicialização.

## O que o painel mede

| Recurso | Disponibilidade |
|---|---|
| Aplicativos abertos | Detecção local; não verifica o plano contratado |
| Quota da assinatura Codex | Via Codex CLI autenticado, quando a leitura oficial está disponível |
| Assinaturas Claude e Gemini | Saldo manual; não há leitura automática validada nesta versão |
| Operações e tokens Codex | Metadados dos arquivos locais de sessão; formatos podem mudar |
| Valor em US$ das operações | Estimativa equivalente de API, quando há tarifa cadastrada; não é cobrança da assinatura |
| Faturamento real de API | Desativado na execução atual, que usa a política `subscriptionOnly` |

O código contém adaptadores legados de custos, mas preencher uma chave não ativa a cobrança/consulta de API nesta versão. Nenhuma chave é necessária para o uso descrito aqui. A referência de preços embutida pode ficar desatualizada; modelos sem tarifa ou usos incompletos aparecem como indisponíveis.

**“—” significa sem leitura confiável**, e não consumo zero. A bateria representa saldo restante; assinatura e cobrança por tokens são medidas diferentes. O saldo manual fica atrasado após 24 horas.

## Como usar

- Arraste a barra pelos pontos no topo.
- Use **H / V** para alternar entre horizontal e vertical.
- Clique no ícone de uma IA para ver o relatório.
- Verde: acima de 40%; amarelo: de 20% a 40%; vermelho: até 20%.
- A bandeja do Windows permite acessar configurações e encerrar o monitor.

## Privacidade

As preferências e eventuais credenciais digitadas ficam em `%LOCALAPPDATA%\AIBattery`, fora do repositório. Credenciais usam DPAPI vinculado ao usuário Windows. Não compartilhe essa pasta nem arquivos `.secret`.

O painel consulta processos locais e pode ler sessões em `%USERPROFILE%\.codex\sessions` para extrair duração, operações e tokens. Não publica essas sessões. A consulta de quota conversa com o Codex CLI autenticado e os serviços do provedor.

Existe uma tentativa de integração opcional com um Cérebro **local** em `http://127.0.0.1:43127`; sem esse serviço, o painel usa a leitura local independente. Nenhum endereço de Cérebro hospedado ou credencial do autor faz parte deste pacote.

Antes de compartilhar screenshots, revise nomes e números visíveis. Nunca envie chaves em issues ou commits.

## Verificar a instalação

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Suite All
```

Os testes usam dados sintéticos. A suíte de conexão pode consultar a disponibilidade do Codex instalado e marcar indisponibilidade sem exigir login novo. Para conferir visualmente a interface, sem outra janela de teste em execução:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Smoke-UI.ps1
```

As imagens de teste são geradas em `docs/previews` e não devem ser publicadas como dados reais de consumo.

## Solução de problemas

- **Barra não aparece:** abra o Codex desktop e restaure sua janela; procure AI Battery na bandeja. Apenas abrir um terminal não equivale à janela desktop do Codex.
- **Quota indisponível:** confirme o login no Codex CLI. Não copie arquivos de autenticação de outras pessoas.
- **Claude/Gemini sem percentual:** informe um saldo manual; detecção do aplicativo não dá acesso automático à quota.
- **Atalho não funciona:** mantenha os arquivos juntos, recompile e reinstale os atalhos após mover a pasta.
- **Windows bloqueou script:** confirme o uso de `powershell.exe` e a origem do download; respeite as políticas da organização.

## Remover

Encerre o monitor pela bandeja, execute `Uninstall-Startup.ps1`, remova os atalhos e depois a pasta do aplicativo. A pasta `%LOCALAPPDATA%\AIBattery` permanece; apague-a manualmente somente se quiser remover também suas preferências e credenciais.

## Fonte e código

A fonte Inter Bold acompanha sua licença SIL Open Font License em `assets/fonts/LICENSE.txt`. O código do aplicativo é disponibilizado publicamente para consulta; nenhuma licença adicional de redistribuição foi definida nesta publicação.
