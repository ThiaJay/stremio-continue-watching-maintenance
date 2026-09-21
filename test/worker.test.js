import test from "node:test";
import assert from "node:assert/strict";
import {
  BATCH_SIZE,MAX_WRITES,EXPLICIT_BATCH_SIZE,MAX_EXPLICIT_WRITES,QUIET_MS,WATCHED_THRESHOLD,CREDITS_THRESHOLD,RESIDUAL_POINTER_MAX_MS,RESIDUAL_STALE_MS,ANCIENT_RESIDUAL_STALE_MS,BULK_WATCHED_TRANSITION_WINDOW_MS,orderedVideos,decodeWatched,watchedAnchor,metadataProof,metadata,playbackActivityTime,observationKey,watchedHash,videoHash,bulkWatchedTransitionDecision,movieMarkedWatchedTransitionDecision,legacyAliasDecision,completionDecision,selectBatch,selectExplicitTransitionItems,run
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
test("watched anchor is recovered from the serialized Stremio watched field",async()=>{
  const ids=videos().map(v=>v.id),field=await encode([true,false,true],ids);
  assert.equal(watchedAnchor(field),"tt12345:1:3");
});

test("metadata proof accepts an alternate provider id only when IMDb identity and watched anchor both match",()=>{
  const meta={id:"tvdb:123",_imdbId:"tt12345",type:"series",videos:videos()};
  assert.equal(metadataProof(meta,"tt12345","tt12345:1:3").ok,true);
  assert.equal(metadataProof(meta,"tt12345","tt12345:9:9").code,"META_ANCHOR_MISMATCH");
});

test("metadata falls back to native Cinemeta only when it independently proves identity and watched anchor",async()=>{
  const item=await libraryItem();
  const wrong={id:"tvdb:999",_imdbId:"tt99999",type:"series",videos:[{id:"tt99999:1:1",season:1,episode:1}]};
  const native={id:"tt12345",type:"series",videos:videos()};
  const got=await metadata({METADATA:metaBinding(wrong)},item,{nativeMetaFetchImpl:async()=>Response.json({meta:native})});
  assert.equal(got.id,"tt12345");
});

test("metadata fails closed when neither provider can prove the watched anchor",async()=>{
  const item=await libraryItem();
  const alias={id:"tvdb:123",_imdbId:"tt12345",type:"series",videos:[{id:"tt12345:9:9",season:9,episode:9}]};
  await assert.rejects(
    ()=>metadata({METADATA:metaBinding(alias)},item,{nativeMetaFetchImpl:async()=>Response.json({meta:{id:"tt12345",type:"series",videos:[{id:"tt12345:8:8",season:8,episode:8}]}})}),
    e=>e?.code==="META_NO_TRUSTED_ANCHOR"
  );
});

test("bitmap decoder round-trips current watched state",async()=>{
  const ids=videos().map(v=>v.id),field=await encode([true,false,true],ids);
  assert.deepEqual(await decodeWatched(field,ids),[true,false,true]);
});
test("Once Upon a Time in Northern Ireland clears after all five episodes are watched without a movie flag",async()=>{
  const id="tt27837209";
  const meta={id,type:"series",videos:[
    {id:`${id}:1:1`,season:1,episode:1,released:"2023-05-22T00:00:00Z"},
    {id:`${id}:1:2`,season:1,episode:2,released:"2023-05-29T00:00:00Z"},
    {id:`${id}:1:3`,season:1,episode:3,released:"2023-06-05T00:00:00Z"},
    {id:`${id}:1:4`,season:1,episode:4,released:"2023-06-12T00:00:00Z"},
    {id:`${id}:1:5`,season:1,episode:5,released:"2023-06-19T00:00:00Z"}
  ]};
  const ids=meta.videos.map(v=>v.id);
  const mtime=NOW-2*24*60*60*1000;
  const item={
    _id:id,type:"series",name:"Once Upon a Time in Northern Ireland",removed:false,temp:false,_mtime:new Date(mtime).toISOString(),
    state:{
      lastWatched:new Date(mtime).toISOString(),
      timeWatched:3_400_000,
      timeOffset:3_400_000,
      overallTimeWatched:17_000_000,
      timesWatched:0,
      flaggedWatched:0,
      duration:3_600_000,
      video_id:`${id}:1:5`,
      watched:await encode([true,true,true,true,true],ids),
      noNotif:false
    },
    poster:null,posterShape:"poster",behaviorHints:{}
  };
  const d=await completionDecision(item,meta,NOW);
  assert.equal(d?.id,id);
  assert.equal(d?.reason,"fully-watched-final-released-episode-stale-progress");
});

test("series completion does not depend on flaggedWatched because Core uses the episode bitmap",async()=>{
  const item=await libraryItem({flagged:0});
  const d=await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW);
  assert.equal(d?.id,"tt12345");
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
test("tiny residual final-episode pointer is correctable when Core watch-time proves completion",async()=>{
  const duration=2_772_441;
  const item=await libraryItem({offset:9_751,duration,mtime:NOW-5*24*60*60*1000});
  item.state.timeWatched=2_758_237;
  item.state.lastWatched=new Date(NOW-5*24*60*60*1000).toISOString();
  item._mtime=new Date(NOW-5*60*1000).toISOString();
  const d=await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW);
  assert.equal(d?.reason,"fully-watched-final-released-episode-residual-progress");
});

test("recent lastWatched is authoritative over old or unrelated record modification time",async()=>{
  const item=await libraryItem({offset:9_000,duration:1000,mtime:NOW-2*24*60*60*1000});
  item.state.timeWatched=1000;
  item.state.lastWatched=new Date(NOW-5*60*1000).toISOString();
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});

test("recent unrelated mtime does not make old completed playback look active",async()=>{
  const item=await libraryItem({offset:9_000,duration:10_000,mtime:NOW-2*24*60*60*1000});
  item.state.timeWatched=9_000;
  item.state.lastWatched=new Date(NOW-2*24*60*60*1000).toISOString();
  item._mtime=new Date(NOW-2*60*1000).toISOString();
  const d=await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW);
  assert.ok(d);
});

