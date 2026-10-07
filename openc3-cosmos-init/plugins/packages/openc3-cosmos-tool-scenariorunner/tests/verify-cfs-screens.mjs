import { readFile, writeFile } from 'node:fs/promises'
import { validatePassiveScreen } from '../src/passiveScreen.js'
const results = []
for (const screen of ['cfe_es_hk_tlm_screen', 'cfe_evs_hk_tlm_screen']) {
  const definition = await readFile(`evidence/${screen}.txt`, 'utf8')
  const { packets } = validatePassiveScreen(definition, 'CFS-1_QEMU')
  results.push({ screen, lines: definition.split('\n').length, packets, accepted: true })
}
await writeFile('evidence/cfs-screen-validation.json', JSON.stringify(results, null, 2))
console.log(JSON.stringify(results, null, 2))
