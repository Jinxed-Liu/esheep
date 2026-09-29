// Development-only component harness. Not an app entry point or production build input.
// No auth, cloud client, network writes, or production farm data.
import React, {useState} from 'react';
import {createRoot} from 'react-dom/client';
import {AppHeader} from '../src/components/AppHeader.jsx';
import {HomeDashboard} from '../src/components/HomeDashboard.jsx';
import {FarmEnvironmentBackground} from '../src/components/FarmEnvironment.jsx';
import {calculateSolarEvents, farmLocalDate, resolveFarmEnvironment} from '../src/lib/farmSolar.js';
import {RecordDialog} from '../src/components/RecordDialog.jsx';
import EntryPage from '../src/components/pages/EntryPage.jsx';
import EventsPage from '../src/components/pages/EventsPage.jsx';
import FlockPage from '../src/components/pages/FlockPage.jsx';
import FeedingPage from '../src/components/pages/FeedingPage.jsx';
import InsightsPage from '../src/components/pages/InsightsPage.jsx';
import {SearchPage,AlertsPage} from '../src/components/pages/AppAlignedPages.jsx';
import '../src/styles.css';
import '../src/skyglass.css';
import '../src/farmEnvironment.css';
import '../src/motion.css';
import {PageMotion} from '../src/components/PageMotion.jsx';
const empty=new URLSearchParams(location.search).has('empty');
const farm={id:'visual-review',name:'示范牧场',role:'owner',timeZoneIdentifier:'Asia/Shanghai',hasAuthoritativeTimeZone:true,latitude:39.9042,longitude:116.4074,locationDisplayName:'北京 · 视觉验收牧场'};
const reviewParams=new URLSearchParams(location.search);
const baseDate=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Shanghai'}).format(new Date());
const event=(id,type,label,object,detail,time)=>({id,type,scope:type,label,object,detail,at:`${baseDate}T${time}:00+08:00`,actor:'视觉验收',status:'synced',fields:[]});
const sheep=['D021','D034','D052'].map((earTag,i)=>({id:earTag,earTag,sex:i===1?'公':'母',status:'active',breed:'湖羊',pen:i===1?'二舍':'一舍',stage:'成年',weight:[48.6,42.6,50.2][i],ageDays:360,labels:[]}));
const workspace={mode:'preview',farm,farms:[farm,{...farm,id:'review-two',name:'第二示范牧场'}],profile:{displayName:'MiMo 助手'},metrics:{activeSheep:empty?0:386,activePens:empty?0:16,feedsToday:empty?0:6},
 events:empty?[]:[event('review-weight','weight','称重','D021','体重 48.6 kg（较上次 +1.2 kg）','14:28'),event('review-feed','feed','投喂','三舍','投喂量 250 kg，饲料：苜蓿草','11:05'),event('review-transfer','transfer','转群','D034','一舍 → 二舍','08:12')],
 sheep:empty?[]:sheep,allSheep:empty?[]:sheep,pens:empty?[]:[{id:'p1',name:'一舍',purpose:'育肥',headCount:32,status:'使用中'},{id:'p2',name:'二舍',purpose:'育肥',headCount:28,status:'使用中'}],alerts:[],tmrMeals:[],feedRecords:[],ingredients:[],recipes:[],batches:[],careItems:[],models:{},insightData:{},projectionCoverage:{real:[],preview:[]}};
