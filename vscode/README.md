<div align="center">

<img src="./media/everdock-banner.jpg" alt="Everywhere - Conectando suas IDEs ao EveryWhere" width="100%" />

# EveryWhere Code for Visual Studio Code

[English](#-english) • [Português](#-português)

</div>

---

## 🇺🇸 English

Run the official **EveryWhere Harness** autonomous AI agent everywhere directly inside Visual Studio Code.

**Everywhere** embeds and manages the authentic EveryWhere Harness agent engine (`ewh` / `dsh`) bound to your current workspace, providing the full web interface, autonomous tool pipeline, file inspection/editing, and session history directly within your IDE.

### Features

#### 1. Embedded EveryWhere Harness Webview
- **Sidebar Panel (Activity Bar)**: Open the EveryWhere Harness interface at any time from the Activity Bar icon.
- **Full Editor Tab (`EveryWhere Harness: Open in Editor Tab`)**: Maximize your workspace by running the full Harness UI inside an editor tab.
- **Autonomous Agent Tools**: Full access to all Harness capabilities:
  - File reading, searching (ripgrep/glob), and editing.
  - Subprocess and terminal execution.
  - Session history, branching, and multi-turn planning.
  - Model switching and reasoning tokens.

#### 2. Lifecycle & Workspace Process Management
- **Automatic Workspace Binding**: Harness starts with your open VS Code workspace folder as its working directory.
- **Status Bar Integration**:
  - `$(hubot) EveryWhere Harness: Active` — Shows current status and active port.
  - Quick access to start, stop, restart, or view logs.
- **Dedicated Output Channel**:
  - Live stdout/stderr logs from the Harness process available under the `EveryWhere Harness` output channel.

#### 3. Flexible Launch Modes
- Detects an installed `ewh` or `dsh` command from your system `PATH` or the extension's private storage.
- Configurable custom command/path (e.g. `ewh`, `dsh`, `pnpm dsh`).
- Configurable port and startup flags.

### Clipboard and webview behavior

The embedded UI runs in an iframe inside a VS Code webview. Text copy buttons are bridged through VS Code's native clipboard API; this does not grant clipboard-read access or change agent approval settings. Downloads are enabled in the inner iframe. Antigravity sign-in links are handed to VS Code's external browser opener instead of relying on a nested webview popup.

The extension tries the authenticated Harness URL on port 3080 when the server permits embedding and the VS Code bridge is available. Otherwise it uses the local authenticated proxy.

After installing an updated extension, run **Developer: Reload Window**. Verify copying a response/code block and pasting into an editor, downloading a file, opening a link, and completing the Antigravity sign-in. Build/unit tests do not replace this VS Code smoke check.

### Configuration

Open VS Code Settings (`Ctrl+,` or `Cmd+,`) and search for **EveryWhere**:

| Setting | Type | Default | Description |
|---|---|---|---|
| `everywhere.dshPath` | `string` | `""` | Custom command or path to harness executable (e.g. `ewh`, `dsh`, `pnpm dsh`). Auto-detects if empty. |
| `everywhere.projectPath` | `string` | `""` | Working directory for EveryWhere Harness. |
| `everywhere.port` | `number` | `0` | Port for the Harness Web server (0 assigns a random available port). |
| `everywhere.profile` | `string` | `"web"` | Profile to boot (e.g. `web`). |
| `everywhere.autoStart` | `boolean` | `true` | Automatically boot the Harness runtime when the view is opened. |
| `everywhere.apiKey` | `string` | `""` | EveryWhere API key. Reads `EVERYWHERE_API_KEY` or `DEEPSEEK_API_KEY` from environment or `.env` if blank. |
| `everywhere.baseUrl` | `string` | `https://api.deepseek.com` | EveryWhere API endpoint base URL. |

### Build & Install

```sh
# 1. Build extension bundle
node scripts/build.mjs

# 2. Package into .vsix
node scripts/package.mjs

# 3. Install into VS Code
code --install-extension everywhere-1.2.6.vsix
```

---

## 🇧🇷 Português

Execute o agente autônomo oficial **EveryWhere Harness** em qualquer lugar diretamente no Visual Studio Code.

O **Everywhere** incorpora e gerencia o motor autêntico do EveryWhere Harness (`ewh` / `dsh`) vinculado ao seu workspace atual, fornecendo interface web completa, pipeline de ferramentas autônomas, inspeção e edição de arquivos e histórico contínuo de sessões diretamente na sua IDE.

### Funcionalidades

#### 1. Webview Embutido do EveryWhere Harness
- **Painel na Barra Lateral (Activity Bar)**: Abra a interface do EveryWhere Harness a qualquer momento clicando no ícone da Activity Bar.
- **Aba Dedicada no Editor (`EveryWhere Harness: Open in Editor Tab`)**: Maximize sua área de trabalho executando a interface completa do Harness em uma aba do editor.
- **Ferramentas do Agente Autônomo**: Acesso irrestrito a todos os recursos do Harness:
  - Leitura, busca (ripgrep/glob) e edição de arquivos em tempo real.
  - Execução de comandos no terminal e subprocessos.
  - Histórico de sessões, ramificações e planejamento multi-turn.
  - Alternância de modelos e tokens de raciocínio.

#### 2. Gerenciamento do Ciclo de Vida e Workspace
- **Vínculo Automático com o Workspace**: O Harness inicia automaticamente com a pasta aberta no VS Code como diretório raiz de trabalho.
- **Integração com a Barra de Status**:
  - `$(hubot) EveryWhere Harness: Active` — Exibe o status atual e a porta em uso.
  - Acesso rápido para iniciar, parar, reiniciar ou exibir logs.
- **Canal de Saída Dedicado**:
  - Logs em tempo real de stdout/stderr disponíveis no canal de saída `EveryWhere Harness`.

#### 3. Modos Flexíveis de Inicialização
- Detecta automaticamente o comando `ewh` ou `dsh` instalado no `PATH` do sistema ou no armazenamento privado da extensão.
- Permite configurar comando/caminho personalizado (ex: `ewh`, `dsh`, `pnpm dsh`).
- Permite personalizar porta e parâmetros de inicialização.

### Cópia e autenticação no webview

O chat roda em um iframe dentro do webview do VS Code. A cópia de texto usa a área de transferência nativa do VS Code; isso não libera leitura da área de transferência nem altera aprovações do agente. Downloads são habilitados no iframe. Os links de login do Antigravity são encaminhados ao navegador externo pelo VS Code, sem depender de um popup aninhado no webview.

A extensão tenta usar o endereço autenticado do Harness na porta 3080 quando o servidor permite incorporação e a ponte VS Code está disponível. Caso contrário, usa o proxy local autenticado.

Após instalar a extensão atualizada, execute **Developer: Reload Window**. Confira copiar uma resposta/bloco de código e colar no editor, baixar um arquivo e concluir o login do Antigravity. Compilação e testes automatizados não substituem essa verificação no VS Code.

### Configurações

Abra as Configurações do VS Code (`Ctrl+,` ou `Cmd+,`) e pesquise por **EveryWhere**:

| Configuração | Tipo | Padrão | Descrição |
|---|---|---|---|
| `everywhere.dshPath` | `string` | `""` | Comando ou caminho customizado para o executável (ex: `ewh`, `dsh`, `pnpm dsh`). Auto-detecta se vazio. |
| `everywhere.projectPath` | `string` | `""` | Diretório de trabalho para o EveryWhere Harness. |
| `everywhere.port` | `number` | `0` | Porta do servidor web do Harness (0 atribui uma porta livre aleatória). |
| `everywhere.profile` | `string` | `"web"` | Perfil a ser iniciado (ex: `web`). |
| `everywhere.autoStart` | `boolean` | `true` | Inicializar automaticamente o runtime ao abrir a visualização. |
| `everywhere.apiKey` | `string` | `""` | Chave de API EveryWhere (também lê `EVERYWHERE_API_KEY` ou `DEEPSEEK_API_KEY` do ambiente ou `.env`). |
| `everywhere.baseUrl` | `string` | `https://api.deepseek.com` | URL base do endpoint da API EveryWhere. |

### Compilação e Instalação

```sh
# 1. Compilar o bundle da extensão
node scripts/build.mjs

# 2. Empacotar no formato .vsix
node scripts/package.mjs

# 3. Instalar no VS Code
code --install-extension everywhere-1.2.6.vsix
```
