// Read a password from stdin so credentials never appear in commands or files.
const password = (await new Promise(resolve => {
  let value = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => { value += chunk; if (value.includes('\n')) resolve(value.split('\n')[0]); });
})).trim();
const email = process.env.MIGRATION_TEST_EMAIL;
if (!email) throw new Error('MIGRATION_TEST_EMAIL is required');
const branch = process.argv.includes('--production') ? 'production' : 'test';
const authBase = branch === 'production'
  ? 'https://ep-tiny-firefly-b3peqnbm.neonauth.c-4.ap-southeast-1.aws.neon.tech/neondb/auth'
  : 'https://ep-broad-dust-b3in7r58.neonauth.c-4.ap-southeast-1.aws.neon.tech/neondb/auth';
const dataBase = branch === 'production'
  ? 'https://ep-tiny-firefly-b3peqnbm.apirest.c-4.ap-southeast-1.aws.neon.tech/neondb/rest/v1'
  : 'https://ep-broad-dust-b3in7r58.apirest.c-4.ap-southeast-1.aws.neon.tech/neondb/rest/v1';
const imageBase = branch === 'production'
  ? 'https://br-quiet-hall-b3cqwaxl-mealimages.compute.c-4.ap-southeast-1.aws.neon.tech/'
  : 'https://br-muddy-wildflower-b3j3c4vm-mealimages.compute.c-4.ap-southeast-1.aws.neon.tech/';
const origin = new URL(authBase).origin;
const login = await fetch(`${authBase}/sign-in/email`, {
  method: 'POST', headers: { 'content-type': 'application/json', origin },
  body: JSON.stringify({ email, password, callbackURL: authBase }),
});
if (!login.ok) throw new Error(`Auth sign-in HTTP ${login.status}`);
const session = await login.json();
const sessionCookie = login.headers.getSetCookie().find(value => value.startsWith('__Secure-neon-auth.session_token='));
if (!sessionCookie) throw new Error('Sign-in did not set a session cookie');
const cookie = sessionCookie.split(';', 1)[0];
const identity = await fetch(`${authBase}/get-session`, { headers: { cookie, origin } });
if (!identity.ok || (await identity.json()).user?.id !== session.user?.id) throw new Error('Session restore failed');
const tokenResponse = await fetch(`${authBase}/token`, { headers: { cookie, origin } });
if (!tokenResponse.ok) throw new Error(`JWT HTTP ${tokenResponse.status}`);
const jwt = (await tokenResponse.json()).token;
const bearer = { authorization: `Bearer ${jwt}` };
const rows = await fetch(`${dataBase}/meals?select=id&limit=1`, { headers: bearer });
if (!rows.ok || !Array.isArray(await rows.json())) throw new Error(`Data API HTTP ${rows.status}`);
const wrongOwner = await fetch(`${dataBase}/meals?select=id&user_id=eq.0bdbcc86-4750-43d3-a0cb-1d04e1323823`, { headers: bearer });
if (!wrongOwner.ok || (await wrongOwner.json()).length !== 0) throw new Error('RLS cross-user query failed');
const anon = await fetch(`${dataBase}/meals?select=id&limit=1`);
if (anon.ok) throw new Error('Anonymous Data API unexpectedly allowed');
const rpc = await fetch(`${dataBase}/rpc/tracker_hourly_energy`, {
  method: 'POST', headers: { ...bearer, 'content-type': 'application/json' },
  body: JSON.stringify({ p_from: '2026-09-27T00:00:00Z', p_to: '2026-09-28T00:00:00Z' }),
});
if (!rpc.ok || !Array.isArray(await rpc.json())) throw new Error(`Hourly RPC HTTP ${rpc.status}`);
const imagePath = `${session.user.id.toLowerCase()}/migration-verify.jpg`;
const sign = await fetch(imageBase, {
  method: 'POST', headers: { ...bearer, 'content-type': 'application/json' },
  body: JSON.stringify({ action: 'download', path: imagePath }),
});
if (!sign.ok || !(await sign.json()).url) throw new Error(`Private image URL HTTP ${sign.status}`);
if (branch === 'test') {
  const upload = await fetch(imageBase, {
    method: 'POST', headers: { ...bearer, 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'upload', path: imagePath }),
  });
  if (!upload.ok) throw new Error(`Image upload signing HTTP ${upload.status}`);
  const put = await fetch((await upload.json()).url, {
    method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
  });
  if (!put.ok) throw new Error(`Signed image PUT HTTP ${put.status}`);
  const download = await fetch(imageBase, {
    method: 'POST', headers: { ...bearer, 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'download', path: imagePath }),
  });
  if (!download.ok) throw new Error(`Image download signing HTTP ${download.status}`);
  const read = await fetch((await download.json()).url);
  if (!read.ok || (await read.arrayBuffer()).byteLength !== 4) throw new Error(`Signed image GET HTTP ${read.status}`);
}
const other = await fetch(imageBase, {
  method: 'POST', headers: { ...bearer, 'content-type': 'application/json' },
  body: JSON.stringify({ action: 'download', path: '0bdbcc86-4750-43d3-a0cb-1d04e1323823/migration-verify.jpg' }),
});
if (other.status !== 400) throw new Error('Cross-owner image path unexpectedly allowed');
const noImageAuth = await fetch(imageBase, { method: 'POST' });
if (noImageAuth.status !== 401) throw new Error('Anonymous image signing unexpectedly allowed');
console.log(`${branch}: sign-in, restore, JWT, owner rows, RLS, RPC, image signing passed`);
process.exit(0);
