const path=require('path');const fs=require('fs');const os=require('os');
const {Pool,Client}=require('pg');
async function boot(port,dir){
  const EP=(await import('embedded-postgres')).default;
  fs.rmSync(dir,{recursive:true,force:true});
  const pg=new EP({databaseDir:dir,user:'postgres',password:'pw',port,persistent:false,createPostgresUser:process.getuid&&process.getuid()===0,onLog:()=>{},onError:()=>{}});
  await pg.initialise();await pg.start();await pg.createDatabase('app');
  const url=`postgres://postgres:pw@localhost:${port}/app`;
  const pool=new Pool({connectionString:url,max:40});
  const root=path.join(__dirname,'..','supabase');
  await pool.query(fs.readFileSync(path.join(__dirname,'supabase_stub.sql'),'utf8'));
  for(const f of ['0001_schema.sql','0002_functions.sql','0003_security.sql'])await pool.query(fs.readFileSync(path.join(root,'migrations',f),'utf8'));
  return {pg,pool,url};
}
// Runs SQL as an API caller would arrive: restricted role plus JWT subject.
async function as(pool,user,sql,params=[]){
  const c=await pool.connect();
  try{await c.query('begin');
    await c.query(`select set_config('request.jwt.sub',$1,true)`,[user||'']);
    await c.query(`set local role ${user?'authenticated':'anon'}`);
    const r=await c.query(sql,params);await c.query('commit');return r;
  }catch(e){await c.query('rollback');throw e}finally{c.release()}
}
module.exports={boot,as};
