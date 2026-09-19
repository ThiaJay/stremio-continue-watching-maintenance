const API="https://api.strem.io/api";
const MAX_LIBRARY=20000;
const BATCH_SIZE=8;
const MAX_WRITES=2;
const QUIET_MS=30*60*1000;
const WATCHED_THRESHOLD=0.7;
const CREDITS_THRESHOLD=0.9;
const RESIDUAL_POINTER_MAX_MS=15_000;
const CRON_MS=10*60*1000;
const BACKUP_TTL_MS=14*24*60*60*1000;
const BULK_WATCHED_TRANSITION_WINDOW_MS=2*60*60*1000;

class StateError extends Error{constructor(code){super(code);this.name="StateError";this.code=code;}}
const assert=(x,code)=>{if(!x)throw new StateError(code);};
const stable=value=>Array.isArray(value)?value.map(stable):value&&typeof value==="object"?Object.fromEntries(Object.keys(value).sort().map(k=>[k,stable(value[k])])):value;
const canonical=value=>JSON.stringify(stable(value));
async function sha256(value){const b=new TextEncoder().encode(String(value));const d=await crypto.subtle.digest("SHA-256",b);return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("");}
async function hash(value){return sha256(canonical(value));}

async function boundedJson(response,limit=12_000_000){
  const type=(response.headers.get("content-type")||"").toLowerCase();
  assert(type.includes("json"),"NOT_JSON");
  const declared=Number(response.headers.get("content-length")||0);
  assert(!declared||declared<=limit,"RESPONSE_TOO_LARGE");
  const bytes=new Uint8Array(await response.arrayBuffer());
  assert(bytes.byteLength<=limit,"RESPONSE_TOO_LARGE");
  try{return JSON.parse(new TextDecoder().decode(bytes));}catch{throw new StateError("INVALID_JSON");}
}
function transient(status){return status===408||status===425||status===429||status>=500;}
async function sleep(ms){if(ms)await new Promise(r=>setTimeout(r,ms));}
async function apiRead(env,endpoint,args={},deps={}){
  assert(typeof env.STREMIO_AUTHKEY==="string"&&env.STREMIO_AUTHKEY.length>=8,"AUTH_REQUIRED");
  assert(["getUser","datastoreGet"].includes(endpoint),"READ_ENDPOINT_BLOCKED");
  const f=deps.fetchImpl||fetch;
  let last;
  for(let attempt=0;attempt<2;attempt++){
    try{
      const r=await f(`${API}/${endpoint}`,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({...args,authKey:env.STREMIO_AUTHKEY}),redirect:"manual",signal:AbortSignal.timeout(15000)});
      if(r.status>=300&&r.status<400)throw new StateError("STREMIO_REDIRECT_BLOCKED");
      if(!r.ok){last=new StateError("STREMIO_HTTP_"+r.status);if(!transient(r.status)||attempt===1)throw last;}
      else return (await boundedJson(r)).result;
    }catch(error){
      last=error;
      if(error instanceof StateError&&!/^STREMIO_HTTP_(408|425|429|5\d\d)$/.test(error.code||""))throw error;
      if(attempt===1)throw error;
    }
    await (deps.sleep||sleep)(100*(attempt+1));
  }
  throw last||new StateError("READ_FAILED");
}
async function putOnce(env,candidate,deps={}){
  const f=deps.fetchImpl||fetch;
  try{
    const r=await f(API+"/datastorePut",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({collection:"libraryItem",changes:[candidate],authKey:env.STREMIO_AUTHKEY}),redirect:"manual",signal:AbortSignal.timeout(15000)});
    if(r.status>=300&&r.status<400)return {kind:"blocked-redirect"};
    if(!r.ok)return {kind:"http",status:r.status,transient:transient(r.status)};
    const result=(await boundedJson(r)).result;
    return result===true||result?.success===true?{kind:"confirmed"}:{kind:"negative"};
  }catch(error){return {kind:"network"};}
}
async function accountFingerprint(env,deps={}){
  const user=await apiRead(env,"getUser",{},deps);const id=user?._id??user?.id;
  assert(typeof id==="string"&&id,"ACCOUNT_ID_MISSING");
  return sha256("stremio:"+id);
}
async function library(env,ids=[],deps={}){
  assert(Array.isArray(ids)&&ids.length<=500,"INVALID_IDS");
  const rows=await apiRead(env,"datastoreGet",{collection:"libraryItem",ids,all:ids.length===0},deps);
  assert(Array.isArray(rows)&&rows.length<=MAX_LIBRARY,"INVALID_LIBRARY");
  return rows;
}