test("meaningful low-progress final-episode rewatch is preserved",async()=>{
  const item=await libraryItem({offset:RESIDUAL_POINTER_MAX_MS+1,duration:100_000});
  item.state.timeWatched=100_000;
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});

test("year-old 12.918 second final pointer for Once Upon a Time in Northern Ireland is stale residue",async()=>{
  const id="tt27837209";
  const meta={id,type:"series",videos:[1,2,3,4,5].map((episode,index)=>({
    id:`${id}:1:${episode}`,season:1,episode,released:new Date(Date.UTC(2023,4,22+index*7)).toISOString()
  }))};
  const ids=meta.videos.map(v=>v.id);
  const item={
    _id:id,type:"series",name:"Once Upon a Time in Northern Ireland",removed:false,temp:false,
    _mtime:"2026-09-03T13:57:55.847Z",
    state:{
      lastWatched:"2025-09-23T21:33:05.000Z",
      timeWatched:12_893,
      timeOffset:12_918,
      overallTimeWatched:0,
      timesWatched:1,
      flaggedWatched:0,
      duration:4_509_040,
      video_id:`${id}:1:5`,
      watched:await encode([true,true,true,true,true],ids),
      noNotif:false
    },
    poster:null,posterShape:"poster",behaviorHints:{}
  };
  assert.ok(NOW-playbackActivityTime(item)>=RESIDUAL_STALE_MS);
  const d=await completionDecision(item,meta,NOW);
  assert.equal(d?.reason,"fully-watched-final-released-episode-stale-residual-progress");
});

test("stale tiny pointer never bypasses an unwatched released episode",async()=>{
  const item=await libraryItem({bits:[true,true,false],offset:12_000,duration:100_000,mtime:NOW-2*RESIDUAL_STALE_MS});
  item.state.timeWatched=12_000;
  item.state.lastWatched=new Date(NOW-2*RESIDUAL_STALE_MS).toISOString();
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});

test("stale tiny pointer on an older watched episode remains a possible rewatch",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",offset:12_000,duration:100_000,mtime:NOW-2*RESIDUAL_STALE_MS});
  item.state.timeWatched=12_000;
  item.state.lastWatched=new Date(NOW-2*RESIDUAL_STALE_MS).toISOString();
  assert.ok(NOW-playbackActivityTime(item)<ANCIENT_RESIDUAL_STALE_MS);
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});

