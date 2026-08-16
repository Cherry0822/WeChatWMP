#!/usr/bin/env node
// Attach to the main WeChatAppEx process and load frida/cloud-probe.js
const { execSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const frida = require('frida')

const findMainPid = () => {
  const out = execSync(
    "pgrep -f '/WeChatAppEx.app/Contents/MacOS/WeChatAppEx --'",
    { encoding: 'utf8' }
  ).trim()
  const pids = out.split('\n').map(Number).filter(Boolean)
  if (!pids.length) throw new Error('WeChatAppEx main process not found')
  // The main process has --mojo-platform-channel-handle; helpers do not.
  for (const pid of pids) {
    try {
      const cmd = execSync(`ps -p ${pid} -o command=`, { encoding: 'utf8' })
      if (cmd.includes('--mojo-platform-channel-handle')) return pid
    } catch (e) {}
  }
  return pids[0]
}

const main = async () => {
  const pid = findMainPid()
  console.log(`[*] attaching to WeChatAppEx main pid=${pid}`)
  const session = await frida.getLocalDevice().then(d => d.attach(pid))
  const code = fs.readFileSync(
    path.join(__dirname, '..', 'frida', 'cloud-probe.js'),
    'utf8'
  )
  const script = await session.createScript(code)
  script.message.connect(message => {
    if (message.type === 'send') console.log(message.payload)
    else if (message.type === 'error') console.error('[script error]', message.stack || message.description)
  })
  await script.load()
  console.log('[*] probe loaded. Ctrl+C to detach.')
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
