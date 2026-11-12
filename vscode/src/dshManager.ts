import { ChildProcess, execFile, execFileSync, spawn } from 'node:child_process'
import { createHash, createHmac } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import http, { Server, RequestOptions, IncomingMessage, ServerResponse, OutgoingHttpHeaders } from 'node:http'
import { Duplex } from 'node:stream'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import * as vscode from 'vscode'
import { ExtensionConfig, HarnessInfo, HarnessStatus } from './types.ts'

interface SavedSession {
  rawUrl: string
  port: number
  token?: string
  updatedAt: number
}

function getSessionFilePath(storageRoot?: string): string {
  if (storageRoot) {
    try {
      if (!existsSync(storageRoot)) {
        mkdirSync(storageRoot, { recursive: true })
      }
      return join(storageRoot, 'last-session.json')
    } catch {
      // Fallback
    }
  }
  const home = homedir()
  const ewhDir = join(home, '.ewh')
  if (existsSync(ewhDir)) {
    return join(ewhDir, 'last-session.json')
  }
  const dshDir = join(home, '.dsh')
  if (existsSync(dshDir)) {
    return join(dshDir, 'last-session.json')
  }
  return join(home, '.ewh-last-session.json')
}

export function saveLastSession(
  storageRoot: string | undefined,
  session: { rawUrl: string; port: number; token?: string },
): void {
  try {
    const file = getSessionFilePath(storageRoot)
    const data: SavedSession = {
      ...session,
      updatedAt: Date.now(),
    }
    writeFileSync(file, JSON.stringify(data, null, 2), 'utf8')
  } catch {
    // Ignore session write errors
  }
}

export function loadLastSession(storageRoot?: string): SavedSession | undefined {
  try {
    const file = getSessionFilePath(storageRoot)
    if (!existsSync(file)) return undefined
    const content = readFileSync(file, 'utf8')
    return JSON.parse(content) as SavedSession
  } catch {
    return undefined
  }
}

export function getDshSecret(): Buffer | undefined {
  const candidatePaths = [
    join(homedir(), '.ewh', '.credentials.yaml'),
    join(homedir(), '.dsh', '.credentials.yaml'),
  ]
  for (const credPath of candidatePaths) {
    if (!existsSync(credPath)) continue
    try {
      const content = readFileSync(credPath, 'utf8')
      const match = content.match(/client-connection\/browser-session:[\s\S]*?secret:\s*([A-Za-z0-9_-]+)/)
      if (match) {
        const secretStr = match[1]
        const padding = '='.repeat((4 - (secretStr.length % 4)) % 4)
        return Buffer.from(secretStr.replaceAll('-', '+').replaceAll('_', '/') + padding, 'base64')
      }
    } catch {
      // Continue to next candidate
    }
  }
  return undefined
}

export function generateDshSessionCookie(authority: string, secret: Buffer): string {
  const encodeBase64Url = (buf: Buffer | string) =>
    Buffer.from(buf).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/g, '')

  const cookieName = 'dsh-auth-' + encodeBase64Url(createHash('sha256').update(authority).digest())
  const now = Date.now()
  const payload = {
    version: 1,
    authority,
    issuedAt: now,
    expiresAt: now + 30 * 24 * 3600 * 1000,
  }
  const body = encodeBase64Url(Buffer.from(JSON.stringify(payload), 'utf8'))
  const sig = encodeBase64Url(createHmac('sha256', secret).update(body).digest())
  const cookieValue = `v1.${body}.${sig}`
  return `${cookieName}=${cookieValue}`
}

export async function checkDshPort(port: number): Promise<boolean> {
  if (port <= 0) return false
  try {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 1200)
    const res = await fetch(`http://127.0.0.1:${port}/`, {
      redirect: 'manual',
      signal: controller.signal,
    })
    clearTimeout(timer)
    if (res.status === 401) {
      const text = await res.text()
      if (text.includes('dsh web authentication required') || text.toLowerCase().includes('dsh')) {
        return true
      }
    }
    if (res.status === 200 || res.status === 303) {
      return true
    }
  } catch {
    // Port closed or unresponsive
  }
  return false
}