test("ancient tiny pointer on a watched older episode clears only after the long inactivity guard",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",offset:12_000,duration:100_000,mtime:NOW-ANCIENT_RESIDUAL_STALE_MS-60_000});
  item.state.timeWatched=11_990;
  item.state.lastWatched=new Date(NOW-ANCIENT_RESIDUAL_STALE_MS-60_000).toISOString();
  const d=await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW);
  assert.equal(d?.reason,"fully-watched-series-ancient-tiny-watched-episode-residual-progress");
});

test("ancient older-episode pointer is preserved when the rewatch had meaningful watch time",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",offset:12_000,duration:100_000,mtime:NOW-ANCIENT_RESIDUAL_STALE_MS-60_000});
  item.state.timeWatched=RESIDUAL_POINTER_MAX_MS+1;
  item.state.lastWatched=new Date(NOW-ANCIENT_RESIDUAL_STALE_MS-60_000).toISOString();
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});

test("live Northern Ireland residue is recognised even though the stale pointer is episode one",async()=>{
  const id="tt27837209";
  const meta={id,type:"series",videos:[1,2,3,4,5].map((episode,index)=>({
    id:`${id}:1:${episode}`,season:1,episode,released:new Date(Date.UTC(2023,4,22+index*7)).toISOString()
  }))};
  const ids=meta.videos.map(v=>v.id);
  const item={
    _id:id,type:"series",name:"Once Upon a Time in Northern Ireland",removed:false,temp:false,
    _mtime:"2026-09-03T13:57:55.847Z",
    state:{
      lastWatched:"2025-09-23T21:33:05.000Z",
      timeWatched:12_893,
      timeOffset:12_918,
      overallTimeWatched:0,
      timesWatched:1,
      flaggedWatched:0,
      duration:4_509_040,
      video_id:`${id}:1:1`,
      watched:await encode([true,true,true,true,true],ids),
      noNotif:false
    },
    poster:null,posterShape:"poster",behaviorHints:{}
  };
  assert.ok(NOW-playbackActivityTime(item)>=ANCIENT_RESIDUAL_STALE_MS);
  const d=await completionDecision(item,meta,NOW);
  assert.equal(d?.reason,"fully-watched-series-ancient-tiny-watched-episode-residual-progress");
});

test("recent tiny final pointer without Core watched-threshold evidence remains a possible rewatch",async()=>{
  const item=await libraryItem({offset:RESIDUAL_POINTER_MAX_MS-1,duration:100_000,mtime:NOW-QUIET_MS-1000});
  item.state.timeWatched=12_000;
  item.state.lastWatched=new Date(NOW-QUIET_MS-1000).toISOString();
  assert.ok(NOW-playbackActivityTime(item)<RESIDUAL_STALE_MS);
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});

test("tiny pointer without Core watched-threshold evidence is preserved",async()=>{
  const item=await libraryItem({offset:RESIDUAL_POINTER_MAX_MS-1,duration:100_000});
  item.state.timeWatched=69_999;
  assert.equal(await completionDecision(item,{id:"tt12345",type:"series",videos:videos()},NOW),null);
});

test("future TBC season and unwatched ancillary Season 0 material do not block normal-series completion",async()=>{
  const meta={id:"tt12345",type:"series",videos:[
    ...videos(),
    {id:"tt12345:0:1",season:0,episode:1,title:'Episode Insider "Finale"',released:"2026-01-16T00:00:00Z",runtime:"5min"},
    {id:"tt12345:0:2",season:0,episode:2,title:"Inside Example Season 1",released:"2026-01-17T00:00:00Z",runtime:"25min"},
    {id:"tt12345:4:1",season:4,episode:1,title:"TBC",released:"2027-01-01T00:00:00Z"}
  ]};
  const ordered=orderedVideos(meta),ids=ordered.map(v=>v.id);
  const bits=ordered.map(v=>Number(v.season)>0&&Date.parse(v.released)<=NOW);
  const item=await libraryItem({offset:900,duration:1000});
  item.state.watched=await encode(bits,ids);
  item.state.video_id="tt12345:1:3";
  assert.ok(await completionDecision(item,meta,NOW));
});

test("released unwatched future-season placeholder becomes completion-relevant once its date arrives",async()=>{
  const meta={id:"tt12345",type:"series",videos:[
    ...videos(),
    {id:"tt12345:4:1",season:4,episode:1,title:"TBC",released:"2026-09-01T00:00:00Z"}
  ]};
  const ordered=orderedVideos(meta),ids=ordered.map(v=>v.id);
  const item=await libraryItem({offset:900,duration:1000});
  item.state.watched=await encode(ordered.map(v=>v.id!=="tt12345:4:1"),ids);
  item.state.video_id="tt12345:1:3";
  assert.equal(await completionDecision(item,meta,NOW),null);
});

