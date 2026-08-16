#!/usr/bin/env node
const { execSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const frida = require('frida')

const pid = parseInt(execSync("pgrep -x WeChat | head -1", { encoding: 'utf8' }).trim(), 10)
if (!pid) throw new Error('WeChat main process not found')

const main = async () => {
  console.log(`[*] attaching WeChat pid=${pid}`)
  const session = await frida.getLocalDevice().then(d => d.attach(pid))
  const code = fs.readFileSync(path.join(__dirname, '..', 'frida', 'sock-probe.js'), 'utf8')
  const script = await session.createScript(code)
  script.message.connect(m => {
    if (m.type === 'log') console.log(m.payload)
    else if (m.type === 'send') console.log(m.payload)
    else if (m.type === 'error') console.error('[script error]', m.stack || m.description)
  })
  await script.load()
  console.log('[*] sock probe loaded. Ctrl+C to detach.')
  process.on('SIGINT', async () => { await script.unload(); await session.detach(); process.exit(0) })
}
main().catch(e => { console.error('ERR', e.message); process.exit(1) })
