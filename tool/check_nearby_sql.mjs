// Local PostgreSQL contract check; auth.users below contains synthetic users only.
// Install @electric-sql/pglite in ignored tmp/nearby-sql before running this file.
import { PGlite } from '../tmp/nearby-sql/node_modules/@electric-sql/pglite/dist/index.js';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const db = new PGlite();
try {
  await db.exec(`create role anon; create role authenticated;
    create schema auth; create table auth.users(id uuid primary key,email text);
    create function auth.uid() returns uuid language sql as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    insert into auth.users values
    ('00000000-0000-4000-8000-000000000001','one@utrgv.edu'),
    ('00000000-0000-4000-8000-000000000002','two@utrgv.edu'),
    ('00000000-0000-4000-8000-000000000003','three@utrgv.edu');`);
  await db.exec(await readFile(new URL('../supabase/migrations/20261105010000_sp_bluetooth_nearby.sql', import.meta.url),'utf8'));
  const query = async (sql, args=[]) => (await db.query(sql,args)).rows;
  const actor = async n => { await query("select set_config('request.jwt.claim.sub',$1,false)",[n ? `00000000-0000-4000-8000-00000000000${n}` : '']); };
  const rpc = async (name,args=[]) => (await query(`select public.sp_nearby_${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
  await actor(1);
  const a = (await rpc('open',['10000000-0000-4000-8000-000000000001'])).token;
  assert.equal((await rpc('open',['10000000-0000-4000-8000-000000000001'])).token,a,'retry open is idempotent');
  await actor(2);
  const b = (await rpc('open',['10000000-0000-4000-8000-000000000002'])).token;
  await rpc('heartbeat',[b,26.31,-98.17,5,new Date().toISOString()]);
  assert.deepEqual((await rpc('read',[b])).players,[],'GPS never creates encounters');
  await actor(1);
  assert.deepEqual((await rpc('read',[a])).players,[]);
  const nonce = await rpc('challenge',[a,b]);
  assert.ok(nonce);
  assert.equal(await rpc('confirm',[a,nonce]),false,'initiator cannot confirm');
  assert.deepEqual((await rpc('read',[a])).players,[],'unconfirmed challenge is invisible');
  await actor(2);
  assert.equal(await rpc('confirm',[b,nonce]),true);
  assert.equal(await rpc('confirm',[b,nonce]),false,'replay does not renew');
  assert.equal((await rpc('read',[b])).players.length,1,'bilateral discovery');
  await actor(1);
  let peers=(await rpc('read',[a])).players;
  assert.equal(peers.length,1);
  assert.ok(peers[0].position);
  assert.equal(peers[0].token,undefined,'secret token not returned to map');
  await assert.rejects(rpc('heartbeat',[b]),/nearby_session_expired/,'other account cannot update');
  await rpc('close',[b]);
  assert.equal((await rpc('read',[a])).players.length,1,'other account cannot close');
  await db.exec("update sp_nearby.sessions set fix_at=clock_timestamp()-interval '7 seconds' where token='"+b+"'");
  assert.equal((await rpc('read',[a])).players[0].position,null,'stale GPS withdraws position');
  await db.exec("update sp_nearby.rounds set completed_at=clock_timestamp()-interval '19 seconds'");
  assert.deepEqual((await rpc('read',[a])).players,[],'stale Bluetooth withdraws peers');
  const late=await rpc('challenge',[a,b]);
  await db.exec("update sp_nearby.rounds set issued_at=clock_timestamp()-interval '9 seconds' where nonce='"+late+"'");
  await actor(2);
  assert.equal(await rpc('confirm',[b,late]),false,'late nonce rejected');
  await rpc('close',[b]);
  await actor(1);
  assert.deepEqual((await rpc('read',[a])).players,[],'closed session disappears');
  await actor(null);
  await assert.rejects(rpc('open',['10000000-0000-4000-8000-000000000003']),/nearby_sign_in_required/);
  await db.exec('set role anon');
  await assert.rejects(rpc('read',[a]),/permission denied/);
  await db.exec('reset role; set role authenticated');
  await assert.rejects(query('select * from sp_nearby.sessions'),/permission denied/);
  await db.exec('reset role');
  assert.equal((await query('select count(*)::int as n from auth.users'))[0].n,3,'existing account records preserved');
  console.log('PASS: PostgreSQL migration, discovery/position separation, bilateral receipt, replay/expiry, session ownership and access restrictions.');
} finally { await db.close(); }