async function transitionObservation(item,{changedAt=NOW-5*60*1000,offset=item.state.timeOffset,lastWatched=Date.parse(item.state.lastWatched||""),prev={}}={}){
  const marker=await watchedHash(item),video=await videoHash(item),timeWatched=Number(item.state.timeWatched)||0,timesWatched=Number(item.state.timesWatched)||0,flagged=Number(item.state.flaggedWatched)||0,duration=Number(item.state.duration)||0,mtime=Date.parse(item._mtime||"")||0;
  return {marker_hash:marker,changed_at:changedAt,time_offset:offset,time_watched:timeWatched,times_watched:timesWatched,flagged_watched:flagged,duration,video_hash:video,last_watched:Number.isFinite(lastWatched)?lastWatched:0,mtime,
    prev_time_offset:prev.timeOffset??offset,prev_time_watched:prev.timeWatched??timeWatched,prev_times_watched:prev.timesWatched??timesWatched,prev_flagged_watched:prev.flaggedWatched??flagged,prev_duration:prev.duration??duration,prev_video_hash:prev.videoHash??video,prev_last_watched:prev.lastWatched??(Number.isFinite(lastWatched)?lastWatched:0),prev_mtime:prev.mtime??mtime};
}
test("bulk watched transition clears stale pointer even when current episode is not final",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",bits:[true,true,true],offset:15_516,duration:120_000,flagged:0,mtime:NOW-2*24*60*60*1000});
  item.state.timeWatched=15_515;item.state.lastWatched=new Date(NOW-2*24*60*60*1000).toISOString();
  const d=await bulkWatchedTransitionDecision(item,{id:"tt12345",type:"series",videos:videos()},await transitionObservation(item),NOW);
  assert.equal(d?.reason,"all-released-watched-transition-stale-progress");
});
test("bulk watched baseline without a real watched-field transition is non-actionable",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",bits:[true,true,true],offset:15_516,duration:120_000,flagged:0});
  assert.equal(await bulkWatchedTransitionDecision(item,{id:"tt12345",type:"series",videos:videos()},await transitionObservation(item,{changedAt:0}),NOW),null);
});
test("bulk watched transition never clears active rewatch playback",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",bits:[true,true,true],offset:15_516,duration:120_000,flagged:0,mtime:NOW-5*60*1000});
  item.state.lastWatched=new Date(NOW-5*60*1000).toISOString();
  assert.equal(await bulkWatchedTransitionDecision(item,{id:"tt12345",type:"series",videos:videos()},await transitionObservation(item),NOW),null);
});
test("bulk watched transition fails closed if playback pointer changed after watched mutation",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",bits:[true,true,true],offset:15_516,duration:120_000,flagged:0});
  const obs=await transitionObservation(item);item.state.timeOffset=20_000;
  assert.equal(await bulkWatchedTransitionDecision(item,{id:"tt12345",type:"series",videos:videos()},obs,NOW),null);
});
test("bulk watched transition ignores future episode but blocks once that episode is released unwatched",async()=>{
  const item=await libraryItem({pointer:"tt12345:1:2",bits:[true,true,true],offset:15_516,duration:120_000,flagged:0,mtime:NOW-2*24*60*60*1000});
  item.state.lastWatched=new Date(NOW-2*24*60*60*1000).toISOString();
  const future={id:"tt12345:2:1",season:2,episode:1,released:new Date(NOW+BULK_WATCHED_TRANSITION_WINDOW_MS).toISOString()};
  let meta={id:"tt12345",type:"series",videos:videos([future])},ids=orderedVideos(meta).map(v=>v.id);
  item.state.watched=await encode([true,true,true,false],ids);
  let obs=await transitionObservation(item);assert.ok(await bulkWatchedTransitionDecision(item,meta,obs,NOW));
  const released={...future,released:new Date(NOW-60_000).toISOString()};meta={id:"tt12345",type:"series",videos:videos([released])};ids=orderedVideos(meta).map(v=>v.id);
  item.state.watched=await encode([true,true,true,false],ids);obs=await transitionObservation(item);
  assert.equal(await bulkWatchedTransitionDecision(item,meta,obs,NOW),null);
});

