import test from "node:test";
import assert from "node:assert/strict";
import {
  BATCH_SIZE,MAX_WRITES,QUIET_MS,WATCHED_THRESHOLD,CREDITS_THRESHOLD,decodeWatched,completionDecision,selectBatch,run
} from "../src/worker.js";

const NOW=Date.parse("2026-09-18T20:00:00Z");
async function deflate(bytes){
  const stream=new Blob([bytes]).stream().pipeThrough(new CompressionStream("deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
async function encode(bits,ids){
  const bytes=new Uint8Array(Math.ceil(ids.length/8));let last=0;
  bits.forEach((v,i)=>{if(v){bytes[i>>3]|=1<<(i%8);last=i;}});
  const compressed=await deflate(bytes);
  let binary="";for(const b of compressed)binary+=String.fromCharCode(b);
  return `${ids[last]}:${last+1}:${btoa(binary)}`;
}
function videos(extra=[]){
  return [
    {id:"tt12345:1:1",season:1,episode:1,released:"2026-01-01T00:00:00Z"},
    {id:"tt12345:1:2",season:1,episode:2,released:"2026-01-08T00:00:00Z"},
    {id:"tt12345:1:3",season:1,episode:3,released:"2026-01-15T00:00:00Z"},
    ...extra
  ];
}
async function libraryItem({pointer="tt12345:1:3",bits=[true,true,true],offset=900,duration=1000,flagged=1,mtime=NOW-QUIET_MS-1000}={}){
  const ids=videos().map(v=>v.id);
  return {_id:"tt12345",type:"series",name:"Example",removed:false,temp:false,_mtime:new Date(mtime).toISOString(),
    state:{lastWatched:new Date(mtime).toISOString(),timeWatched:0,timeOffset:offset,overallTimeWatched:3000,timesWatched:3,flaggedWatched:flagged,duration,video_id:pointer,watched:await encode(bits,ids),noNotif:false},
    poster:null,posterShape:"poster",behaviorHints:{}};
}
test("bitmap decoder round-trips current watched state",async()=>{
  const ids=videos().map(v=>v.id),field=await encode([true,false,true],ids);
  assert.deepEqual(await decodeWatched(field,ids),[true,false,true]);
});
test("fully watched final released episode with stale completed progress is correctable",async()=>{
  const item=await libraryItem();const d=await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW);
  assert.equal(d?.id,"tt12345");
});
test("new released episode/season prevents cleanup and allows future re-entry",async()=>{
  const meta={id:"tt12345",type:"series",videos:videos([{id:"tt12345:2:1",season:2,episode:1,released:"2026-09-01T00:00:00Z"}])};
  const ids=meta.videos.map(v=>v.id);
  const item=await libraryItem();item.state.watched=await encode([true,true,true,false],ids);
  assert.equal(await completionDecision(item,meta,NOW),null);
});
test("future unreleased episode does not keep completed series in Continue Watching",async()=>{
  const meta={id:"tt12345",type:"series",videos:videos([{id:"tt12345:2:1",season:2,episode:1,released:"2026-10-01T00:00:00Z"}])};
  const ids=meta.videos.map(v=>v.id);
  const item=await libraryItem();item.state.watched=await encode([true,true,true,false],ids);
  assert.ok(await completionDecision(item,meta,NOW));
});
test("rewatching an older episode is preserved",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2"});
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});
test("active/recent playback is preserved",async()=>{
  const item=await libraryItem({mtime:NOW-5*60*1000});
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});
test("sub-threshold progress is preserved as an intentional resume",async()=>{
  const item=await libraryItem({offset:500,duration:1000});
  assert.ok(500/1000<WATCHED_THRESHOLD);
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});
test("unwatched released episode prevents cleanup",async()=>{
  const item=await libraryItem({bits:[true,true,false]});
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});
test("batch selection is deterministic and bounded",async()=>{
  const rows=[];for(let i=0;i<29;i++){const x=await libraryItem();x._id="tt"+String(10000+i);rows.push(x);}
  const seen=new Set(),count=Math.ceil(rows.length/BATCH_SIZE);
  for(let slot=0;slot<count;slot++)for(const x of selectBatch(rows,slot*10*60*1000).items)seen.add(x._id);
  assert.equal(seen.size,rows.length);
});
class DB{
  constructor(){this.rows=[];this.state=[];}
  prepare(sql){const self=this;return{bind(...args){return{async run(){if(sql.startsWith("INSERT INTO watch_backups")){self.rows.push(args);return{success:true};}if(sql.startsWith("DELETE"))return{success:true};if(sql.startsWith("INSERT INTO maintenance_state")){self.state=args;return{success:true};}throw new Error("sql");}}}};}
}
function metaBinding(meta){return{fetch:async r=>Response.json({meta})};}
async function fingerprint(){
  const b=new TextEncoder().encode("stremio:account-1");const d=await crypto.subtle.digest("SHA-256",b);return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("");
}
function fixture(initial){
  let row=structuredClone(initial),puts=0,reads=0;
  const fetchImpl=async(url,init={})=>{
    const ep=String(url).split("/").pop(),body=JSON.parse(init.body||"{}");
    if(ep==="getUser")return Response.json({result:{_id:"account-1"}});
    if(ep==="datastoreGet"){reads++;if(body.all)return Response.json({result:[structuredClone(row)]});return Response.json({result:[structuredClone(row)]});}
    if(ep==="datastorePut"){puts++;row=structuredClone(body.changes[0]);return Response.json({result:{success:true}});}
    throw new Error(ep);
  };
  return{fetchImpl,get row(){return row},get puts(){return puts},get reads(){return reads}};
}
function key(){const b=new Uint8Array(32);crypto.getRandomValues(b);let s="";for(const x of b)s+=String.fromCharCode(x);return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");}
test("scheduled run clears only timeOffset and keeps watched history intact",async()=>{
  const before=await libraryItem(),f=fixture(before),db=new DB(),meta={id:"tt12345",type:"series",videos:videos()};
  const env={STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,METADATA:metaBinding(meta)};
  const s=await run(env,NOW,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(s.verifiedWrites,1);assert.equal(f.puts,1);assert.equal(f.row.state.timeOffset,0);
  const a=structuredClone(before),b=structuredClone(f.row);delete a._mtime;delete b._mtime;delete a.state.timeOffset;delete b.state.timeOffset;
  assert.deepEqual(b,a);assert.equal(db.rows.length,1);
});
test("hard write cap is enforced",async()=>{
  const rows=[];for(let i=0;i<5;i++){const x=await libraryItem();x._id="tt"+String(12345+i);const ids=videos().map(v=>v.id.replace("tt12345",x._id));x.state.video_id=ids[2];x.state.watched=await encode([true,true,true],ids);rows.push(x);}
  let current=structuredClone(rows),puts=0;
  const fetchImpl=async(url,init={})=>{const ep=String(url).split("/").pop(),body=JSON.parse(init.body||"{}");if(ep==="getUser")return Response.json({result:{_id:"account-1"}});if(ep==="datastoreGet"){if(body.all)return Response.json({result:structuredClone(current)});const x=current.find(r=>r._id===body.ids[0]);return Response.json({result:x?[structuredClone(x)]:[]});}if(ep==="datastorePut"){puts++;const c=body.changes[0];current=current.map(x=>x._id===c._id?structuredClone(c):x);return Response.json({result:true});}};
  const db=new DB(),env={STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,METADATA:{fetch:async r=>{const id=new URL(r.url).pathname.split("/").pop().replace(".json","");return Response.json({meta:{id,type:"series",videos:videos().map(v=>({...v,id:v.id.replace("tt12345",id)}))}});}}};
  const s=await run(env,NOW,{fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(s.attemptedWrites,MAX_WRITES);assert.equal(puts,MAX_WRITES);
});
test("public surface is closed",async()=>{assert.equal((await (await import("../src/worker.js")).default.fetch(new Request("https://x/"))).status,404);});


function movieItem({offset=950,duration=1000,flagged=1,mtime=NOW-QUIET_MS-1000,id="tt9990001"}={}){
  return {
    _id:id,type:"movie",name:"Movie Example",removed:false,temp:false,
    _mtime:new Date(mtime).toISOString(),
    state:{
      lastWatched:new Date(mtime).toISOString(),timeWatched:950,timeOffset:offset,
      overallTimeWatched:950,timesWatched:1,flaggedWatched:flagged,duration,
      video_id:id,watched:null,noNotif:false
    },
    poster:null,posterShape:"poster",behaviorHints:{}
  };
}

test("movie past Core credits threshold is eligible without metadata lookup",async()=>{
  const item=movieItem({offset:950,duration:1000});
  assert.ok(950/1000>CREDITS_THRESHOLD);
  const d=await completionDecision(item,null,NOW);
  assert.equal(d?.reason,"movie-past-native-credits-threshold-stale-progress");
});

test("movie at or below Core credits threshold is preserved",async()=>{
  assert.equal(await completionDecision(movieItem({offset:900,duration:1000}),null,NOW),null);
  assert.equal(await completionDecision(movieItem({offset:899,duration:1000}),null,NOW),null);
});

test("movie without watched flag or with recent playback is preserved",async()=>{
  assert.equal(await completionDecision(movieItem({flagged:0}),null,NOW),null);
  assert.equal(await completionDecision(movieItem({mtime:NOW-5*60*1000}),null,NOW),null);
});

test("scheduled movie cleanup does not depend on metadata service",async()=>{
  const before=movieItem({id:"tt9990002"});
  const f=fixture(before),db=new DB();
  const env={
    STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),
    BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,
    METADATA:{fetch:async()=>{throw new Error("metadata should not be called for movies");}}
  };
  const s=await run(env,NOW,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(s.verifiedWrites,1);
  assert.equal(f.row.state.timeOffset,0);
  assert.equal(db.rows.length,1);
});
