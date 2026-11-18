// Real isolated PostgreSQL; synthetic reports are not Bluetooth/runtime evidence.
import {PGlite} from '../tmp/nearby-sql/node_modules/@electric-sql/pglite/dist/index.js';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const db=new PGlite();
const users=[1,2,3,4].map(n=>`00000000-0000-4000-8000-00000000000${n}`);
const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
let currentAccount;
const actor=async n=>{currentAccount=users[n-1]??'';return q("select set_config('request.jwt.claim.sub',$1,false)",[currentAccount]);};
const rpc=async(name,args=[]) => (await q(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) v`,args))[0].v;
const sync=events=>rpc('sp_contacts_sync',[currentAccount,JSON.stringify(events)]);
const read=()=>rpc('sp_contacts_read');
try {
 await db.exec(`create role anon;create role authenticated;create schema auth;
 create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql as $$select jsonb_build_object('exp',extract(epoch from clock_timestamp()+interval '1 hour')::bigint)$$;`);
 for(let i=0;i<users.length;i++) await q('insert into auth.users values($1,$2)',[users[i],`contact${i}@utrgv.edu`]);
 for(const file of ['20261108010000_sp_permanent_teams.sql','20261105010000_sp_bluetooth_nearby.sql',
  '20261115010000_sp_friend_communication.sql','20261116010000_sp_offline_friend_directory.sql',
  '20261116020000_sp_durable_offline_friends.sql','20261116030000_sp_short_friend_codes.sql',
  '20261117010000_sp_location_quizzes.sql','20261118010000_sp_bluetooth_contacts.sql']) {
  await db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
 }
 const codes=[];
 for(let n=1;n<=4;n++) { await actor(n);codes.push((await rpc('sp_friend_directory_read')).self_code); }
 await actor(1);
 const friendship=await rpc('sp_friend_directory_request_code',[codes[1].replaceAll('-','').slice(0,8)]);
 await actor(2);await rpc('sp_friend_directory_respond',[friendship,'accept']);
 const base=Date.now()-3_600_000,sa=randomUUID(),sb=randomUUID(),channel=randomUUID();
 const reports=(self,peer,code,ch=channel,offset=0,count=40)=>Array.from({length:count},(_,i)=>({
  id:randomUUID(),own_session:self,peer_session:peer,peer_code:code,contact_id:ch,
  started_at:new Date(base+offset+i*15000).toISOString(),ended_at:new Date(base+offset+(i+1)*15000).toISOString(),duration_ms:15000,
 }));
 const a=reports(sa,sb,codes[1]),b=reports(sb,sa,codes[0]);
 await db.exec('set role authenticated');
 await actor(0);await assert.rejects(read(),/authenticated UTRGV/);
 await actor(1);
 assert.equal((await read()).level,1); assert.equal((await read()).quiz_points,1);
 assert.equal((await sync(a)).progress.friend_seconds,0,'one phone cannot award time alone');
 await actor(2);
 await assert.rejects(rpc('sp_contacts_sync',[users[0],JSON.stringify(a)]),/Contact account changed/);
 let result=await sync(b);
 assert.equal(result.accepted.length,40);assert.equal(result.progress.friend_seconds,600);assert.equal(result.progress.level,2);
 assert.equal((await sync(b)).progress.friend_seconds,600,'retry cannot award twice');
 await assert.rejects(sync([{...b[0],duration_ms:1}]),/Contact ID already used/);
 await actor(1);assert.equal((await read()).friend_seconds,600,'counterpart upload credits both accounts');
 await assert.rejects(sync([{...a[0],id:randomUUID(),duration_ms:20000}]),/timestamps or duration/);
 const futureId=randomUUID();
 await sync([{...a[0],id:futureId,ended_at:new Date(Date.now()+300_000).toISOString()}]);
 assert.equal((await read()).friend_seconds,600,'wrong-clock logs are retained without credit or a poisoned retry queue');
 await assert.rejects(sync(Array(51).fill(a[0])),/up to 50/);
 await assert.rejects(q('select * from sp_contacts.reports'),/permission denied/);
 await assert.rejects(q('update sp_contacts.progress set periods=\'{}\''),/permission denied/);
 // Independent contact with another accepted friend at the same time stays 600s.
 const f3=await rpc('sp_friend_directory_request_code',[codes[2].replaceAll('-','').slice(0,8)]);
 await actor(3);await rpc('sp_friend_directory_respond',[f3,'accept']);
 const sc=randomUUID(),ch3=randomUUID();
 await actor(1);await sync(reports(sa,sc,codes[2],ch3));
 await actor(3);await sync(reports(sc,sa,codes[0],ch3));
 assert.equal((await read()).friend_seconds,600);
 await actor(1);assert.equal((await read()).friend_seconds,600,'multiple friends never multiply elapsed time');
 // Detected nonfriends are logged, with no progress, even if they claim a channel.
 const sd=randomUUID(),ch4=randomUUID();
 await sync(reports(sa,sd,codes[3],ch4,600_000,1));
 await actor(4);await sync(reports(sd,sa,codes[0],ch4,600_000,1));
 assert.equal((await read()).friend_seconds,0,'nonfriend time is ineligible');
 // Expired sessions and different channel IDs cannot be paired accidentally.
 const stale=reports(sd,sb,codes[1],randomUUID(),900_000,1);
 await sync(stale);
 await actor(2);await sync(reports(sb,sd,codes[3],randomUUID(),900_000,1));
 await actor(4);assert.equal((await read()).friend_seconds,0);
 // Earned progress survives removing a friendship; new time does not count.
 await actor(1);await rpc('sp_friend_directory_respond',[friendship,'remove']);
 assert.equal((await read()).friend_seconds,600);
 await sync(reports(sa,sb,codes[1],channel,600_000,1));
 await actor(2);await sync(reports(sb,sa,codes[0],channel,600_000,1));
 assert.equal((await read()).friend_seconds,600);
 await db.exec('reset role;update sp_contacts.settings set seconds_per_level=60;set role authenticated');
 await actor(1);assert.equal((await read()).level,11,'level interval is live data, not a client constant');
 assert.equal((await read()).quiz_points,2);
 await db.exec('set role anon');await assert.rejects(read(),/permission denied/);
 console.log('PASS: paired reports, 600s threshold, duplicate/lost-response retries, overlapping friends, nonfriends, mismatched sessions, removal, live configuration and private permissions.');
} finally { await db.close(); }