function movieTransitionItem({timesWatched=1,offset=342_284,timeWatched=6_698_015,duration=6_923_626,flagged=1,lastWatched=NOW-5*60*1000,mtime=NOW-5*60*1000}={}){
  return {_id:"tt0367594",type:"movie",name:"Example Movie",removed:false,temp:false,_mtime:new Date(mtime).toISOString(),state:{lastWatched:new Date(lastWatched).toISOString(),timeWatched,timeOffset:offset,overallTimeWatched:timeWatched,timesWatched,flaggedWatched:flagged,duration,video_id:"tt0367594",watched:"undefined:1:eJwDAAAAAAE=",noNotif:false},poster:null,posterShape:"poster",behaviorHints:{}};
}
test("explicit movie mark-watched transition clears stale resume without seeking to end",async()=>{
  const item=movieTransitionItem({timesWatched:2});
  const obs=await transitionObservation(item,{changedAt:NOW-2*60*1000,prev:{timeOffset:item.state.timeOffset,timeWatched:item.state.timeWatched,timesWatched:1,flaggedWatched:item.state.flaggedWatched,duration:item.state.duration,videoHash:await videoHash(item),lastWatched:NOW-24*60*60*1000,mtime:NOW-24*60*60*1000},lastWatched:NOW-2*60*1000});
  const d=await movieMarkedWatchedTransitionDecision(item,obs,NOW);
  assert.equal(d?.reason,"explicit-movie-mark-watched-stale-progress");
});
test("movie watched status and resume progress remain distinct after a later rewatch",async()=>{
  const item=movieTransitionItem({timesWatched:2,offset:600_000,timeWatched:6_900_000,lastWatched:NOW-5*60*1000,mtime:NOW-5*60*1000});
  const obs=await transitionObservation(item,{changedAt:NOW-20*60*1000,prev:{timeOffset:342_284,timeWatched:6_698_015,timesWatched:1,flaggedWatched:1,duration:item.state.duration,videoHash:await videoHash(item),lastWatched:NOW-24*60*60*1000,mtime:NOW-24*60*60*1000},lastWatched:NOW-5*60*1000});
  assert.equal(await movieMarkedWatchedTransitionDecision(item,obs,NOW),null);
});
test("automatic movie threshold transition is not mistaken for explicit mark watched",async()=>{
  const item=movieTransitionItem({timesWatched:1,offset:5_000_000,timeWatched:5_000_000,flagged:1,lastWatched:NOW-2*60*1000,mtime:NOW-2*60*1000});
  const obs=await transitionObservation(item,{changedAt:NOW-2*60*1000,prev:{timeOffset:4_800_000,timeWatched:4_800_000,timesWatched:0,flaggedWatched:0,duration:item.state.duration,videoHash:await videoHash(item),lastWatched:NOW-12*60*1000,mtime:NOW-12*60*1000},lastWatched:NOW-2*60*1000});
  assert.equal(await movieMarkedWatchedTransitionDecision(item,obs,NOW),null);
});
test("historical/external watched sync does not clear an active resume pointer",async()=>{
  const item=movieTransitionItem({timesWatched:1,lastWatched:NOW-7*24*60*60*1000,mtime:NOW-2*60*1000});
  const obs=await transitionObservation(item,{changedAt:NOW-2*60*1000,prev:{timeOffset:item.state.timeOffset,timeWatched:item.state.timeWatched,timesWatched:0,flaggedWatched:item.state.flaggedWatched,duration:item.state.duration,videoHash:await videoHash(item),lastWatched:NOW-7*24*60*60*1000,mtime:NOW-24*60*60*1000},lastWatched:NOW-7*24*60*60*1000});
  assert.equal(await movieMarkedWatchedTransitionDecision(item,obs,NOW),null);
});