function quoteCmdArgument(value: string): string {
  if (!/[\s&|<>()^"%!]/.test(value)) return value
  return `"${value.replace(/(["^&|<>()%!])/g, '^$1')}"`
}

export function buildWindowsCmdCommand(command: string, args: string[]): string {
  const commandLine = [quoteCmdArgument(command), ...args.map(quoteCmdArgument)].join(' ')
  // cmd.exe /s /c requires an additional outer quote pair when the command
  // itself starts with a quoted executable path. windowsVerbatimArguments
  // below prevents Node from converting those quotes to literal \" text.
  return `"${commandLine}"`
}

function spawnExecutable(
  command: string,
  args: string[],
  options: Parameters<typeof spawn>[2],
): ChildProcess {
  if (process.platform === 'win32' && command.toLowerCase().endsWith('.cmd')) {
    const commandLine = buildWindowsCmdCommand(command, args)
    return spawn(process.env.ComSpec ?? 'cmd.exe', ['/d', '/s', '/c', commandLine], {
      ...options,
      windowsVerbatimArguments: true,
    })
  }
  return spawn(command, args, options)
}

/**
 * Transfers a successfully upgraded WebSocket connection in both directions.
 */
export function bridgeWebSocket(
  clientSocket: Duplex,
  serverSocket: Duplex,
  clientHead: Buffer,
  serverHead: Buffer,
): void {
  if (serverHead.length > 0) clientSocket.write(serverHead)
  if (clientHead.length > 0) serverSocket.write(clientHead)
  clientSocket.pipe(serverSocket).pipe(clientSocket)
}

/**
 * Finds the real Node.js binary on the system (avoiding process.execPath which is the VS Code / Antigravity binary).
 */
export function findNodeBinary(): string {
  const home = homedir()

  if (process.platform === 'win32') {
    try {
      const pathNode = execFileSync('where.exe', ['node.exe'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      })
        .split(/\r?\n/)
        .map(candidate => candidate.trim())
        .find(candidate => candidate.length > 0)
      if (pathNode) {
        return pathNode
      }
    } catch {
      // Continue with the standard Windows locations.
    }
  }

  // 1. Check NVM installations (prefer newest version)
  const nvmDir = join(home, '.nvm/versions/node')
  if (existsSync(nvmDir)) {
    try {
      const versions = readdirSync(nvmDir)
        .filter(v => v.startsWith('v'))
        .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))
      for (const v of versions) {
        const candidate = join(nvmDir, v, 'bin/node')
        if (existsSync(candidate)) {
          return candidate
        }
      }
    } catch {
      // Ignore filesystem read errors
    }
  }

  // 2. Check standard system locations
  const candidates = process.platform === 'win32'
    ? [
      join(process.env.ProgramFiles ?? 'C:\\Program Files', 'nodejs', 'node.exe'),
      join(process.env.ProgramW6432 ?? 'C:\\Program Files', 'nodejs', 'node.exe'),
      join(process.env.LOCALAPPDATA ?? join(home, 'AppData', 'Local'), 'Programs', 'nodejs', 'node.exe'),
      join(process.env.APPDATA ?? join(home, 'AppData', 'Roaming'), 'npm', 'node.exe'),
    ]
    : [
      '/usr/bin/node',
      '/usr/local/bin/node',
      join(home, '.local/share/pnpm/node'),
      join(home, '.local/bin/node'),
      '/bin/node',
    ]

  for (const c of candidates) {
    if (existsSync(c)) {
      return c
    }
  }

  return 'node'
}

/**
 * Finds the corresponding npm binary.
 */
export function findNpmBinary(): string {
  const nodeBin = findNodeBinary()
  if (nodeBin !== 'node') {
    const isWin = process.platform === 'win32'
    const npmCandidate = join(dirname(nodeBin), isWin ? 'npm.cmd' : 'npm')
    if (existsSync(npmCandidate)) {
      return npmCandidate
    }
  }
  return process.platform === 'win32' ? 'npm.cmd' : 'npm'
}

function findProcessIdOnPort(port: number): Promise<number | undefined> {
  if (port <= 0) return Promise.resolve(undefined)
  return new Promise((resolvePort) => {
    const command = process.platform === 'win32' ? 'netstat.exe' : 'lsof'
    const args = process.platform === 'win32'
      ? ['-ano']
      : ['-ti', `tcp:${port}`]
    execFile(command, args, { encoding: 'utf8' }, (_error, stdout) => {
      const lines = stdout.split(/\r?\n/)
      if (process.platform === 'win32') {
        const match = lines.find(line =>
          new RegExp(`127\\.0\\.0\\.1:${port}\\s+.*LISTENING`, 'i').test(line) ||
          new RegExp(`0\\.0\\.0\\.0:${port}\\s+.*LISTENING`, 'i').test(line),
        )
        const pid = match?.trim().split(/\s+/).at(-1)
        resolvePort(pid ? Number(pid) : undefined)
        return
      }
      const pid = lines.map(line => Number(line.trim())).find(value => Number.isInteger(value) && value > 0)
      resolvePort(pid)
    })
  })
}

async function stopProcessOnPort(
  port: number,
  outputChannel: vscode.OutputChannel,
  excludedPid?: number,
): Promise<void> {
  const pid = await findProcessIdOnPort(port)
  if (!pid || pid === excludedPid) return

  outputChannel.appendLine(`[EveryWhere Harness] Stopping process ${pid} listening on port ${port}...`)
  await new Promise<void>((resolveStop) => {
    if (process.platform === 'win32') {
      execFile('taskkill.exe', ['/PID', String(pid), '/T', '/F'], () => resolveStop())
    } else {
      try {
        process.kill(pid, 'SIGTERM')
      } catch {
        // Process may have exited between discovery and termination.
      }
      resolveStop()
    }
  })
}

async function stopOrphanDshProcesses(
  outputChannel: vscode.OutputChannel,
  excludedPid?: number,
): Promise<void> {
  for (const port of [3080, 3000]) {
    await stopProcessOnPort(port, outputChannel, excludedPid)
  }

  if (process.platform === 'win32') {
    execFile('taskkill.exe', ['/IM', 'ewh.exe', '/F'], () => {})
    execFile('taskkill.exe', ['/IM', 'dsh.exe', '/F'], () => {})
  } else {
    await new Promise<void>((resolveStop) => {
      execFile('pgrep', ['-f', '(ewh|dsh).*--profile'], { encoding: 'utf8' }, async (_err, stdout) => {
        if (stdout) {
          const lines = stdout.split(/\r?\n/)
          for (const line of lines) {
            const pid = Number(line.trim())
            if (Number.isInteger(pid) && pid > 0 && pid !== excludedPid && pid !== process.pid) {
              outputChannel.appendLine(`[EveryWhere Harness] Stopping orphan process ${pid}...`)
              try {
                process.kill(pid, 'SIGTERM')
              } catch {
                // Ignore
              }
            }
          }
        }
        resolveStop()
      })
    })
  }
}

