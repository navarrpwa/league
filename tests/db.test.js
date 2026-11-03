// Runs against a real PostgreSQL server using the same migrations as production.
const {boot,as}=require('./lib');const assert=require('assert');
let pass=0,fail=0;const T=async(n,f)=>{try{await f();pass++;console.log('  ok  '+n)}catch(e){fail++;console.log('FAIL  '+n+'\n      '+e.message)}};
const denied=async p=>{let m=null;try{await p}catch(e){m=e.message}assert(m,'expected refusal');return m};
(async()=>{
const {pg,pool}=await boot(55441,require('os').tmpdir()+'/league-pg-test');
const mk=async e=>(await pool.query(`insert into auth.users(email) values($1) returning id`,[e])).rows[0].id;
const admin=await mk('admin@x.io');await pool.query(`select private.bootstrap_admin('admin@x.io','Doha League')`);
const A=(s,p)=>as(pool,admin,s,p);
const one=async(u,fn,...args)=>{const ph=args.map((_,i)=>'$'+(i+1)).join(',');return Object.values((await as(pool,u,`select public.${fn}(${ph}) r`,args)).rows[0])[0]};
const st=async()=>(await as(pool,null,'select public.get_auction_state() r')).rows[0].r;
const teams={};const users={};
for(const n of ['Falcons','Oryx','Pearls','Dunes']){const t=await one(admin,'admin_save_team',JSON.stringify({name:n,starting_budget:1000,squad_limit:2}));teams[n]=t.id;const u=await mk(n+'@x.io');users[n]=u;await one(admin,'admin_link_team_login',t.id,n+'@x.io')}
const reg=(i,o={})=>one(null,'register_player',JSON.stringify({full_name:'Player '+i,phone:'+974 5550 '+String(1000+i),photo_path:`registrations/00000000-0000-0000-0000-${String(i).padStart(12,'0')}.jpg`,primary_position:'Forward',age:22,category:'Senior',...o}));
const pidOf=async name=>(await pool.query('select id from players where full_name=$1',[name])).rows[0].id;
const apOf=async name=>(await pool.query('select a.id from auction_players a join players p on p.id=a.player_id where p.full_name=$1',[name])).rows[0].id;
const approve=async(name,base=100)=>one(admin,'admin_set_player_status',await pidOf(name),'approved',base);
const bid=(team,ap,amt)=>one(users[team],'place_bid',ap,amt);

console.log('Registration');
await T('anon can register; gets unique sequential id',async()=>{const r=await reg(1);assert.equal(r.code,'P-0001');assert.equal(r.status,'pending');const r2=await reg(2);assert.equal(r2.code,'P-0002')});
await T('duplicate phone refused, formatting ignored',async()=>{const m=await denied(reg(3,{phone:'974-5550-1001'}));assert.match(m,/already registered/)});
await T('photo path outside registrations refused',async()=>{await denied(reg(4,{photo_path:'players/x.jpg'}))});
await T('bad position refused',async()=>{await denied(reg(5,{primary_position:'Wizard'}))});
await T('precheck reports duplicate',async()=>{const r=await one(null,'registration_precheck','97455501001');assert.equal(r.ok,false)});
await T('closing registration blocks new ones',async()=>{await one(admin,'admin_save_tournament',JSON.stringify({registration_open:false}));await denied(reg(6));await one(admin,'admin_save_tournament',JSON.stringify({registration_open:true}))});

console.log('Privacy and permissions');
await T('anon cannot read phone numbers',async()=>{const r=await as(pool,null,'select * from player_contacts');assert.equal(r.rowCount,0)});
await T('team cannot read phone numbers',async()=>{const r=await as(pool,users.Oryx,'select * from player_contacts');assert.equal(r.rowCount,0)});
await T('admin can read phone numbers',async()=>{const r=await A('select * from player_contacts');assert.equal(r.rowCount,2)});
await T('pending players hidden from public',async()=>{const r=await as(pool,null,'select * from players');assert.equal(r.rowCount,0)});
await T('public state has no phone anywhere',async()=>{assert(!/5550/.test(JSON.stringify(await st())))});
for(const [n,q] of Object.entries({
 'budget':`update team_budgets set spent=0, starting_budget=999999`,'insert budget':`insert into team_budgets values (gen_random_uuid(),gen_random_uuid(),1,0,1)`,
 'session':`update auction_sessions set status='ended'`,'sale':`delete from player_sales`,'bid insert':`insert into bids(session_id,auction_player_id,team_id,amount,round) select id,id,id,1,1 from auction_sessions`,
 'role':`update profiles set role='admin'`,'audit':`delete from admin_audit_logs`,'players':`update players set status='approved'`,'membership':`insert into team_memberships(team_id,user_id) values(gen_random_uuid(),gen_random_uuid())`}))
 await T('team cannot write directly: '+n,()=>denied(as(pool,users.Oryx,q)));
for(const fn of ['admin_start_auction()','admin_list(\'players\')','admin_undo_sale(gen_random_uuid(),\'nope\')','admin_save_team(\'{"name":"zz"}\')']){
 await T('team refused: '+fn,()=>denied(as(pool,users.Oryx,'select public.'+fn)));
 await T('anon refused: '+fn,()=>denied(as(pool,null,'select public.'+fn)));
}
await T('internal functions unreachable by API roles',async()=>{await denied(as(pool,users.Oryx,`select private.bootstrap_admin('Oryx@x.io')`));await denied(as(pool,users.Oryx,`select private.recalc_budget(gen_random_uuid())`));await denied(as(pool,null,`select private.apply_bid(gen_random_uuid(),gen_random_uuid(),1,'team')`))});
await T('team cannot open another team dashboard',async()=>{await denied(one(users.Oryx,'get_team_dashboard',teams.Falcons));assert.equal((await one(users.Oryx,'get_team_dashboard')).team.name,'Oryx')});
await T('anon cannot bid',()=>denied(one(null,'place_bid','00000000-0000-0000-0000-000000000000',1)));
await T('anon may upload only to registrations',async()=>{await as(pool,null,`insert into storage.objects(bucket_id,name) values('league-media','registrations/a.jpg')`);await denied(as(pool,null,`insert into storage.objects(bucket_id,name) values('league-media','teams/a.jpg')`));await denied(as(pool,users.Oryx,`insert into storage.objects(bucket_id,name) values('league-media','teams/b.jpg')`));await A(`insert into storage.objects(bucket_id,name) values('league-media','teams/c.jpg')`)});
await T('every public function is security definer or read-only, none open to anon by accident',async()=>{const r=await pool.query(`select p.proname from pg_proc p where p.pronamespace='public'::regnamespace and has_function_privilege('anon',p.oid,'execute')`);assert.deepEqual(r.rows.map(x=>x.proname).sort(),['get_auction_state','register_player','registration_precheck'])});
await T('every table has RLS',async()=>{const r=await pool.query(`select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity`);assert.equal(r.rowCount,0)});

console.log('Auction flow');
await approve('Player 1',100);await approve('Player 2',100);for(let i=7;i<=12;i++){await reg(i);await approve('Player '+i,100)}
const P1=await apOf('Player 1'),P2=await apOf('Player 2');
await T('stats: pool of 8',async()=>{const s=(await st()).stats;assert.equal(s.registered,8);assert.equal(s.remaining,8);assert.equal(s.teams,4)});
await T('cannot select before start',()=>denied(one(admin,'admin_select_player',P1,'order')));
await one(admin,'admin_start_auction');
await T('select player -> introduction',async()=>{await one(admin,'admin_select_player',P1,'order');const s=await st();assert.equal(s.session.phase,'introduction');assert.equal(s.current.next_bid,100)});
await T('second selection refused while one active',()=>denied(one(admin,'admin_select_player',P2,'order')));
await T('bid before bidding opens rejected',async()=>{assert.equal((await bid('Falcons',P1,100)).code,'not_open')});
await T('sold without last call refused',async()=>{await one(admin,'admin_open_bidding');await denied(one(admin,'admin_confirm_sold',P1))});
await T('first bid must equal base',async()=>{assert.equal((await bid('Falcons',P1,50)).code,'price_moved');assert.equal((await bid('Falcons',P1,100)).ok,true)});
await T('leader cannot outbid itself',async()=>{assert.equal((await bid('Falcons',P1,110)).code,'already_leading')});
await T('underbid and overbid rejected',async()=>{assert.equal((await bid('Oryx',P1,100)).code,'price_moved');assert.equal((await bid('Oryx',P1,500)).code,'price_moved')});
await T('rejected bids are logged for admin',async()=>{const e=await one(admin,'admin_list','events',50);assert(e.some(x=>x.type==='bid_rejected'))});
await T('100 simultaneous bids: exactly one accepted',async()=>{
  const names=Object.keys(users).filter(n=>n!=='Falcons');const rs=await Promise.all(Array.from({length:100},(_,i)=>bid(names[i%3],P1,110)));
  assert.equal(rs.filter(r=>r.ok).length,1);const s=await st();assert.equal(s.current.high_bid,110);assert.equal(s.current.bid_count,2)});
await T('multi-round race keeps a strictly increasing ladder',async()=>{
  let cur=(await st()).current;const all=Object.keys(users);
  for(let i=0;i<8;i++){const amt=cur.high_bid+cur.bid_increment;await Promise.all(all.map(n=>bid(n,P1,amt)));const nx=(await st()).current;assert.equal(nx.high_bid,amt);assert.equal(nx.bid_count,cur.bid_count+1);cur=nx}
  const b=(await pool.query('select amount from bids where auction_player_id=$1 and voided_at is null order by created_at',[P1])).rows.map(x=>x.amount);
  b.forEach((v,i)=>i&&assert.equal(v,b[i-1]+10));assert.equal(new Set(b).size,b.length)});
await T('pause blocks bids, keeps countdown; resume restores',async()=>{const c=(await st()).current;await one(admin,'admin_pause_auction');const nb=c.high_bid+10;const other=Object.keys(teams).find(n=>teams[n]!==c.high_team_id);assert.equal((await bid(other,P1,nb)).code,'paused');const s=await st();assert(s.session.paused_remaining_ms>0);assert.equal(s.session.countdown_ends_at,null);await denied(one(admin,'admin_last_call'));await one(admin,'admin_resume_auction');assert((await st()).session.countdown_ends_at)});
await T('last call then reopen',async()=>{await one(admin,'admin_last_call');assert.equal((await st()).session.phase,'last_call');await one(admin,'admin_open_bidding');assert.equal((await st()).session.phase,'bidding')});
await T('expired last call rejects bids but does not sell',async()=>{await one(admin,'admin_last_call');await pool.query(`update auction_sessions set countdown_ends_at=now()-interval '1 second'`);const s=await st();const nb=s.current.next_bid;const other=Object.keys(teams).find(n=>teams[n]!==s.current.high_team_id);assert.equal((await bid(other,P1,nb)).code,'last_call_over');const s2=await st();assert.equal(s2.session.phase,'last_call');assert.equal(s2.current.status,'active');assert.equal(s2.last_result,null);assert.equal((await pool.query('select count(*)::int c from player_sales')).rows[0].c,0)});
let saleId,winner,price;
await T('confirm sold deducts exactly once under 10 concurrent confirms',async()=>{const s=await st();winner=s.current.high_team_id;price=s.current.high_bid;
  const rs=await Promise.allSettled(Array.from({length:10},()=>one(admin,'admin_confirm_sold',P1)));assert.equal(rs.filter(r=>r.status==='fulfilled').length,1);
  const s2=await st();assert.equal(s2.session.phase,'sold');assert.equal(s2.last_result.price,price);assert.equal(s2.teams.find(t=>t.id===winner).spent,price);assert.equal(s2.teams.find(t=>t.id===winner).squad_count,1);assert.equal(s2.last_result.team_spent,price);saleId=rs.find(r=>r.status==='fulfilled').value.sale_id});
await T('bid after sale rejected',async()=>{const n=Object.keys(teams).find(k=>teams[k]!==winner);assert.equal((await bid(n,P1,price+10)).code,'not_open')});
await T('stats after sale',async()=>{const s=(await st()).stats;assert.equal(s.sold,1);assert.equal(s.remaining,7);assert.equal(Number(s.progress),12.5)});
await T('undo needs reason',()=>denied(one(admin,'admin_undo_sale',saleId,'')));
await T('undo restores points, requeues, audit written, once only',async()=>{await one(admin,'admin_undo_sale',saleId,'Wrong team');const s=await st();assert.equal(s.teams.find(t=>t.id===winner).spent,0);assert.equal(s.teams.find(t=>t.id===winner).squad_count,0);assert.equal(s.session.phase,'idle');assert.equal(s.stats.sold,0);assert.equal(s.stats.remaining,8);assert.equal(s.last_result,null);
  await denied(one(admin,'admin_undo_sale',saleId,'again'));const a=await one(admin,'admin_list','audit',50);assert(a.some(x=>x.action==='auction.undo_sale'&&x.reason==='Wrong team'));
  const l=(await one(admin,'admin_list','lots')).find(x=>x.auction_player_id===P1);assert.equal(l.status,'queued');assert.equal(l.bid_count,0)});
await T('audit log is append-only even for owner',()=>denied(pool.query('delete from admin_audit_logs')));
await T('resold player restarts from base after undo',async()=>{await one(admin,'admin_select_player',P1,'order');await one(admin,'admin_open_bidding');assert.equal((await bid('Oryx',P1,100)).ok,true);await one(admin,'admin_last_call');await one(admin,'admin_confirm_sold',P1);assert.equal((await st()).teams.find(t=>t.name==='Oryx').spent,100)});
await T('budget cap: cannot bid beyond remaining',async()=>{await one(admin,'admin_save_team',JSON.stringify({id:teams.Pearls,starting_budget:50}));await one(admin,'admin_select_player',P2,'order');await one(admin,'admin_open_bidding');const r=await bid('Pearls',P2,100);assert.equal(r.code,'insufficient_points')});
await T('budget cannot be cut below spent',()=>denied(one(admin,'admin_save_team',JSON.stringify({id:teams.Oryx,starting_budget:50}))));
await T('squad limit below current refused; squad full blocks bids',async()=>{await bid('Oryx',P2,100);await one(admin,'admin_last_call');await one(admin,'admin_confirm_sold',P2);await denied(one(admin,'admin_save_team',JSON.stringify({id:teams.Oryx,squad_limit:1})));
  const P3=await apOf('Player 7');await one(admin,'admin_select_player',P3,'order');await one(admin,'admin_open_bidding');assert.equal((await bid('Oryx',P3,100)).code,'squad_full')});
await T('unsold with no bids; reopen returns to queue',async()=>{const P3=await apOf('Player 7');await one(admin,'admin_mark_unsold',P3);let s=await st();assert.equal(s.session.phase,'unsold');assert.equal(s.stats.unsold,1);assert.equal(s.last_result.status,'unsold');await denied(one(admin,'admin_confirm_sold',P3));await one(admin,'admin_reopen_unsold',P3);s=await st();assert.equal(s.stats.unsold,0)});
await T('skip voids bids and allows reselection from base',async()=>{const P=await apOf('Player 8');await one(admin,'admin_select_player',P,'order');await one(admin,'admin_open_bidding');await bid('Dunes',P,100);await one(admin,'admin_skip_player',P);let s=await st();assert.equal(s.session.phase,'idle');await one(admin,'admin_select_player',P,'order');s=await st();assert.equal(s.current.high_bid,null);assert.equal(s.current.next_bid,100);await one(admin,'admin_skip_player',P)});
await T('withdrawn player leaves the pool; sold player cannot withdraw',async()=>{const before=(await st()).stats.remaining;await one(admin,'admin_set_player_status',await pidOf('Player 12'),'withdrawn',null);assert.equal((await st()).stats.remaining,before-1);await denied(one(admin,'admin_set_player_status',await pidOf('Player 1'),'withdrawn',null))});
await T('base price locked after bids; increment editable',async()=>{const P=await apOf('Player 9');await one(admin,'admin_select_player',P,'order');await one(admin,'admin_open_bidding');await bid('Dunes',P,100);await denied(one(admin,'admin_update_lot',P,200,null));await one(admin,'admin_update_lot',P,null,25);assert.equal((await st()).current.next_bid,125)});
await T('admin can enter a bid for a team and it is audited',async()=>{const P=await apOf('Player 9');const r=await one(admin,'admin_place_bid',P,teams.Falcons,125);assert.equal(r.ok,true);const a=await one(admin,'admin_list','audit',5);assert(a.some(x=>x.action==='auction.admin_bid'))});
await T('end refused during active lot, allowed after',async()=>{const P=await apOf('Player 9');await denied(one(admin,'admin_end_auction'));await one(admin,'admin_last_call');await one(admin,'admin_confirm_sold',P);await one(admin,'admin_end_auction');const s=await st();assert.equal(s.session.status,'ended');assert.equal(s.teams.find(t=>t.name==='Falcons').spent,125)});
await T('budgets match sales ledger',async()=>{const r=await pool.query(`select b.team_id from team_budgets b left join (select team_id,sum(price) s from player_sales where undone_at is null group by 1) x using(team_id) where b.spent<>coalesce(x.s,0)`);assert.equal(r.rowCount,0)});
await T('version strictly grew',async()=>{assert((await st()).session.version>20)});
await T('csv import reports row errors',async()=>{const r=await one(admin,'admin_import_players',JSON.stringify([{full_name:'Imp One',phone:'55512345',primary_position:'Forward',category:'Senior'},{full_name:'Imp Dup',phone:'55512345',primary_position:'Forward',category:'Senior'},{full_name:'Bad',phone:'1',primary_position:'Forward',category:'Senior'}]));assert.equal(r.created,1);assert.equal(r.errors.length,2)});
console.log(`\n${pass} passed, ${fail} failed`);await pool.end();await pg.stop();process.exit(fail?1:0);
})().catch(e=>{console.error(e);process.exit(2)});
