// Cloud function route-B probe v5 (version 269136 / arm64)
// Dumps the operateWXData request object (bounded) so we can see cmd/JSON.

const MODULE_NAME = 'WeChatAppEx Framework'
const TARGETS = [0x4ffa02c, 0x4ff5230]

const m = Process.findModuleByName(MODULE_NAME)
if (!m) {
  console.error('[cloud-probe] module not found')
} else {
  console.log(`[cloud-probe] base=${m.base} size=${m.size}`)

  const bstr = p => {
    try {
      if (p.isNull()) return ''
      const b = new Uint8Array(p.readByteArray(128))
      let n = 0
      while (n < b.length && b[n] !== 0) n++
      return String.fromCharCode.apply(null, b.subarray(0, n))
    } catch (e) {
      return ''
    }
  }

  // printable ascii from bounded memory
  const asciiOf = (p, len) => {
    try {
      if (p.isNull()) return ''
      const b = new Uint8Array(p.readByteArray(len))
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

  const rate = { count: 0, windowStart: Date.now() }
  const shouldLog = () => {
    const now = Date.now()
    if (now - rate.windowStart > 1000) {
      rate.count = 0
      rate.windowStart = now
    }
    rate.count++
    return rate.count <= 12
  }

  for (const off of TARGETS) {
    const addr = m.base.add(off)
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          const api = bstr(args[3])
          if (off === 0x4ffa02c) {
            if (api !== 'operateWXData') return
            if (!shouldLog()) return
            console.log(`\n[cloud] operateWXData x0=${args[0]} x1=${args[1]}`)
            console.log(`  x0ascii: ${JSON.stringify(asciiOf(args[0], 512))}`)
            console.log(`  x1ascii: ${JSON.stringify(asciiOf(args[1], 512))}`)
            for (let i = 4; i < 8; i++) {
              console.log(`  x${i}=${args[i]} str=${JSON.stringify(bstr(args[i]).slice(0, 100))}`)
            }
            const bt = Thread.backtrace(this.context, Backtracer.FUZZY)
              .slice(0, 5).map(a => a.sub(m.base).toString()).join(' <- ')
            console.log(`  bt=${bt}`)
          } else {
            const cmd = bstr(args[4])
            if (!cmd) return
            if (!shouldLog()) return
            console.log(`[cloud] 0x4ff5230 cmd=${JSON.stringify(cmd.slice(0, 120))}`)
          }
        }
      })
      console.log(`[cloud-probe] hooked ${'0x' + off.toString(16)}`)
    } catch (e) {
      console.error(`[cloud-probe] hook failed ${'0x' + off.toString(16)}: ${e.message}`)
    }
  }

  setInterval(() => {
    console.log(`[alive] ts=${Date.now()}`)
  }, 15000)
}
