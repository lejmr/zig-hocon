import { parseFile } from '@o3co/ts.hocon'
try {
  const cfg = parseFile(process.argv[2])
  process.stdout.write(JSON.stringify(cfg.toObject()) + '\n')
} catch (e) {
  process.stderr.write('ERROR: ' + (e && e.message || e) + '\n')
  process.exit(1)
}
