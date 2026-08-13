#!/usr/bin/env node
/*
 * 生成新版 WMPFDebugger-mac 配置文件
 * 用法:
 *   node scripts/generate-address.js <version> <LoadStartHookOffset> <LoadStartHookOffset2> <CDPFilterHookOffset> <ResourceCachePolicyHookOffset> <StructOffset> [SceneOffset]
 * 示例:
 *   node scripts/generate-address.js 20008 0x4F744C4 0x8444BD0 0x8436B98 0x4FDC5BC 1440 456
 *
 * x64 表会沿用 addresses.18788.json 的旧值，Intel 用户请按需修改。
 */
const fs = require("fs");
const path = require("path");

const usage = `用法:
  node scripts/generate-address.js <version> <LoadStartHookOffset> <LoadStartHookOffset2> <CDPFilterHookOffset> <ResourceCachePolicyHookOffset> <StructOffset> [SceneOffset]

示例:
  node scripts/generate-address.js 20008 0x4F744C4 0x8444BD0 0x8436B98 0x4FDC5BC 1440 456
`;

const argv = process.argv.slice(2);
if (argv.length < 6) {
  console.log(usage);
  process.exit(1);
}

const [
  version,
  loadStart,
  loadStart2,
  cdpFilter,
  resourceCache,
  structOffset,
  sceneOffset,
] = argv;

const basePath = path.join(
  __dirname,
  "..",
  "frida",
  "config",
  "addresses.18788.json"
);
const base = JSON.parse(fs.readFileSync(basePath, "utf8"));

const out = {
  Version: Number(version) || String(version),
  Arch: {
    arm64: {
      LoadStartHookOffset: loadStart,
      LoadStartHookOffset2: loadStart2,
      CDPFilterHookOffset: cdpFilter,
      ResourceCachePolicyHookOffset: resourceCache,
      StructOffset: Number(structOffset),
      SceneOffset:
        sceneOffset !== undefined
          ? Number(sceneOffset)
          : base.Arch?.arm64?.SceneOffset ?? 488,
    },
    x64: base.Arch?.x64 ?? null,
  },
};

const outPath = path.join(
  __dirname,
  "..",
  "frida",
  "config",
  `addresses.${out.Version}.json`
);
fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
console.log(`已生成: ${outPath}`);
console.log(
  "注意: x64 表沿用了 addresses.18788.json 的旧值，Intel 用户请自行更新。"
);
