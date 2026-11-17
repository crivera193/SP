// Synthetic local PostgreSQL checks. Never connects to a hosted backend.
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
  for (const name of ['20261105010000_sp_bluetooth_nearby.sql','20261115010000_sp_friend_communication.sql','20261117011000_sp_friend_only_positions.sql']) {
    await db.exec(await readFile(new URL('../supabase/migrations/'+name,import.meta.url),'utf8'));
  }
  const q = async (sql,args=[]) => (await db.query(sql,args)).rows;
  const actor = async n => { await q("select set_config('request.jwt.claim.sub',$1,false)",[
    n ? `00000000-0000-4000-8000-00000000000${n}` : '']); };
  const rpc = async (name,args=[]) => (await q(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
  const sessions=[];
  for(let n=1;n<=3;n++) {
    await actor(n);
    sessions.push((await rpc('sp_nearby_open',[`10000000-0000-4000-8000-00000000000${n}`])).token);
  }
  const [a,b,c]=sessions;
  await db.exec("update sp_nearby.sessions set latitude=0,longitude=0,accuracy_m=3,fix_at=clock_timestamp()");
  const ids=(await q('select token,public_id from sp_nearby.sessions'));
  const peerId=t=>ids.find(x=>x.token===t).public_id;
  async function encounter(from,to) {
    await actor(from); const nonce=await rpc('sp_nearby_challenge',[sessions[from-1],sessions[to-1]]);
    await actor(to); assert.equal(await rpc('sp_nearby_confirm',[sessions[to-1],nonce]),true);
  }
  const requestId='20000000-0000-4000-8000-000000000001',key='ab'.repeat(32);
  const open=()=>rpc('sp_friend_channel_open',[a,peerId(b),requestId,key]);
  await actor(1);
  await assert.rejects(open(),/friend_nearby_required/);
  await assert.rejects(rpc('sp_friends_request',[a,peerId(b)]),/friend_nearby_required/);
  await encounter(1,2); await encounter(1,3);
  await actor(1);
  let peers=(await rpc('sp_nearby_read',[a])).players;
  assert.equal(peers.length,2,'nonfriends remain discoverable');
  assert.ok(peers.every(x=>x.friendship==='none'));
  assert.ok(peers.every(x=>x.position===null),'nonfriends cannot receive GPS through legacy RPC');
  await assert.rejects(open(),/friend_verification_required/);
  const relationship=await rpc('sp_friends_request',[a,peerId(b)]);
  assert.equal(await rpc('sp_friends_request',[a,peerId(b)]),relationship,'request retries are idempotent');
  await assert.rejects(rpc('sp_friends_respond',[a,relationship,'accept']),/friend_recipient_only/);
  await assert.rejects(open(),/friend_verification_required/,'pending is not accepted');
  await actor(2);
  assert.equal(await rpc('sp_friends_request',[b,peerId(a)]),relationship,'cross request requires explicit acceptance');
  assert.equal((await rpc('sp_friends_read',[b])).entries[0].status,'incoming');
  await actor(3);
  await assert.rejects(rpc('sp_friends_respond',[c,relationship,'accept']),/friend_not_found/);
  await actor(2); await rpc('sp_friends_respond',[b,relationship,'accept']);
  await actor(1);
  const ticket=await open();
  assert.equal(ticket.key_hex,key);
  assert.equal((await open()).id,ticket.id,'open retry reuses its existing key');
  await db.exec('update sp_nearby.settings set friend_limit=1,communication_s=10');
  await assert.rejects(rpc('sp_friends_request',[a,peerId(c)]),/friend_limit_reached/,'server catalog limit changes without an app rebuild');
  const limited=await rpc('sp_friend_channel_check',[a,ticket.id]);
  assert.ok(new Date(limited.expires_at)-new Date(limited.server_now)<=10000,'server communication setting bounds fresh authorization');
  await db.exec('update sp_nearby.settings set friend_limit=100,communication_s=30');
  peers=(await rpc('sp_nearby_read',[a])).players;
  assert.equal(peers.find(x=>x.id===peerId(b)).friendship,'accepted');
  await db.exec("update sp_nearby.sessions set fix_at=clock_timestamp()");
  peers=(await rpc('sp_nearby_read',[a])).players;
  assert.ok(peers.find(x=>x.id===peerId(b)).position,'accepted friend with fresh Bluetooth may receive legacy GPS');
  assert.equal(peers.find(x=>x.id===peerId(c)).position,null,'other nearby player remains locked');
  assert.ok(peers.every(x=>x.key_hex===undefined && x.peer_token===undefined),'discovery leaks no channel secrets');
  await actor(2);
  const recipient=await rpc('sp_friend_channel_check',[b,ticket.id]);
  assert.equal(recipient.key_hex,key);
  assert.notEqual(recipient.first,ticket.first,'directional nonce namespaces differ');
  await actor(3);
  assert.equal(await rpc('sp_friend_channel_check',[c,ticket.id]),null,'outsider cannot fetch a stolen channel ID');
  await rpc('sp_friend_channel_close',[c,ticket.id]);
  await actor(2); assert.ok(await rpc('sp_friend_channel_check',[b,ticket.id]),'outsider cannot close');
  await actor(1);
  await rpc('sp_friends_respond',[a,relationship,'remove']);
  assert.equal(await rpc('sp_friend_channel_check',[a,ticket.id]),null,'removal revokes channel and key');
  const afterRemoval=(await rpc('sp_nearby_read',[a])).players;
  assert.equal(afterRemoval.length,2,'removal preserves detection');
  assert.ok(afterRemoval.every(x=>x.position===null),'removal withdraws legacy GPS immediately');
  const next=await rpc('sp_friends_request',[a,peerId(b)]);
  await actor(2); await rpc('sp_friends_respond',[b,next,'accept']);
  await actor(1); const reopened=await open();
  await db.exec("update sp_nearby.rounds set completed_at=clock_timestamp()-interval '19 seconds'");
  assert.equal(await rpc('sp_friend_channel_check',[a,reopened.id]),null,'stale Bluetooth cannot authorize communication');
  await encounter(1,2); await actor(1);
  assert.ok(await rpc('sp_friend_channel_check',[a,reopened.id]));
  await rpc('sp_nearby_close',[a]);
  await actor(2);
  assert.equal(await rpc('sp_friend_channel_check',[b,reopened.id]),null,'account session exit removes channels');
  await db.exec('set role authenticated');
  await assert.rejects(q('select * from sp_friends.channels'),/permission denied/);
  await db.exec('reset role; set role anon');
  await assert.rejects(rpc('sp_friends_read',[b]),/permission denied/);
  await assert.rejects(rpc('sp_friend_channel_check',[b,reopened.id]),/permission denied/);
  await db.exec('reset role');
  assert.equal((await q('select count(*)::int as n from auth.users'))[0].n,3);
  console.log('PASS: nonfriend discovery, explicit mutual friendship, account-bound channel keys, idempotency, outsider denial, revocation, stale Bluetooth, session exit and table/RPC permissions.');
} finally { await db.close(); }