test("canonical series without watched anchor evidence are skipped without metadata errors",async()=>{
  const before=await libraryItem();
  before.state.watched=null;
  const f=fixture(before),db=new DB();
  const env={STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,METADATA:{fetch:async()=>{throw new Error("metadata should not be called");}}};
  const s=await run(env,NOW,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(s.verifiedWrites,0);
  assert.equal(s.errorCodes.includes("META_WATCHED_ANCHOR_MISSING"),false);
  assert.equal(f.puts,0);
});

test("explicit transition queue skips anchorless series before metadata evaluation",async()=>{
  const before=await libraryItem();
  before.state.watched=null;
  const f=fixture(before),db=new DB(),itemHash=await observationKey(before);
  db.observations.set(itemHash,{
    item_hash:itemHash,
    media_type:"series",
    marker_hash:await watchedHash(before),
    changed_at:NOW-60_000
  });
  const env={STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,METADATA:{fetch:async()=>{throw new Error("metadata should not be called");}}};
  const s=await run(env,NOW,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(s.fastLaneScanned,1);
  assert.equal(s.fastLaneCandidates,0);
  assert.equal(s.errorCodes.includes("META_WATCHED_ANCHOR_MISSING"),false);
  assert.equal(f.puts,0);
});

test("non-canonical series that cannot be safely aliased are skipped without metadata errors",async()=>{
  const before=await libraryItem();
  before._id="tmdb:999";
  before.state.video_id="tmdb:999:1:3";
  const f=fixture(before),db=new DB();
  const env={STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,METADATA:{fetch:async()=>{throw new Error("metadata should not be called");}}};
  const s=await run(env,NOW,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(s.verifiedWrites,0);
  assert.equal(s.errorCodes.includes("META_CANONICAL_ID_REQUIRED"),false);
  assert.equal(f.puts,0);
});

test("batch selection is deterministic and bounded",async()=>{
  const rows=[];for(let i=0;i<29;i++){const x=await libraryItem();x._id="tt"+String(10000+i);rows.push(x);}
  const seen=new Set(),count=Math.ceil(rows.length/BATCH_SIZE);
  for(let slot=0;slot<count;slot++)for(const x of selectBatch(rows,slot*10*60*1000).items)seen.add(x._id);
  assert.equal(seen.size,rows.length);
});
test("explicit transition queue is oldest first and bounded independently of ordinary batch",async()=>{
  const rows=[],observations=new Map();
  for(let i=0;i<EXPLICIT_BATCH_SIZE+5;i++){
    const x=movieTransitionItem({timesWatched:1,offset:1000+i,lastWatched:NOW-24*60*60*1000,mtime:NOW-60*60*1000});
    x._id="tt"+String(8000000+i);
    rows.push(x);
    observations.set(await observationKey(x),{changed_at:NOW-(i+1)*60_000});
  }
  const queue=await selectExplicitTransitionItems(rows,observations,NOW);
  assert.equal(queue.length,EXPLICIT_BATCH_SIZE);
  assert.ok(queue.every(({item})=>!selectBatch(rows,NOW).items.some(x=>x._id===item._id))||queue.length===EXPLICIT_BATCH_SIZE);
  for(let i=1;i<queue.length;i++)assert.ok(queue[i-1].changedAt<=queue[i].changedAt);
});
class DB{
  constructor(){this.rows=[];this.state=[];this.observations=new Map();}
  prepare(sql){
    const self=this;
    return{
      async all(){
        if(sql.startsWith("SELECT * FROM watch_observations_v2"))return{results:[...self.observations.values()].map(x=>({...x}))};
        throw new Error("sql-all");
      },
      bind(...args){return{async run(){
        if(sql.startsWith("INSERT INTO watch_backups")){self.rows.push(args);return{success:true};}
        if(sql.startsWith("DELETE"))return{success:true};
        if(sql.startsWith("INSERT INTO maintenance_state")){self.state=args;return{success:true};}
        if(sql.startsWith("INSERT INTO watch_observations_v2")){
          const [item_hash,media_type,marker_hash,changed_at,time_offset,time_watched,times_watched,flagged_watched,duration,video_hash,last_watched,mtime,prev_time_offset,prev_time_watched,prev_times_watched,prev_flagged_watched,prev_duration,prev_video_hash,prev_last_watched,prev_mtime]=args;
          self.observations.set(item_hash,{item_hash,media_type,marker_hash,changed_at,time_offset,time_watched,times_watched,flagged_watched,duration,video_hash,last_watched,mtime,prev_time_offset,prev_time_watched,prev_times_watched,prev_flagged_watched,prev_duration,prev_video_hash,prev_last_watched,prev_mtime});return{success:true};
        }
        if(sql.startsWith("UPDATE watch_observations_v2")){
          const [media_type,marker_hash,changed_at,time_offset,time_watched,times_watched,flagged_watched,duration,video_hash,last_watched,mtime,prev_time_offset,prev_time_watched,prev_times_watched,prev_flagged_watched,prev_duration,prev_video_hash,prev_last_watched,prev_mtime,item_hash]=args;
          self.observations.set(item_hash,{item_hash,media_type,marker_hash,changed_at,time_offset,time_watched,times_watched,flagged_watched,duration,video_hash,last_watched,mtime,prev_time_offset,prev_time_watched,prev_times_watched,prev_flagged_watched,prev_duration,prev_video_hash,prev_last_watched,prev_mtime});return{success:true};
        }
        throw new Error("sql");
      }}}
    };
  }
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
  return{fetchImpl,get row(){return row},replaceRow(next){row=structuredClone(next)},get puts(){return puts},get reads(){return reads}};
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
test("observed watched-field transition clears stale pointer from explicit bulk watched intent",async()=>{
  const before=await libraryItem({pointer:"tt12345:1:2",bits:[true,false,false],offset:15_516,duration:120_000,flagged:0,mtime:NOW-QUIET_MS-60_000});
  before.state.lastWatched=new Date(NOW-QUIET_MS-60_000).toISOString();
  const f=fixture(before),db=new DB(),meta={id:"tt12345",type:"series",videos:videos()};
  const env={STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,METADATA:metaBinding(meta)};
  const first=await run(env,NOW,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(first.verifiedWrites,0);assert.equal(f.row.state.timeOffset,15_516);assert.equal(db.observations.size,1);
  const changed=structuredClone(f.row),ids=videos().map(v=>v.id);
  changed.state.watched=await encode([true,true,true],ids);changed._mtime=new Date(NOW+5*60_000).toISOString();
  f.replaceRow(changed);
  const second=await run(env,NOW+10*60_000,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW+10*60_000});
  assert.equal(second.verifiedWrites,1);assert.equal(f.row.state.timeOffset,0);assert.equal(f.puts,1);
  assert.equal(db.rows.length,1);
});

test("observed explicit movie mark watched clears stale resume without faking end progress",async()=>{
  const before=movieTransitionItem({timesWatched:0,offset:342_284,timeWatched:1_234_567,flagged:0,lastWatched:NOW-24*60*60*1000,mtime:NOW-24*60*60*1000});
  const f=fixture(before),db=new DB(),env={STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,METADATA:metaBinding({})};
  const first=await run(env,NOW,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(first.verifiedWrites,0);assert.equal(f.row.state.timeOffset,342_284);
  const changed=structuredClone(f.row);changed.state.timesWatched=1;changed.state.lastWatched=new Date(NOW+5*60_000).toISOString();changed._mtime=new Date(NOW+5*60_000).toISOString();f.replaceRow(changed);
  const second=await run(env,NOW+10*60_000,{fetchImpl:f.fetchImpl,sleep:async()=>{},now:()=>NOW+10*60_000});
  assert.equal(second.verifiedWrites,1);assert.equal(f.row.state.timeOffset,0);assert.equal(f.puts,1);
  assert.equal(f.row.state.timeWatched,1_234_567);assert.equal(f.row.state.timesWatched,1);assert.equal(db.rows.length,1);
});

test("explicit watched fast lane clears a transition even when its item is outside the ordinary rotating batch",async()=>{
  const current=[];
  for(let i=0;i<25;i++){
    const id="tt"+String(7000000+i),x=await libraryItem({pointer:"tt12345:1:2",bits:[true,false,false],offset:15_516,duration:120_000,flagged:0,mtime:NOW-QUIET_MS-60_000});
    x._id=id;x.name="Series "+i;x.state.video_id=id+":1:2";x.state.lastWatched=new Date(NOW-QUIET_MS-60_000).toISOString();
    const ids=videos().map(v=>v.id.replace("tt12345",id));
    x.state.watched=await encode([true,false,false],ids);
    current.push(x);
  }
  let puts=0;
  const fetchImpl=async(url,init={})=>{
    const ep=String(url).split("/").pop(),body=JSON.parse(init.body||"{}");
    if(ep==="getUser")return Response.json({result:{_id:"account-1"}});
    if(ep==="datastoreGet"){
      if(body.all)return Response.json({result:structuredClone(current)});
      return Response.json({result:body.ids.map(id=>current.find(x=>x._id===id)).filter(Boolean).map(x=>structuredClone(x))});
    }
    if(ep==="datastorePut"){
      puts++;const candidate=structuredClone(body.changes[0]),index=current.findIndex(x=>x._id===candidate._id);
      current[index]=candidate;return Response.json({result:{success:true}});
    }
    throw new Error(ep);
  };
  const db=new DB(),env={
    STREMIO_AUTHKEY:"auth-key-value",EXPECTED_ACCOUNT_FINGERPRINT:await fingerprint(),BACKUP_ENCRYPTION_KEY:key(),BACKUP_DB:db,
    METADATA:{fetch:async r=>{const id=new URL(r.url).pathname.split("/").pop().replace(".json","");return Response.json({meta:{id,type:"series",videos:videos().map(v=>({...v,id:v.id.replace("tt12345",id)}))}});}}
  };
  const first=await run(env,NOW,{fetchImpl,sleep:async()=>{},now:()=>NOW});
  assert.equal(first.verifiedWrites,0);

  const secondTime=NOW+10*60_000,ordinaryIds=new Set(selectBatch(current,secondTime).items.map(x=>x._id));
  const target=current.find(x=>!ordinaryIds.has(x._id));
  assert.ok(target);
  const targetIds=videos().map(v=>v.id.replace("tt12345",target._id));
  target.state.watched=await encode([true,true,true],targetIds);
  target._mtime=new Date(NOW+5*60_000).toISOString();

  const second=await run(env,secondTime,{fetchImpl,sleep:async()=>{},now:()=>secondTime});
  assert.equal(ordinaryIds.has(target._id),false);
  assert.equal(second.fastLaneCandidates,1);
  assert.equal(second.verifiedWrites,1);
  assert.equal(current.find(x=>x._id===target._id).state.timeOffset,0);
  assert.equal(puts,1);
  assert.ok(second.attemptedWrites<=MAX_EXPLICIT_WRITES+MAX_WRITES);
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


test("removed temporary TMDB alias is cleared only when an exact canonical IMDb counterpart exists",async()=>{
  const canonical=await libraryItem();
  canonical._id="tt2374744";canonical.name="The Next Step";canonical.state.video_id="tt2374744:2:24";
  const alias=structuredClone(canonical);
  alias._id="tmdb:62404";alias.removed=true;alias.temp=true;alias._mtime=new Date(NOW-QUIET_MS-1000).toISOString();
  const byId=new Map([[canonical._id,canonical],[alias._id,alias]]);
  const d=legacyAliasDecision(alias,byId,NOW);
  assert.equal(d?.canonicalId,"tt2374744");
  assert.equal(d?.reason,"legacy-tmdb-alias-stale-progress");
});

test("alias cleanup rejects mismatched names, missing canonical item and active recent alias",async()=>{
  const canonical=await libraryItem();canonical._id="tt2374744";canonical.name="The Next Step";canonical.state.video_id="tt2374744:2:24";
  const alias=structuredClone(canonical);alias._id="tmdb:62404";alias.removed=true;alias.temp=true;
  let byId=new Map([[canonical._id,canonical],[alias._id,alias]]);
  alias.name="Different";assert.equal(legacyAliasDecision(alias,byId,NOW),null);
  alias.name="The Next Step";byId=new Map([[alias._id,alias]]);assert.equal(legacyAliasDecision(alias,byId,NOW),null);
  byId=new Map([[canonical._id,canonical],[alias._id,alias]]);alias._mtime=new Date(NOW-5*60*1000).toISOString();alias.state.lastWatched=alias._mtime;
  assert.equal(legacyAliasDecision(alias,byId,NOW),null);
});

test("active duplicate alias is cleared only for identical progress or stale near-zero progress",async()=>{
  const canonical=await libraryItem();canonical._id="tt1864017";canonical.name="Stella";canonical.state.video_id="tt1864017:2:1";canonical._mtime=new Date(NOW-QUIET_MS).toISOString();
  const alias=structuredClone(canonical);alias._id="tmdb:39367";alias._mtime=new Date(NOW-QUIET_MS*2).toISOString();alias.state.lastWatched=alias._mtime;
  let byId=new Map([[canonical._id,canonical],[alias._id,alias]]);
  assert.ok(legacyAliasDecision(alias,byId,NOW));
  alias.state.timeOffset=400;canonical.state.timeOffset=900;alias.state.video_id="tt1864017:1:1";
  assert.ok(legacyAliasDecision(alias,byId,NOW));
  alias.state.timeOffset=5000;
  assert.equal(legacyAliasDecision(alias,byId,NOW),null);
});
