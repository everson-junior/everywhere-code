import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { runInNewContext } from 'node:vm'
import ts from 'typescript'
import http from 'node:http'

const require = createRequire(import.meta.url)
function loadSource(name, dependencies = {}, suffix = '') {
  const source = readFileSync(new URL(`../src/${name}.ts`, import.meta.url), 'utf8')
  const { outputText } = ts.transpileModule(source + suffix, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true },
  })
  const exports = {}
  runInNewContext(outputText, {
    exports, require: name => dependencies[name] ?? require(name),
    URL, Buffer, process, setTimeout, clearTimeout, console, AbortSignal,
  })
  return exports
}
const bridge = loadSource('webviewBridge')

function browser({ embedded = true, nativeWrite } = {}) {
  const messages = []
  const timers = new Map()
  let listener
  let timerId = 0
  const parent = { postMessage: (data, origin) => messages.push({ data, origin }) }
  const nativeOpened = []
  const window = { parent, location: { href: 'http://127.0.0.1:4567/?token=auth#/session/selected' }, addEventListener: (_, fn) => { listener = fn }, open: (...args) => { nativeOpened.push(args); return null } }
  if (!embedded) window.parent = window
  const navigator = { clipboard: { writeText: nativeWrite } }
  const html = bridge.injectHarnessBridge('<html><head><script>app()</script></head></html>')
  const script = html.match(/<script data-ewh-webview-bridge>([\s\S]*?)<\/script>/)[1]
  runInNewContext(script, {
    window, navigator, URL, CustomEvent,
    setTimeout: fn => { timers.set(++timerId, fn); return timerId },
    clearTimeout: id => timers.delete(id),
  })
  const origin = 'vscode-webview://trusted'
  return {
    navigator, messages, timers, parent, window, nativeOpened,
    receive(data, overrides = {}) { listener?.({ source: parent, origin, data, ...overrides }) },
    init() { this.receive({ type: 'ewh/bridge-init' }) },
  }
}

describe('Harness clipboard bridge', () => {
  it('installs before app scripts and preserves the document', () => {
    const html = bridge.injectHarnessBridge('<!DOCTYPE html><html><HEAD lang="en"><script>app()</script></HEAD></html>')
    assert.ok(html.indexOf('data-ewh-webview-bridge') < html.indexOf('app()'))
    assert.ok(html.startsWith('<!DOCTYPE html>'))
  })

  it('does not modify the clipboard in a top-level browser', () => {
    const nativeWrite = () => Promise.resolve()
    assert.equal(browser({ embedded: false, nativeWrite }).navigator.clipboard.writeText, nativeWrite)
  })

  it('writes via the parent and resolves only after native success, including empty text', async () => {
    const page = browser()
    page.init()
    assert.equal(page.messages[0].data.type, 'ewh/bridge-ready')
    let done = false
    const result = page.navigator.clipboard.writeText('').then(() => { done = true })
    const { data, origin } = page.messages[1]
    assert.equal(data.type, 'dsh/copy')
    assert.equal(data.text, '')
    assert.equal(origin, 'vscode-webview://trusted')
    await Promise.resolve()
    assert.equal(done, false)
    page.receive({ type: 'ewh/copy-result', requestId: data.requestId, ok: true })
    await result
    assert.equal(page.timers.size, 0)
  })

  it('rejects native failures and timed-out requests', async () => {
    const page = browser()
    page.init()
    const result = page.navigator.clipboard.writeText('text')
    page.receive({ type: 'ewh/copy-result', requestId: page.messages[1].data.requestId, ok: false })
    await assert.rejects(result, /could not copy/)
    const timedOut = page.navigator.clipboard.writeText('next')
    for (const fn of page.timers.values()) fn()
    await assert.rejects(timedOut, /timed out/)
  })

  it('ignores messages from other frames and origins', async () => {
    const page = browser()
    page.receive({ type: 'ewh/bridge-init' }, { source: {} })
    assert.equal(page.messages.length, 0)
    page.init()
    let done = false
    const result = page.navigator.clipboard.writeText('secret').then(() => { done = true })
    const ack = { type: 'ewh/copy-result', requestId: page.messages[1].data.requestId, ok: true }
    page.receive(ack, { origin: 'https://evil.invalid' })
    page.receive(ack, { source: {} })
    await Promise.resolve()
    assert.equal(done, false)
    page.receive(ack)
    await result
  })

  it('hands delayed Antigravity OAuth popup navigation to the VS Code host', () => {
    const page = browser()
    page.init()
    const popup = page.window.open('about:blank', '_blank')
    assert.equal(popup.opener, null)
    popup.location.replace('https://accounts.google.com/o/oauth2/auth?state=test')
    assert.equal(page.nativeOpened.length, 0, 'avoid the blocked nested webview popup')
    assert.equal(page.messages[1].data.type, 'dsh/open-external')
    assert.equal(page.messages[1].data.url, 'https://accounts.google.com/o/oauth2/auth?state=test')
    assert.equal(page.messages[1].origin, 'vscode-webview://trusted')
  })

  it('allows only HTTP(S) external URLs and escapes iframe attributes', () => {
    for (const value of ['command:workbench.action.terminal.new', 'javascript:alert(1)', 'file:///C:/secret', 'https://user:pass@example.com', null]) {
      assert.equal(bridge.isSafeExternalUrl(value), false)
    }
    assert.equal(bridge.isSafeExternalUrl('http://127.0.0.1:4567/#session'), true)
    assert.equal(bridge.escapeHtmlAttribute('"<&\'>'), '&quot;&lt;&amp;&#39;&gt;')
  })
})

