# EveryWhere Harness para RAD Studio — experimental

Pacote Delphi Open Tools API (OTA) para **Delphi e C++Builder**, com menu da IDE,
janela VCL **modeless** e navegador `TEdgeBrowser` (WebView2). O workspace é o
diretório do projeto ativo salvo. **Não há docking nem aba de editor nesta etapa.**
O código novo segue a licença [MIT do repositório](<../LICENSE>).

**Nenhuma versão da IDE está homologada.** Os candidatos são RAD Studio 12 Athens
(IDE de 32 bits) e 13 Florence (IDE de 32/64 bits); veja a
[matriz e política](<docs/COMPATIBILITY.md>) e os
[metadados verificáveis](<compatibility.json>). Compilar não equivale a homologar.

## Pré-requisitos

- Windows, instalação **licenciada do compilador Delphi** e bibliotecas OTA/VCL da
  versão/arquitetura da IDE. Uma instalação somente C++Builder, headers C++ ou
  arquivos DCP isolados não substituem `dcc32.exe`/`dcc64.exe`.
- Microsoft Edge WebView2 Runtime instalado e `WebView2Loader.dll` da arquitetura
  **da IDE**, obtida dos redistribuíveis oficiais da sua instalação RAD Studio.
  Configure sua localização conforme a documentação do fornecedor; mantenha a DLL
  em diretório pesquisável pelo carregador do processo da IDE (por exemplo, um
  diretório dedicado no `PATH` antes de abrir a IDE). Confirme o carregamento no
  smoke test: estar ao lado da BPL não garante a busca da DLL por toda versão.
  Não copiar a DLL ou qualquer binário proprietário para este repositório.
- Runtime EveryWhere/DeepSeek Harness (`ewh`/`dsh`) instalado, ou Node.js/npm para a
  instalação explícita pela janela. A versão do runtime deve oferecer perfil web
  e emissão de URL local compatível com o protocolo implementado.
- Credenciais/configuração de provedores pertencem ao runtime, herdadas do ambiente
  da IDE. Configure-as **antes** de abrir a IDE; não as coloque nas opções do pacote.

No ambiente de desenvolvimento inspecionado, a instalação em
`C:/Program Files (x86)/Embarcadero/Studio/37.0` contém headers C++ mas não contém
executáveis `dcc`. Portanto **não houve build Delphi nem smoke test da IDE**.
Nenhum header ou binário dessa instalação foi copiado.

## Build manual (PowerShell)

Execute na raiz do repositório, com o ambiente da instalação RAD Studio licenciada:

```powershell
# Exemplo: substitua Bds pela raiz real da sua instalação com Delphi.
.\embarcadero\scripts\build.ps1 -Bds 'C:\Program Files (x86)\Embarcadero\Studio\37.0' -Platform Win32 -RunTests
.\embarcadero\scripts\build.ps1 -Bds 'C:\Program Files (x86)\Embarcadero\Studio\37.0' -Platform Win64 -RunTests
```

O [script](<scripts/build.ps1>) exige `-Bds`, aceita `-Platform Win32|Win64`
(padrão Win32) e procura o compilador correspondente em `Bds/bin`. Não baixa nem
contorna licenciamento. Valida as bibliotecas `lib/<platform>/release` e
`designide.dcp` antes de compilar. A plataforma é a **arquitetura da IDE que carrega
a BPL**, não a plataforma do projeto Delphi/C++Builder em edição.

O pacote [EverywhereRAD](<EverywhereRAD.dpk>) gera
`embarcadero/build/<platform>/EverywhereRAD.bpl`, DCP no mesmo diretório e DCUs em
`dcu/`. `-RunTests` compila e executa os
[testes Delphi do protocolo](<tests/ProtocolTests.dpr>); qualquer erro de compilação
ou execução retorna falha. Faça builds de versões distintas em checkouts limpos
ou limpe o diretório de saída: versões da IDE não podem compartilhar a mesma BPL.
O script não instala o pacote nem publica release.

## Instalação e remoção manuais

1. Compile para a versão exata do RAD Studio e arquitetura da IDE a usar. Para a
   IDE 32 bits, Win32; para a IDE 64 bits do Florence, Win64. Não misture BPL/DCP/DCU
   de versões/arquiteturas. Não mova pacotes para as pastas `bin`/`bin64` da IDE.
2. Instale WebView2 Runtime e disponibilize o loader oficial da arquitetura correta.
3. Na IDE, abra **Component > Install Packages > Add** e escolha a BPL produzida.
   Os nomes do menu podem variar conforme idioma/versão. Confirme a carga sem erro.
