function oneTimeReportedWatchedMovieProgressDecision(item,now){
  if(!item||item.type!=="movie")return null;
  if(item.removed&&!item.temp)return null;
  const state=item.state||{},offset=Number(state.timeOffset),duration=Number(state.duration);
  if(!(offset>0)||!(duration>0))return null;
  if((Number(state.timesWatched)||0)<1)return null;
  if(Number(state.flaggedWatched)!==0)return null;
  if(offset/duration>=0.2)return null;
  if(now-playbackActivityTime(item)<QUIET_MS)return null;
  if(typeof state.video_id!=="string"||!state.video_id)return null;
  return {id:item._id,before:structuredClone(item),reason:"user-confirmed-watched-movie-stale-replay-progress"};
}
