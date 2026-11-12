# Compatibilidade e política de validação

**Estado: experimental; homologação de todos os alvos pendente.** A fonte de dados
legível por ferramentas é [compatibility.json](<../compatibility.json>). O código
segue a [licença MIT](<../../LICENSE>), sem redistribuição de SDKs proprietários.

## Matriz candidata

| Alvo | Arquitetura da IDE | Build do pacote | Evidência desta entrega |
| --- | --- | --- | --- |
| RAD Studio 12 Athens | 32 bits | Win32 | Candidato, não compilado/homologado. |
| RAD Studio 13 Florence | 32 bits | Win32 | Candidato, não compilado/homologado. |
| RAD Studio 13 Florence | 64 bits | Win64 | Candidato, não compilado/homologado. |

A matriz trata do **processo da IDE**, não dos alvos de compilação da aplicação.
Não se afirma suporte a toda edição, update, hotfix ou versão atual/futura.
O build Win64 não torna a mesma BPL carregável em uma IDE Win32. Compilar para uma
versão não comprova ABI compatível com outra. Headers OTA instalados não são
prova de compilação nem de execução.

Referências oficiais para a avaliação dos candidatos:

- [RAD Studio Athens](https://docwiki.embarcadero.com/RADStudio/Athens/en/Main_Page).
- [Florence: IDE 64-bit](https://docwiki.embarcadero.com/RADStudio/Florence/en/64-bit_IDE):
  pacotes design-time precisam de build 64 bits separado e diretório distinto;
  não instalar os pacotes no diretório `bin64` da IDE. Página consultada durante a
  implementação; confirmar disponibilidade de compilador, componentes e OTA na
  edição/update exatos usados na homologação.
- [TEdgeBrowser e WebView2](https://docwiki.embarcadero.com/Libraries/Florence/en/Vcl.Edge.TEdgeBrowser):
  dependências e limitações precisam ser verificadas na versão instalada.

## Evidências e limites atuais

O usuário confirmou compilação e instalação da revisão anterior via IDE 13.2
Win32 e depois relatou docking/renderização funcionando. A falha de início
registrada era conflito na porta 3080 (`EADDRINUSE`). A revisão de barra compacta
e área web ampliada precisa ser recompilada e retestada.
A Trial instalada recusa compilação de linha de comando; CI nativa ainda depende
de licença adequada. Não foram incluídos SDKs/redistribuíveis no repositório.
Os testes de contrato não substituem o compilador nem homologam os alvos.
O painel usa `INTACustomDockableForm` e frame VCL: pode ser arrastado para a IDE,
sem aba de editor. Validar salvar/restaurar layout e descarregar pacote.
FMX é contexto de projeto; não existe adaptação de designer. Não duplicar
ferramentas Enterprise licenciadas. Consulte a [matriz funcional](<../README.md#paridade-honesta>).

## Política proposta D0, D7, D21, D30

**Dono: Engenharia V&D. Aprovação: ainda necessária.** Janela proposta de 30 dias
corridos a partir da publicação de uma nova versão/update relevante do fornecedor.
Trata-se de planejamento operacional, **não certificação automática, garantia
contratual de suporte ou promessa já aprovada**. Sem evidência, manter candidato.

| Marco | Ação / entrega | Responsável |
| --- | --- | --- |
| D0 | Registrar release/update, versão exata, arquitetura, licença disponível e ticket; nomear executor e aprovador. | Engenharia V&D |
| D7 | Triar mudanças OTA/VCL, compilador, ABI, WebView2, Delphi/C++Builder; registrar riscos e bloqueios. | Engenharia V&D |
| D21 | Compilar por alvo em ambiente licenciado, executar protocolo e smoke tests; anexar evidências sanitizadas e regressões. | Engenharia V&D |
| D30 | Publicar decisão: homologar com evidências e limites, manter experimental ou suspender; documentar bloqueador e novo plano se pendente. | Engenharia V&D + aprovador designado |

Ausência de licença, falha de build ou prazo vencido não autoriza marcar
`validated: true`. Atualize metadados, testes de contrato e documentação juntos,
com rastreabilidade do ticket e aprovação. Não publicar credenciais, tokens ou
URLs de sessão nas evidências.

## Checklist por alvo

Preencher uma cópia por **versão completa/update/arquitetura**, anexando ticket,
executor, data e resultado; não marcar itens somente por inspeção de strings.

- [ ] Dono Engenharia V&D confirmou executor, aprovador e aprovação da política.
- [ ] Registrar produto, edição, versão completa, hotfixes, arquitetura da IDE,
      Windows, compilador licenciado, WebView2 Runtime/loader e versão do Harness.
- [ ] Build limpo do pacote e execução dos testes Delphi de protocolo com
      `-RunTests`; preservar logs sanitizados, saída e identificação do commit.
- [ ] Instalar BPL em **Install Packages**, reiniciar IDE e verificar menu OTA;
      desinstalar e reinstalar sem erro ou dependência de artefato antigo.
- [ ] Confirmar criação/navegação WebView2 assíncronas, HRESULT acessível em Diagnósticos se faltar loader,
      parar/reiniciar durante navegação e recuperação via Recarregar; loader da arquitetura correta e fallback
      por navegador externo quando indisponível; registrar falha separadamente.
- [ ] Projetos Delphi e C++Builder ativos: diretório correto, espaços/Unicode,
      projeto não salvo, ausência de projeto e troca de projeto + Reiniciar.
- [ ] Docking com sessão aberta: flutuante/acoplado/abas, resize, minimizar/restaurar,
      monitor/DPI e movimento durante criação WebView2; verificar ausência de tela
      branca, recarga contínua e mudança do PID do runtime durante docking.
- [ ] Iniciar/parar/reiniciar/recarregar: interface responsiva, estados coerentes,
      processo próprio encerrado ao fechar janela/IDE, sem processo órfão.
- [ ] Runtime ausente, instalação explícita, executável inválido, perfil web e
      perfil inválido; erro útil, sem instalação durante carga do pacote.
- [ ] Porta 0 usa padrão do runtime; porta explícita e ocupada, sem reutilizar ou
      encerrar serviço alheio. Conferir que outro processo permanece vivo.
- [ ] URL aceita só origem local prevista; token em memória, logs sanitizados,
      INI sem segredos; revisar persistência do perfil WebView2/navegador/runtime.
- [ ] Validar credenciais herdadas sem imprimir valores e permissões do workspace;
      execução não requer privilégios administrativos desnecessários.
- [ ] Testar docking, redimensionamento, fechar/reabrir, layout e ausência de aba editor;
      confirmar que não duplica ferramentas Enterprise.
- [ ] Revisar política de redistribuição WebView2/Embarcadero: nenhum SDK/header/DLL
      proprietário no Git ou nos artefatos fonte.
- [ ] Aprovador registrou decisão, evidências e restrições; atualizar
      [metadados](<../compatibility.json>) somente após revisão.