function episodeInfo(video){
  const season=Number(video?.season??video?.seriesInfo?.season??video?.series_info?.season);
  const episode=Number(video?.episode??video?.seriesInfo?.episode??video?.series_info?.episode);
  return Number.isInteger(season)&&season>=0&&Number.isInteger(episode)&&episode>=1?{season,episode}:null;
}
function orderedVideos(meta){
  return [...(meta?.videos||[])].sort((a,b)=>{
    const ai=episodeInfo(a),bi=episodeInfo(b);
    return (ai?.season??-1)-(bi?.season??-1)||(ai?.episode??-1)-(bi?.episode??-1)||(Date.parse(a.released)||0)-(Date.parse(b.released)||0)||String(a.id).localeCompare(String(b.id));
  });
}
async function inflate(raw){
  const stream=new Blob([raw]).stream().pipeThrough(new DecompressionStream("deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
async function decodeWatched(serialized,ids){
  assert(ids.length>0&&ids.length<=10000,"EPISODE_LIMIT");
  if(!serialized)return ids.map(()=>false);
  assert(typeof serialized==="string"&&serialized.length<100000,"INVALID_WATCHED_BITMAP");
  const p=serialized.split(":"),packed=p.pop(),length=Number(p.pop()),anchor=p.join(":");
  assert(Number.isInteger(length)&&length>=1&&length<=10000&&/^[A-Za-z0-9+/]+={0,2}$/.test(packed),"INVALID_WATCHED_BITMAP");
  const anchorIndex=ids.indexOf(anchor);assert(anchorIndex>=0,"WATCHED_ANCHOR_MISSING");
  let bytes;try{bytes=await inflate(Uint8Array.from(atob(packed),c=>c.charCodeAt(0)));}catch{throw new StateError("WATCHED_BITMAP_CORRUPT");}
  assert(bytes.length*8>=length,"WATCHED_BITMAP_TRUNCATED");
  const offset=length-1-anchorIndex;
  return ids.map((_,i)=>{const j=i+offset;return j>=0&&j<bytes.length*8&&(bytes[j>>3]&(1<<(j%8)))!==0;});
}
async function metadata(env,id){
  assert(env.METADATA?.fetch,"METADATA_BINDING_REQUIRED");
  const r=await env.METADATA.fetch(new Request(`https://watch-state-maintenance.internal/meta/series/${id}.json`,{headers:{accept:"application/json"}}));
  assert(r.ok,"META_HTTP_"+r.status);
  const payload=await boundedJson(r,8_000_000);
  assert(payload?.meta?.id===id&&payload.meta.type==="series","META_IDENTITY_MISMATCH");
  return payload.meta;
}
function activityTime(item){
  const values=[Date.parse(item?._mtime||""),Date.parse(item?.state?.lastWatched||"")].filter(Number.isFinite);
  return values.length?Math.max(...values):0;
}
function playbackActivityTime(item){
  const lastWatched=Date.parse(item?.state?.lastWatched||"");
  if(Number.isFinite(lastWatched))return lastWatched;
  const modified=Date.parse(item?._mtime||"");
  return Number.isFinite(modified)?modified:0;
}
function normalizedName(value){return String(value||"").normalize("NFKC").trim().replace(/\s+/g," ").toLowerCase();}
function canonicalIdFromVideoId(value){const m=String(value||"").match(/^(tt\d{5,12})(?::|$)/);return m?m[1]:null;}
async function observationKey(item){return (await sha256(String(item?._id||""))).slice(0,16);}
async function watchedHash(item){return sha256(String(item?.state?.watched||""));}
async function videoHash(item){return (await sha256(String(item?.state?.video_id||""))).slice(0,16);}
async function observeWatchedChanges(env,items,when){
  assert(env.BACKUP_DB?.prepare,"BACKUP_DB_REQUIRED");
  const q=await env.BACKUP_DB.prepare("SELECT item_hash,watched_hash,watched_changed_at,time_offset_at_change,video_hash_at_change,last_watched_at_change,mtime_at_change FROM watch_observations").all();
  const current=new Map((q?.results||[]).map(x=>[x.item_hash,x]));
  const series=items.filter(x=>x?.type==="series"&&/^tt\d{5,12}$/.test(String(x._id||""))&&Number(x?.state?.timeOffset)>0&&!(x.removed&&!x.temp));
  for(const item of series){
    const itemHash=await observationKey(item),wHash=await watchedHash(item),vHash=await videoHash(item);
    const lastWatched=Date.parse(item?.state?.lastWatched||""),mtime=Date.parse(item?._mtime||"");
    const snapshot={item_hash:itemHash,watched_hash:wHash,watched_changed_at:0,time_offset_at_change:Number(item.state?.timeOffset)||0,video_hash_at_change:vHash,last_watched_at_change:Number.isFinite(lastWatched)?lastWatched:0,mtime_at_change:Number.isFinite(mtime)?mtime:0};
    const previous=current.get(itemHash);
    if(!previous){
      await env.BACKUP_DB.prepare("INSERT INTO watch_observations (item_hash,watched_hash,watched_changed_at,time_offset_at_change,video_hash_at_change,last_watched_at_change,mtime_at_change) VALUES (?,?,?,?,?,?,?)").bind(itemHash,wHash,0,snapshot.time_offset_at_change,vHash,snapshot.last_watched_at_change,snapshot.mtime_at_change).run();
      current.set(itemHash,snapshot);continue;
    }
    if(previous.watched_hash!==wHash){
      snapshot.watched_changed_at=when;
      await env.BACKUP_DB.prepare("UPDATE watch_observations SET watched_hash=?,watched_changed_at=?,time_offset_at_change=?,video_hash_at_change=?,last_watched_at_change=?,mtime_at_change=? WHERE item_hash=?").bind(wHash,when,snapshot.time_offset_at_change,vHash,snapshot.last_watched_at_change,snapshot.mtime_at_change,itemHash).run();
      current.set(itemHash,snapshot);
    }
  }
  return current;
}
async function bulkWatchedTransitionDecision(item,meta,observation,now){
  if(!observation||!(Number(observation.watched_changed_at)>0)||now-Number(observation.watched_changed_at)>BULK_WATCHED_TRANSITION_WINDOW_MS)return null;
  if(!item||item.type!=="series"||!/^tt\d{5,12}$/.test(String(item._id||""))||!(Number(item.state?.timeOffset)>0))return null;
  if(now-playbackActivityTime(item)<QUIET_MS)return null;
  if(await watchedHash(item)!==observation.watched_hash||await videoHash(item)!==observation.video_hash_at_change)return null;
  if(Number(item.state?.timeOffset)!==Number(observation.time_offset_at_change))return null;
  if(Number(observation.last_watched_at_change)>0&&Number(observation.watched_changed_at)-Number(observation.last_watched_at_change)<QUIET_MS)return null;
  const videos=orderedVideos(meta);assert(videos.length>0,"EPISODE_LIST_EMPTY");
  const ids=videos.map(v=>String(v.id));assert(new Set(ids).size===ids.length,"DUPLICATE_VIDEO_ID");
  const bits=await decodeWatched(item.state?.watched,ids);
  const released=videos.map((v,i)=>({v,i,info:episodeInfo(v)})).filter(x=>x.info&&x.info.season>0&&(!x.v.released||Date.parse(x.v.released)<=now));
  assert(released.length>0,"RELEASED_EPISODE_MAPPING_MISSING");
  if(!released.every(({i})=>bits[i]===true))return null;
  const pointerIndex=ids.indexOf(String(item.state?.video_id||""));if(pointerIndex<0||bits[pointerIndex]!==true)return null;
  return {id:item._id,before:structuredClone(item),reason:"all-released-watched-transition-stale-progress"};
}
function legacyAliasDecision(item,byId,now){
  if(!item||!String(item._id||"").startsWith("tmdb:")||!(["series","movie"].includes(item.type)))return null;
  if(!(Number(item.state?.timeOffset)>0)||now-playbackActivityTime(item)<QUIET_MS)return null;
  const canonicalId=canonicalIdFromVideoId(item.state?.video_id);if(!canonicalId)return null;
  const canonicalItem=byId.get(canonicalId);if(!canonicalItem||canonicalItem.type!==item.type)return null;
  if(canonicalItem.removed||canonicalItem.temp)return null;
  if(normalizedName(canonicalItem.name)!==normalizedName(item.name))return null;
  let safe=false;
  if(item.removed&&item.temp)safe=true;
  const samePointer=String(canonicalItem.state?.video_id||"")===String(item.state?.video_id||"");
  const sameOffset=Number(canonicalItem.state?.timeOffset)===Number(item.state?.timeOffset);
  const sameDuration=Number(canonicalItem.state?.duration)===Number(item.state?.duration);
  if(!safe&&samePointer&&sameOffset&&sameDuration&&activityTime(canonicalItem)>=activityTime(item))safe=true;
  if(!safe&&Number(item.state?.timeOffset)<=1000&&activityTime(canonicalItem)>activityTime(item)&&Number(canonicalItem.state?.timeOffset)>=Number(item.state?.timeOffset))safe=true;
  if(!safe)return null;
  return {id:item._id,before:structuredClone(item),reason:"legacy-tmdb-alias-stale-progress",canonicalId};
}
async function completionDecision(item,meta,now){
  if(!item||!["series","movie"].includes(item.type))return null;
  if(item.removed&&!item.temp)return null;
  const state=item.state||{};
  if(!(Number(state.timeOffset)>0)||!(Number(state.duration)>0))return null;
  if(now-playbackActivityTime(item)<QUIET_MS)return null;

  if(item.type==="movie"){
    if(Number(state.flaggedWatched)!==1)return null;
    if(Number(state.timeOffset)/Number(state.duration)<=CREDITS_THRESHOLD)return null;
    if(typeof state.video_id!=="string"||!state.video_id)return null;
    return {id:item._id,before:structuredClone(item),reason:"movie-past-native-credits-threshold-stale-progress"};
  }

  if(!/^tt\d{5,12}$/.test(item._id))return null;
  if(Number(state.flaggedWatched)!==1)return null;
  const videos=orderedVideos(meta);assert(videos.length>0,"EPISODE_LIST_EMPTY");
  const ids=videos.map(v=>String(v.id));
  assert(new Set(ids).size===ids.length,"DUPLICATE_VIDEO_ID");
  const bits=await decodeWatched(state.watched,ids);
  const released=videos.map((v,i)=>({v,i,info:episodeInfo(v)}))
    .filter(x=>x.info&&x.info.season>0&&(!x.v.released||Date.parse(x.v.released)<=now));
  assert(released.length>0,"RELEASED_EPISODE_MAPPING_MISSING");
  if(!released.every(({i})=>bits[i]===true))return null;
  const last=released.at(-1);
  if(String(state.video_id||"")!==String(last.v.id))return null;
  if(bits[last.i]!==true)return null;
  const offsetRatio=Number(state.timeOffset)/Number(state.duration);
  if(offsetRatio>=WATCHED_THRESHOLD){
    return {id:item._id,before:structuredClone(item),reason:"fully-watched-final-released-episode-stale-progress"};
  }
  const timeWatchedRatio=Number(state.timeWatched)/Number(state.duration);
  if(Number(state.timeOffset)<=RESIDUAL_POINTER_MAX_MS&&timeWatchedRatio>=WATCHED_THRESHOLD){
    return {id:item._id,before:structuredClone(item),reason:"fully-watched-final-released-episode-residual-progress"};
  }
  return null;
}
function selectBatch(items,scheduledTime){
  const candidates=items.filter(x=>["series","movie"].includes(x?.type)&&Number(x?.state?.timeOffset)>0&&!(x.removed&&!x.temp))
    .sort((a,b)=>String(a._id).localeCompare(String(b._id)));
  if(!candidates.length)return {items:[],batchIndex:0,batchCount:0,total:0};
  const batchCount=Math.ceil(candidates.length/BATCH_SIZE),slot=Math.floor(scheduledTime/CRON_MS),batchIndex=((slot%batchCount)+batchCount)%batchCount;
  return {items:candidates.slice(batchIndex*BATCH_SIZE,(batchIndex+1)*BATCH_SIZE),batchIndex,batchCount,total:candidates.length};
}

function b64(bytes){let s="";for(const b of bytes)s+=String.fromCharCode(b);return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");}
function unb64(v){const p=v.replace(/-/g,"+").replace(/_/g,"/")+"===".slice((v.length+3)%4);return Uint8Array.from(atob(p),c=>c.charCodeAt(0));}
async function cryptoKey(secret){
  assert(typeof secret==="string"&&secret.length>=40,"BACKUP_KEY_REQUIRED");
  const raw=unb64(secret.trim());assert(raw.byteLength===32,"BACKUP_KEY_INVALID");
  return crypto.subtle.importKey("raw",raw,{name:"AES-GCM"},false,["encrypt"]);
}
async function encrypt(value,secret){
  const iv=crypto.getRandomValues(new Uint8Array(12)),key=await cryptoKey(secret),data=new TextEncoder().encode(canonical(value));
  assert(data.byteLength<=1_000_000,"BACKUP_TOO_LARGE");
  const enc=new Uint8Array(await crypto.subtle.encrypt({name:"AES-GCM",iv,additionalData:new TextEncoder().encode("stremio-watch-state-backup-v1")},key,data));
  return JSON.stringify({v:1,iv:b64(iv),data:b64(enc)});
}
async function backup(env,record){
  assert(env.BACKUP_DB?.prepare,"BACKUP_DB_REQUIRED");
  const itemHash=(await sha256(record.before._id)).slice(0,16),key=`v1/${record.createdAt.slice(0,10)}/${itemHash}/${crypto.randomUUID()}`;
  const payload=await encrypt(record,env.BACKUP_ENCRYPTION_KEY),created=Date.parse(record.createdAt),expires=created+BACKUP_TTL_MS;
  const r=await env.BACKUP_DB.prepare("INSERT INTO watch_backups (backup_key,created_at,expires_at,item_hash,payload) VALUES (?,?,?,?,?)").bind(key,created,expires,itemHash,payload).run();
  assert(r?.success!==false,"BACKUP_WRITE_FAILED");return key;
}
async function prune(env,now){
  if(!env.BACKUP_DB?.prepare)return;
  await env.BACKUP_DB.prepare("DELETE FROM watch_backups WHERE expires_at < ?").bind(now).run();
}
async function apply(env,plan,expected,deps={}){
  assert(await accountFingerprint(env,deps)===expected,"ACCOUNT_CHANGED");
  const [current]=await library(env,[plan.id],deps);assert(current,"ITEM_MISSING");
  assert(await hash(current)===plan.beforeHash,"ITEM_CHANGED_BEFORE_WRITE");
  if(Number(current.state?.timeOffset)===0)return {status:"ALREADY_CLEAR"};
  const [confirm]=await library(env,[plan.id],deps);assert(confirm&&await hash(confirm)===await hash(current),"ITEM_CHANGED_BEFORE_WRITE");
  const candidate=structuredClone(confirm);candidate.state.timeOffset=0;candidate._mtime=new Date((deps.now||Date.now)()).toISOString();
  const backupKey=await backup(env,{schema:1,createdAt:new Date((deps.now||Date.now)()).toISOString(),account:expected,before:confirm,candidate,reason:plan.reason});
  const outcome=await putOnce(env,candidate,deps);
  const [after]=await library(env,[plan.id],deps);assert(after,"READBACK_MISSING");
  if(outcome.kind!=="confirmed"&&Number(after.state?.timeOffset)!==0)throw new StateError("WRITE_UNCONFIRMED");
  assert(Number(after.state?.timeOffset)===0,"READBACK_OFFSET_MISMATCH");
  const a=structuredClone(confirm),b=structuredClone(after);delete a._mtime;delete b._mtime;a.state={...a.state};b.state={...b.state};delete a.state.timeOffset;delete b.state.timeOffset;
  assert(canonical(a)===canonical(b),"UNRELATED_STATE_CHANGED");
  return {status:"VERIFIED",backupKey};
}
async function recordRun(env,s,when){
  if(!env.BACKUP_DB?.prepare)return;
  await env.BACKUP_DB.prepare("INSERT INTO maintenance_state (state_key,last_run,continue_watching_series,batch_index,batch_count,scanned,candidates,attempted_writes,verified_writes,stopped,error_codes) VALUES ('latest',?,?,?,?,?,?,?,?,?,?) ON CONFLICT(state_key) DO UPDATE SET last_run=excluded.last_run,continue_watching_series=excluded.continue_watching_series,batch_index=excluded.batch_index,batch_count=excluded.batch_count,scanned=excluded.scanned,candidates=excluded.candidates,attempted_writes=excluded.attempted_writes,verified_writes=excluded.verified_writes,stopped=excluded.stopped,error_codes=excluded.error_codes")
    .bind(when,s.continueWatchingSeries,s.batchIndex,s.batchCount,s.scanned,s.candidates,s.attemptedWrites,s.verifiedWrites,s.stopped?1:0,JSON.stringify(s.errorCodes)).run();
}
async function run(env,scheduledTime=Date.now(),deps={}){
  assert(/^[0-9a-f]{64}$/i.test(env.EXPECTED_ACCOUNT_FINGERPRINT||""),"EXPECTED_ACCOUNT_REQUIRED");
  const expected=env.EXPECTED_ACCOUNT_FINGERPRINT.toLowerCase();assert(await accountFingerprint(env,deps)===expected,"ACCOUNT_CHANGED");
  if(Math.floor(scheduledTime/CRON_MS)%144===0)try{await prune(env,scheduledTime);}catch{}
  const rows=await library(env,[],deps),byId=new Map(rows.map(x=>[x._id,x])),batch=selectBatch(rows,scheduledTime),plans=[],errors=[];
  let observations=new Map();
  try{observations=await observeWatchedChanges(env,rows,scheduledTime);}catch(e){errors.push(e?.code||"OBSERVATION_FAILED");}
  for(const item of batch.items){
    try{
      const alias=legacyAliasDecision(item,byId,scheduledTime);
      if(alias){alias.beforeHash=await hash(item);plans.push(alias);continue;}
      const meta=item.type==="series"?await metadata(env,item._id):null;
      if(item.type==="series"){
        const transition=await bulkWatchedTransitionDecision(item,meta,observations.get(await observationKey(item)),scheduledTime);
        if(transition){transition.beforeHash=await hash(item);plans.push(transition);continue;}
      }
      const d=await completionDecision(item,meta,scheduledTime);
      if(d){d.beforeHash=await hash(item);plans.push(d);}
    }catch(e){errors.push(e?.code||"EVALUATION_FAILED");}
  }
  let attempted=0,verified=0,stopped=false;
  for(const plan of plans.slice(0,MAX_WRITES)){
    try{attempted++;const r=await apply(env,plan,expected,deps);if(["VERIFIED","ALREADY_CLEAR"].includes(r.status))verified++;}
    catch(e){errors.push(e?.code||"WRITE_FAILED");stopped=true;break;}
  }
  return {continueWatchingSeries:batch.total,batchIndex:batch.batchIndex,batchCount:batch.batchCount,scanned:batch.items.length,candidates:plans.length,attemptedWrites:attempted,verifiedWrites:verified,stopped,errorCodes:[...new Set(errors)].slice(0,12)};
}
const worker={
  async fetch(){return new Response(JSON.stringify({error:"Not found"}),{status:404,headers:{"content-type":"application/json","cache-control":"no-store"}});},
  async scheduled(controller,env,ctx){const when=Number(controller?.scheduledTime||Date.now());const task=run(env,when).then(async s=>{try{await recordRun(env,s,when);}catch{}console.log(JSON.stringify({event:"stremio-watch-state-maintenance",...s}));});ctx?.waitUntil?ctx.waitUntil(task):await task;}
};
export {worker as default,StateError,BATCH_SIZE,MAX_WRITES,QUIET_MS,WATCHED_THRESHOLD,CREDITS_THRESHOLD,RESIDUAL_POINTER_MAX_MS,BULK_WATCHED_TRANSITION_WINDOW_MS,episodeInfo,orderedVideos,decodeWatched,activityTime,playbackActivityTime,normalizedName,canonicalIdFromVideoId,observationKey,watchedHash,videoHash,observeWatchedChanges,bulkWatchedTransitionDecision,legacyAliasDecision,completionDecision,selectBatch,run,apply};