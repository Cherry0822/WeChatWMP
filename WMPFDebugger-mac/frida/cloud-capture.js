// Route B cloud capture (macOS WMPF)
// Hooks BoringSSL payload write/read in the NetworkService process and emits
// plaintext TLS payloads to the Node host, which parses HTTP/1.1 + HTTP/2.
// Offsets are injected by scripts/run-cloud-capture.js via @@CONFIG@@.

const rawConfig = `@@CONFIG@@`
const cfg = rawConfig.includes('@@') ? null : JSON.parse(rawConfig)

const m = Process.findModuleByName('WeChatAppEx Framework')
if (!m || !cfg) {
  console.error('[cloud-capture] module/config missing')
} else {
  const readOff = cfg.SSLPayloadReadOffset
  const writeOff = cfg.SSLPayloadWriteOffset
  console.log(`[cloud-capture] base=${m.base} read=${readOff} write=${writeOff}`)

  const MAX = 1 << 24 // 16MB sanity cap
  const bytesOf = (p, len) => {
    try {
      return Array.from(new Uint8Array(p.readByteArray(Math.min(len, MAX))))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('')
    } catch (e) {
      return ''
    }
  }

  try {
    Interceptor.attach(m.base.add(writeOff), {
      onEnter(args) {
        const len = args[2].toInt32()
        if (len <= 0 || len > MAX) return
        send({
          dir: 'W',
          ssl: args[0].toString(),
          hex: bytesOf(args[1], len)
        })
      }
    })
  } catch (e) {
    console.error('[cloud-capture] write hook failed:', e.message)
  }

  try {
    Interceptor.attach(m.base.add(readOff), {
      onEnter(args) {
        this.buf = args[1]
        this.cap = args[2].toInt32()
        this.ssl = args[0].toString()
      },
      onLeave(retval) {
        const n = retval.toInt32()
        if (n <= 0 || n > this.cap || n > MAX) return
        send({
          dir: 'R',
          ssl: this.ssl,
          hex: bytesOf(this.buf, n)
        })
      }
    })
  } catch (e) {
    console.error('[cloud-capture] read hook failed:', e.message)
  }

  console.log('[cloud-capture] hooks installed')
}
