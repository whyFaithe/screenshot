# Single-file Render deploy: Dockerfile writes server.js and runs it.
# Uses the Playwright base image (Chromium + deps preinstalled).
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

WORKDIR /app

# Write the entire server in one go (no Express needed).
RUN cat > /app/server.js <<'EOF'
const http = require("http");
const crypto = require("crypto");
const { chromium } = require("playwright");

const PORT = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || ""; // set in Render → Environment

// Reuse one browser for performance
let browserPromise;
async function getBrowser() {
  if (!browserPromise) {
    browserPromise = chromium.launch({
      headless: true,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
      ],
    });
  }
  return browserPromise;
}

function sendJSON(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length
  });
  res.end(body);
}

function isProbablyPrivateHost(hostname) {
  const patterns = [
    /^localhost$/i, /^127\./, /^\[?::1\]?$/, /^10\./, /^192\.168\./,
    /^172\.(1[6-9]|2\d|3[0-1])\./, /^169\.254\./
  ];
  return patterns.some(re => re.test(hostname));
}

function isValidHttpUrl(u) {
  try {
    const url = new URL(u);
    if (!/^https?:$/.test(url.protocol)) return false;
    if (isProbablyPrivateHost(url.hostname)) return false;
    return true;
  } catch {
    return false;
  }
}

function unauthorized(res) {
  return sendJSON(res, 401, { ok: false, error: "unauthorized" });
}

async function handleScreenshot(qs, res) {
  const target = (qs.get("url") || "").trim();
  if (!target || !isValidHttpUrl(target)) {
    return sendJSON(res, 400, { ok: false, error: "invalid url" });
  }

  const w = Math.max(300, Math.min(3000, parseInt(qs.get("w") || "1200", 10) || 1200));
  const h = Math.max(200, Math.min(3000, parseInt(qs.get("h") || "800", 10) || 800));
  const full = (qs.get("full") || "0") === "1";
  const waitStr = (qs.get("wait") || "load").toLowerCase();
  const waitUntil = ["load","domcontentloaded","networkidle"].includes(waitStr) ? waitStr : "load";
  const delay = Math.max(0, Math.min(5000, parseInt(qs.get("delay") || "0", 10) || 0));
  const blockAds = (qs.get("blockAds") || "0") === "1";
  const timeoutMs = Math.min(20000, Math.max(2000, parseInt(qs.get("timeoutMs") || "12000", 10) || 12000));
  const ua = (qs.get("ua") || "").trim();
  const format = (qs.get("format") || "png").toLowerCase(); // "png" | "json"

  const meta = { url: target, w, h, full, wait: waitUntil, delay, blockAds, timeoutMs };

  let context, page;
  try {
    const browser = await getBrowser();
    context = await browser.newContext({
      viewport: { width: w, height: h },
      userAgent: ua || "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36",
      deviceScaleFactor: 1,
      bypassCSP: true,
      ignoreHTTPSErrors: true
    });

    if (blockAds) {
      const kill = [
        "googletagmanager.com","google-analytics.com","doubleclick.net",
        "adservice.google.com","facebook.net","hotjar.com",
        "segment.io","mixpanel.com","analytics."
      ];
      await context.route("**/*", route => {
        const url = route.request().url();
        if (kill.some(k => url.includes(k))) return route.abort();
        return route.continue();
      });
    }

    page = await context.newPage();
    await page.goto(target, { waitUntil, timeout: timeoutMs });
    if (delay) await page.waitForTimeout(delay);

    const png = await page.screenshot({ type: "png", fullPage: full });
    const etag = crypto.createHash("sha1").update(png).digest("hex");

    const headers = {
      "Cache-Control": "public, max-age=604800, s-maxage=604800",
      "ETag": etag
    };

    if (format === "json") {
      return sendJSON(res, 200, {
        ok: true, ...meta,
        bytes: png.length,
        image_mime: "image/png",
        image_base64: Buffer.from(png).toString("base64")
      });
    }

    res.writeHead(200, { "content-type": "image/png", ...headers });
    res.end(png);
  } catch (err) {
    console.error("screenshot error:", err);
    return sendJSON(res, 500, { ok: false, error: String(err), ...meta });
  } finally {
    try { if (page) await page.close(); } catch {}
    try { if (context) await context.close(); } catch {}
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const path = url.pathname;

    // Optional API key
    if (API_KEY) {
      const key = req.headers["x-api-key"];
      if (key !== API_KEY) return unauthorized(res);
    }

    if (path === "/status") {
      return sendJSON(res, 200, { ok: true });
    }

    if (path === "/screenshot") {
      return await handleScreenshot(url.searchParams, res);
    }

    return sendJSON(res, 404, { ok: false, error: "not found" });
  } catch (e) {
    return sendJSON(res, 500, { ok: false, error: String(e) });
  }
});

server.listen(PORT, () => {
  console.log("screenshot api listening on :" + PORT);
});
EOF

ENV NODE_ENV=production
ENV PORT=10000
# Do NOT set API_KEY here; set it in Render dashboard
EXPOSE 10000

CMD ["node", "server.js"]