/**
 * Enhanced PATH builder that includes common Node/pnpm install locations.
 */
function resolveEnhancedEnv(userConfig: ExtensionConfig): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env }
  // VSCode launches the extension host outside the integrated terminal, so
  // terminal.integrated.env.windows does not reach the DSH child process.
  // Corporate TLS interception requires Node to trust the Windows system store.
  if (process.platform === 'win32' && !env.NODE_EXTRA_CA_CERTS?.trim()) {
    env.NODE_OPTIONS = [env.NODE_OPTIONS, '--use-system-ca'].filter(Boolean).join(' ')
  }

  if (userConfig.apiKey) {
    env.EVERYWHERE_API_KEY = userConfig.apiKey
    env.DEEPSEEK_API_KEY = userConfig.apiKey
  }
  if (userConfig.baseUrl) {
    env.EVERYWHERE_BASE_URL = userConfig.baseUrl
    env.DEEPSEEK_BASE_URL = userConfig.baseUrl
  }

  const home = homedir()
  const candidateDirs = [
    join(home, '.local/share/pnpm'),
    join(home, '.pnpm'),
    join(home, '.npm-global/bin'),
    join(home, '.cargo/bin'),
  ]

  if (process.platform === 'win32') {
    const appData = process.env.APPDATA
    if (appData) {
      candidateDirs.push(join(appData, 'npm'))
    }
    const localAppData = process.env.LOCALAPPDATA
    if (localAppData) {
      candidateDirs.push(join(localAppData, 'npm'))
    }
  } else {
    candidateDirs.push(
      '/usr/local/bin',
      '/usr/bin',
      join(home, '.local/bin'),
      join(home, '.npm-global/bin'),
    )
  }

  const nodeBin = findNodeBinary()
  if (nodeBin !== 'node') {
    candidateDirs.push(dirname(nodeBin))
  }

  const nvmVersionsDir = join(home, '.nvm/versions/node')
  if (existsSync(nvmVersionsDir)) {
    try {
      const versions = readdirSync(nvmVersionsDir)
      for (const v of versions) {
        candidateDirs.push(join(nvmVersionsDir, v, 'bin'))
      }
    } catch {
      // Ignore directory read errors
    }
  }

  const currentPath = env.PATH ?? ''
  const pathSep = process.platform === 'win32' ? ';' : ':'
  const extraPaths = candidateDirs.filter(d => existsSync(d) && !currentPath.includes(d))
  if (extraPaths.length > 0) {
    env.PATH = `${extraPaths.join(pathSep)}${pathSep}${currentPath}`
  }

  return env
}

/**
 * Resolves the executable command and arguments for booting EveryWhere Harness.
 */
