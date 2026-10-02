// Idempotent import of a verified, private Supabase export into Neon.
// Requires DATABASE_URL (direct), EXPORT_DIRECTORY and MIGRATION_TARGET_USER_ID.
import { createHash } from 'node:crypto';
import { createReadStream, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join } from 'node:path';
import pg from 'pg';

const { Client } = pg;
const directory = process.env.EXPORT_DIRECTORY;
const targetUserId = process.env.MIGRATION_TARGET_USER_ID;
if (!directory || !process.env.DATABASE_URL ||
    !/^[0-9a-f-]{36}$/i.test(targetUserId ?? '')) {
  throw new Error('Requires EXPORT_DIRECTORY, DATABASE_URL, and MIGRATION_TARGET_USER_ID');
}
const sampleHealth = process.argv.includes('--sample-health');
const manifest = JSON.parse(readFileSync(join(directory, 'manifest.json'), 'utf8'));
const tables = [
  { name: 'health_samples', columns: ['id','user_id','external_id','type','start_at','end_at','value','unit','source','created_at','source_metadata'], conflict: ['user_id','external_id'] },
  { name: 'workouts', columns: ['id','user_id','healthkit_id','type','start_at','end_at','duration_seconds','active_energy_kcal','avg_heart_rate','max_heart_rate','created_at','source_metadata'], conflict: ['user_id','healthkit_id'] },
  { name: 'meals', columns: ['id','user_id','eaten_at','note','image_path','created_at'], conflict: ['id'] },
  { name: 'meal_estimates', columns: ['id','user_id','meal_id','calories_kcal','protein_g','carbs_g','fat_g','confidence','estimation_metadata','created_at'], conflict: ['user_id','meal_id'] },
  { name: 'protein_targets', columns: ['id','user_id','recorded_at','min_g','max_g','source','created_at'], conflict: ['id'] },
  { name: 'daily_summaries', columns: ['user_id','date','timezone','weight_kg','steps','active_energy_kcal','basal_energy_kcal','sleep_minutes','workout_minutes','intake_kcal','protein_g','aggregation_metadata','updated_at'], conflict: ['user_id','date','timezone'] },
  { name: 'pending_food_logs', schema: 'private', columns: ['id','source_url','log_date','timezone','meal_label','food','original_note','original_estimate','imported_at','linked_meal_id'], conflict: ['id'] },
];
const jsonColumns = new Set(['source_metadata','estimation_metadata','aggregation_metadata','original_estimate']);
const client = new Client({ connectionString: process.env.DATABASE_URL });
await client.connect();
try {
  const user = await client.query('select id from neon_auth."user" where id = $1', [targetUserId]);
  if (user.rowCount !== 1) throw new Error('Target Neon Auth user does not exist');
  for (const table of tables) {
    if (table.schema === 'private' && !manifest.tables[table.name]) continue;
    const fileName = join(directory, `${table.name}.jsonl`);
    if (manifest.tables[table.name]) {
      const hash = createHash('sha256');
      for await (const chunk of createReadStream(fileName)) hash.update(chunk);
      if (hash.digest('hex') !== manifest.tables[table.name].sha256) {
        throw new Error(`${table.name} checksum does not match backup manifest`);
      }
    }
    const fullName = `${table.schema ?? 'public'}.${table.name}`;
    const updates = table.columns.filter(column => !table.conflict.includes(column));
    const upsert = `on conflict (${table.conflict.join(',')}) do update set ${updates.map(column => `${column}=excluded.${column}`).join(',')}`;
    const batch = [];
    let count = 0;
    let sourceCount = 0;
    await client.query('begin');
    try {
      const lines = createInterface({ input: createReadStream(fileName), crlfDelay: Infinity });
      for await (const line of lines) {
        if (!line) continue;
        sourceCount++;
        const row = JSON.parse(line);
        if (row.user_id && row.user_id !== manifest.ownerId) {
          throw new Error(`${table.name} contains a different source user`);
        }
        if (sampleHealth && ['health_samples','workouts'].includes(table.name) && sourceCount > 5) continue;
        if (row.user_id) row.user_id = targetUserId;
        if (row.image_path?.startsWith(`${manifest.ownerId}/`)) {
          row.image_path = `${targetUserId}/${row.image_path.slice(manifest.ownerId.length + 1)}`;
        }
        batch.push(row);
        if (batch.length === 200) {
          await insertBatch(table, fullName, upsert, batch);
          count += batch.length;
          batch.length = 0;
        }
      }
      if (manifest.tables[table.name] && sourceCount !== manifest.tables[table.name].count) {
        throw new Error(`${table.name} row count does not match backup manifest`);
      }
      if (batch.length) {
        await insertBatch(table, fullName, upsert, batch);
        count += batch.length;
      }
      await client.query('commit');
      console.log(`${table.name}: ${count} imported`);
    } catch (error) {
      await client.query('rollback');
      throw error;
    }
  }
  await client.query(`insert into private.tracker_access(singleton,owner_id)
    values(true,$1) on conflict(singleton) do update set owner_id=excluded.owner_id`, [targetUserId]);
} finally {
  await client.end();
}

async function insertBatch(table, fullName, upsert, batch) {
  const columns = table.columns;
  const values = [];
  const groups = batch.map(row => {
    const placeholders = columns.map(column => {
      const value = row[column] ?? null;
      values.push(jsonColumns.has(column) && value !== null ? JSON.stringify(value) : value);
      return `$${values.length}`;
    });
    return `(${placeholders.join(',')})`;
  });
  const sql = `insert into ${fullName} (${columns.join(',')}) values ${groups.join(',')}
    ${upsert}`;
  await client.query(sql, values);
}
