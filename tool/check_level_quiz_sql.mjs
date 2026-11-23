// Isolated PostgreSQL only. Synthetic BLE reports exercise server rules, not radio range.
import {PGlite} from '../tmp/nearby-sql/node_modules/@electric-sql/pglite/dist/index.js';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const db=new PGlite();
const users=[1,2,3].map(n=>`00000000-0000-4000-8000-00000000000${n}`);
const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
let current;
const actor=async n=>{current=users[n-1]??'';await q("select set_config('request.jwt.claim.sub',$1,false)",[current]);};
const rpc=async(name,args=[]) => (await q(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) v`,args))[0].v;
const fix=()=>[0,0,3,new Date().toISOString()];
const begin=(location)=>rpc('sp_quiz_begin',[location,randomUUID(),...fix()]);
const answer=(attempt,selected=true,command=randomUUID())=>rpc('sp_quiz_answer',[attempt.id,command,selected,...fix()]);
const read=()=>rpc('sp_contacts_read');
const admin=async sql=>{await db.exec('reset role');await db.exec(sql);await db.exec('set role authenticated');};
try {
 await db.exec(`create role anon;create role authenticated;create schema auth;
 create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql as $$select jsonb_build_object('exp',extract(epoch from clock_timestamp()+interval '1 hour')::bigint)$$;`);
 for(let i=0;i<users.length;i++) await q('insert into auth.users values($1,$2)',[users[i],`level${i}@utrgv.edu`]);
 for(const file of ['20261108010000_sp_permanent_teams.sql','20261105010000_sp_bluetooth_nearby.sql',
  '20261115010000_sp_friend_communication.sql','20261116010000_sp_offline_friend_directory.sql',
  '20261116020000_sp_durable_offline_friends.sql','20261116030000_sp_short_friend_codes.sql',
  '20261117010000_sp_location_quizzes.sql','20261118010000_sp_bluetooth_contacts.sql']) {
  await db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
 }
 await db.exec('update sp_quiz.locations set latitude=0,longitude=0;set role authenticated');
 const codes=[];
 for(let n=1;n<=3;n++) {
  await actor(n);await rpc('sp_teams_choose',[n===1?'health_science':'math_engineering']);
  codes.push((await rpc('sp_friend_directory_read')).self_code);
 }
 await actor(1);const relationship=await rpc('sp_friend_directory_request_code',[codes[1].replaceAll('-','').slice(0,8)]);
 await actor(2);await rpc('sp_friend_directory_respond',[relationship,'accept']);
 // Preserve an actual old one-point receipt and score through the additive migration.
 await actor(3);const oldAttempt=await begin('kitty-island'),oldCommand=randomUUID();
 await answer(oldAttempt,true,oldCommand);
 await db.exec('reset role');
 await db.exec(await readFile(new URL('../supabase/migrations/20261118011000_sp_level_quiz_points.sql',import.meta.url),'utf8'));
 await db.exec('set role authenticated');
 const old=await answer(oldAttempt,true,oldCommand);
 assert.equal(old.awarded_points,1);assert.equal(old.reward_level,1);
 assert.equal(old.location.scores[0].correct,1);assert.equal(old.location.scores[0].points,1);
 const sa=randomUUID(),sb=randomUUID(),channel=randomUUID(),base=Date.now()-4*3_600_000;
 const rows=(n,start,end)=>Array.from({length:end-start},(_,offset)=>{
  const i=start+offset;return {id:randomUUID(),own_session:n===1?sa:sb,peer_session:n===1?sb:sa,
   peer_code:n===1?codes[1]:codes[0],contact_id:channel,
   started_at:new Date(base+i*15000).toISOString(),ended_at:new Date(base+(i+1)*15000).toISOString(),duration_ms:15000};
 });
 const upload=async(n,start,end)=>{
  await actor(n);const records=rows(n,start,end);
  for(let i=0;i<records.length;i+=50) await rpc('sp_contacts_sync',[current,JSON.stringify(records.slice(i,i+50))]);
 };
 await upload(1,0,320);assert.equal((await read()).level,1,'one-sided contact logs grant no levels');
 await upload(2,0,320);assert.equal((await read()).level,9);assert.equal((await read()).quiz_points,1);
 await actor(1);const below=await answer(await begin('kitty-island'));
 assert.equal(below.reward_level,9);assert.equal(below.awarded_points,1);
 assert.equal(below.location.owner.id,'math_engineering','first-to-score tie behavior is preserved');
 await upload(1,320,360);await upload(2,320,360);
 assert.equal((await read()).level,10);assert.equal((await read()).quiz_points,2);
 await actor(1);const active=await begin('stallion'),command=randomUUID();
 await assert.rejects(rpc('sp_quiz_answer',[active.id,command,true,1,1,3,new Date().toISOString()]),/proximity/);
 const bonus=await answer(active,true,command);
 assert.equal(bonus.awarded_points,2);assert.equal(bonus.reward_level,10);
 assert.equal(bonus.location.scores[0].correct,1);assert.equal(bonus.location.scores[0].points,2);
 assert.equal((await answer(active,true,command)).awarded_points,2,'receipt retry cannot award twice');
 await actor(2);await assert.rejects(answer(active,true,command),/unavailable/);
 const tie=await answer(await begin('stallion'));
 assert.equal(tie.location.owner.id,'health_science','first team reaching a tied weighted score wins');
 await actor(3);await answer(await begin('monstera'));
 await actor(1);const take=await answer(await begin('monstera'));
 assert.equal(take.location.owner.id,'health_science','two points beat one despite equal correct-answer counts');
 assert.equal(take.location.scores[0].points,2);assert.equal(take.location.scores[1].points,1);
 await actor(3);const wrong=await answer(await begin('stallion'),false);
 assert.equal(wrong.awarded_points,0);assert.equal(wrong.reward_level,1);
 assert.equal(wrong.location.owner.id,'health_science');
 await upload(1,360,560);await upload(2,360,560);
 assert.equal((await read()).level,15);assert.equal((await read()).quiz_points,2);
 await upload(1,560,600);await upload(2,560,600);
 assert.equal((await read()).level,16);assert.equal((await read()).quiz_points,2,'awards stay capped at two beyond level 15');
 await actor(1);
 await admin("update sp_contacts.settings set bonus_quiz_points=5;update sp_quiz.attempts set answered_at=clock_timestamp()-interval '601 seconds' where id='"+active.id+"'");
 assert.equal((await answer(active,true,command)).awarded_points,2,'saved reward cannot change with level or live rule changes');
 const repeat=await begin('stallion'),repeatCommand=randomUUID(),changed=await answer(repeat,true,repeatCommand);
 assert.notEqual(repeat.id,active.id);assert.equal(changed.awarded_points,5);assert.equal(changed.reward_level,16);
 const blue=changed.location.scores.find(s=>s.team.id==='health_science');
 assert.equal(blue.correct,2);assert.equal(blue.points,7,'configuration affects only new awards');
 await assert.rejects(q('update sp_contacts.settings set bonus_quiz_points=100'),/permission denied/);
 await assert.rejects(q('update sp_quiz.scores set points=100'),/permission denied/);
 const catalog = () => rpc('sp_quiz_catalog');
 const setHeaders = headers => q("select set_config('request.headers',$1,false)", [headers]);
 const original = await catalog();
 const duckHeader = JSON.stringify({'x-sp-quiz-animations':'horse,plant,cats,duck'});
 await setHeaders(duckHeader);
 assert.deepEqual(await catalog(), original, 'new app still works before the migration');
 await admin(await readFile(new URL('../supabase/migrations/20261122010000_sp_eieab_duck_quiz.sql',import.meta.url),'utf8'));
 await setHeaders('');
 assert.deepEqual(await catalog(), original, 'old apps retain their complete catalog');
 await setHeaders('{"content-type":"application/json"}');
 assert.deepEqual(await catalog(), original, 'old REST requests omit the capability header');
 await setHeaders(duckHeader);
 const locations = await catalog();
 const duck = locations.find(p=>p.id==='eieab');
 assert.deepEqual(locations.filter(p=>p.id!=='eieab'), original);
 assert.equal(duck.animation,'duck');
 assert.equal(duck.name,'Computer Science (EIEAB)');
 assert.equal(duck.owner,null);
 await assert.rejects(begin('eieab'),/proximity/);
 const duckFix = () => [duck.latitude,duck.longitude,3,new Date().toISOString()];
 const attempt = await rpc('sp_quiz_begin',['eieab',randomUUID(),...duckFix()]);
 assert.equal(attempt.location.id,'eieab');
 assert.equal(attempt.correct,null);
 const solved = await rpc('sp_quiz_answer',[attempt.id,randomUUID(),true,...duckFix()]);
 assert.equal(solved.correct,true);
 assert.equal(solved.awarded_points,5,'EIEAB uses the same current score rules');
 assert.equal(solved.location.owner.id,'health_science');
 const coolingDown = await rpc('sp_quiz_begin',['eieab',randomUUID(),...duckFix()]);
 assert.equal(coolingDown.id,solved.id,'cooldown returns the saved result');
 assert.equal(coolingDown.retry_at,solved.retry_at);
 await db.exec('set role anon');
 await assert.rejects(answer(repeat,true,repeatCommand),/permission denied/);
 await assert.rejects(catalog(),/permission denied/);
 console.log('PASS: old results preserved; matched Bluetooth reports -> levels 9/10/15/16 -> authoritative 1/2 point awards; weighted ownership, ties, cooldowns, wrong answers, immutable retries, live rules and private permissions.');
 console.log('PASS: EIEAB is opt-in by animation support; old catalogs stay identical; proximity, scoring, cooldown and permissions apply to the duck quiz.');
} finally {await db.close();}
