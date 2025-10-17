# ----- Render single-file service: Playwright + Node -----
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=10000
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN npm init -y && npm install --omit=dev playwright@1.47.0

RUN cat > /app/server.js <<'EOF'
const http = require("http");
const crypto = require("crypto");
const { chromium } = require("playwright");

const PORT = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || "";

let browserPromise;
async function getBrowser(){
  if (!browserPromise){
    browserPromise = chromium.launch({
      headless: true,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
        "--disable-features=IsolateOrigins,site-per-process",
        "--disable-blink-features=AutomationControlled"
      ]
    });
  }
  return browserPromise;
}

function sendJSON(res, code, obj){
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {"content-type":"application/json; charset=utf-8","content-length":body.length});
  res.end(body);
}
function unauthorized(res){ return sendJSON(res, 401, {ok:false, error:"unauthorized"}); }
function isPrivateHost(h){ return [/^localhost$/i,/^127\./,/^\[?::1\]?$/, /^10\./,/^192\.168\./,/^172\.(1[6-9]|2\d|3[0-1])\./,/^169\.254\./].some(re=>re.test(h)); }
function isValidHttpUrl(u){ try{ const x=new URL(u); return /^https?:$/.test(x.protocol) && !isPrivateHost(x.hostname); } catch { return false; } }

async function simulateHumanBehavior(page){
  try {
    // Random mouse movements
    const w = page.viewportSize().width;
    const h = page.viewportSize().height;
    
    for (let i = 0; i < 3; i++){
      const x = Math.floor(Math.random() * w);
      const y = Math.floor(Math.random() * h);
      await page.mouse.move(x, y, { steps: Math.floor(Math.random() * 10) + 5 });
      await page.waitForTimeout(Math.random() * 200 + 50);
    }
    
    // Random scroll
    await page.evaluate(() => {
      window.scrollBy({
        top: Math.random() * 300 + 100,
        behavior: 'smooth'
      });
    });
    await page.waitForTimeout(Math.random() * 500 + 300);
    
    // Scroll back up
    await page.evaluate(() => {
      window.scrollTo({
        top: 0,
        behavior: 'smooth'
      });
    });
    await page.waitForTimeout(Math.random() * 300 + 200);
  } catch {}
}

async function applyStealth(page, {acceptLang="en-US,en;q=0.9", tz="America/Chicago"} = {}){
  await page.addInitScript(() => {
    // Hide webdriver
    Object.defineProperty(navigator, "webdriver", {get: () => undefined});
    delete navigator.__proto__.webdriver;
    
    // Fix chrome object
    window.chrome = {
      runtime: {},
      loadTimes: function() {},
      csi: function() {},
      app: {}
    };
    
    // Fix permissions
    const origQuery = navigator.permissions.query;
    navigator.permissions.query = (p)=> p && p.name==="notifications" ? Promise.resolve({state: Notification.permission}) : origQuery(p);
    
    // Fix plugins with more realistic data
    Object.defineProperty(navigator, "plugins", { 
      get: () => {
        const p = [
          {0: {type: "application/pdf"}, name: "Chrome PDF Plugin", filename: "internal-pdf-viewer", description: "Portable Document Format", length: 1},
          {0: {type: "application/x-google-chrome-pdf"}, name: "Chrome PDF Viewer", filename: "mhjfbmdgcfjbbpaeojofohoefgiehjai", description: "", length: 1},
          {0: {type: "application/x-nacl"}, name: "Native Client", filename: "internal-nacl-plugin", description: "", length: 2}
        ];
        p.length = 3;
        return p;
      }
    });
    
    // Fix languages
    Object.defineProperty(navigator, "languages", { get: () => ["en-US","en"] });
    
    // Fix platform
    Object.defineProperty(navigator, "platform", { get: () => "Win32" });
    
    // Fix hardwareConcurrency
    Object.defineProperty(navigator, "hardwareConcurrency", { get: () => 8 });
    
    // Fix deviceMemory
    Object.defineProperty(navigator, "deviceMemory", { get: () => 8 });
    
    // Fix headless detection
    Object.defineProperty(navigator, "maxTouchPoints", { get: () => 0 });
    
    // Fix vendor
    Object.defineProperty(navigator, "vendor", { get: () => "Google Inc." });
    
    // Override toString to hide proxy
    const oldToString = Function.prototype.toString;
    Function.prototype.toString = function() {
      if (this === navigator.permissions.query) {
        return "function query() { [native code] }";
      }
      return oldToString.call(this);
    };
    
    // Pass iframe test
    Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow', {
      get: function() {
        return window;
      }
    });
    
    // Mock screen properties
    Object.defineProperty(screen, 'availTop', { get: () => 0 });
    Object.defineProperty(screen, 'availLeft', { get: () => 0 });
    
    // Hide automation in Error stack traces
    Error.stackTraceLimit = 10;
  });
  
  try { await page.emulateMedia({ colorScheme: "light" }); } catch {}
  try {
    await page.context().addInitScript(tzName => {
      try {
        Intl.DateTimeFormat = class extends Intl.DateTimeFormat {
          constructor(locale, options={}) { super(locale, { timeZone: tzName, ...options }); }
        };
      } catch {}
    }, tz);
  } catch {}
  try {
    await page.context().setExtraHTTPHeaders({
      "Accept-Language": acceptLang,
      "Upgrade-Insecure-Requests": "1",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-User": "?1",
      "Sec-Fetch-Dest": "document",
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
    });
  } catch {}
}

