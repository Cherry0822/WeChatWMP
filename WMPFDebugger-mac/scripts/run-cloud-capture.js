#!/usr/bin/env node
// Route B cloud capture runner.
// Attaches to the WeChatAppEx NetworkService process, loads frida/cloud-capture.js
// with the arm64 offsets from frida/config, and prints decoded HTTP traffic,
// highlighting cloud-gateway requests. Full raw capture goes to CLOUD_CAPTURE_LOG
// (default /tmp/cloud-capture.log).
const { execSync } = require('child_process')
const zlib = require('zlib')
const fs = require('fs')
const path = require('path')
const frida = require('frida')

const LOG_PATH = process.env.CLOUD_CAPTURE_LOG || '/tmp/cloud-capture.log'
const CLOUD_RE = /servicewechat\.com|wxqcloud|myqcloud|tencentcloudapi|tcb-api|request_body|x-wx-ob/

const findNetPid = () => {
  const out = execSync(
    "pgrep -f 'network.mojom.NetworkService' | while read p; do ps -p $p -o command= | rg -q WeChatAppEx && echo $p; done",
    { encoding: 'utf8', shell: '/bin/zsh' }
  ).trim()
  const pid = parseInt(out.split('\n')[0], 10)
  if (!pid) throw new Error('WeChatAppEx NetworkService not found')
  return pid
}

const loadArm64Config = () => {
  const dir = path.join(__dirname, '..', 'frida', 'config')
  for (const f of fs.readdirSync(dir)) {
    if (!/^addresses\.\d+\.json$/.test(f)) continue
    const cfg = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'))
    const arm = cfg.Arch && cfg.Arch.arm64
    if (arm && arm.SSLPayloadReadOffset && arm.SSLPayloadWriteOffset) return arm
  }
  throw new Error('no config with SSL offsets found (run the offset finder first)')
}

const hexToBuf = hex => Buffer.from(hex, 'hex')

const classify = buf => {
  const head = buf.slice(0, Math.min(buf.length, 4096)).toString('latin1')
  if (/^(GET|POST|PUT|DELETE|PATCH|HEAD) \S+ HTTP\/1\.[01]/.test(head)) return 'REQ1'
  if (/^HTTP\/1\.[01] \d{3}/.test(head)) return 'RESP1'
  if (head.startsWith('PRI * HTTP/2.0')) return 'H2PREFACE'
  return null
}

// split http/2 frames out of a payload; returns [{type, flags, sid, payload}]
const h2Frames = buf => {
  const frames = []
  let off = 0
  while (off + 9 <= buf.length) {
    const len = buf.readUIntBE(off, 3)
    if (off + 9 + len > buf.length) break
    frames.push({
      type: buf[off + 3],
      flags: buf[off + 4],
      sid: buf.readUInt32BE(off + 5) & 0x7fffffff,
      payload: buf.slice(off + 9, off + 9 + len)
    })
    off += 9 + len
  }
  return frames
}

const TYPE_NAME = { 0x0: 'DATA', 0x1: 'HEADERS', 0x2: 'PRIORITY', 0x3: 'RST_STREAM', 0x4: 'SETTINGS', 0x5: 'PUSH_PROMISE', 0x6: 'PING', 0x7: 'GOAWAY', 0x8: 'WINDOW_UPDATE', 0x9: 'CONTINUATION' }

const printable = buf => {
  let s = ''
  for (const b of buf.subarray(0, 8192)) s += b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : '.'
  return s
}

const maybeGunzip = buf => {
  if (buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b) {
    try {
      return { ok: true, data: zlib.gunzipSync(buf) }
    } catch (e) {
      return { ok: false, data: buf }
    }
  }
  return { ok: false, data: buf }
}

const pretty = (ev) => {
  const buf = hexToBuf(ev.hex)
  const conn = ev.ssl.slice(-4)
  const kind = classify(buf)
  const lines = []
  if (kind === 'REQ1') {
    const h = buf.toString('latin1')
    const host = (h.match(/^Host: (.+)$/m) || [])[1] || '?'
    lines.push(`REQ  conn=${conn} ${h.split('\r\n')[0]} host=${host}`)
  } else if (kind === 'RESP1') {
    lines.push(`RESP conn=${conn} ${buf.toString('latin1').split('\r\n')[0]}`)
  } else {
    const frames = h2Frames(buf)
    for (const f of frames) {
      const name = TYPE_NAME[f.type] || `0x${f.type.toString(16)}`
      if (f.type === 0x0) {
        const gz = maybeGunzip(f.payload)
        const shown = gz.ok ? gz.data : f.payload
        const p = printable(shown)
        const texty = [...shown].filter(b => b >= 0x20 && b < 0x7f).length / Math.max(1, shown.length)
        lines.push(`H2 ${name} conn=${conn} sid=${f.sid} len=${f.payload.length}${gz.ok ? ` [gunzip->${gz.data.length}]` : ''}${texty > 0.5 ? ` ascii=${JSON.stringify(p.slice(0, 400))}` : ' <binary>'}`)
      } else {
        lines.push(`H2 ${name} conn=${conn} sid=${f.sid} flags=0x${f.flags.toString(16)} len=${f.payload.length} hex=${f.payload.subarray(0, 32).toString('hex')}`)
      }
    }
    if (!frames.length) {
      const p = printable(buf)
      const texty = [...buf].filter(b => b >= 0x20 && b < 0x7f).length / Math.max(1, buf.length)
      lines.push(`RAW conn=${conn} len=${buf.length}${texty > 0.5 ? ` ascii=${JSON.stringify(p.slice(0, 300))}` : ' <binary>'}`)
    }
  }
  return lines
}

const main = async () => {
  const pid = findNetPid()
  const cfg = loadArm64Config()
  console.log(`[*] attaching NetworkService pid=${pid}`)
  console.log(`[*] offsets read=${cfg.SSLPayloadReadOffset} write=${cfg.SSLPayloadWriteOffset}`)
  console.log(`[*] full log: ${LOG_PATH}`)
  const session = await frida.getLocalDevice().then(d => d.attach(pid))
  let code = fs.readFileSync(path.join(__dirname, '..', 'frida', 'cloud-capture.js'), 'utf8')
  code = code.split('@@CONFIG@@').join(JSON.stringify(cfg))
  const script = await session.createScript(code)
  const logStream = fs.createWriteStream(LOG_PATH, { flags: 'a' })
  script.message.connect(message => {
    if (message.type === 'send') {
      const ev = message.payload
      logStream.write(`${new Date().toISOString()} ${ev.dir} ${ev.ssl} ${ev.hex}\n`)
      for (const l of pretty(ev)) {
        const mark = CLOUD_RE.test(l) ? ' [CLOUD]' : ''
        console.log(`[${ev.dir}] ${l}${mark}`)
      }
    } else if (message.type === 'error') {
      console.error('[script error]', message.stack || message.description)
    }
  })
  await script.load()
  console.log('[*] cloud capture running. Ctrl+C to stop.')
  process.on('SIGINT', async () => {
    logStream.end()
    await script.unload()
    await session.detach()
    process.exit(0)
  })
}

main().catch(e => {
  console.error('ERR', e.message)
  process.exit(1)
})
