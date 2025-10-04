import express from 'express';
import bodyParser from 'body-parser';
import fs from 'fs';
import path from 'path';
import { exec } from 'child_process';
import cron from 'node-cron';

const app = express();
app.use(bodyParser.urlencoded({ extended: true }));

// Emplacements dans le conteneur
const APP_DIR     = '/app';
const CONFIG_PATH = path.join(APP_DIR, 'server', 'config.json');
const LOG_FILE    = path.join(APP_DIR, 'logs',  'rebooter.log');
const SCRIPT      = path.join(APP_DIR, 'scripts','repeater_reboot.sh');

let currentTask = null;

/* ---------- Utils ---------- */
function ensureFiles(){
  fs.mkdirSync(path.dirname(CONFIG_PATH), { recursive: true });
  fs.mkdirSync(path.dirname(LOG_FILE),   { recursive: true });
  if (!fs.existsSync(CONFIG_PATH)) {
    fs.writeFileSync(CONFIG_PATH, JSON.stringify({
      ip: '192.168.1.2',
      username: 'admin',
      password: 'password',
      method: 'RAW_CURL',
      dow: '0',
      time: '03:30',
      raw_curl_login: '',
      raw_curl_reboot: ''
    }, null, 2));
  }
}
ensureFiles();

function escapeHtml(s = '') {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function loadConfig(){
  try {
    const raw = fs.readFileSync(CONFIG_PATH, 'utf-8');
    return JSON.parse(raw);
  } catch (e) {
    console.error('Invalid config.json, resetting to defaults:', e.message);
    const def = {
      ip: '192.168.1.2',
      username: 'admin',
      password: '',
      method: 'RAW_CURL',
      dow: '0',
      time: '03:30',
      raw_curl_login: '',
      raw_curl_reboot: ''
    };
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(def, null, 2));
    return def;
  }
}

function isValidTime(hhmm){ return /^([01]?\d|2[0-3]):[0-5]\d$/.test(hhmm || ''); }
function isValidDow(d){ return /^[0-6]$/.test(String(d)); }
function scheduleFrom(dow, hhmm){
  const safeDow  = isValidDow(dow)  ? dow  : '0';
  const safeTime = isValidTime(hhmm) ? hhmm : '03:30';
  const [h, m] = safeTime.split(':');
  return { spec: `${m} ${h} * * ${safeDow}`, safeDow, safeTime };
}

function startScheduler(){
  const cfg = loadConfig();
  const { spec, safeDow, safeTime } = scheduleFrom(cfg.dow, cfg.time);
  if (currentTask) currentTask.stop();
  currentTask = cron.schedule(spec, () => runOnce(), { timezone: process.env.TZ || 'Europe/Paris' });
  console.log('Scheduler set to', spec, '(dow=', safeDow, 'time=', safeTime + ')');
}

function runOnce(){
  return new Promise((resolve) => {
    const env = { ...process.env, LOG_FILE };
    exec(`${SCRIPT} ${CONFIG_PATH}`, { env }, (err, stdout, stderr) => {
      // On journalise tout dans le fichier (et on neutralise d’éventuels CR Windows)
      const out = `[RUN ${new Date().toISOString()}] exit=${err ? err.code : 0}\n${String(stdout)}${String(stderr)}`;
      fs.appendFileSync(LOG_FILE, out.replace(/\r/g, ''));
      resolve();
    });
  });
}

function tailLog(n = 200){
  if (!fs.existsSync(LOG_FILE)) return '';
  const lines = fs.readFileSync(LOG_FILE, 'utf-8').replace(/\r/g, '').trim().split('\n');
  return lines.slice(-n).join('\n');
}

/* ---------- Routes ---------- */

// Page principale (no-cache pour éviter de voir une vieille version en dev)
app.get('/', (req, res) => {
  const cfg  = loadConfig();
  const html = fs.readFileSync(path.join(APP_DIR, 'server', 'views', 'index.html'), 'utf-8')
    .replace('{{config}}',  escapeHtml(JSON.stringify(cfg, null, 2)))
    .replace('{{logTail}}', escapeHtml(tailLog()));
  res.set({
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store'
  }).send(html);
});

// Sauvegarde config (RAW_CURL only) + restart scheduler
app.post('/save', (req, res) => {
  const cfg = loadConfig();
  const next = {
    ...cfg,
    ip:        req.body.ip        || cfg.ip,
    username:  req.body.username  || cfg.username,
    password:  (req.body.password ?? cfg.password),
    method:    'RAW_CURL',
    dow:       (isValidDow(req.body.dow)   ? req.body.dow   : (cfg.dow   ?? '0')),
    time:      (isValidTime(req.body.time) ? req.body.time  : (cfg.time  ?? '03:30')),
  };
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(next, null, 2));
  startScheduler();
  res.redirect(303, '/');
});

// Exécution immédiate
app.post('/run-now', async (req, res) => {
  await runOnce();
  res.redirect(303, '/');
});

// Endpoint santé
app.get('/healthz', (req, res) => {
  res.status(200).json({ ok: true, time: new Date().toISOString() });
});

/* ---------- Serveur ---------- */
const PORT = process.env.PORT || 3333;
app.listen(PORT, () => {
  startScheduler();
  console.log(`Web UI on :${PORT}`);
});
