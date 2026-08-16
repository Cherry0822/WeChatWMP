#!/usr/bin/env node
// Attach to the WeChatAppEx NetworkService helper and load frida/net-probe.js
const { execSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const frida = require('frida')

const findNetPid = () => {
  const out = execSync(
    "pgrep -f 'network.mojom.NetworkService' | while read p; do ps -p $p -o command= | rg -q WeChatAppEx && echo $p; done",
    { encoding: 'utf8', shell: '/bin/zsh' }
  ).trim()
  const pid = parseInt(out.split('\n')[0], 10)
  if (!pid) throw new Error('WeChatAppEx NetworkService not found')
  return pid
}

const main = async () => {
  const pid = findNetPid()
  console.log(`[*] attaching to NetworkService pid=${pid}`)
  const session = await frida.getLocalDevice().then(d => d.attach(pid))
  const code = fs.readFileSync(path.join(__dirname, '..', 'frida', 'net-probe.js'), 'utf8')
  const script = await session.createScript(code)
  script.message.connect(message => {
    if (message.type === 'send') console.log(message.payload)
    else if (message.type === 'error') console.error('[script error]', message.stack || message.description)
  })
  await script.load()
  console.log('[*] net probe loaded. Ctrl+C to detach.')
  process.on('SIGINT', async () => {
    await script.unload()
    await session.detach()
    process.exit(0)
  })
}

main().catch(e => {
  console.error('ERR', e.message)
  process.exit(1)
})