describe('Webview and extension integration', () => {
  function render() {
    let html
    let hostHandler
    const copied = []
    const opened = []
    const replies = []
    const errors = []
    let failOpen = false
    const vscode = {
      env: { clipboard: { writeText: async text => copied.push(text) }, openExternal: async uri => { opened.push(uri); if (failOpen) throw new Error('browser blocked'); return true } },
      Uri: { parse: value => value },
      ViewColumn: { Active: 1 },
      window: {
        createWebviewPanel: () => ({ webview: {
          set html(value) { html = value },
          onDidReceiveMessage: fn => { hostHandler = fn },
          postMessage: async data => replies.push(data),
        }, onDidDispose() {} }),
        showInformationMessage() {}, showErrorMessage: message => errors.push(message),
      },
    }
    const provider = loadSource('chatViewProvider', { vscode, './webviewBridge.ts': bridge, './dshManager.ts': {} })
    provider.openHarnessInEditorTab({ extensionUri: {} }, {
      info: { status: 'running', url: 'http://127.0.0.1:4567/?token=test&other=1' },
      onStatusChanged: () => ({ dispose() {} }),
    })
    return { html, hostHandler, copied, opened, replies, errors, failOpen: value => { failOpen = value } }
  }

  it('removes the added navigation controls and preserves the compact chat frame', () => {
    const { html } = render()
    assert.doesNotMatch(html, /Abrir sessão no navegador|Abrir browser|Ampliar/)
    assert.doesNotMatch(html, /open-browser|open-editor/)
    assert.match(html, /<iframe[^>]+allow-downloads/)
    assert.match(html, /allow-popups-to-escape-sandbox/)
    assert.doesNotMatch(html, /allow-top-navigation/)
    assert.match(html, /token=test&amp;other=1/)
  })

  it('uses native clipboard with acknowledgment and rejects command links', async () => {
    const page = render()
    await page.hostHandler({ command: 'copy', text: '', requestId: 'copy-1', bridgeToken: 'host-token' })
    assert.deepEqual(page.copied, [''])
    assert.equal(page.replies[0].ok, true)
    assert.equal(page.replies[0].bridgeToken, 'host-token')
    await page.hostHandler({ command: 'openExternal', text: 'command:bad' })
    assert.equal(page.opened.length, 0)
    await page.hostHandler({ command: 'openExternal', text: 'https://example.com/' })
    assert.deepEqual(page.opened, ['https://example.com/'])
    page.failOpen(true)
    await page.hostHandler({ command: 'openExternal', text: 'https://accounts.google.com/' })
    assert.equal(page.errors.length, 1)
    assert.match(page.errors[0], /browser blocked/)
  })

  it('validates iframe source/origin and relays clipboard results back', () => {
    const { html } = render()
    const scripts = [...html.matchAll(/<script nonce="[^"]+">([\s\S]*?)<\/script>/g)]
    const sent = []
    const childMessages = []
    const handlers = {}
    const child = { postMessage: (data, origin) => childMessages.push({ data, origin }) }
    const frame = { src: 'http://127.0.0.1:4567/', contentWindow: child, addEventListener: (_, fn) => { handlers.load = fn } }
    const window = { addEventListener: (_, fn) => { handlers.message = fn } }
    runInNewContext(scripts[0][1], {
      window, URL, acquireVsCodeApi: () => ({ postMessage: data => sent.push(data) }),
      document: { getElementById: id => id === 'harness' ? frame : { addEventListener: (_, fn) => { handlers[id] = fn } } },
    })
    handlers.load()
    assert.equal(childMessages[0].data.type, 'ewh/bridge-init')
    const data = { type: 'dsh/copy', text: 'answer', requestId: 'copy-1' }
    handlers.message({ source: child, origin: 'https://evil.invalid', data })
    handlers.message({ source: {}, origin: 'http://127.0.0.1:4567', data })
    assert.equal(sent.length, 0)
    handlers.message({ source: child, origin: 'http://127.0.0.1:4567', data })
    assert.equal(sent[0].command, 'copy')
    const beforeAck = childMessages.length
    const shell = {}
    handlers.message({ source: shell, data: { type: 'ewh/copy-result', requestId: 'copy-1', ok: true, bridgeToken: 'forged' } })
    assert.equal(childMessages.length, beforeAck, 'unauthenticated replies must be ignored')
    handlers.message({ source: shell, data: { type: 'ewh/copy-result', requestId: 'copy-1', ok: true, bridgeToken: sent[0].bridgeToken } })
    assert.equal(childMessages.at(-1).data.type, 'ewh/copy-result', 'VS Code replies originate in its outer shell')
    assert.equal(childMessages.at(-1).data.bridgeToken, undefined, 'the child must never receive the host token')
  })
})

describe('Direct authenticated Harness URL selection', () => {
  const manager = loadSource('dshManager', { vscode: {}, './webviewBridge.ts': bridge }, '\nexport { tryDirectHarnessUrl }')
  const session = { rawUrl: 'http://127.0.0.1:3080/?token=one-time-token', token: 'one-time-token', port: 3080 }

  function server(documentHeaders = {}, documentHtml = '<html><head><script data-ewh-webview-bridge></script></head></html>') {
    const requests = []
    const instance = http.createServer((req, res) => {
      requests.push({ url: req.url, cookie: req.headers.cookie })
      if (req.url.startsWith('/?token=one-time-token')) {
        res.writeHead(303, { location: './', 'set-cookie': 'dsh-auth=valid; Path=/; HttpOnly; SameSite=Strict' })
        res.end()
        return
      }
      res.writeHead(200, { 'content-type': 'text/html', ...documentHeaders })
      res.end(documentHtml)
    })
    return { instance, requests }
  }

  it('only uses 3080 when its authenticated HTML already has the VS Code bridge', async () => {
    const { instance, requests } = server()
    await new Promise(resolve => instance.listen(0, '127.0.0.1', resolve))
    try {
      const port = instance.address().port
      const fetchImpl = (url, options) => fetch(String(url).replace('127.0.0.1:3080', `127.0.0.1:${port}`), options)
      assert.equal(await manager.tryDirectHarnessUrl(3080, session, '', fetchImpl), session.rawUrl)
      assert.equal(requests[0].url, '/?token=one-time-token')
      assert.equal(requests[1].url, '/')
      assert.match(requests[1].cookie, /dsh-auth=valid/)
    } finally {
      instance.closeAllConnections()
      await new Promise(resolve => instance.close(resolve))
    }
  })

  it('falls back when the direct server denies framing or the session is not 3080', async () => {
    const { instance } = server({ 'x-frame-options': 'SAMEORIGIN' })
    await new Promise(resolve => instance.listen(0, '127.0.0.1', resolve))
    try {
      const port = instance.address().port
      const fetchImpl = (url, options) => fetch(String(url).replace('127.0.0.1:3080', `127.0.0.1:${port}`), options)
      assert.equal(await manager.tryDirectHarnessUrl(3080, session, '', fetchImpl), undefined)
      assert.equal(await manager.tryDirectHarnessUrl(3000, { ...session, port: 3000 }, '', fetchImpl), undefined)
    } finally {
      instance.closeAllConnections()
      await new Promise(resolve => instance.close(resolve))
    }
  })
})

describe('Real HTTP iframe proxy', () => {
  it('injects only HTML documents and keeps API responses intact', async () => {
    const upstreamRequests = []
    const backend = http.createServer((req, res) => {
      upstreamRequests.push(req.headers)
      if (req.url === '/api/test') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"ok":true}')
      } else {
        const html = '<html><head></head><body>Chat</body></html>'
        res.writeHead(200, { 'content-type': 'text/html', 'content-length': Buffer.byteLength(html), etag: 'old' })
        res.end(html)
      }
    })
    await new Promise(resolve => backend.listen(0, '127.0.0.1', resolve))
    const manager = loadSource('dshManager', { vscode: {}, './webviewBridge.ts': bridge }, '\nexport { createIframeProxy, tryDirectHarnessUrl }')
    let proxy
    try {
      proxy = await manager.createIframeProxy(backend.address().port, 'dsh-auth-test=cookie')
      const url = `http://127.0.0.1:${proxy.port}`
      const response = await fetch(url, { headers: { accept: 'text/html', 'if-none-match': 'old' } })
      assert.match(await response.text(), /data-ewh-webview-bridge/)
      assert.equal(response.headers.get('etag'), null)
      assert.equal(response.headers.get('cache-control'), 'no-store')
      assert.equal(upstreamRequests[0]['accept-encoding'], 'identity')
      assert.equal(upstreamRequests[0]['if-none-match'], undefined)
      assert.match(upstreamRequests[0].cookie, /dsh-auth-test=cookie/)
      const api = await fetch(`${url}/api/test`)
      assert.equal(await api.text(), '{"ok":true}')
    } finally {
      if (proxy) { proxy.server.closeAllConnections(); await new Promise(resolve => proxy.server.close(resolve)) }
      backend.closeAllConnections()
      await new Promise(resolve => backend.close(resolve))
    }
  })
})
