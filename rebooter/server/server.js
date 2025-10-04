import express from 'express';
import bodyParser from 'body-parser';
import fs from 'fs';
import path from 'path';
import { exec } from 'child_process';
import cron from 'node-cron';

const app = express();
app.use(bodyParser.urlencoded({ extended: true }));

const APP_DIR = '/app';
const CONFIG_PATH = path.join(APP_DIR, 'server', 'config.json');
const LOG_FILE   = path.join(APP_DIR, 'logs',  'rebooter.log');
const SCRIPT     = path.join(APP_DIR, 'scripts','repeater_reboot.sh');
let currentTask = null;

function ensureFiles(){
  fs.mkdirSync(path.dirname(CONFIG_PATH), { recursive: true });
  fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
  if (!fs.existsSync(CONFIG_PATH)) {
    fs.writeFileSync(CONFIG_PATH, JSON.stringify({
      ip:"192.168.1.2", username:"admin", password:"",
      method:"RAW_CURL", dow:"0", time:"03:30",
      raw_curl_login:"", raw_curl_reboot:""
    }, null, 2));
  }
}
ensureFiles();

function escapeHtml(s=''){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function loadConfig(){ return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8')); }
function scheduleFrom(dow, hhmm){ const [h,m]=(hhmm||'03:30').split(':'); return `${m} ${h} * * ${dow??'0'}`; }

function startScheduler(){
  const cfg=loadConfig();
  const spec=scheduleFrom(cfg.dow, cfg.time);
  if (currentTask) currentTask.stop();
  currentTask=cron.schedule(spec, ()=>runOnce(), { timezone: process.env.TZ||'Europe/Paris' });
  console.log('Scheduler set to', spec);
}

function runOnce(){
  return new Promise(resolve=>{
    const env={...process.env, LOG_FILE};
    exec(`${SCRIPT} ${CONFIG_PATH}`, { env }, (err, stdout, stderr)=>{
      const out=`[RUN ${new Date().toISOString()}] exit=${err?err.code:0}\n${stdout}${stderr}`;
      fs.appendFileSync(LOG_FILE, out.replace(/\r/g,''));
      resolve();
    });
  });
}
function tailLog(n=200){
  if (!fs.existsSync(LOG_FILE)) return '';
  const lines=fs.readFileSync(LOG_FILE,'utf-8').replace(/\r/g,'').trim().split('\n');
  return lines.slice(-n).join('\n');
}

app.get('/', (req,res)=>{
  const cfg=loadConfig();
  const html=fs.readFileSync(path.join(APP_DIR,'server','views','index.html'),'utf-8')
    .replace('{{config}}', escapeHtml(JSON.stringify(cfg,null,2)))
    .replace('{{logTail}}', escapeHtml(tailLog()));
  res.set('Content-Type','text/html').send(html);
});

app.post('/save', (req,res)=>{
  const cfg=loadConfig();
  const next={
    ...cfg,
    ip: req.body.ip || cfg.ip,
    username: req.body.username || cfg.username,
    password: req.body.password ?? cfg.password,
    method: 'RAW_CURL', // ← forcé
    dow: req.body.dow || cfg.dow || '0',
    time: req.body.time || cfg.time || '03:30',
    raw_curl_login:  req.body.raw_curl_login  || '',
    raw_curl_reboot: req.body.raw_curl_reboot || ''
  };
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(next,null,2));
  startScheduler();
  res.redirect(303,'/');
});

app.post('/run-now', async (req,res)=>{ await runOnce(); res.redirect(303,'/'); });

const PORT=process.env.PORT||3333;
app.listen(PORT, ()=>{ startScheduler(); console.log(`Web UI on :${PORT}`); });
