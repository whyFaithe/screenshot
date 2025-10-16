# Single-file Render deploy: installs Playwright and writes server.js inline.
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

WORKDIR /app

# Create a tiny package.json inside the image and install the only dep we need
RUN npm --yes init -y && npm i playwright@1.47.0

# Write the HTTP server that takes screenshots with Playwright
RUN cat > /app/server.js <<'EOF'
const http = require("http");
const crypto = require("crypto");
const { chromium } = require("playwright");

const PORT = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || ""; // set in Render → Environment

let browserPromise;
async function getBrowser() {
  if (!browserPromise) {
    browserPromise = chromium.launch({
      headless: true,
      args: ["--no-sandbox","--disable-setuid-sandbox","--disable-dev-shm-usage","--disable-gpu"]
    });
  }
  return browserPromise;
}

function sendJSON(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {"content-type":"application/json; charset=utf-8","content-length":body.length});
  res.end(body);
}
function unauthorized(res){ return sendJSON(res,401,{ok:false,error:"unauthorized"}); }
function isPrivate(host) {
  return [/^localhost$/i,/^127\./,/^\[?::1\]?$/, /^10\./,/^192\.168\./,/^172\.(1[6-9]|2\d|3[0-1])\./,/^169\.254\./].some(r=>r.test(host));
}
function isHttpUrl(u){
  try{ const x=new URL(u); return /^https?:$/.test(x.protocol) && !isPrivate(x.hostname); }catch{return false;}
}

async function handleScreenshot(qs, res){
  const target=(qs.get("url")||"").trim();
  if(!target || !isHttpUrl(target)) return sendJSON(res,400,{ok:false,error:"invalid url"});

  const w=Math.max(300,Math.min(3000,parseInt(qs.get("w")||"1200",10)||1200));
  const h=Math.max(200,Math.min(3000,parseInt(qs.get("h")||"800",10)||800));
  const full=(qs.get("full")||"0")==="1";
  const waitStr=(qs.get("wait")||"load").toLowerCase();
  const wait=["load","domcontentloaded","networkidle"].includes(waitStr)?waitStr:"load";
  const delay=Math.max(0,Math.min(5000,parseInt(qs.get("delay")||"0",10)||0));
  const timeoutMs=Math.min(20000,Math.max(2000,parseInt(qs.get("timeoutMs")||"12000",10)||12000));
  const ua=(qs.get("ua")||"").trim();
  const format=(qs.get("format")||"png").toLowerCase(); // "png" or "json"

  let context,page;
  try{
    const browser=await getBrowser();
    context=await browser.newContext({
      viewport:{width:w,height:h},
      userAgent: ua || "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36",
      ignoreHTTPSErrors:true
    });
    page=await context.newPage();
    await page.goto(target,{waitUntil:wait,timeout:timeoutMs});
    if(delay) await page.waitForTimeout(delay);
    const png=await page.screenshot({type:"png",fullPage:full});
    const etag=crypto.createHash("sha1").update(png).digest("hex");

    if(format==="json"){
      return sendJSON(res,200,{ok:true,url:target,w,h,full,wait,bytes:png.length,image_mime:"image/png",image_base64:Buffer.from(png).toString("base64")});
    }
    res.writeHead(200,{"content-type":"image/png","cache-control":"public, max-age=604800, s-maxage=604800","etag":etag});
    return res.end(png);
  }catch(e){
    return sendJSON(res,500,{ok:false,error:String(e),url:target});
  }finally{
    try{ if(page) await page.close(); }catch{}
    try{ if(context) await context.close(); }catch{}
  }
}

const server=http.createServer(async (req,res)=>{
  try{
    const url=new URL(req.url,`http://${req.headers.host}`);
    if(process.env.API_KEY){
      const key=req.headers["x-api-key"];
      if(key!==process.env.API_KEY) return unauthorized(res);
    }
    if(url.pathname==="/status") return sendJSON(res,200,{ok:true});
    if(url.pathname==="/screenshot") return handleScreenshot(url.searchParams,res);
    return sendJSON(res,404,{ok:false,error:"not found"});
  }catch(e){
    return sendJSON(res,500,{ok:false,error:String(e)});
  }
});
server.listen(PORT,()=>console.log("listening on :"+PORT));
EOF

ENV NODE_ENV=production
ENV PORT=10000
EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=3s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/status').then(r=>r.ok?process.exit(0):process.exit(1)).catch(()=>process.exit(1))"

CMD ["node","server.js"]
