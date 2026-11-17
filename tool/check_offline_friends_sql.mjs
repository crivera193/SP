// Local PostgreSQL only: no hosted connection, real users or invented BLE receipts.
import {PGlite} from '../tmp/nearby-sql/node_modules/@electric-sql/pglite/dist/index.js';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const db=new PGlite();
try {
 await db.exec(`create role anon;create role authenticated;
 create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 create function auth.jwt() returns jsonb language sql as $$ select jsonb_build_object('exp',extract(epoch from clock_timestamp()+interval '1 hour')::bigint) $$;
 insert into auth.users values
 ('00000000-0000-4000-8000-000000000001','one@utrgv.edu'),
 ('00000000-0000-4000-8000-000000000002','two@utrgv.edu'),
 ('00000000-0000-4000-8000-000000000003','three@utrgv.edu');`);
 for(const name of ['20261105010000_sp_bluetooth_nearby.sql','20261115010000_sp_friend_communication.sql','20261116010000_sp_offline_friend_directory.sql','20261116020000_sp_durable_offline_friends.sql','20261116030000_sp_short_friend_codes.sql']) {
  await db.exec(await readFile(new URL('../supabase/migrations/'+name,import.meta.url),'utf8'));
 }
 const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
 const actor=async n=>q("select set_config('request.jwt.claim.sub',$1,false)",[n?`00000000-0000-4000-8000-00000000000${n}`:'']);
 const rpc=async(name,args=[]) =>(await q(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
 await actor(1);const a=await rpc('sp_friend_directory_read');
 await actor(2);const b=await rpc('sp_friend_directory_read');
 await actor(3);await rpc('sp_friend_directory_read');
 await actor(1);
 await assert.rejects(rpc('sp_friend_directory_request_code',['ZZZZ-1234']),/friend_code_invalid/);
 const short=b.self_code.replaceAll('-','').slice(0,8);
 const id=await rpc('sp_friend_directory_request_code',[short.slice(0,4)+'-'+short.slice(4)]);
 assert.equal(await rpc('sp_friend_directory_request_code',[short.toUpperCase()]),id,'formatted/lowercase/uppercase short codes resolve the same account');
 await q("insert into auth.users values ('00000000-0000-4000-8000-000000000004','four@utrgv.edu')");
 await assert.rejects(q("insert into sp_friends.identities(user_id,code) values ('00000000-0000-4000-8000-000000000004',$1::uuid)",[short+'-0000-4000-8000-000000000099']),/identities_friend_code_unique/,'a short-code collision never aliases another account');
 assert.equal((await rpc('sp_friend_directory_read')).entries[0].key_hex,null,'pending requests disclose no key');
 await assert.rejects(rpc('sp_friend_directory_respond',[id,'accept']),/friend_recipient_only/);
 await actor(2);
 assert.equal(await rpc('sp_friend_directory_request',[a.self_code]),id,'cross requests do not implicitly accept');
 await rpc('sp_friend_directory_respond',[id,'accept']);
 const bk=(await rpc('sp_friend_directory_read')).entries[0].key_hex;
 await actor(1);const ar=await rpc('sp_friend_directory_read');
 assert.match(bk,/^[0-9a-f]{64}$/);assert.equal(ar.entries[0].key_hex,bk,'only both accepted parties share the pair key');
 assert.equal(ar.valid_until,null);assert.equal(ar.trust_policy,'until_friend_change','Bluetooth trust is independent of login-token expiry');
 await actor(3);assert.deepEqual((await rpc('sp_friend_directory_read')).entries,[],'outsider gets no friend identities or keys');
 await assert.rejects(rpc('sp_friend_directory_respond',[id,'remove']),/friend_not_found/);
 await actor(1);await rpc('sp_friend_directory_respond',[id,'remove']);
 await actor(2);assert.deepEqual((await rpc('sp_friend_directory_read')).entries,[]);
 const next=await rpc('sp_friend_directory_request',[a.self_code]);
 await actor(1);await rpc('sp_friend_directory_respond',[next,'accept']);
 assert.notEqual((await rpc('sp_friend_directory_read')).entries[0].key_hex,bk,'re-friending rotates credentials');
 await db.exec('set role anon');
 await assert.rejects(rpc('sp_friend_directory_read'),/permission denied/);
 await assert.rejects(rpc('sp_friend_directory_request_code',['1234-5678']),/permission denied/);
 await db.exec('reset role;set role authenticated');
 await assert.rejects(q('select offline_key_hex from sp_friends.relationships'),/permission denied/);
 console.log('PASS: online account-scoped provisioning, short-code lookup/collision guard, explicit consent, pending/outsider key denial, durable offline trust, removal, re-friending rotation and RPC/table permissions.');
} finally {await db.close();}
