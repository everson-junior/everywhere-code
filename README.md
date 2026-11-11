<div align="center">

<img src="./assets/everdock-banner.jpg" alt="EveryWhere Harness - Conectando suas IDEs ao EveryWhere" width="100%" />

# EveryWhere Harness 🌐⚡

**EveryWhere Harness — Connecting your IDEs to EveryWhere**

[![VS Code Extension](https://img.shields.io/badge/VS%20Code-Extension-blue?logo=visualstudiocode)](./vscode)
[![Visual Studio 2022](https://img.shields.io/badge/Visual%20Studio-2022%20(v17.0%2B)-purple?logo=visualstudio)](./visualstudio)
[![IntelliJ IDEA](https://img.shields.io/badge/IntelliJ%20IDEA-JetBrains%20Marketplace%20%2335191-fe2857?logo=intellijidea)](https://plugins.jetbrains.com/plugin/35191)
[![Eclipse IDE](https://img.shields.io/badge/Eclipse%20IDE-2026--09%20(4.41.0)-2c2255?logo=eclipseide)](./eclipse)
[![EveryWhere](https://img.shields.io/badge/AI-EveryWhere-007acc)](https://deepseek.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Active%20Development-success)]()

[English](#-english) • [Português](#-português)

</div>

---

## 🇺🇸 English

*EveryWhere is the definitive bridge to run the EveryWhere Harness anywhere — bringing autonomous intelligence directly into your daily development environment and workflow.*

### 📖 Overview

**EveryWhere** turns your editor into a complete command center for **EveryWhere** intelligent agents. The name **EveryWhere** reflects the flexibility of running the assistant anywhere: it automates the installation, boot, and lifecycle management of the official **EveryWhere Harness (`ewh` / `dsh`)** runtime, binding it natively to your active workspace.

With EveryWhere, intelligent AI models gain supervised access to your real project context: code inspection, file editing, integrated terminal execution, continuous session history, and autonomous tools with zero complex setup.

### ✨ Key Features

- 🌐 **EveryWhere Anywhere**: Seamless management and execution of the `ewh` runtime across any project.
- 🤖 **Embedded Autonomous Agent**: High-performance Webview panel in sidebars and dedicated full editor tabs.
- 🔄 **Auto-Recovery & Resilience**: Automatic handling for busy ports (3080/3000) and cleanup of orphaned processes with transparent reconnection on exit code 1.
- 📂 **Real Workspace Context**: The agent runs bound to your open project directory, ensuring pinpoint accuracy in terminal commands and code modifications.
- 🛡️ **Secure Session Proxy**: Automatic cookie-signed authentication handshake and iframe restriction neutralization (`CSP`/`X-Frame-Options`).
- ⚡ **Full Lifecycle Control**: Fast start, restart, and shutdown with live real-time output channel logs.
- ⚙️ **Multi-Profile Support**: Compatible with EveryWhere Harness profiles (`web`, `headless`, `tui`) and custom API keys.

### 🧩 Available Extensions

| IDE | Technology | Distribution | Documentation |
|---|---|---|---|
| **VS Code** | TypeScript, Webview | Visual Studio Marketplace (`.vsix`) | [VS Code README](./vscode/README.md) |
| **Visual Studio 2022** | C#, WPF, Microsoft Edge WebView2 | Visual Studio Marketplace (`.vsix`) | [Visual Studio README](./visualstudio/README.md) |
| **IntelliJ IDEA** | Kotlin, Gradle, JCEF Chromium | [JetBrains Marketplace](https://plugins.jetbrains.com/plugin/35191) (Plugin #35191) | [IntelliJ README](./intellij/README.md) |
| **Eclipse IDE** | Java 17+, OSGi Tycho, SWT Browser | [Eclipse Marketplace](https://marketplace.eclipse.org/content/everywhere-deepseek-harness) (p2 Site) | [Eclipse README](./eclipse/README.md) |

<br/>

<div align="center" style="display: flex; gap: 16px; justify-content: center; align-items: center; flex-wrap: wrap;">
  <a href="https://plugins.jetbrains.com/plugin/35191" target="_blank" rel="noopener">
    <img src="https://img.shields.io/badge/JetBrains%20Marketplace-Install%20in%20IntelliJ-fe2857?style=for-the-badge&logo=intellijidea&logoColor=white" alt="Install EveryWhere in IntelliJ IDEA from JetBrains Marketplace"/>
  </a>
  <a href="https://marketplace.eclipse.org/content/everywhere-deepseek-harness" target="_blank" rel="noopener">
    <img src="https://marketplace.eclipse.org/sites/all/modules/custom/marketplace/images/installbutton.png" alt="Drag and drop into a running Eclipse IDE to install EveryWhere Harness in Eclipse"/>
  </a>
</div>

---

## 🇧🇷 Português

*EveryWhere é a ponte definitiva para rodar o EveryWhere Harness em qualquer lugar — trazendo a inteligência autônoma diretamente para o seu ambiente de desenvolvimento e fluxo de trabalho diário.*

### 📖 Visão Geral

O **EveryWhere** transforma o seu editor em uma central completa para agentes inteligentes do **EveryWhere**. O nome **EveryWhere** reflete a flexibilidade de poder rodar o assistente em qualquer lugar: ele automatiza a instalação, inicialização e gerenciamento do runtime oficial do **EveryWhere Harness (`ewh` / `dsh`)**, integrando-o nativamente ao seu workspace.

Com isso, os modelos ganham acesso supervisionado ao contexto real do projeto: edição e inspeção de código, execução no terminal integrado, histórico contínuo de sessões e ferramentas autônomas sem a necessidade de configurações complexas.

### ✨ Recursos Principais

- 🌐 **EveryWhere em Qualquer Lugar**: Gerenciamento e instalação transparente do runtime `ewh`, permitindo o uso ágil em qualquer projeto.
- 🤖 **Agente Autônomo Embutido**: Painel Webview de alta performance na barra lateral e em abas dedicadas do editor (`Editor Tab`).
- 🔄 **Auto-Recuperação & Resiliência**: Tratamento automático para portas ocupadas e encerramento de processos órfãos — reconexão transparente caso ocorra falha inicial de conexão (`exit code 1`).
- 📂 **Contexto Real do Workspace**: O agente roda vinculado à pasta do seu projeto aberto, garantindo precisão em comandos de terminal e edição de código.
- 🛡️ **Proxy de Sessão Seguro**: Handshake de autenticação automático via cookies assinados e neutralização de restrições de iframe (`CSP`/`X-Frame-Options`).
- ⚡ **Gerenciamento de Ciclo de Vida**: Início rápido, reinicialização e parada direta de processos com logs em tempo real no canal de saída.
- ⚙️ **Suporte a Múltiplos Perfis**: Compatível com perfis do EveryWhere Harness (`web`, `headless`, `tui`) e chaves personalizadas de API.

### 🧩 Extensões Disponíveis

| IDE | Tecnologia | Distribuição | Documentação |
|---|---|---|---|
| **VS Code** | TypeScript, Webview | Visual Studio Marketplace (`.vsix`) | [README do VS Code](./vscode/README.md) |
| **Visual Studio 2022** | C#, WPF, Microsoft Edge WebView2 | Visual Studio Marketplace (`.vsix`) | [README do Visual Studio](./visualstudio/README.md) |
| **IntelliJ IDEA** | Kotlin, Gradle, JCEF Chromium | [JetBrains Marketplace](https://plugins.jetbrains.com/plugin/35191) (Plugin #35191) | [README do IntelliJ](./intellij/README.md) |
| **Eclipse IDE** | Java 17+, OSGi PDE, SWT Browser | Plugin Eclipse (`.jar`) | [README do Eclipse](./eclipse/README.md) |

---

## RAD Studio / Embarcadero (experimental)

A new Delphi design-time package targets **Delphi and C++Builder** projects in RAD Studio, hosting the same `ewh`/`dsh` web runtime used by the other extensions. Includes lifecycle actions, project-directory binding, WebView2, runtime installation and settings. **Native compilation, IDE smoke tests and full UI parity are pending; this is not a certified release.**

Novo pacote Delphi para projetos **Delphi e C++Builder**, incluindo contexto de projetos FMX sem substituir ferramentas nativas Enterprise. A janela inicial não oferece docking nem aba de editor. A meta de atualização em até 30 dias depende do processo de manutenção e homologação descrito na documentação.

- [Build, installation and feature matrix / Instalação e funcionalidades](<embarcadero/README.md>)
- [Compatibility and 30-day maintenance policy / Compatibilidade e manutenção](<embarcadero/docs/COMPATIBILITY.md>)

---

## 📁 Estrutura do Projeto / Project Structure

```text
everywhere/
├── .github/workflows/
│   └── release.yml             # CI/CD: Multi-IDE packaging & Marketplace publishing
├── assets/                     # Banners & icons
├── visualstudio/               # Microsoft Visual Studio 2022 extension (C# / WPF / VSIX)
├── intellij/                   # IntelliJ IDEA 2024.1+ plugin (Kotlin / Gradle / JCEF)
├── eclipse/                    # Eclipse IDE 2026-09 plugin (Java 17+ / OSGi / SWT Browser)
├── vscode/                     # Visual Studio Code extension (TypeScript / Webview)
└── README.md                   # Main Project Hub
```

---

## 📄 Licença / License

Distribuído sob os termos da licença [MIT](LICENSE).
Distributed under the terms of the [MIT](LICENSE) License.
