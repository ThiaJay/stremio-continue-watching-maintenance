import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {spawnSync} from "node:child_process";
import crypto from "node:crypto";

const ROOT=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const PRIVATE=path.join(ROOT,".private");
const CONFIG=path.join(ROOT,"wrangler.local.toml");
const KEY_FILE=path.join(PRIVATE,"backup-encryption-key.txt");
const WRANGLER=path.join(ROOT,"node_modules",".bin",process.platform==="win32"?"wrangler.cmd":"wrangler");
const DB="stremio-watch-state-maintenance";
const AAD=new TextEncoder().encode("stremio-watch-state-backup-v1");

function fail(code){console.error(JSON.stringify({error:code}));process.exit(1);}
function d1(command){
  const args=["d1","execute",DB,"--remote","--config",CONFIG,"--command",command,"--json"];
  const r=process.platform==="win32"
    ? spawnSync(process.env.ComSpec||"cmd.exe",["/d","/c",WRANGLER,...args],{cwd:ROOT,encoding:"utf8",windowsHide:true})
    : spawnSync(WRANGLER,args,{cwd:ROOT,encoding:"utf8",windowsHide:true});
  if(r.status!==0)fail("D1_COMMAND_FAILED");
  let parsed;try{parsed=JSON.parse(String(r.stdout||"[]"));}catch{fail("D1_RESULT_INVALID");}
  if(!Array.isArray(parsed)||!parsed[0]?.success)fail("D1_RESULT_INVALID");
  return parsed[0].results??[];
}
function unb64(v){const s=String(v).replace(/-/g,"+").replace(/_/g,"/");const p=s+"=".repeat((4-s.length%4)%4);return Uint8Array.from(Buffer.from(p,"base64"));}
async function decrypt(payload,secret){
  let p;try{p=JSON.parse(payload);}catch{fail("BACKUP_PAYLOAD_INVALID");}
  if(p?.v!==1||typeof p.iv!=="string"||typeof p.data!=="string")fail("BACKUP_PAYLOAD_INVALID");
  const raw=unb64(secret);if(raw.byteLength!==32)fail("BACKUP_KEY_INVALID");
  const key=await crypto.webcrypto.subtle.importKey("raw",raw,{name:"AES-GCM"},false,["decrypt"]);
  let plain;try{plain=await crypto.webcrypto.subtle.decrypt({name:"AES-GCM",iv:unb64(p.iv),additionalData:AAD},key,unb64(p.data));}
  catch{fail("BACKUP_DECRYPT_FAILED");}
  try{return JSON.parse(new TextDecoder().decode(plain));}catch{fail("BACKUP_PLAINTEXT_INVALID");}
}
if(!fs.existsSync(CONFIG))fail("PRIVATE_WRANGLER_CONFIG_REQUIRED");
const cmd=process.argv[2]||"help";
if(cmd==="help"){console.log("Hosted watch-state backups: list | export <backup-key>");process.exit(0);}
if(cmd==="list"){
  const rows=d1("SELECT backup_key,created_at,expires_at,item_hash FROM watch_backups ORDER BY created_at DESC LIMIT 100");
  console.log(JSON.stringify(rows.map(x=>({key:x.backup_key,createdAt:x.created_at,expiresAt:x.expires_at,itemHash:x.item_hash})),null,2));
  process.exit(0);
}
if(cmd==="export"){
  const backupKey=process.argv[3];
  if(!backupKey||!/^v1\/\d{4}-\d{2}-\d{2}\/[0-9a-f]{16}\/[0-9a-f-]{36}$/.test(backupKey))fail("BACKUP_KEY_INVALID");
  if(!fs.existsSync(KEY_FILE))fail("BACKUP_ENCRYPTION_KEY_REQUIRED");
  const escaped=backupKey.replace(/'/g,"''");
  const rows=d1("SELECT payload FROM watch_backups WHERE backup_key='"+escaped+"' LIMIT 1");
  if(rows.length!==1||typeof rows[0].payload!=="string")fail("BACKUP_NOT_FOUND");
  const record=await decrypt(rows[0].payload,fs.readFileSync(KEY_FILE,"utf8").trim());
  if(record?.schema!==1||!record?.before||!record?.candidate||!record?.account)fail("BACKUP_RECORD_INVALID");
  fs.mkdirSync(PRIVATE,{recursive:true});
  const out=path.join(PRIVATE,"hosted-watch-backup-"+new Date().toISOString().replace(/[:.]/g,"-")+".json");
  fs.writeFileSync(out,JSON.stringify(record,null,2)+"\n",{encoding:"utf8",flag:"wx",mode:0o600});
  console.log(JSON.stringify({status:"EXPORTED",file:path.basename(out),createdAt:record.createdAt??null,schema:record.schema},null,2));
  process.exit(0);
}
fail("UNKNOWN_COMMAND");
