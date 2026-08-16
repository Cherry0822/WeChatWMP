// NetworkService TLS plaintext probe (version 269136 / arm64)
// SSL_read  = 0x9a8308 (ssl, buf, len) -> bytes read
// SSL_write = 0x1357bac (ssl, buf, len) -> bytes written
const MODULE_NAME = 'WeChatAppEx Framework'
const SSL_READ = 0x9a8308
const SSL_WRITE = 0x1357bac

const m = Process.findModuleByName(MODULE_NAME)
if (!m) {
  console.error('[tls-probe] module not found')
} else {
  console.log(`[tls-probe] base=${m.base} pid=${Process.id}`)

  const hexOf = (p, len) => {
    try {
      const b = new Uint8Array(p.readByteArray(Math.min(len, 4096)))
      return Array.from(b).map(x => x.toString(16).padStart(2, '0')).join(' ')
    } catch (e) {
      return ''
    }
  }
  const asciiOf = (p, len) => {
    try {
      const b = new Uint8Array(p.readByteArray(Math.min(len, 32768)))
      let s = ''
      for (let i = 0; i < b.length; i++) {
        const c = b[i]
        s += c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '.'
      }
      return s
    } catch (e) {
      return ''
    }
  }
  const looksHttp = (p, len) => {
    try {
      const b = new Uint8Array(p.readByteArray(Math.min(len, 1024)))
      const head = Array.from(b).map(x => String.fromCharCode(x)).join('')
      return /(GET|POST|PUT|DELETE|PATCH|HEAD) \S+ HTTP\/|\bHTTP\/[12]\.\d|PRI \* HTTP\/2\.0|:method|:path|:authority/.test(head)
    } catch (e) {
      return false
    }
  }
  const tag = (p, len, dir) => {
    try {
      const b = new Uint8Array(p.readByteArray(Math.min(len, 8192)))
      const head = Array.from(b).map(x => String.fromCharCode(x)).join('')
      if (/(GET|POST|PUT|DELETE|PATCH|HEAD) \S+ HTTP\/|\bHTTP\/[12]\.\d|PRI \* HTTP\/2\.0/.test(head)) {
        return dir === 'W' ? 'HTTP-WRITE' : 'HTTP-READ'
      }
      if (/(request_body|callFunction|CALLFUNCTION|x-wx-ob|tcb-api|tencentcloudapi)/.test(head)) {
        return dir === 'W' ? 'CLOUD-WRITE' : 'CLOUD-READ'
      }
      return dir === 'W' ? 'WRITE' : 'READ'
    } catch (e) {
      return dir === 'W' ? 'WRITE' : 'READ'
    }
  }

  Interceptor.attach(m.base.add(SSL_WRITE), {
    onEnter(args) {
      const len = args[2].toInt32()
      if (len <= 0 || len > 1 << 24) return
      const kind = tag(args[1], len, 'W')
      console.log(`\n[tls] ${kind} len=${len}`)
      console.log(`  hex: ${hexOf(args[1], len)}`)
      console.log(`  ascii: ${JSON.stringify(asciiOf(args[1], len))}`)
    }
  })

  Interceptor.attach(m.base.add(SSL_READ), {
    onEnter(args) {
      this.buf = args[1]
      this.cap = args[2].toInt32()
    },
    onLeave(retval) {
      const n = retval.toInt32()
      if (n <= 0 || n > this.cap || n > 1 << 24) return
      const kind = tag(this.buf, n, 'R')
      console.log(`\n[tls] ${kind} len=${n}`)
      console.log(`  hex: ${hexOf(this.buf, n)}`)
      console.log(`  ascii: ${JSON.stringify(asciiOf(this.buf, n))}`)
    }
  })

  console.log('[tls-probe] hooked SSL_read + SSL_write')
  setInterval(() => {
    console.log(`[alive] ts=${Date.now()}`)
  }, 20000)
}
