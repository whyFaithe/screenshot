# ----- Render single-file service: Playwright + Node -----
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

WORKDIR /app

# (Optional) basic packages; keep image slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

# Write the whole server in one go
RUN cat > /app/server.js <<'EOF'
const http = require("http");
const crypto = require("crypto");
const { chromium } = require("playwright");

/* -------------------- Config -------------------- */
const PORT   = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || ""; // Set in Render env if you want auth

// Reuse Chromium across requests for speed
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
        "--disable-features=IsolateOrigins,site-per-process"
      ]
    });
  }
  return browserPromise;
}

/* -------------------- Helpers -------------------- */
function sendJSON(res, code, obj){
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {"content-type":"application/json; charset=utf-8","content-length":body.length});
  res.end(body);
}
function unauthorized(res){ return sendJSON(res, 401, {ok:false, error:"unauthorized"}); }

function isProbablyPrivateHost(hostname){
  const priv = [/^localhost$/i,/^127\./,/^\[?::1\]?$/, /^10\./,/^192\.168\./,/^172\.(1[6-9]|2\d|3[0-1])\./,/^169\.254\./];
  return priv.some(re => re.test(hostname));
}
function isValidHttpUrl(u){
  try{
    const url = new URL(u);
    if (!/^https?:$/.test(url.protocol)) return false;
    if (isProbablyPrivateHost(url.hostname)) return false;
    return true;
  } catch { return false; }
}

/* -------------------- Stealth patches -------------------- */
async function applyStealth(page, {acceptLang="en-US,en;q=0.9", tz="America/Chicago"} = {}){
  await page.addInitScript(() => {
    // webdriver -> false
    Object.defineProperty(navigator, "webdriver", {get: () => false});
    // chrome object
    window.chrome = window.chrome || { runtime: {} };
    // permissions
    const origQuery = window.navigator.permissions.query;
    window.navigator.permissions.query = (p) =>
      p && p.name === "notifications"
        ? Promise.resolve({ state: Notification.permission })
        : origQuery(p);
    // plugins & languages
    Object.defineProperty(navigator, "plugins", { get: () => [1,2,3] });
    Object.defineProperty(navigator, "languages", { get: () => ["en-US","en"] });
    // hairline fix / media codecs hints (lightweight)
    const _canPlayType = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function(type){
      if (/video\/webm; codecs="vp9"/i.test(type)) return "probably";
      return _canPlayType.call(this, type);
    };
  });

  // Locale & timezone hints
  try { await page.emulateMedia({ colorScheme: "light" }); } catch {}
  try { await page.context().addInitScript(tzName => {
    try {
      Intl.DateTimeFormat = class extends Intl.DateTimeFormat {
        constructor(locale, options = {}) { super(locale, {timeZone: tzName, ...options}); }
      };
    } catch {}
  }, tz); } catch {}

  // Accept-Language + realistic headers via extra headers
  try {
    await page.context().setExtraHTTPHeaders({
      "Accept-Language": acceptLang,
      "Upgrade-Insecure-Requests": "1",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-User": "?1",
      "Sec-Fetch-Dest": "document"
    });
  } catch {}
}

/* -------------------- Navigation w/ retry -------------------- */
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

/* -------------------- Main handler -------------------- */
async function handleScreenshot(qs, res){
  const target = (qs.get("url") || "").trim();
  if (!target || !isValidHttpUrl(target)) return sendJSON(res, 400, {ok:false, error:"invalid url"});

  const w        = Math.max(300,  Math.min(3000, parseInt(qs.get("w") || "1200", 10) || 1200));
  const h        = Math.max(200,  Math.min(3000, parseInt(qs.get("h") || "800", 10)  || 800));
  const full     = (qs.get("full") || "0") === "1";
  const delay    = Math.max(0,    Math.min(10000, parseInt(qs.get("delay") || "0", 10) || 0));
  const waitStr  = (qs.get("wait") || "domcontentloaded").toLowerCase();
  const waitUntil= ["load","domcontentloaded","networkidle"].includes(waitStr) ? waitStr : "domcontentloaded";
  const timeoutMs= Math.min(30000, Math.max(4000, parseInt(qs.get("timeoutMs") || "20000", 10) || 20000));
  const blockAds = (qs.get("blockAds") || "0") === "1";
  const format   = (qs.get("format") || "png").toLowerCase(); // "png" | "json"
  const ua       = (qs.get("ua") || "").trim();
  const stealth  = (qs.get("stealth") || "1") !== "0";        // default ON
  const acceptLang = (qs.get("al") || "en-US,en;q=0.9").trim();
  const tz       = (qs.get("tz") || "America/Chicago").trim();

  const meta = { url: target, w, h, full, wait: waitUntil, delay, blockAds, timeoutMs, stealth };

  let context, page;
  try{
    const browser = await getBrowser();
    context = await browser.newContext({
      viewport: { width: w, height: h },
      deviceScaleFactor: 1,
      userAgent: ua || "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36",
      bypassCSP: true,
      ignoreHTTPSErrors: true,
      javaScriptEnabled: true,
      locale: (acceptLang.split(",")[0] || "en-US")
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

    await gotoWithRetry(page, target, { waitUntil, timeoutMs });
    if (delay) await page.waitForTimeout(delay);

    const png = await page.screenshot({ type: "png", fullPage: full });
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

/* -------------------- HTTP server -------------------- */
const server = http.createServer(async (req, res) => {
  try{
    const url = new URL(req.url, `http://${req.headers.host}`);

    // Optional API key
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

ENV NODE_ENV=production
ENV PORT=10000
EXPOSE 10000

# Simple healthcheck hits /health
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node","/app/server.js"]
