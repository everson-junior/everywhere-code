/** Runs in the proxied Harness document, before the application scripts. */
function installHarnessBridge(): void {
  if (window.parent === window) return
  let parentOrigin: string | undefined
  let sequence = 0
  const pending = new Map<string, { resolve: () => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }>()
  const clipboard = navigator.clipboard
  const nativeWrite = clipboard?.writeText?.bind(clipboard)
  const openExternal = (value: unknown): boolean => {
    if (typeof value !== 'string') return false
    try {
      const url = new URL(value)
      if (url.protocol !== 'https:' || url.username || url.password || !parentOrigin) return false
      // The extension host opens the URL in the user's system browser. This
      // avoids Chromium blocking a delayed popup navigation from the iframe.
      window.parent.postMessage({ type: 'dsh/open-external', url: url.href }, parentOrigin)
      return true
    } catch {
      return false
    }
  }

  const nativeOpen = window.open.bind(window)
  window.open = ((url?: string | URL, target?: string, features?: string) => {
    if (url !== 'about:blank') return nativeOpen(url, target, features)
    let closed = false
    const popup = {
      opener: null,
      get closed() { return closed },
      close() { closed = true },
      location: {
        replace(value: string) {
          if (openExternal(value)) closed = true
        },
      },
    }
    // The account plugin opens about:blank during the click and redirects it
    // later after receiving the authorization URL over its RPC stream.
    // Immediately hand a known HTTPS URL to the extension host.
    return popup as unknown as Window
  }) as typeof window.open

  window.addEventListener('message', (event: MessageEvent) => {
    if (event.source !== window.parent) return
    const data = event.data
    if (!data || typeof data !== 'object') return
    if (data.type === 'ewh/bridge-init' && !parentOrigin) {
      parentOrigin = event.origin
      window.parent.postMessage({ type: 'ewh/bridge-ready' }, parentOrigin)
    }
    if (event.origin !== parentOrigin) return
    if (data.type === 'ewh/open-external' && typeof data.url === 'string') openExternal(data.url)
    if (data.type === 'ewh/copy-result' && typeof data.requestId === 'string') {
      const request = pending.get(data.requestId)
      if (!request) return
      clearTimeout(request.timer)
      pending.delete(data.requestId)
      if (data.ok === true) request.resolve()
      else request.reject(new Error('VS Code could not copy to the clipboard.'))
    }
  })

  const writeText = (text: string): Promise<void> => {
    const targetOrigin = parentOrigin
    if (!targetOrigin) {
      return nativeWrite ? nativeWrite(text) : Promise.reject(new Error('Clipboard bridge is not ready.'))
    }
    return new Promise((resolve, reject) => {
      const requestId = `copy-${++sequence}`
      const timer = setTimeout(() => {
        pending.delete(requestId)
        reject(new Error('VS Code clipboard request timed out.'))
      }, 5000)
      pending.set(requestId, { resolve, reject, timer })
      window.parent.postMessage({ type: 'dsh/copy', text: String(text), requestId }, targetOrigin)
    })
  }

  // Do not read the clipboard or change browser permissions. Only explicit text
  // writes from the UI are delegated to the extension's native clipboard API.
  try {
    if (clipboard) Object.defineProperty(clipboard, 'writeText', { configurable: true, value: writeText })
    else Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } })
  } catch {
    // A future browser may make this API non-configurable; leave it untouched.
  }
}

export function injectHarnessBridge(html: string): string {
  const script = `<script data-ewh-webview-bridge>(${installHarnessBridge.toString()})();</script>`
  // The early insertion ensures application code captures the bridged API.
  return /<head(?:\s[^>]*)?>/i.test(html)
    ? html.replace(/<head(?:\s[^>]*)?>/i, match => match + script)
    : script + html
}

export function escapeHtmlAttribute(value: string): string {
  return value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]!)
}

export function isSafeExternalUrl(value: unknown): value is string {
  if (typeof value !== 'string') return false
  try {
    const url = new URL(value)
    return (url.protocol === 'http:' || url.protocol === 'https:') && !url.username && !url.password
  } catch {
    return false
  }
}
