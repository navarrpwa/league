// Local stand-in for Supabase's HTTP APIs, used for browser tests. Business logic and permissions still run in real PostgreSQL.
const http=require('http'),fs=require('fs'),path=require('path'),crypto=require('crypto');
const {boot}=require('./lib');const {WebSocketServer}=require('ws');const {Client}=require('pg');
const SECRET='test';const b64=x=>Buffer.from(x).toString('base64url');
const sign=u=>{const h=b64(JSON.stringify({alg:'HS256',typ:'JWT'})),p=b64(JSON.stringify({sub:u.id,email:u.email,role:'authenticated',aud:'authenticated',exp:Math.floor(Date.now()/1000)+3600}));return `${h}.${p}.${crypto.createHmac('sha256',SECRET).update(h+'.'+p).digest('base64url')}`};
const verify=t=>{try{const [h,p,s]=t.split('.');if(crypto.createHmac('sha256',SECRET).update(h+'.'+p).digest('base64url')!==s)return null;return JSON.parse(Buffer.from(p,'base64url'))}catch{return null}};
const sha=p=>crypto.createHash('sha256').update(p).digest('hex');
const CORS={'access-control-allow-origin':'*','access-control-allow-headers':'*','access-control-allow-methods':'*','access-control-expose-headers':'*'};
const media=new Map();
async function start({apiPort=8089,sitePort=8088,pgPort=55442}={}){
  const {pg,pool,url}=await boot(pgPort,require('os').tmpdir()+'/league-pg-e2e');
  await pool.query(`create function private.t_notify() returns trigger language plpgsql as $$ begin perform pg_notify('rt',row_to_json(new)::text); return new; end $$; create trigger t_notify after update on public.auction_sessions for each row execute function private.t_notify();`);
  const argCache={};
  const fnArgs=async f=>argCache[f]||(argCache[f]=(await pool.query(`select unnest(proargnames) n,unnest(proargtypes::regtype[]::text[]) t from pg_proc where proname=$1 and pronamespace='public'::regnamespace`,[f])).rows);
  const send=(res,code,obj,h={})=>{res.writeHead(code,{'content-type':'application/json',...CORS,...h});res.end(obj===undefined?'':JSON.stringify(obj))};
  const session=u=>({access_token:sign(u),token_type:'bearer',expires_in:3600,expires_at:Math.floor(Date.now()/1000)+3600,refresh_token:u.id,user:userObj(u)});
  const userObj=u=>({id:u.id,aud:'authenticated',role:'authenticated',email:u.email,app_metadata:{},user_metadata:{},identities:[{id:u.id}],created_at:new Date().toISOString()});
  const stats={rpc:[],killed:false};
  const api=http.createServer(async(req,res)=>{
    if(req.method==='OPTIONS')return send(res,204);
    const u=new URL(req.url,'http://x');const chunks=[];for await(const c of req)chunks.push(c);const buf=Buffer.concat(chunks);
    const body=()=>{try{return JSON.parse(buf.toString()||'{}')}catch{return{}}};
    const claims=verify((req.headers.authorization||'').replace('Bearer ',''));
    try{
      if(u.pathname==='/auth/v1/token'){
        const b=body();let r;
        if(u.searchParams.get('grant_type')==='password')r=await pool.query('select * from auth.users where lower(email)=lower($1) and encrypted_password=$2',[b.email,sha(b.password)]);
        else r=await pool.query('select * from auth.users where id=$1',[b.refresh_token]);
        if(!r.rowCount)return send(res,400,{error_code:'invalid_credentials',msg:'Invalid login credentials',message:'Invalid login credentials'});
        return send(res,200,session(r.rows[0]));
      }
      if(u.pathname==='/auth/v1/signup'){const b=body();
        const ex=await pool.query('select * from auth.users where lower(email)=lower($1)',[b.email]);
        if(ex.rowCount)return send(res,422,{code:422,error_code:'user_already_exists',msg:'User already registered'});
        const r=await pool.query('insert into auth.users(email,encrypted_password) values($1,$2) returning *',[b.email,sha(b.password)]);return send(res,200,session(r.rows[0]));}
      if(u.pathname==='/auth/v1/user'){if(!claims)return send(res,401,{msg:'no'});
        if(req.method==='PUT'){const b=body();if(b.password)await pool.query('update auth.users set encrypted_password=$2 where id=$1',[claims.sub,sha(b.password)])}
        return send(res,200,userObj({id:claims.sub,email:claims.email}));}
      if(u.pathname==='/auth/v1/logout')return send(res,204);
      if(u.pathname==='/auth/v1/recover')return send(res,200,{});
      let m;
      if((m=u.pathname.match(/^\/rest\/v1\/rpc\/(\w+)$/))){
        const fn=m[1],b=body();stats.rpc.push(fn);if(stats.down)return res.destroy();
        const defs=await fnArgs(fn);const vals=[],parts=[];
        for(const [k,v] of Object.entries(b)){const d=defs.find(x=>x.n===k);if(!d)return send(res,404,{message:'no arg '+k});vals.push(d.t==='jsonb'?JSON.stringify(v):v);parts.push(`${k} => $${vals.length}::${d.t}`)}
        const c=await pool.connect();
        try{await c.query('begin');await c.query(`select set_config('request.jwt.sub',$1,true)`,[claims?.sub||'']);await c.query(`set local role ${claims?'authenticated':'anon'}`);
          const r=await c.query(`select public.${fn}(${parts.join(',')}) as r`,vals);await c.query('commit');return send(res,200,r.rows[0].r);
        }catch(e){await c.query('rollback');return send(res,e.code==='42501'?403:400,{message:e.message,code:e.code})}finally{c.release()}
      }
      if((m=u.pathname.match(/^\/storage\/v1\/object\/public\/league-media\/(.+)$/))){const f=media.get(decodeURIComponent(m[1]));if(!f){return send(res,404,{})}res.writeHead(200,{'content-type':f.type,...CORS});return res.end(f.data)}
      if((m=u.pathname.match(/^\/storage\/v1\/object\/league-media\/(.+)$/))&&req.method==='POST'){
        const name=decodeURIComponent(m[1]);const c=await pool.connect();
        try{await c.query('begin');await c.query(`select set_config('request.jwt.sub',$1,true)`,[claims?.sub||'']);await c.query(`set local role ${claims?'authenticated':'anon'}`);await c.query(`insert into storage.objects(bucket_id,name) values('league-media',$1)`,[name]);await c.query('commit')}
        catch(e){await c.query('rollback');return send(res,403,{statusCode:'403',error:'Unauthorized',message:e.message})}finally{c.release()}
        let data=buf;const ct=req.headers['content-type']||'';let type=ct;
        if(ct.includes('multipart')){const bd=Buffer.from('--'+ct.split('boundary=')[1]);const parts=[];let i=buf.indexOf(bd);while(i>=0){const j=buf.indexOf(bd,i+bd.length);if(j<0)break;parts.push(buf.slice(i+bd.length+2,j-2));i=j}
          const fp=parts.find(p=>/content-type/i.test(p.slice(0,300).toString()));const he=fp.indexOf('\r\n\r\n');type=/content-type:\s*([^\r\n]+)/i.exec(fp.slice(0,he).toString())[1];data=fp.slice(he+4)}
        media.set(name,{data,type});return send(res,200,{Key:'league-media/'+name,Id:name});
      }
      send(res,404,{message:'not found '+u.pathname});
    }catch(e){send(res,500,{message:e.message})}
  });
  // Realtime: the parts of the Phoenix channel protocol supabase-js uses.
  const wss=new WebSocketServer({server:api,path:'/realtime/v1/websocket'});
  const clients=new Set();
  wss.on('connection',(ws,req)=>{
    const v2=new URL(req.url,'http://x').searchParams.get('vsn')==='2.0.0';
    const tx=(join,ref,topic,event,payload)=>{try{ws.send(JSON.stringify(v2?[join,ref,topic,event,payload]:{join_ref:join,ref,topic,event,payload}))}catch{}};
    const c={ws,tx,topics:new Map()};clients.add(c);
    ws.on('close',()=>clients.delete(c));
    ws.on('message',m=>{let d=JSON.parse(m.toString());if(Array.isArray(d))d={join_ref:d[0],ref:d[1],topic:d[2],event:d[3],payload:d[4]};
      if(d.event==='phx_join'){const pc=(d.payload.config?.postgres_changes||[]).map((x,i)=>({id:i+1,...x}));c.topics.set(d.topic,{join:d.join_ref||d.ref,ids:pc.map(x=>x.id)});
        tx(d.join_ref||d.ref,d.ref,d.topic,'phx_reply',{status:'ok',response:{postgres_changes:pc}});
        tx(null,null,d.topic,'system',{channel:d.topic.replace('realtime:',''),extension:'postgres_changes',message:'Subscribed to PostgreSQL',status:'ok'});}
      else if(d.event==='phx_leave'){c.topics.delete(d.topic);tx(d.join_ref,d.ref,d.topic,'phx_reply',{status:'ok',response:{}})}
      else tx(d.join_ref??null,d.ref,d.topic,'phx_reply',{status:'ok',response:{}});
    });
  });
  const lis=new Client({connectionString:url});await lis.connect();await lis.query('listen rt');
  lis.on('notification',n=>{const rec=JSON.parse(n.payload);for(const c of clients)for(const [t,i] of c.topics)c.tx(i.join,null,t,'postgres_changes',{ids:i.ids,data:{type:'UPDATE',schema:'public',table:'auction_sessions',commit_timestamp:new Date().toISOString(),columns:Object.keys(rec).map(k=>({name:k,type:'text'})),record:rec,old_record:{},errors:null}})});
  await new Promise(r=>api.listen(apiPort,r));
  // Static site served under a project subpath, the way GitHub Pages does.
  const root=path.join(__dirname,'..');
  const types={'.html':'text/html','.js':'text/javascript','.webmanifest':'application/manifest+json','.png':'image/png'};
  const site=http.createServer((req,res)=>{let p=new URL(req.url,'http://x').pathname;
    if(!p.startsWith('/league-auction/')){res.writeHead(404);return res.end('outside subpath')}
    p=p.replace('/league-auction/','')||'index.html';const f=path.join(root,p);
    if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){res.writeHead(404);return res.end()}
    let d=fs.readFileSync(f);if(p==='index.html')d=d.toString().replace('YOUR_SUPABASE_URL',`http://localhost:${apiPort}`).replace('YOUR_SUPABASE_PUBLISHABLE_KEY','anon');
    res.writeHead(200,{'content-type':types[path.extname(f)]||'text/plain'});res.end(d)});
  await new Promise(r=>site.listen(sitePort,r));
  return {pool,pg,stats,clients,stop:async()=>{wss.close();api.close();site.close();await lis.end();await pool.end();await pg.stop()}};
}
module.exports={start,sha};
