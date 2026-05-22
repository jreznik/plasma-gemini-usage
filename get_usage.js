#!/usr/bin/env node
/**
 * Copyright (C) 2026 Jaroslav Reznik
 *
 * get_usage.js - Puppeteer-based Gemini usage scraper for KDE Plasma widget
 *
 * Uses the system Chrome (puppeteer-core) to fully render the Gemini usage
 * page so the SPA has time to inject the real usage percentages and reset
 * time strings into the DOM before we read them.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

'use strict';

const fs   = require('fs');
const path = require('path');
const puppeteer = require('puppeteer-core');

// ──────────────────────────────────────────────
// Paths
// ──────────────────────────────────────────────
const HOME_DIR     = process.env.HOME || require('os').homedir() || '/tmp';
const CONFIG_DIR   = path.join(HOME_DIR, '.config', 'plasma-gemini-usage');
const CONFIG_PATH  = path.join(CONFIG_DIR, 'config.json');
const CACHE_PATH   = path.join(CONFIG_DIR, 'cache.json');
const LOG_PATH     = path.join(CONFIG_DIR, 'puppeteer.log');

const CHROME_PATHS = [
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/google-chrome-beta',
  '/usr/bin/google-chrome-unstable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/snap/bin/chromium',
  '/var/lib/flatpak/exports/bin/com.google.Chrome',
  '/var/lib/flatpak/exports/bin/org.chromium.Chromium',
  '/usr/bin/microsoft-edge',
  '/usr/bin/microsoft-edge-stable',
  '/usr/bin/microsoft-edge-beta',
];

const DEFAULT_UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' +
                   '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

// ──────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────
function ensureDir() {
  if (!fs.existsSync(CONFIG_DIR)) fs.mkdirSync(CONFIG_DIR, { recursive: true });
}

function log(...args) {
  try {
    const msg = `[${new Date().toISOString()}] ${args.join(' ')}\n`;
    fs.appendFileSync(LOG_PATH, msg);
  } catch (_) {}
}

function loadConfig() {
  ensureDir();
  const defaults = { cookie: '', user_agent: DEFAULT_UA, cache_expiry: 900 };
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      return { ...defaults, ...JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')) };
    }
  } catch (_) {}
  return defaults;
}

function saveConfig(cfg) {
  try {
    ensureDir();
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
  } catch (err) {
    log('Failed to save config:', err.message);
  }
}

function loadCache() {
  try {
    if (fs.existsSync(CACHE_PATH)) {
      return JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'));
    }
  } catch (_) {}
  return null;
}

function saveCache(data) {
  try {
    ensureDir();
    fs.writeFileSync(CACHE_PATH, JSON.stringify(data, null, 2));
  } catch (err) {
    log('Failed to save cache:', err.message);
  }
}

function findChrome() {
  for (const p of CHROME_PATHS) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function jitter(minMs = 100, maxMs = 3000) {
  return new Promise(r => setTimeout(r, minMs + Math.random() * (maxMs - minMs)));
}

// ──────────────────────────────────────────────
// Parse epoch from reset-time strings like:
//   "Resets at 1:19 AM"  ->  today or tomorrow at 01:19
//   "Resets May 26 at 9:19 AM"  ->  specific date + time
// Returns epoch seconds, or 0 on failure.
// ──────────────────────────────────────────────
function parseResetTime(text) {
  if (!text) return 0;
  const now = new Date();
  const MONTHS = {
    // English
    jan:0, feb:1, mar:2, apr:3, may:4, jun:5, jul:6, aug:7, sep:8, oct:9, nov:10, dec:11,
    // Czech
    led:0, úno:1, bře:2, dub:3, kvě:4, čer:5, čvc:6, srp:7, zář:8, říj:9, lis:10, pro:11,
    kvé:4, cer:5, rij:9,
    // German
    mär:2, mai:4, okt:9, dez:11, mae:2,
    // French
    fév:1, avr:3, aoû:7, déc:11, fev:1, aou:7, dec:11,
    // Spanish / Italian
    ene:0, abr:3, ago:7, dic:11
  };

  // Match either "Month Day" or "Day Month", optionally followed by comma and/or year using Unicode support.
  // Must check this first so that it doesn't match the time-only regex and ignore the date.
  let m = text.match(/(?:Resets?\s+|obnov[íi]\s+se\s+|zur[üu]ckgesetzt\s+|re-sets?\s+)(?:([\p{L}]+)\s+(\d{1,2})\.?|(\d{1,2})\.?\s+([\p{L}]+))(?:,?\s+\d{4})?\s+(?:at|v|um|am|at)\s+(\d{1,2}):(\d{2})\s*(AM|PM)?/ui);
  if (m) {
    let [, mon1, day1, day2, mon2, h, min, ampm] = m;
    let mon = mon1 || mon2;
    let day = parseInt(day1 || day2, 10);
    h = parseInt(h, 10);
    min = parseInt(min, 10);
    
    let monthIdx = undefined;
    if (mon) {
      const monthKey = mon.slice(0, 3).toLowerCase();
      monthIdx = MONTHS[monthKey];
    }
    
    if (ampm && ampm.toUpperCase() === 'PM' && h !== 12) h += 12;
    if (ampm && ampm.toUpperCase() === 'AM' && h === 12) h = 0;
    
    const year = (monthIdx !== undefined && monthIdx < now.getMonth()) 
                  ? now.getFullYear() + 1 
                  : now.getFullYear();
    const d = new Date(year, monthIdx ?? now.getMonth(), day, h, min, 0, 0);
    const epoch = Math.floor(d.getTime() / 1000);
    return isNaN(epoch) ? 0 : epoch;
  }

  // Time-only: "Resets at H:MM AM/PM" or "Resets at H:MM", or custom multilingual phrases.
  // Checked second to allow date-time matching first.
  m = text.match(/(?:Resets?\s+(?:at|v|um)\s+|obnov[íi]\s+se\s+v\s+|zur[üu]ckgesetzt\s+(?:um|am)\s+|re-sets?\s+at\s+)?(\d{1,2}):(\d{2})\s*(AM|PM)?/ui);
  if (m) {
    let [, h, min, ampm] = m;
    h = parseInt(h, 10);
    min = parseInt(min, 10);
    if (ampm && ampm.toUpperCase() === 'PM' && h !== 12) h += 12;
    if (ampm && ampm.toUpperCase() === 'AM' && h === 12) h = 0;
    const d = new Date(now);
    d.setHours(h, min, 0, 0);
    if (d <= now) d.setDate(d.getDate() + 1); // next occurrence
    const epoch = Math.floor(d.getTime() / 1000);
    return isNaN(epoch) ? 0 : epoch;
  }

  return 0;
}

// ──────────────────────────────────────────────
// Anti-Detection Evasion & Stealth Helpers
// ──────────────────────────────────────────────
function getSecChUaHeaders(ua) {
  const match = ua.match(/Chrome\/(\d+)\./);
  const major = match ? match[1] : '124';
  return {
    'Sec-Ch-Ua': `"Google Chrome";v="${major}", "Chromium";v="${major}", "Not-A.Brand";v="99"`,
    'Sec-Ch-Ua-Mobile': '?0',
    'Sec-Ch-Ua-Platform': '"Linux"',
  };
}

async function applyStealthMask(page) {
  await page.evaluateOnNewDocument(() => {
    // 1. Overwrite webdriver
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

    // 2. Mock chrome object (automated browsers often lack this)
    window.chrome = {
      app: {
        isInstalled: false,
        InstallState: { DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed' },
        RunningState: { CANNOT_RUN: 'cannot_run', RUNNING: 'running', CAN_RUN: 'can_run' }
      },
      runtime: {
        OnInstalledReason: { CHROME_UPDATE: 'chrome_update', INSTALL: 'install', SHARED_MODULE_UPDATE: 'shared_module_update', UPDATE: 'update' },
        OnRestartRequiredReason: { APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic' },
        PlatformArch: { ARM: 'arm', ARM64: 'arm64', MIPS: 'mips', MIPS64: 'mips64', X86_32: 'x86-32', X86_64: 'x86-64' },
        PlatformNaclArch: { ARM: 'arm', MIPS: 'mips', X86_32: 'x86-32', X86_64: 'x86-64' },
        PlatformOs: { ANDROID: 'android', CROS: 'cros', LINUX: 'linux', MAC: 'mac', OPENBSD: 'openbsd', WIN: 'win' },
        RequestUpdateCheckStatus: { NO_UPDATE: 'no_update', THROTTLED: 'throttled', UPDATE_AVAILABLE: 'update_available' }
      }
    };

    // 3. Mock plugins (empty plugins list is a classic tell of automation)
    const mockPlugins = [
      { name: 'PDF Viewer', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
      { name: 'Chrome PDF Viewer', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
      { name: 'Chromium PDF Viewer', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
      { name: 'Microsoft Edge PDF Viewer', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
      { name: 'WebKit built-in PDF', filename: 'internal-pdf-viewer', description: 'Portable Document Format' }
    ];
    
    Object.defineProperty(navigator, 'plugins', {
      get: () => {
        const pluginsList = Object.create(PluginArray.prototype);
        mockPlugins.forEach((p, idx) => {
          const plugin = Object.create(Plugin.prototype);
          Object.defineProperties(plugin, {
            name: { value: p.name },
            filename: { value: p.filename },
            description: { value: p.description },
            length: { value: 0 }
          });
          pluginsList[idx] = plugin;
          pluginsList[p.name] = plugin;
        });
        Object.defineProperties(pluginsList, {
          length: { value: mockPlugins.length },
          item: { value: (idx) => pluginsList[idx] },
          namedItem: { value: (name) => pluginsList[name] }
        });
        return pluginsList;
      }
    });

    // 4. Mock hardwareConcurrency (Google sometimes flags low values like 1)
    Object.defineProperty(navigator, 'hardwareConcurrency', {
      get: () => 8
    });

    // 5. Mock languages to align with headers
    Object.defineProperty(navigator, 'languages', {
      get: () => ['en-US', 'en']
    });
  });
}

// ──────────────────────────────────────────────
// Main scrape
// ──────────────────────────────────────────────
async function scrape(cookie, userAgent) {
  if (!cookie) {
    return { status: 'auth_error',
             message: 'Cookie is not configured. Open settings and paste your Cookie string.' };
  }

  const chromePath = findChrome();
  if (!chromePath) {
    return { status: 'error', message: 'Google Chrome not found on this system.' };
  }

  log('Launching Chrome:', chromePath);

  await jitter(100, 1500); // stealth jitter before launch

  const browser = await puppeteer.launch({
    executablePath: chromePath,
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-blink-features=AutomationControlled',
      '--excludeSwitches=enable-automation',
      '--disable-infobars',
      '--window-size=1280,800',
    ],
  });

  try {
    const page = await browser.newPage();

    // Apply advanced stealth overrides to mock real desktop browser
    await applyStealthMask(page);

    await page.setUserAgent(userAgent || DEFAULT_UA);
    await page.setViewport({ width: 1280, height: 800 });
    await page.setExtraHTTPHeaders({
      'Accept-Language': 'en-US,en;q=0.9',
      'Referer': 'https://gemini.google.com/',
    });

    // Inject the cookie via request interception — exactly like the Python version's
    // raw `Cookie:` HTTP header approach. This is the most reliable method for Google.
    await page.setRequestInterception(true);
    page.on('request', req => {
      try {
        const url = req.url();
        // ONLY inject cookie on gemini.google.com. Restricting to gemini.google.com
        // prevents infinite redirect loops on accounts.google.com when cookies expire.
        if (url.includes('gemini.google.com')) {
          const ua = userAgent || DEFAULT_UA;
          const secChHeaders = getSecChUaHeaders(ua);
          const headers = {
            ...req.headers(),
            'Cookie': cookie,
            'Accept-Language': 'en-US,en;q=0.9',
            ...secChHeaders,
          };
          req.continue({ headers });
        } else {
          req.continue();
        }
      } catch (_) {
        try { req.continue(); } catch (__) {}
      }
    });
    log('Request interception enabled — raw Cookie header will be injected on gemini.google.com');

    // Navigate to the usage page
    // Use 'load' not 'networkidle2' — Gemini SPA keeps background XHR connections
    // open indefinitely, so networkidle2 would always timeout.
    log('Navigating to usage page');
    let response = null;
    try {
      response = await page.goto('https://gemini.google.com/usage', {
        waitUntil: 'load',
        timeout: 30000,
      });
    } catch (navErr) {
      log('Navigation warning:', navErr.message);
      const isTimeout = navErr.message.toLowerCase().includes('timeout');
      if (!isTimeout) {
        if (navErr.message.includes('ERR_TOO_MANY_REDIRECTS')) {
          return { status: 'auth_error', message: 'Google cookie is expired or invalid (Too many redirects).' };
        }
        return { status: 'error', message: `Navigation failed: ${navErr.message}` };
      }
    }

    // Check for auth redirect (explicit redirect case)
    const finalUrl = page.url();
    if (finalUrl.includes('accounts.google.com')) {
      return { status: 'auth_error',
               message: 'Google cookie is expired or invalid. Please update it.' };
    }

    if (response && response.status && response.status() >= 400) {
      return { status: 'error',
               message: `Google returned HTTP ${response.status()}` };
    }

    // Wait for the usage content to render
    // We wait for a % character to appear — the SPA injects usage percentages
    log('Waiting for usage content to render');
    try {
      await page.waitForFunction(
        () => document.body.innerText.includes('%') &&
              !/sign\s*in|přihlásit|anmelden|se\s*connecter/i.test(document.body.innerText),
        { timeout: 20000 }
      );
    } catch (_) {
      log('Timeout waiting for % without Sign in — proceeding anyway');
    }

    // ── Human-like interaction simulation during settle time ──
    try {
      log('Simulating human mouse movements and scrolling...');
      // 1. Random mouse coordinates
      const x = 200 + Math.random() * 400;
      const y = 200 + Math.random() * 400;
      await page.mouse.move(x, y);
      await new Promise(r => setTimeout(r, 200 + Math.random() * 300));
      await page.mouse.move(x + 100, y + 100);
      
      // 2. Dynamic smooth scroll down & up
      await page.evaluate(async () => {
        await new Promise((resolve) => {
          let totalHeight = 0;
          const distance = 80;
          const timer = setInterval(() => {
            window.scrollBy(0, distance);
            totalHeight += distance;
            if (totalHeight >= 320) {
              clearInterval(timer);
              // scroll back up after brief delay
              setTimeout(() => {
                let scrollUpHeight = 320;
                const scrollUpTimer = setInterval(() => {
                  window.scrollBy(0, -distance);
                  scrollUpHeight -= distance;
                  if (scrollUpHeight <= 0) {
                    clearInterval(scrollUpTimer);
                    resolve();
                  }
                }, 80 + Math.random() * 100);
              }, 300 + Math.random() * 200);
            }
          }, 80 + Math.random() * 100);
        });
      });
      log('Human simulation completed successfully');
    } catch (simErr) {
      log('Human simulation warning:', simErr.message);
      // Fallback simple sleep if interaction fails
      await new Promise(r => setTimeout(r, 3000));
    }

    // Check for sign-in wall after waiting (non-redirect case)
    const bodyCheck = await page.evaluate(() => document.body.innerText.slice(0, 200));
    log('Post-wait body check:', bodyCheck);
    if (/sign\s*in|přihlásit|anmelden|se\s*connecter/i.test(bodyCheck) && !bodyCheck.includes('%')) {
      return { status: 'auth_error',
               message: 'Google cookie is expired or invalid. Page showed sign-in wall.' };
    }

    // ── Extract data from the fully rendered page ──
    const result = await page.evaluate(() => {
      const bodyText = document.body.innerText || '';
      const lines = bodyText.split('\n').map(l => l.trim()).filter(Boolean);

      let fiveHourPct   = null;
      let weeklyPct     = null;
      let fiveHourReset = '';
      let weeklyReset   = '';
      let countdown     = 'Active';

      // ── Section-aware extraction ──
      // Find "Current usage" and "Weekly limit" sections (multilingual support) and read the next few lines.

      const findSection = (anchorPattern) => {
        for (let i = 0; i < lines.length; i++) {
          if (anchorPattern.test(lines[i])) return i;
        }
        return -1;
      };

      // Multilingual anchor patterns (English, Czech, German, French, Spanish, Portuguese, Italian)
      const currentIdx = findSection(/current\s+usage|aktu[áa]ln[íi]\s+vyu[žz]it[íi]|aktuelle\s+nutzung|utilisation\s+actuelle|uso\s+actual|utiliz[az]ione\s+atual/i);
      const weeklyIdx  = findSection(/weekly\s+(?:limit|budget)|t[ýy]denn[íi]\s+limit|w[öo]chentliches\s+limit|limite\s+hebdo|l[íi]mite\s+semanal|limite\s+settimanale/i);

      // Extract from current usage section (lines after the heading, up to next heading)
      if (currentIdx !== -1) {
        const end = (weeklyIdx > currentIdx) ? weeklyIdx : (currentIdx + 8);
        for (let i = currentIdx + 1; i < Math.min(end, lines.length); i++) {
          const line = lines[i];
          if (fiveHourPct === null && /\b\d+%/.test(line)) {
            const m = line.match(/(\d+)%/);
            if (m) fiveHourPct = parseInt(m[1], 10);
          }
          if (!fiveHourReset && /(?:Resets?\s+at\s+|obnov[íi]\s+se\s+v\s+|zur[üu]ckgesetzt\s+um\s+|re-sets?\s+at\s+)\d/i.test(line)) {
            fiveHourReset = line;
          }
          if (countdown === 'Active' && /(?:refresh|reset|obnov|aktualiz|zur[üu]ck).*in\s+\d/i.test(line)) {
            countdown = line;
          }
        }
      }

      // Extract from weekly limit section
      if (weeklyIdx !== -1) {
        for (let i = weeklyIdx + 1; i < Math.min(weeklyIdx + 8, lines.length); i++) {
          const line = lines[i];
          if (weeklyPct === null && /\b\d+%/.test(line)) {
            const m = line.match(/(\d+)%/);
            if (m) weeklyPct = parseInt(m[1], 10);
          }
          if (!weeklyReset && /(?:Resets?\s+|obnov[íi]\s+se\s+|zur[üu]ckgesetzt\s+am\s+)(?:\S+\s+\d+|\d+\s+\S+)/i.test(line)) {
            weeklyReset = line;
          }
          // Also catch "Resets at X" for weekly if no date-based reset found
          if (!weeklyReset && /(?:Resets?\s+at\s+|obnov[íi]\s+se\s+v\s+|zur[üu]ckgesetzt\s+um\s+|re-sets?\s+at\s+)\d/i.test(line) && line !== fiveHourReset) {
            weeklyReset = line;
          }
        }
      }

      // ── WIZ_global_data fallback for percentages (can be slightly stale) ──
      if (fiveHourPct === null || weeklyPct === null) {
        try {
          const wiz = window.WIZ_global_data;
          if (wiz) {
            for (const [k, v] of Object.entries(wiz)) {
              if (typeof v === 'string' && v.startsWith('%.@.')) {
                const inner = v.slice(4);
                const arr = JSON.parse('[' + inner);
                if (Array.isArray(arr) && arr.length >= 3 &&
                    arr[0] === null &&
                    typeof arr[1] === 'number' && arr[1] >= 0 && arr[1] <= 100 &&
                    typeof arr[2] === 'number' && arr[2] >= 0 && arr[2] <= 100 &&
                    !['hsFLT', 'UUFaWc'].includes(k)) {
                  if (fiveHourPct === null) fiveHourPct = Math.round(arr[1]);
                  if (weeklyPct === null)   weeklyPct   = Math.round(arr[2]);
                  break;
                }
              }
            }
          }
        } catch (_) {}
      }

      return {
        fiveHourPct:  fiveHourPct  ?? 0,
        weeklyPct:    weeklyPct    ?? 0,
        fiveHourReset,
        weeklyReset,
        countdown,
        bodySnippet: bodyText.slice(0, 2000),
      };
    });

    log('Raw extraction:', JSON.stringify({
      fiveHourPct:  result.fiveHourPct,
      weeklyPct:    result.weeklyPct,
      fiveHourReset: result.fiveHourReset,
      weeklyReset:  result.weeklyReset,
    }));

    // If both percentages are 0, reset strings are empty, and no % was found in the body snippet,
    // it indicates a failed load or session expiry rather than genuine 0% usage.
    if (result.fiveHourPct === 0 && result.weeklyPct === 0 && !result.fiveHourReset && !result.weeklyReset && !result.bodySnippet.includes('%')) {
      return {
        status: 'auth_error',
        message: 'Google cookie is expired or invalid. Could not load usage page.'
      };
    }

    // Log full body for debugging reset strings
    if (!result.fiveHourReset || !result.weeklyReset) {
      log('Reset strings not found — full body text:', result.bodySnippet);
    }

    // Parse reset strings into epoch timestamps
    const fiveHourResetEpoch = parseResetTime(result.fiveHourReset);
    const weeklyResetEpoch   = parseResetTime(result.weeklyReset);
    const nowSec = Math.floor(Date.now() / 1000);

    // Fallback for 5-hour epoch if DOM parsing failed. Keep 0 if usage is 0% to show Capacity: Full Speed.
    let finalFiveHourEpoch = fiveHourResetEpoch;
    if (finalFiveHourEpoch <= 0 && result.fiveHourPct > 0) {
      finalFiveHourEpoch = nowSec + Math.floor(5 * 3600 * (1 - result.fiveHourPct / 100));
    }

    // Fallback weekly epoch: next Monday 00:00 UTC
    let finalWeeklyEpoch = weeklyResetEpoch;
    if (!finalWeeklyEpoch) {
      const now = new Date();
      const daysUntilMonday = (7 - now.getUTCDay() + 1) % 7 || 7;
      const nextMonday = new Date(Date.UTC(
        now.getUTCFullYear(), now.getUTCMonth(),
        now.getUTCDate() + daysUntilMonday, 0, 0, 0
      ));
      finalWeeklyEpoch = Math.floor(nextMonday.getTime() / 1000);
    }

    return {
      status: 'success',
      five_hour_pct:        result.fiveHourPct,
      weekly_pct:           result.weeklyPct,
      countdown:            result.countdown,
      five_hour_reset_epoch: finalFiveHourEpoch,
      weekly_reset_epoch:   finalWeeklyEpoch,
      five_hour_reset_str:  result.fiveHourReset,
      weekly_reset_str:     result.weeklyReset,
      timestamp: nowSec,
    };

  } finally {
    await browser.close();
  }
}

// ──────────────────────────────────────────────
// Interactive Login Flow
// ──────────────────────────────────────────────
async function interactiveLogin() {
  const chromePath = findChrome();
  if (!chromePath) {
    return { status: 'error', message: 'Google Chrome not found on this system.' };
  }

  log('Launching Chrome for interactive login:', chromePath);

  const browser = await puppeteer.launch({
    executablePath: chromePath,
    headless: false,
    defaultViewport: null,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-blink-features=AutomationControlled',
      '--excludeSwitches=enable-automation',
      '--disable-infobars',
      '--window-size=1280,800',
    ],
  });

  try {
    const pages = await browser.pages();
    const page = pages.length > 0 ? pages[0] : await browser.newPage();

    // Apply advanced stealth overrides to mock real desktop browser
    await applyStealthMask(page);

    await page.setViewport({ width: 1280, height: 800 });

    log('Navigating to Gemini usage page for sign-in');
    await page.goto('https://gemini.google.com/usage', {
      waitUntil: 'load',
      timeout: 60000,
    });

    log('Waiting for user login and usage metrics...');
    // Wait up to 5 minutes for successful sign-in (represented by '%' in page content)
    await page.waitForFunction(
      () => document.body.innerText.includes('%') &&
            !/sign\s*in|přihlásit|anmelden|se\s*connecter/i.test(document.body.innerText),
      { timeout: 300000 }
    );

    // Dynamic settle time
    await new Promise(r => setTimeout(r, 2000));

    // Capture cookies
    const cookies = await page.cookies();
    const cookieString = cookies.map(c => `${c.name}=${c.value}`).join('; ');

    // Capture the exact browser User-Agent
    const userAgent = await page.evaluate(() => navigator.userAgent);

    log('Interactive sign-in successful. Saving config...');

    // Save to configuration
    const cfg = loadConfig();
    cfg.cookie = cookieString;
    cfg.user_agent = userAgent;
    saveConfig(cfg);

    // Clear cache
    try {
      if (fs.existsSync(CACHE_PATH)) fs.unlinkSync(CACHE_PATH);
    } catch (_) {}

    return {
      status: 'success',
      message: 'Successfully signed in and captured credentials.',
      cookie: cookieString,
      user_agent: userAgent,
    };
  } finally {
    try {
      await browser.close();
    } catch (_) {}
  }
}

// ──────────────────────────────────────────────
// Entry point
// ──────────────────────────────────────────────
async function main() {
  const args = process.argv.slice(2);

  // ── --save-config mode ──
  if (args.includes('--save-config')) {
    const cfg = loadConfig();
    for (let i = 0; i < args.length - 1; i++) {
      if (args[i] === '--cookie')     cfg.cookie      = args[i + 1];
      if (args[i] === '--user-agent') cfg.user_agent  = args[i + 1];
      if (args[i] === '--expiry')     cfg.cache_expiry = parseInt(args[i + 1]) || 900;
    }
    saveConfig(cfg);
    // Clear cache on config change
    try {
      if (fs.existsSync(CACHE_PATH)) fs.unlinkSync(CACHE_PATH);
    } catch (_) {}
    process.stdout.write(JSON.stringify({ status: 'success', message: 'Configuration saved.' }) + '\n');
    return;
  }

  // ── --login mode ──
  if (args.includes('--login')) {
    try {
      const res = await interactiveLogin();
      process.stdout.write(JSON.stringify(res) + '\n');
    } catch (err) {
      log('Interactive login error:', err.message);
      process.stdout.write(JSON.stringify({
        status: 'error',
        message: `Interactive sign-in error: ${err.message}`,
      }) + '\n');
    }
    return;
  }


  // ── Normal fetch mode ──
  const cfg    = loadConfig();
  const expiry = cfg.cache_expiry || 900;
  const nowSec = Math.floor(Date.now() / 1000);

  // 1. Try cache
  const cached = loadCache();
  if (cached && cached.status === 'success') {
    const age = nowSec - (cached.timestamp || 0);
    if (age < expiry) {
      cached.cached = true;
      cached.cache_age_seconds = age;
      process.stdout.write(JSON.stringify(cached) + '\n');
      return;
    }
  }

  // 2. Scrape fresh
  try {
    const result = await scrape(cfg.cookie, cfg.user_agent);
    if (result.status === 'success') {
      result.cached = false;
      saveCache(result);
    }
    process.stdout.write(JSON.stringify(result) + '\n');
  } catch (err) {
    log('Uncaught error:', err.message);
    process.stdout.write(JSON.stringify({
      status: 'error',
      message: `Puppeteer error: ${err.message}`,
    }) + '\n');
  }
}

main().catch(err => {
  process.stdout.write(JSON.stringify({
    status: 'error',
    message: `Fatal: ${err.message}`,
  }) + '\n');
  process.exit(1);
});
