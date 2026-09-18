import {spawnSync} from "node:child_process";
for(const file of ["src/worker.js","scripts/hosted-backups.mjs","scripts/restore.mjs"]){
  const r=spawnSync(process.execPath,["--check",file],{stdio:"inherit"});
  if(r.status!==0)process.exit(r.status??1);
}
console.log("PASS: source syntax checks");