4. Abra e salve um projeto Delphi ou C++Builder; abra o menu **EveryWhere Harness**.
   Configure executável/perfil e clique **Iniciar**. Sem projeto salvo ativo o
   runtime não inicia: não há fallback silencioso para outra pasta.
5. Execute o [checklist de homologação](<docs/COMPATIBILITY.md#checklist-por-alvo>)
   antes de autorizar uso. A disponibilidade do navegador externo não prova
   funcionamento do WebView2 embarcado.

Para remover: pare/feche a janela, desmarque/remova o pacote em **Install Packages**,
feche a IDE e só então apague os artefatos de build. A configuração local e o
perfil WebView2 podem ser removidos separadamente após fechar a IDE.

## Operação e limites

| Controle | Comportamento atual |
| --- | --- |
| Iniciar | Inicia processo próprio no diretório do projeto Delphi/C++Builder ativo salvo. |
| Parar | Interrompe o processo próprio e limpa a URL em memória; não encerra processos pela porta. |
| Reiniciar | Para e inicia novamente, relendo o projeto ativo e as opções atuais. |
| Recarregar | Navega novamente para a URL da sessão; não reinicia o processo. |
| Navegador | Abre a URL da sessão no navegador externo padrão. |
| Configurações | Executável, perfil, porta e início ao abrir a janela; não há campo de credencial. |
| Instalar runtime | Instalação explícita pelo runtime/npm, nunca durante a carga do pacote. |

O perfil padrão é `web`; um perfil personalizado deve disponibilizar a interface
web. O nome aceita 1–64 letras ASCII, números, `_` ou `-` e deve começar com
letra ou número. **Porta 0 omite a opção de porta e usa o padrão do runtime; não garante porta
aleatória.** Portas explícitas aceitam 1–65535. Conflitos são falhas a diagnosticar:
o pacote não reutiliza serviços de terceiros, não toma posse deles e não mata
processos por porta. Trocar o projeto ativo não troca um processo já iniciado:
use **Reiniciar**. Fechar a janela para o processo próprio; ela é ocultada e pode
ser aberta novamente. Início automático é desativado por padrão.

A API interna é `Start(Workspace, Executable, Profile: string; Port: Integer)`,
`Stop`, `Install` e `Poll` chamado pelo timer da UI. Veja
[runtime](<src/Everywhere.Runtime.pas>) e [protocolo](<src/Everywhere.Protocol.pas>).
Essa API não é promessa de compatibilidade binária pública.

### Contrato inicial do runtime

- Executável e workspace usam caminhos locais absolutos com letra de unidade;
  compartilhamentos UNC não são suportados nesta etapa. Executáveis personalizados
  aceitam `.exe` ou `.cmd`; caminhos `.cmd` com metacaracteres de shell são rejeitados.
- Perfil: até 64 caracteres ASCII alfanuméricos, hífen e sublinhado, começando com
  letra ou número. Perfis sem interface web resultarão em timeout.
- Readiness aceita anúncio `ewh web:` ou `dsh web:` com URL
  `http://127.0.0.1:<porta>/`, opcionalmente `?token=<token>` base64/base64url.
  O sufixo informativo ` (LAN: ...)` é descartado; nunca se navega para a URL LAN.
  `localhost`, IPv6, caminhos alternativos e tokens percent-encoded não são aceitos.
- Timeout de início: 60 segundos; instalação: 10 minutos. Não há reinício
  automático em falhas nem adoção de serviços preexistentes.
- O botão instala somente `@everywhere-harness/ewh`. Caso o instalador de plugins
  do Harness exija `pnpm`, instale-o separadamente conforme a documentação do runtime.

### Configuração e segurança

As opções não secretas ficam em `%LOCALAPPDATA%/Everywhere/RADStudio/settings.ini`.
O pacote não grava credenciais nem URL/token de sessão nesse INI; a URL de
navegação fica em memória e os logs exibidos são sanitizados. **Isso não garante
que dados nunca cheguem ao disco**: o perfil WebView2 é persistente em
`%LOCALAPPDATA%/Everywhere/RADStudio/WebView2`, e runtime, navegador externo,
histórico/cache e variáveis de ambiente têm seus próprios riscos e políticas.
Não compartilhe URLs de sessão, dumps, logs brutos ou arquivos de perfil.
Não execute projetos não confiáveis nem instale runtimes sem verificar sua origem.

### Paridade honesta

| Recurso | Estado inicial RAD Studio |
| --- | --- |
| Menu OTA + janela VCL modeless + WebView2 | Implementado em fonte; validação nativa pendente. |
| Lifecycle, perfil, porta, logs e instalação explícita | Implementado em fonte; smoke tests pendentes. |
| Projeto Delphi/C++Builder ativo como workspace | Implementado em fonte; exige projeto salvo. |
| Docking / aba de editor / restauração do layout da IDE | **Não implementado.** |
| Reuso de serviço alheio / encerramento por porta | **Não suportado por segurança.** |
| Integração de designer FireMonkey (FMX) | **Não implementada**; FMX é somente contexto do projeto. |
| Substituir ferramentas Enterprise | **Fora de escopo**; não duplicar recursos licenciados de análise, banco de dados, modelagem ou depuração. |

## Validação sem licença

```powershell
python -B -m unittest discover -s embarcadero/tests -p "test_*.py" -v
```

Os [testes estáticos](<tests/test_contract.py>) verificam metadados, caminhos e
unidades do pacote, ausência de binários/headers proprietários e caminhos de erro
reais do PowerShell (quando disponível). A
[CI dedicada](<../.github/workflows/validate-embarcadero.yml>) executa apenas esses
contratos Python em Windows; **não compila Delphi, não instala a IDE e não publica
BPL automaticamente**. Testes estáticos não validam ABI, OTA, WebView2 ou UX.


## GitHub Actions: gerar o artefato BPL

O [workflow de build nativo](<../.github/workflows/build-embarcadero.yml>) pode ser
executado sozinho por **Actions > Build RAD Studio package > Run workflow** ou
chamado pelo [pipeline multi-IDE](<../.github/workflows/release.yml>). Ele gera um
ZIP em **Artifacts**, com BPL, instruções de instalação, licença, documentação e
manifesto com commit, versão do compilador e SHA-256. Não anexa automaticamente
esse pacote experimental aos assets públicos da Release nem o homologa.

### Preparação obrigatória pelo administrador

1. Disponibilize runner **self-hosted Windows**, dedicado/isolado, com Git,
   Windows PowerShell 5.1 e Delphi licenciado para a conta que executa o serviço.
   Confirme que os termos da licença permitem esse uso em CI. Não envie arquivos
   de licença nem chaves ao Git, aos logs ou aos artefatos.
2. Configure as labels `self-hosted`, `Windows`, `radstudio` e **uma** label de alvo:
   `rad12-win32`, `rad13-win32` ou `rad13-win64`. A label identifica a instalação
   realmente provisionada, não comprova compatibilidade. Use runners separados
   para instalações distintas. RAD Studio 10 não está habilitado nesta matriz.
3. No ambiente da conta/serviço do runner, configure `RADSTUDIO_BDS` com a raiz
   da instalação licenciada. Reinicie o serviço após configurar. Garanta que o
   ambiente do compilador funciona nessa conta (bibliotecas OTA/VCL e licença);
   não basta funcionar na sessão interativa de outro usuário.
4. Crie o environment GitHub **`radstudio-ci`**, configure revisores obrigatórios
   e restrinja branches/tags autorizadas. Restrinja também o grupo do runner ao
   repositório. Nunca aprove código de PR/fork ou ref não revisada nesse ambiente.
   O workflow não possui gatilho de pull request e não mantém credencial Git no checkout.
5. Em **Settings > Secrets and variables > Actions > Variables**, configure:

   | Variável de repositório | Valor |
   | --- | --- |
   | `RADSTUDIO_CI_ENABLED` | `true`, somente depois de provisionar o runner |
   | `RADSTUDIO_CI_TARGET` | `rad13-win32` (padrão), `rad12-win32` ou `rad13-win64` |

   O alvo manual é escolhido no formulário. A variável de alvo é usada pelo
   pipeline multi-IDE. Sem o opt-in, o job multi-IDE é ignorado, e uma execução
   manual falha no preflight hospedado, sem aguardar runner inexistente. Com o
   opt-in mas sem runner online com as labels corretas, o job ficará na fila.
6. Execute inicialmente o workflow manual em ref revisada. Após sucesso, abra
   **Artifacts > everywhere-embarcadero-<alvo>-<commit>** e extraia o ZIP interno.
   Instale a BPL pela opção **Component > Install Packages > Add** da IDE correta.

O build limpa saídas antigas, exige compilação e testes Delphi de protocolo,
registra a versão do compilador e só então empacota arquivos de uma lista explícita.
Não inclui executável dos testes, DCP/DCU, SDKs, WebView2Loader nem licenças de terceiros.
`build-manifest.json` no ZIP é a evidência do build; os metadados de compatibilidade
do repositório continuam experimentais até os smoke tests da IDE serem aprovados.
Nenhum runner/licença foi provisionado e nenhuma BPL foi gerada nesta alteração.
