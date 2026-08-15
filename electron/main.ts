import { app, BrowserWindow, shell } from "electron";
import * as path from "node:path";
import { existsSync } from "node:fs";

let mainWindow: BrowserWindow | null = null;

const isDev = process.env.NODE_ENV === "development" || !app.isPackaged;
const PRODUCTION_URL = "https://magic-receipt-fixer.vercel.app";
const DEV_URL = "http://localhost:5173";

async function createWindow() {
  const preloadPath = existsSync(path.join(__dirname, "preload.cjs"))
    ? path.join(__dirname, "preload.cjs")
    : path.join(__dirname, "preload.js");

  mainWindow = new BrowserWindow({
    width: 1366,
    height: 850,
    minWidth: 1024,
    minHeight: 700,
    title: "Magic Receipt — Ön Muhasebe & e-Fatura",
    show: false,
    backgroundColor: "#0f172a",
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      devTools: true,
    },
  });

  mainWindow.setMenuBarVisibility(false);

  const targetUrl = isDev ? DEV_URL : PRODUCTION_URL;

  mainWindow.once("ready-to-show", () => {
    mainWindow?.show();
  });

  try {
    await mainWindow.loadURL(targetUrl);
  } catch {
    await mainWindow.loadURL(
      `data:text/html;charset=utf-8,${encodeURIComponent(`<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Magic Receipt</title>
<style>
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    display:flex;align-items:center;justify-content:center;height:100vh;
    background:#0f172a;color:#f8fafc}
  .card{text-align:center;padding:32px;background:#1e293b;border-radius:16px;
    border:1px solid rgba(255,255,255,0.08);max-width:420px}
  h1{font-size:20px;margin:0 0 12px}
  p{font-size:14px;color:#94a3b8;margin:0 0 20px;line-height:1.6}
  button{background:#3b82f6;color:#fff;border:none;padding:10px 24px;
    border-radius:8px;font-size:14px;cursor:pointer}
  button:hover{background:#2563eb}
</style></head><body>
<div class="card">
  <h1>Bağlantı Kurulamadı</h1>
  <p>İnternet bağlantınızı kontrol edip tekrar deneyin.</p>
  <button onclick="location.reload()">Tekrar Dene</button>
</div></body></html>`)}`,
    );
    mainWindow?.show();
  }

  mainWindow.webContents.on("will-navigate", (event, navigationUrl) => {
    try {
      const parsed = new URL(navigationUrl);
      const current = new URL(targetUrl);
      if (parsed.origin !== current.origin) {
        event.preventDefault();
        void shell.openExternal(navigationUrl);
      }
    } catch {
      /* ignore */
    }
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: "deny" };
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
} else {
  app.on("second-instance", () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });

  app.whenReady().then(async () => {
    await createWindow();
    app.on("activate", () => {
      if (BrowserWindow.getAllWindows().length === 0) void createWindow();
    });
  });

  app.on("window-all-closed", () => {
    if (process.platform !== "darwin") app.quit();
  });
}