async function gotoWithRetry(page, url, {waitUntil="domcontentloaded", timeoutMs=20000}={}){
  const tries = [
    { waitUntil, timeout: timeoutMs },
    { waitUntil: "load", timeout: timeoutMs },
    { waitUntil: "networkidle", timeout: Math.min(30000, timeoutMs + 5000) }
  ];
  let lastErr;
  for (const opt of tries){
    try { return await page.goto(url, opt); }
    catch (e){ lastErr = e; }
  }
  throw lastErr;
}

async function handleScreenshot(qs, res){
  const target = (qs.get("url") || "").trim();
  if (!target || !isValidHttpUrl(target)) return sendJSON(res, 400, {ok:false, error:"invalid url"});

  const w         = Math.max(300,  Math.min(3000, parseInt(qs.get("w") || "1200", 10) || 1200));
  const h         = Math.max(200,  Math.min(3000, parseInt(qs.get("h") || "800", 10)  || 800));
  const full      = (qs.get("full") || "0") === "1";
  const delay     = Math.max(0,     Math.min(10000, parseInt(qs.get("delay") || "0", 10) || 0));
  const waitStr   = (qs.get("wait") || "domcontentloaded").toLowerCase();
  const waitUntil = ["load","domcontentloaded","networkidle"].includes(waitStr) ? waitStr : "domcontentloaded";
  const timeoutMs = Math.min(30000, Math.max(4000, parseInt(qs.get("timeoutMs") || "20000", 10) || 20000)); // nav timeout
  const shotMs    = Math.min(60000, Math.max(5000, parseInt(qs.get("shotTimeoutMs") || String(timeoutMs + 10000), 10))); // screenshot timeout
  const blockAds  = (qs.get("blockAds") || "0") === "1";
  const format    = (qs.get("format") || "png").toLowerCase(); // "png" | "json"
  const ua        = (qs.get("ua") || "").trim();
  const stealth   = (qs.get("stealth") || "1") !== "0";
  const humanLike = (qs.get("human") || "1") !== "0";
  const acceptLang= (qs.get("al") || "en-US,en;q=0.9").trim();
  const tz        = (qs.get("tz") || "America/Chicago").trim();

  const meta = { url: target, w, h, full, wait: waitUntil, delay, blockAds, timeoutMs, shotTimeoutMs: shotMs, stealth };

  let context, page;
  try{
    const browser = await getBrowser();
    context = await browser.newContext({
      viewport: { width: w, height: h },
      deviceScaleFactor: 1,
      userAgent: ua || "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
      bypassCSP: true,
      ignoreHTTPSErrors: true,
      javaScriptEnabled: true,
      locale: (acceptLang.split(",")[0] || "en-US"),
      hasTouch: false,
      isMobile: false,
      colorScheme: "light",
      acceptDownloads: false,
      screen: {
        width: 1920,
        height: 1080
      },
      timezoneId: tz
    });

    if (blockAds){
      const deny = [
        "googletagmanager.com","google-analytics.com","doubleclick.net",
        "adservice.google.com","facebook.net","hotjar.com","segment.io","mixpanel.com","analytics."
      ];
      await context.route("**/*", route => {
        const u = route.request().url();
        if (deny.some(k => u.includes(k))) return route.abort();
        return route.continue();
      });
    }

    page = await context.newPage();
    if (stealth) await applyStealth(page, {acceptLang, tz});

    // Random initial delay to seem more human
    if (humanLike) await page.waitForTimeout(Math.random() * 500 + 200);

    await gotoWithRetry(page, target, { waitUntil, timeoutMs });
    
    // Simulate human behavior before screenshot
    if (humanLike){
      await page.waitForTimeout(Math.random() * 1000 + 500);
      await simulateHumanBehavior(page);
    }
    
    if (delay) await page.waitForTimeout(delay);

    // Don't let web fonts block the shot forever
    try {
      await page.evaluate(() => {
        const s = document.createElement('style');
        s.textContent = `
          * { animation: none !important; transition: none !important; }
          @font-face { font-display: swap !important; }
        `;
        document.documentElement.appendChild(s);
      });
      await page.evaluate(() => {
        if (document.fonts && document.fonts.ready) {
          // race: wait for fonts OR 1500ms, whichever first
          return Promise.race([document.fonts.ready, new Promise(r=>setTimeout(r,1500))]);
        }
      });
    } catch {}

    // Try screenshot (with its own timeout); fallback once if it times out
    let png;
    try {
      png = await page.screenshot({ type: "png", fullPage: full, animations: "disabled", timeout: shotMs });
    } catch (e) {
      // Fallback: ensure no pending fonts/animations, then try once more
      try { await page.evaluate(() => document.body && (document.body.style.caretColor = "transparent")); } catch {}
      png = await page.screenshot({ type: "png", fullPage: false, animations: "disabled", timeout: Math.max(5000, Math.floor(shotMs/2)) });
    }

    const etag = crypto.createHash("sha1").update(png).digest("hex");

    if (format === "json"){
      return sendJSON(res, 200, {
        ok: true, ...meta,
        bytes: png.length,
        image_mime: "image/png",
        image_base64: Buffer.from(png).toString("base64")
      });
    }

    res.writeHead(200, {
      "content-type": "image/png",
      "Cache-Control": "public, max-age=604800, s-maxage=604800",
      "ETag": etag
    });
    res.end(png);
  } catch (e){
    console.error("screenshot error:", e);
    return sendJSON(res, 500, { ok:false, error:String(e), ...meta });
  } finally {
    try { if (page) await page.close(); } catch {}
    try { if (context) await context.close(); } catch {}
  }
}

const server = http.createServer(async (req, res) => {
  try{
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (API_KEY){
      const key = req.headers["x-api-key"];
      if (key !== API_KEY) return unauthorized(res);
    }

    if (url.pathname === "/health" || url.pathname === "/status"){
      return sendJSON(res, 200, { ok:true });
    }
    if (url.pathname === "/screenshot"){
      return handleScreenshot(url.searchParams, res);
    }
    return sendJSON(res, 404, { ok:false, error:"not found" });
  } catch (e){
    return sendJSON(res, 500, { ok:false, error:String(e) });
  }
});

server.listen(PORT, () => console.log("screenshot api listening on :"+PORT));
EOF

EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node","/app/server.js"]
