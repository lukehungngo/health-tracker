// One-time, read-only owner export for the Supabase -> Neon migration.
// Read the password from stdin; never commit a password or output data.
import { createHash } from 'node:crypto';
import { createWriteStream, readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { finished } from 'node:stream/promises';
import { join } from 'node:path';

const sourceUrl = 'https://ursehfspdrzpuytymbrn.supabase.co';
const sourceEmail = process.env.SOURCE_EMAIL;
const config = readFileSync(new URL('../Config/SupabaseArchive.xcconfig', import.meta.url), 'utf8');
const publishableKey = config.match(/^SUPABASE_PUBLISHABLE_KEY\s*=\s*(\S+)/m)?.[1];
if (!publishableKey || !process.env.EXPORT_DIRECTORY || !sourceEmail) {
  throw new Error('Requires archived source publishable key, SOURCE_EMAIL, and EXPORT_DIRECTORY');
}
const password = (await new Promise(resolve => {
  let value = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => { value += chunk; if (value.includes('\n')) resolve(value.split('\n')[0]); });
})).trim();

const authResponse = await fetch(`${sourceUrl}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: { apikey: publishableKey, 'content-type': 'application/json' },
  body: JSON.stringify({ email: sourceEmail, password }),
});
if (!authResponse.ok) throw new Error(`Source sign-in failed: HTTP ${authResponse.status}`);
const auth = await authResponse.json();
const ownerId = auth.user?.id;
if (!ownerId || !auth.access_token) throw new Error('Source sign-in returned no owner/token');

const cutoff = process.env.EXPORT_CUTOFF;
if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/.test(cutoff ?? '')) {
  throw new Error('EXPORT_CUTOFF must be an ISO timestamp');
}

const directory = process.env.EXPORT_DIRECTORY;
mkdirSync(directory, { recursive: true, mode: 0o700 });
const tables = [
  { name: 'health_samples', date: 'end_at' },
  { name: 'workouts', date: 'end_at' },
  { name: 'meals', date: 'eaten_at' },
  { name: 'meal_estimates' },
  { name: 'protein_targets', date: 'recorded_at' },
  { name: 'daily_summaries', date: 'date' },
];
const manifest = { sourceProject: 'ursehfspdrzpuytymbrn', ownerId, cutoff, exportedAt: new Date().toISOString(), tables: {} };

for (const table of tables) {
  const fileName = `${table.name}.jsonl`;
  const output = createWriteStream(join(directory, fileName), { mode: 0o600 });
  const hash = createHash('sha256');
  let count = 0;
  let offset = 0;
  let cursor;
  while (true) {
    const url = new URL(`${sourceUrl}/rest/v1/${table.name}`);
    url.searchParams.set('select', '*');
    url.searchParams.set('user_id', `eq.${ownerId}`);
    if (table.date) url.searchParams.set(table.date, `gte.${table.name === 'daily_summaries' ? cutoff.slice(0, 10) : cutoff}`);
    if (table.name === 'health_samples') {
      // The source has an (user_id,end_at) index. Deep OFFSET scans time out.
      url.searchParams.set('order', 'end_at.asc,id.asc');
      if (cursor) {
        url.searchParams.set('or', `(end_at.gt.${cursor.end_at},and(end_at.eq.${cursor.end_at},id.gt.${cursor.id}))`);
      }
    } else {
      url.searchParams.set('order', `${table.name === 'daily_summaries' ? 'date' : 'id'}.asc`);
      url.searchParams.set('offset', String(offset));
    }
    url.searchParams.set('limit', '500');
    const response = await fetch(url, {
      headers: { apikey: publishableKey, authorization: `Bearer ${auth.access_token}` },
    });
    if (!response.ok) throw new Error(`${table.name} export failed at offset ${offset}: HTTP ${response.status} ${await response.text()}`);
    const rows = await response.json();
    if (!Array.isArray(rows)) throw new Error(`${table.name} export returned non-array`);
    for (const row of rows) {
      const line = `${JSON.stringify(row)}\n`;
      if (!output.write(line)) await new Promise(resolve => output.once('drain', resolve));
      hash.update(line);
    }
    count += rows.length;
    offset += rows.length;
    if (table.name === 'health_samples' && rows.length) cursor = rows.at(-1);
    if (rows.length < 500) break;
  }
  output.end();
  await finished(output);
  manifest.tables[table.name] = { count, file: fileName, sha256: hash.digest('hex') };
  console.log(`${table.name}: ${count}`);
}

writeFileSync(join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o600 });
console.log(`Backup directory: ${directory}`);
process.exit(0);
