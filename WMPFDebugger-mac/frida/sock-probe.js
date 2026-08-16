// WeChat 主进程 socket 抓包探针：hook send/sendto/write/connect，
// 过滤 HTTP/云函数特征的数据并打印。
const FILTER = /(POST|GET|PUT|DELETE|HEAD) |HTTP\/|cloud|tcb|CALLFUNCTION|callFunction|tencentcloudapi|servicewechat/
let count = 0
const MAX = 300

const bstr = (p, len) => {
  try {
    const b = new Uint8Array(p.readByteArray(Math.min(len, 2048)))
    let s = ''
    for (let i = 0; i < b.length; i++) {
      const c = b[i]
      s += c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '.'
    }
    return s
  } catch (e) { return '' }
}

const tryLog = (tag, fd, p, len) => {
  if (count >= MAX) return
  const s = bstr(p, len)
  if (!FILTER.test(s)) return
  count++
  console.log(`\n[sock] ${tag} fd=${fd} len=${len}`)
  console.log(`  ${JSON.stringify(s.slice(0, 600))}`)
}

const exports = ['send', 'sendto', 'write']
const hooked = new Set()
for (const name of exports) {
  for (const mod of Process.enumerateModules()) {
    try {
      const addr = mod.findExportByName(name)
      if (!addr || hooked.has(addr.toString())) continue
      hooked.add(addr.toString())
      Interceptor.attach(addr, {
        onEnter(args) {
          try { tryLog(name.toUpperCase(), args[0].toInt32(), args[1], args[2].toInt32()) } catch (e) {}
        }
      })
      console.log(`[sock-probe] hooked ${name} @ ${addr} (${mod.name})`)
    } catch (e) {
      console.log(`[sock-probe] hook ${name} fail in ${mod.name}: ${e.message}`)
    }
  }
}

for (const mod of Process.enumerateModules()) {
  try {
    const conn = mod.findExportByName('connect')
    if (!conn) continue
    Interceptor.attach(conn, {
      onEnter(args) {
        try {
          const sockaddr = args[1]
          if (sockaddr.isNull()) return
          const family = sockaddr.readU16()
          if (family === 2) {
            const raw = sockaddr.add(2).readU16()
            const port = ((raw & 0xff) << 8) | (raw >> 8)
            const ip = sockaddr.add(4).readU32()
            const ipStr = [(ip & 0xff), (ip >> 8 & 0xff), (ip >> 16 & 0xff), (ip >> 24 & 0xff)].join('.')
            console.log(`[sock] CONNECT fd=${args[0].toInt32()} ${ipStr}:${port}`)
          }
        } catch (e) {}
      }
    })
    console.log(`[sock-probe] hooked connect @ ${conn} (${mod.name})`)
  } catch (e) {}
}