export function resolveHarnessCommand(
  config: ExtensionConfig,
  storageRoot?: string,
): { command: string; args: string[] } {
  const profileArgs = ['--profile', config.profile || 'web', '--no-open']
  if (config.port > 0) {
    profileArgs.push('--port', String(config.port))
  }

  // 1. Explicit user path configured
  if (config.dshPath && config.dshPath.trim() !== '') {
    const parts = config.dshPath.trim().match(/(?:[^\s"]+|"[^"]*")+/g) ?? []
    const command = parts[0]?.replace(/^"|"$/g, '') ?? ''
    const extraArgs = parts.slice(1)
    return {
      command,
      args: [...extraArgs, ...profileArgs],
    }
  }

  const nodeBin = findNodeBinary()
  const isWin = process.platform === 'win32'
  const candidateBinNames = isWin ? ['ewh.cmd', 'dsh.cmd'] : ['ewh', 'dsh']

  // 2. Extension private storage installation (isolated auto-install without sudo)
  if (storageRoot) {
    for (const binName of candidateBinNames) {
      const storageBin = join(storageRoot, 'node_modules', '.bin', binName)
      if (existsSync(storageBin)) {
        return {
          command: storageBin,
          args: profileArgs,
        }
      }
    }
  }

  // 3. Check global binary in nodeBin directory
  if (nodeBin !== 'node') {
    for (const binName of candidateBinNames) {
      const directCandidate = join(dirname(nodeBin), binName)
      if (existsSync(directCandidate)) {
        return {
          command: directCandidate,
          args: profileArgs,
        }
      }
    }
  }

  // 4. Check directories in enhanced PATH for installed ewh or dsh binary
  const env = resolveEnhancedEnv(config)
  const pathSep = isWin ? ';' : ':'
  const dirs = (env.PATH ?? '').split(pathSep).filter(Boolean)
  for (const binName of candidateBinNames) {
    for (const dir of dirs) {
      const candidatePath = join(dir, binName)
      if (existsSync(candidatePath)) {
        return {
          command: candidatePath,
          args: profileArgs,
        }
      }
    }
  }

  // 5. Fallback to global `ewh` CLI command if neither binary was explicitly located
  return {
    command: isWin ? 'ewh.cmd' : 'ewh',
    args: profileArgs,
  }
}

/**
 * Resolves the source CLI command for a selected EveryWhere Harness checkout.
 */
export function resolveWorkspaceSourceCommand(
  projectPath: string,
  config: ExtensionConfig,
): { command: string; args: string[] } {
  const sourceBin = join(projectPath, 'apps', 'cli', 'src', 'bin.ts')
  if (!existsSync(sourceBin)) {
    throw new Error(`The selected folder is not an EveryWhere Harness source checkout: ${sourceBin}`)
  }

  const args = ['--import', 'tsx/esm', sourceBin, '--profile', config.profile || 'web', '--no-open']
  if (config.port > 0) {
    args.push('--port', String(config.port))
  }
  return { command: findNodeBinary(), args }
}

/**
 * Checks if an installed EveryWhere Harness command is available on this system.
 */
export async function checkDshAvailable(
  config: ExtensionConfig,
  storageRoot?: string,
): Promise<boolean> {
  // 1. Check explicit config
  if (config.dshPath && config.dshPath.trim() !== '') {
    return true
  }

  const isWin = process.platform === 'win32'
  const candidateBinNames = isWin ? ['ewh.cmd', 'dsh.cmd'] : ['ewh', 'dsh']

  // 2. Check private storage installation
  if (storageRoot) {
    for (const binName of candidateBinNames) {
      const storageBin = join(storageRoot, 'node_modules', '.bin', binName)
      if (existsSync(storageBin)) return true
    }
  }

  // 3. Check direct candidate in node bin directory
  const nodeBin = findNodeBinary()
  if (nodeBin !== 'node') {
    for (const binName of candidateBinNames) {
      const directCandidate = join(dirname(nodeBin), binName)
      if (existsSync(directCandidate)) return true
    }
  }

  // 4. Check system PATH via `ewh --version` or `dsh --version`
  const env = resolveEnhancedEnv(config)
  for (const cmd of candidateBinNames) {
    const ok = await new Promise<boolean>((res) => {
      const child = spawnExecutable(cmd, ['--version'], { env, stdio: 'ignore' })
      child.on('error', () => res(false))
      child.on('close', code => res(code === 0))
    })
    if (ok) return true
  }

  return false
}

/**
 * Creates a local reverse proxy that always injects the active DSH session cookie
 * and normalizes browser security headers (Origin, sec-fetch-site, Referer) so that
 * all /api endpoints (such as directoryPicker/pick) pass the DSH trust fence without HTTP 403.
 */
function createIframeProxy(
  dshPort: number,
  initialCookie: string,
): Promise<{ server: Server; port: number; updateCookie: (c: string) => void }> {
  return new Promise((resolveProxy, rejectProxy) => {
    let currentCookie = initialCookie

    const server = http.createServer((req: IncomingMessage, res: ServerResponse) => {
      const targetUrl = new URL(req.url ?? '/', `http://127.0.0.1:${dshPort}`)

      // Merge client cookies with the essential dsh-auth session cookie
      const existingCookie = req.headers.cookie ?? ''
      const forwardCookie = currentCookie
        ? existingCookie
          ? `${currentCookie}; ${existingCookie}`
          : currentCookie
        : existingCookie

      const forwardHeaders: OutgoingHttpHeaders = {
        ...req.headers,
        host: `127.0.0.1:${dshPort}`,
        cookie: forwardCookie,
      }

      // Sanitize Origin & sec-fetch-site to satisfy isTrustedApiRequest in api-request-trust.ts
      if (forwardHeaders['origin']) {
        forwardHeaders['origin'] = `http://127.0.0.1:${dshPort}`
      }
      if (forwardHeaders['referer']) {
        forwardHeaders['referer'] = `http://127.0.0.1:${dshPort}/`
      }
      if (forwardHeaders['sec-fetch-site']) {
        forwardHeaders['sec-fetch-site'] = 'same-origin'
      }

      const options: RequestOptions = {
        hostname: '127.0.0.1',
        port: dshPort,
        path: targetUrl.pathname + targetUrl.search,
        method: req.method,
        headers: forwardHeaders,
      }

      const connector = http.request(options, (targetRes: IncomingMessage) => {
        const headers = { ...targetRes.headers }

        // Capture newly rotated cookies from the backend
        if (headers['set-cookie']) {
          const newCookie = headers['set-cookie'].find(c => c.includes('dsh-auth'))
          if (newCookie) {
            currentCookie = newCookie.split(';')[0]
          }

          headers['set-cookie'] = headers['set-cookie'].map(cookie =>
            cookie
              .replace(/;\s*SameSite=Strict/gi, '')
              .replace(/;\s*HttpOnly/gi, ''),
          )
        }

        // Allow embedding in Webview iframes & disable framing restrictions
        delete headers['x-frame-options']
        delete headers['content-security-policy']
        headers['access-control-allow-origin'] = '*'

        res.writeHead(targetRes.statusCode ?? 200, headers)
        targetRes.pipe(res)
      })

      connector.on('error', (err) => {
        if (!res.headersSent) {
          res.writeHead(502, { 'Content-Type': 'text/plain' })
          res.end(`Proxy connection error: ${err.message}`)
        }
      })

      req.pipe(connector)
    })

    // Forward WebSocket / HTTP upgrade requests
    server.on('upgrade', (req: IncomingMessage, clientSocket: Duplex, clientHead: Buffer) => {
      const existingCookie = req.headers.cookie ?? ''
      const forwardCookie = currentCookie
        ? existingCookie
          ? `${currentCookie}; ${existingCookie}`
          : currentCookie
        : existingCookie

      const forwardHeaders: OutgoingHttpHeaders = {
        ...req.headers,
        host: `127.0.0.1:${dshPort}`,
        cookie: forwardCookie,
      }

      if (forwardHeaders['origin']) {
        forwardHeaders['origin'] = `http://127.0.0.1:${dshPort}`
      }
      if (forwardHeaders['referer']) {
        forwardHeaders['referer'] = `http://127.0.0.1:${dshPort}/`
      }
      if (forwardHeaders['sec-fetch-site']) {
        forwardHeaders['sec-fetch-site'] = 'same-origin'
      }

      const proxyReq = http.request({
        hostname: '127.0.0.1',
        port: dshPort,
        path: req.url,
        method: req.method,
        headers: forwardHeaders,
      })

      proxyReq.on('upgrade', (proxyRes: IncomingMessage, serverSocket: Duplex, serverHead: Buffer) => {
        clientSocket.write(
          'HTTP/1.1 101 Switching Protocols\r\n' +
            Object.entries(proxyRes.headers)
              .map(([k, v]) => `${k}: ${v}`)
              .join('\r\n') +
            '\r\n\r\n',
        )
        bridgeWebSocket(clientSocket, serverSocket, clientHead, serverHead)
      })

      proxyReq.on('error', () => {
        clientSocket.destroy()
      })

      proxyReq.end()
    })

    server.listen(0, '127.0.0.1', () => {
      const addr = server.address()
      if (addr && typeof addr === 'object') {
        resolveProxy({
          server,
          port: addr.port,
          updateCookie: (c: string) => {
            currentCookie = c
          },
        })
      } else {
        rejectProxy(new Error('Failed to obtain proxy address'))
      }
    })

    server.on('error', (err) => {
      rejectProxy(err)
    })
  })
}

/**
 * Manages the lifecycle of the EveryWhere Harness runtime process and Webview proxy.
 */
export class DshProcessManager {
  private childProcess: ChildProcess | null = null
  private proxyServer: Server | null = null
  private currentInfo: HarnessInfo = { status: 'stopped' }
  private backendPort?: number
  private isStopping = false
  private storageRoot?: string

  private readonly _onStatusChanged = new vscode.EventEmitter<HarnessInfo>()
  public readonly onStatusChanged: vscode.Event<HarnessInfo> = this._onStatusChanged.event

  constructor(
    private config: ExtensionConfig,
    private readonly outputChannel: vscode.OutputChannel,
    storageRoot?: string,
  ) {
    this.storageRoot = storageRoot
    this.initStatus()
  }

  public async initStatus(): Promise<void> {
    if (this.currentInfo.status === 'running') {
      return
    }

    // Check if an existing EveryWhere Harness service is already running on the system
    const existing = await this.findRunningDsh(this.config.port)
    if (existing) {
      try {
        await this.attachToRunningService(existing)
        return
      } catch {
        // Fall back to checking installation status
      }
    }

    const available = await this.isAvailable()
    if (!available) {
      this.setStatus('not_installed')
    } else if (this.currentInfo.status === 'not_installed' || this.currentInfo.status === 'starting') {
      this.setStatus('stopped')
    }
  }

  public async isAvailable(): Promise<boolean> {
    return checkDshAvailable(this.config, this.storageRoot)
  }

  public get info(): HarnessInfo {
    return this.currentInfo
  }

  public updateConfig(newConfig: ExtensionConfig): void {
    this.config = newConfig
    this.initStatus()
  }

  public setStatus(status: HarnessStatus, extra?: Partial<HarnessInfo>): void {
    this.currentInfo = {
      ...this.currentInfo,
      status,
      ...extra,
    }
    this._onStatusChanged.fire(this.currentInfo)
  }

  /**
   * Probes for an already running EveryWhere Harness backend on configured or standard ports.
   */
  public async findRunningDsh(targetPort?: number): Promise<{ port: number; pid?: number } | undefined> {
    const candidatePorts = [targetPort ?? this.config.port, 3080, 3000].filter(
      (p): p is number => typeof p === 'number' && p > 0,
    )
    const uniquePorts = Array.from(new Set(candidatePorts))

    for (const port of uniquePorts) {
      const isDsh = await checkDshPort(port)
      if (isDsh) {
        const pid = await findProcessIdOnPort(port)
        return { port, pid }
      }
    }
    return undefined
  }

  /**
   * Attaches the VS Code Webview proxy to an already running EveryWhere Harness instance.
   */
  public async attachToRunningService(service: { port: number; pid?: number }): Promise<string> {
    const dshPort = service.port
    const saved = loadLastSession(this.storageRoot)

    let initialCookie = ''
    let rawDshUrl = `http://127.0.0.1:${dshPort}/`

    // 1. Try using saved token if available for this port
    if (saved && saved.port === dshPort && saved.token) {
      try {
        const authRes = await fetch(`http://127.0.0.1:${dshPort}/?token=${saved.token}`, {
          redirect: 'manual',
        })
        const rawCookie = authRes.headers.get('set-cookie')
        if (rawCookie) {
          initialCookie = rawCookie.split(';')[0]
          rawDshUrl = saved.rawUrl
        }
      } catch {
        // Fall back to generated cookie
      }
    }

    // 2. Fall back to cryptographically signed session cookie from ~/.dsh/.credentials.yaml
    if (!initialCookie) {
      const secret = getDshSecret()
      if (secret) {
        initialCookie = generateDshSessionCookie(`127.0.0.1:${dshPort}`, secret)
      }
    }

    // 3. Fall back to saved URL if available
    if (saved && saved.port === dshPort && saved.rawUrl) {
      rawDshUrl = saved.rawUrl
    }

    // Close any previous proxy server
    this.closeProxy()

    try {
      const { server, port: proxyPort } = await createIframeProxy(dshPort, initialCookie)
      this.proxyServer = server

      const webviewUrl = `http://127.0.0.1:${proxyPort}/`
      this.backendPort = dshPort
      this.setStatus('running', { url: webviewUrl, port: dshPort, pid: service.pid })
      this.outputChannel.appendLine(`[EveryWhere Harness] Backend ready at: ${rawDshUrl}`)
      this.outputChannel.appendLine(`[EveryWhere Harness] Webview sidebar ready at: ${webviewUrl}`)
      return webviewUrl
    } catch (proxyErr: unknown) {
      const msg = proxyErr instanceof Error ? proxyErr.message : String(proxyErr)
      this.outputChannel.appendLine(`[EveryWhere Harness] Proxy start failed: ${msg}. Using raw URL.`)
      this.backendPort = dshPort
      this.setStatus('running', { url: rawDshUrl, port: dshPort, pid: service.pid })
      this.outputChannel.appendLine(`[EveryWhere Harness] Backend ready at: ${rawDshUrl}`)
      return rawDshUrl
    }
  }

  /**
   * Automatically installs EveryWhere Harness using npm.
   * Tries global install first, falls back to isolated extension storage prefix if permissions fail.
   */
  public async installHarness(): Promise<void> {
    this.setStatus('installing')
    this.outputChannel.show(true)
    this.outputChannel.appendLine('=========================================')
    this.outputChannel.appendLine('[EveryWhere Harness] Starting automated installation...')
    this.outputChannel.appendLine('=========================================')

    const npmBin = findNpmBinary()
    const env = resolveEnhancedEnv(this.config)

    // Step 1: Try global installation
    const runInstall = (args: string[], desc: string): Promise<boolean> => {
      return new Promise<boolean>((res) => {
        this.outputChannel.appendLine(`[EveryWhere Harness] Executing: ${npmBin} ${args.join(' ')}`)
        const child = spawnExecutable(npmBin, args, {
          env,
          stdio: ['ignore', 'pipe', 'pipe'],
        })

        child.stdout?.on('data', d => this.outputChannel.append(d.toString()))
        child.stderr?.on('data', d => this.outputChannel.append(d.toString()))

        child.on('close', (code) => {
          if (code === 0) {
            this.outputChannel.appendLine(`[EveryWhere Harness] ${desc} succeeded!`)
            res(true)
          } else {
            this.outputChannel.appendLine(`[EveryWhere Harness] ${desc} exited with code ${code}.`)
            res(false)
          }
        })
        child.on('error', () => res(false))
      })
    }

    // The Harness plugin installer requires pnpm. Install it first on every platform.
    const pnpmReady = await runInstall(['install', '-g', 'pnpm'], 'Global install (pnpm)')
    if (!pnpmReady) {
      this.outputChannel.appendLine('[EveryWhere Harness] Warning: pnpm could not be installed automatically. Continuing with Harness installation...')
    }

    // Step 1: Try global installation of @everywhere-harness/ewh, then legacy fallbacks
    let success = await runInstall(['install', '-g', '@everywhere-harness/ewh'], 'Global install (@everywhere-harness/ewh)')
    if (!success) {
      success = await runInstall(['install', '-g', 'everywhere-harness'], 'Global install (everywhere-harness)')
    }
    if (!success) {
      success = await runInstall(['install', '-g', '@deepseek-ai/dsh'], 'Global install (@deepseek-ai/dsh)')
    }

    // Step 2: Try local extension storage fallback
    if (!success && this.storageRoot) {
      try {
        if (!existsSync(this.storageRoot)) {
          mkdirSync(this.storageRoot, { recursive: true })
        }
      } catch {}

      success = await runInstall(['install', '@everywhere-harness/ewh', '--prefix', this.storageRoot], 'Local storage install (@everywhere-harness/ewh)')
      if (!success) {
        success = await runInstall(['install', 'everywhere-harness', '--prefix', this.storageRoot], 'Local storage install (everywhere-harness)')
      }
      if (!success) {
        success = await runInstall(['install', '@deepseek-ai/dsh', '--prefix', this.storageRoot], 'Local storage install (@deepseek-ai/dsh)')
      }
    }

    if (success) {
      this.setStatus('stopped')
      vscode.window.showInformationMessage('EveryWhere Harness installed successfully!')
    } else {
      const errMsg = 'Failed to install EveryWhere Harness. Please run "npm install -g @everywhere-harness/ewh" manually in terminal.'
      this.setStatus('not_installed', { error: errMsg })
      vscode.window.showErrorMessage(errMsg, 'View Logs').then((action) => {
        if (action === 'View Logs') {
          this.outputChannel.show(true)
        }
      })
    }
  }

  /**
   * Start the EveryWhere Harness runtime and proxy.
   * Resolves when the authenticated web URL is ready to be embedded.
   */
  public async start(): Promise<string> {
    if (this.currentInfo.status === 'running' && this.currentInfo.url) {
      return this.currentInfo.url
    }

    const available = await this.isAvailable()
    if (!available) {
      this.setStatus('not_installed')
      throw new Error('EveryWhere Harness is not installed. Please click "Instalar EveryWhere Harness" in the sidebar.')
    }

    // Check if an existing EveryWhere Harness service is already running
    const existing = await this.findRunningDsh(this.config.port)
    if (existing) {
      this.outputChannel.appendLine(
        `[EveryWhere Harness] Existing service detected on port ${existing.port}. Connecting to open instance...`,
      )
      return this.attachToRunningService(existing)
    }

    const workspaceFolders = vscode.workspace.workspaceFolders
    const { command, args } = resolveHarnessCommand(this.config, this.storageRoot)
    const cwd = workspaceFolders && workspaceFolders.length > 0
      ? workspaceFolders[0].uri.fsPath
      : process.cwd()
    return this.startProcess(command, args, cwd)
  }

  /**
   * Start the selected repository's source CLI for development and provider debugging.
   */
  public async startFromWorkspaceSource(projectPath: string): Promise<string> {
    const { command, args } = resolveWorkspaceSourceCommand(projectPath, this.config)
    return this.startProcess(command, args, projectPath)
  }

  private async startProcess(
    command: string,
    args: string[],
    cwd: string,
    isRetry = false,
  ): Promise<string> {
    if (this.currentInfo.status === 'running' && this.currentInfo.url) {
      return this.currentInfo.url
    }

    if (this.currentInfo.status === 'starting') {
      return new Promise<string>((resolve, reject) => {
        const disposable = this.onStatusChanged((info) => {
          if (info.status === 'running' && info.url) {
            disposable.dispose()
            resolve(info.url)
          } else if (info.status === 'error' || info.status === 'not_installed') {
            disposable.dispose()
            reject(new Error(info.error ?? 'Failed to start EveryWhere Harness'))
          }
        })
      })
    }

    this.isStopping = false
    this.setStatus('starting', { url: undefined, port: undefined, error: undefined, pid: undefined })
    const env = resolveEnhancedEnv(this.config)

    this.outputChannel.appendLine('=========================================')
    this.outputChannel.appendLine('[EveryWhere Harness] Starting process...')
    this.outputChannel.appendLine(`[EveryWhere Harness] Command: ${command} ${args.join(' ')}`)
    this.outputChannel.appendLine(`[EveryWhere Harness] Working directory: ${cwd}`)
    this.outputChannel.appendLine('=========================================')

    return new Promise<string>((resolve, reject) => {
      let isSettled = false

      // 65-second startup timeout safeguard (30 extra seconds for slow startups)
      const startupTimer = setTimeout(() => {
        if (!isSettled) {
          isSettled = true
          const errMsg = 'Timeout waiting for EveryWhere Harness to start. Check output logs for details.'
          this.outputChannel.appendLine(`[EveryWhere Harness] ERROR: ${errMsg}`)
          this.setStatus('error', { error: errMsg })
          reject(new Error(errMsg))
        }
      }, 65000)

      try {
        const child = spawnExecutable(command, args, {
          cwd,
          env,
          stdio: ['pipe', 'pipe', 'pipe'],
        })

        this.childProcess = child
        this.setStatus('starting', { pid: child.pid })

        const urlRegex = /(?:ewh|dsh)\s+web:\s+(https?:\/\/[^\s\)]+)/i

        const handleData = async (data: Buffer) => {
          const text = data.toString('utf-8')
          this.outputChannel.append(text)

          const match = text.match(urlRegex)
          if (match && !isSettled) {
            isSettled = true
            clearTimeout(startupTimer)
            const rawDshUrl = match[1]

            let dshPort = 3000
            let token = ''
            try {
              const parsed = new URL(rawDshUrl)
              dshPort = parseInt(parsed.port, 10)
              token = parsed.searchParams.get('token') ?? ''
            } catch {
              // fallback
            }

            try {
              // Perform initial handshake to capture the signed dsh-auth session cookie
              let initialCookie = ''
              try {
                const initialRes = await fetch(`http://127.0.0.1:${dshPort}/?token=${token}`, {
                  redirect: 'manual',
                })
                const rawCookie = initialRes.headers.get('set-cookie')
                if (rawCookie) {
                  initialCookie = rawCookie.split(';')[0]
                }
              } catch (authFetchErr) {
                this.outputChannel.appendLine(
                  `[EveryWhere Harness] Warning during initial auth fetch: ${authFetchErr}`,
                )
              }

              // Create the proxy that auto-injects this cookie and sanitizes origin/sec-fetch-site
              const { server, port: proxyPort } = await createIframeProxy(dshPort, initialCookie)
              this.proxyServer = server

              const webviewUrl = `http://127.0.0.1:${proxyPort}/`
              this.backendPort = dshPort
              this.setStatus('running', { url: webviewUrl, port: dshPort, pid: child.pid })
              saveLastSession(this.storageRoot, { rawUrl: rawDshUrl, port: dshPort, token })
              this.outputChannel.appendLine(`[EveryWhere Harness] Backend ready at: ${rawDshUrl}`)
              this.outputChannel.appendLine(`[EveryWhere Harness] Webview sidebar ready at: ${webviewUrl}`)
              resolve(webviewUrl)
            } catch (proxyErr: unknown) {
              const msg = proxyErr instanceof Error ? proxyErr.message : String(proxyErr)
              this.outputChannel.appendLine(`[EveryWhere Harness] Proxy start failed: ${msg}. Using raw URL.`)
              this.backendPort = dshPort
              this.setStatus('running', { url: rawDshUrl, port: dshPort, pid: child.pid })
              saveLastSession(this.storageRoot, { rawUrl: rawDshUrl, port: dshPort, token })
              this.outputChannel.appendLine(`[EveryWhere Harness] Backend ready at: ${rawDshUrl}`)
              resolve(rawDshUrl)
            }
          }
        }

        child.stdout?.on('data', handleData)
        child.stderr?.on('data', handleData)

        child.on('error', (err: Error) => {
          this.outputChannel.appendLine(`[EveryWhere Harness] Process spawn error: ${err.message}`)
          if (!isSettled) {
            isSettled = true
            clearTimeout(startupTimer)
            this.setStatus('error', { error: err.message })
            reject(err)
          }
        })

        child.on('close', async (code: number | null, signal: string | null) => {
          clearTimeout(startupTimer)
          this.outputChannel.appendLine(
            `[EveryWhere Harness] Process exited (code: ${code}, signal: ${signal})`,
          )
          this.childProcess = null
          this.closeProxy()

          if (this.isStopping) {
            this.setStatus('stopped', { url: undefined, port: undefined, pid: undefined })
          } else if (!isSettled) {
            isSettled = true

            // When failing with exit code 1, check if EveryWhere Harness is already running
            if (code === 1) {
              const running = await this.findRunningDsh(this.config.port)
              if (running) {
                this.outputChannel.appendLine(
                  `[EveryWhere Harness] Process exited with code 1 because EveryWhere Harness is already running on port ${running.port}. Connecting to existing instance...`,
                )
                try {
                  const attachedUrl = await this.attachToRunningService(running)
                  resolve(attachedUrl)
                  return
                } catch (attachErr: unknown) {
                  this.outputChannel.appendLine(
                    `[EveryWhere Harness] Failed to attach to running service: ${attachErr}`,
                  )
                }
              }

              if (!isRetry) {
                this.outputChannel.appendLine(
                  '[EveryWhere Harness] Process exited with code 1 on initial connect. Stopping existing service/processes and restarting chat...',
                )
                try {
                  await this.stop()
                  await new Promise((resolveWait) => setTimeout(resolveWait, 1000))
                  const retryUrl = await this.startProcess(command, args, cwd, true)
                  resolve(retryUrl)
                  return
                } catch (retryErr: unknown) {
                  const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr)
                  this.outputChannel.appendLine(
                    `[EveryWhere Harness] Automatic restart after stop failed: ${retryMsg}`,
                  )
                  this.setStatus('error', { error: retryMsg, url: undefined, port: undefined, pid: undefined })
                  reject(new Error(retryMsg))
                  return
                }
              }
            }

            const errMsg = `EveryWhere Harness exited with code ${code}`
            this.setStatus('error', { error: errMsg, url: undefined, port: undefined, pid: undefined })
            reject(new Error(errMsg))
          } else {
            this.setStatus('stopped', { url: undefined, port: undefined, pid: undefined })
          }
        })
      } catch (err: unknown) {
        clearTimeout(startupTimer)
        const error = err instanceof Error ? err : new Error(String(err))
        this.outputChannel.appendLine(`[EveryWhere Harness] Spawn exception: ${error.message}`)
        this.setStatus('error', { error: error.message })
        if (!isSettled) {
          isSettled = true
          reject(error)
        }
      }
    })
  }

  private closeProxy(): void {
    if (this.proxyServer) {
      try {
        this.proxyServer.close()
      } catch {
        // ignore
      }
      this.proxyServer = null
    }
  }

  /**
   * Stop the running EveryWhere Harness instance and proxy.
   */
  public async stop(): Promise<void> {
    this.closeProxy()
    const backendPort = this.backendPort ?? this.currentInfo.port ?? this.config.port
    this.backendPort = undefined

    if (!this.childProcess) {
      if (backendPort && backendPort > 0) {
        await stopProcessOnPort(backendPort, this.outputChannel)
      }
      await stopOrphanDshProcesses(this.outputChannel)
      this.setStatus('stopped', { url: undefined, port: undefined, pid: undefined })
      return
    }

    this.isStopping = true
    this.outputChannel.appendLine('[EveryWhere Harness] Stopping process...')

    const child = this.childProcess
    await new Promise<void>((resolve) => {
      let resolved = false
      const timeout = setTimeout(() => {
        if (!resolved && this.childProcess) {
          this.outputChannel.appendLine('[EveryWhere Harness] Forcing kill (SIGKILL)...')
          try {
            child.kill('SIGKILL')
          } catch {
            // Ignore
          }
          resolved = true
          this.childProcess = null
          this.setStatus('stopped', { url: undefined, port: undefined, pid: undefined })
          resolve()
        }
      }, 3000)

      child.once('close', () => {
        clearTimeout(timeout)
        if (!resolved) {
          resolved = true
          this.childProcess = null
          this.setStatus('stopped', { url: undefined, port: undefined, pid: undefined })
          resolve()
        }
      })

      try {
        child.kill('SIGTERM')
      } catch {
        clearTimeout(timeout)
        resolved = true
        this.childProcess = null
        this.setStatus('stopped', { url: undefined, port: undefined, pid: undefined })
        resolve()
      }
    })

    if (backendPort && backendPort > 0) {
      await stopProcessOnPort(backendPort, this.outputChannel)
    }
    await stopOrphanDshProcesses(this.outputChannel, child.pid)
    this.setStatus('stopped', { url: undefined, port: undefined, pid: undefined })
  }

  public async restart(): Promise<string> {
    await this.stop()
    return this.start()
  }

  public async dispose(): Promise<void> {
    await this.stop()
    this._onStatusChanged.dispose()
  }
}