function Review(){
 const [page,setPage]=useState('home'),[context,setContext]=useState({}),[activeFarm,setFarm]=useState(farm),[record,setRecord]=useState(null),[notice,setNotice]=useState('');
 const [weatherOpen,setWeatherOpen]=useState(false);
 const localDate=farmLocalDate(new Date(),activeFarm.timeZoneIdentifier);
 const solar=calculateSolarEvents(localDate,activeFarm.latitude,activeFarm.longitude);
 const moments={dawn:Date.parse(solar.dawnAt)+4*60_000,earlyMorning:Date.parse(solar.sunriseAt)+20*60_000,morning:Date.parse(solar.solarNoonAt)-120*60_000,noon:Date.parse(solar.solarNoonAt),afternoon:Date.parse(solar.solarNoonAt)+120*60_000,evening:Date.parse(solar.sunsetAt)-30*60_000,twilight:Date.parse(solar.sunsetAt)+20*60_000,night:Date.parse(solar.duskAt)+90*60_000};
 const now=new Date(moments[reviewParams.get('phase')]??Date.now());
 const kind=reviewParams.get('weather')||'clear';
 const mode=reviewParams.get('mode')||'auto';
 const weather={condition:kind,temperatureC:kind==='snow'?-2:kind==='rain'?14:22,feelsLikeC:kind==='snow'?-5:20,cloudCover:kind==='clear'?.1:.8,precipitationIntensity:kind==='rain'?1:0,windSpeedMps:3.2,humidity:.66,visibilityM:10000};
 const environment={now,timeZone:activeFarm.timeZoneIdentifier,location:activeFarm,hasLocation:true,localDate,solar,weather,scene:resolveFarmEnvironment(now,solar,kind,weather.cloudCover),snapshot:{farmID:activeFarm.id,current:weather,observedAt:now.toISOString(),fetchedAt:now.toISOString()},detail:{availability:{hourly:false,daily:false}},error:'',loadDetail:async()=>null};
 const data={...workspace,farm:activeFarm};
 const navigate=(next,ctx={})=>{setPage(next);setContext(ctx);window.scrollTo(0,0);};
 const open=(type)=>setRecord(type);
 const safeSave=async()=>{setNotice('本地视觉验收：未保存或提交任何数据。');};
 let content;
 switch(page){
 case 'home':content=<HomeDashboard workspace={data} environment={environment} onNavigate={navigate} onCreateRecord={open} onWeatherDetailChange={setWeatherOpen}/>;break;
 case 'entry':content=<EntryPage workspace={data} onNavigate={navigate} onCreateRecord={open}/>;break;
 case 'events':content=<EventsPage workspace={data} {...context}/>;break;
 case 'flock':case 'pens':content=<FlockPage workspace={data} initialView={page==='pens'?'pens':'sheep'} selectedID={context.selectedID} onCreateRecord={open} onLabelSubmit={safeSave}/>;break;
 case 'feeding':case 'tmr':content=<FeedingPage workspace={data} onNavigate={navigate} onCreateRecord={open}/>;break;
 case 'search':content=<SearchPage searchIndex={sheep.map(s=>({id:s.id,kind:'sheep',title:s.earTag,detail:s.pen,haystack:s.earTag.toLowerCase()}))} onOpenResult={s=>navigate('flock',{selectedID:s.id})}/>;break;
 case 'alerts':content=<AlertsPage workspace={data} onNavigate={navigate} onCreateRecord={open}/>;break;
 case 'insights':content=<InsightsPage workspace={data} onNavigate={navigate}/>;break;
 default:content=<main className="page feature-page"><h1>{page==='settings'?'账户与牧场设置':'Codex 助手'}</h1><p>此本地验收页只用于界面检查，不连接云端服务。</p></main>;
 }
 return <div className="app-shell" data-content-theme={reviewParams.get('theme')||'light'} data-environment-phase={mode==='off'?'unknown':environment.scene.phase} data-environment-weather={mode==='off'?'unknown':kind}><FarmEnvironmentBackground environment={environment} mode={mode} surface={page} paused={Boolean(record)||weatherOpen||page!=='home'}/><AppHeader activePage={page} workspace={data} onNavigate={navigate} onFarmChange={id=>setFarm(data.farms.find(f=>f.id===id))} onSignOut={()=>{}}/><div className="review-fixture-banner">本地视觉验收 · 示例数据与示例天气 · 不提交云端</div><PageMotion route={page}>{content}</PageMotion>{record?<RecordDialog requestedType={record} workspace={data} onClose={()=>setRecord(null)} onSave={safeSave}/>:null}{notice?<div role="status" className="toast">{notice}</div>:null}</div>;
}
const reviewRoot = createRoot(document.getElementById('root'));
reviewRoot.render(<Review/>);
if (import.meta.hot) import.meta.hot.dispose(() => reviewRoot.unmount());
