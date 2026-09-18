import fs from "node:fs";
import crypto from "node:crypto";

function fail(code){console.error(JSON.stringify({error:code}));process.exit(1);}
function stable(v){if(Array.isArray(v))return v.map(stable);if(v&&typeof v==="object")return Object.fromEntries(Object.keys(v).sort().map(k=>[k,stable(v[k])]));return v;}
const canonical=v=>JSON.stringify(stable(v));
const sha=v=>crypto.createHash("sha256").update(String(v)).digest("hex");
function sameExceptMtime(a,b){const x=structuredClone(a),y=structuredClone(b);delete x._mtime;delete y._mtime;return canonical(x)===canonical(y);}
async function call(authKey,endpoint,args={}){
  const r=await fetch("https://api.strem.io/api/"+endpoint,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({...args,authKey}),redirect:"manual",signal:AbortSignal.timeout(15000)});
  if(r.status>=300&&r.status<400)fail("STREMIO_REDIRECT_BLOCKED");
  if(!r.ok)fail("STREMIO_HTTP_"+r.status);
  const j=await r.json();return j.result;
}
async function fingerprint(authKey){const u=await call(authKey,"getUser");const id=u?._id??u?.id;if(!id)fail("ACCOUNT_ID_MISSING");return sha("stremio:"+id);}
async function get(authKey,id){const rows=await call(authKey,"datastoreGet",{collection:"libraryItem",ids:[id],all:false});if(!Array.isArray(rows)||rows.length!==1)fail("ITEM_MISSING");return rows[0];}
function authFromArgs(){
  const env=String(process.env.STREMIO_AUTHKEY||"").trim();
  if(env)return env;
  if(process.argv.includes("--auth-stdin")){const s=fs.readFileSync(0,"utf8").trim();if(s)return s;}
  fail("AUTH_REQUIRED");
}
const file=process.argv[2];
if(!file||!process.argv.includes("--ack-account-write"))fail("USAGE_RESTORE_BACKUP_ACK_REQUIRED");
let backup;try{backup=JSON.parse(fs.readFileSync(file,"utf8"));}catch{fail("BACKUP_FILE_INVALID");}
if(backup?.schema!==1||!backup?.account||!backup?.before||!backup?.candidate)fail("BACKUP_RECORD_INVALID");
const before=backup.before,candidate=backup.candidate;
if(!/^tt\d{5,12}$/.test(before._id||"")||before._id!==candidate._id||before.type!==candidate.type)fail("BACKUP_RECORD_INVALID");
if(Number(candidate.state?.timeOffset)!==0)fail("BACKUP_CANDIDATE_NOT_COMPLETION_CLEAR");
const auth=authFromArgs();
if(await fingerprint(auth)!==backup.account)fail("ACCOUNT_CHANGED");
const current=await get(auth,before._id);
if(Number(current.state?.timeOffset)!==0||!sameExceptMtime(candidate,current))fail("ITEM_CHANGED_SINCE_BACKUP");
const confirm=await get(auth,before._id);
if(canonical(confirm)!==canonical(current))fail("ITEM_CHANGED_BEFORE_RESTORE");
const restored=structuredClone(before);restored._mtime=new Date().toISOString();
const put=await call(auth,"datastorePut",{collection:"libraryItem",changes:[restored]});
if(!(put===true||put?.success===true))fail("STREMIO_WRITE_NOT_CONFIRMED");
const after=await get(auth,before._id);
if(!sameExceptMtime(before,after))fail("RESTORE_READBACK_MISMATCH");
console.log(JSON.stringify({status:"VERIFIED",id:before._id,timeOffset:after.state?.timeOffset??null,unrelatedStateRestored:true},null,2));
