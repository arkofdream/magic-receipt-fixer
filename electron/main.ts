import { app, BrowserWindow, shell, ipcMain } from "electron";
import * as path from "node:path";
import * as http from "node:http";
import * as net from "node:net";
import { fork, ChildProcess } from "node:child_process";

let mainWindow: BrowserWindow | null = null;
let serverProcess: ChildProcess | null = null;

const isDev = process.env.NODE_ENV === "development" || !app.isPackaged;
const DEFAULT_PORT = 34567;

function getAvailablePort(startingPort: number): Promise<number> {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.listen(startingPort, "127.0.0.1", () => {
      server.once("close", () => resolve(startingPort));
      server.close();
    });
    server.on("error", () => {
      resolve(getAvailablePort(startingPort + 1));
    });
  });
}

function waitForServer(url: string, timeoutMs = 25000): Promise<void> {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const check = () => {
      const req = http.get(url, (res) => {
        if (res.statusCode && res.statusCode < 500) {
          resolve();
        } else {
          setTimeout(check, 300);
        }
      });
      req.on("error", () => {
        if (Date.now() - start > timeoutMs) {
          reject(new Error("Server startup timed out"));
        } else {
          setTimeout(check, 300);
        }
      });
      req.end();
    };
    check();
  });
}

async function startProductionServer(port: number): Promise<void> {
  const serverScript = path.join(__dirname, "..", ".output", "server", "index.mjs");

  serverProcess = fork(serverScript, [], {
    env: {
      ...process.env,
      PORT: String(port),
      HOST: "127.0.0.1",
      NITRO_PORT: String(port),
      NITRO_HOST: "127.0.0.1",
      NODE_ENV: "production",
    },
    stdio: "pipe",
  });

  serverProcess.on("error", (err) => {
    console.error("[Nitro Server Process Error]:", err);
  });

  await waitForServer(`http://127.0.0.1:${port}`);
}

async function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1366,
    height: 850,
    minWidth: 1024,
    minHeight: 700,
    title: "Magic Receipt — Ön Muhasebe & e-Fatura",
    show: false,
    backgroundColor: "#ffffff",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      devTools: isDev,
    },
  });

  // Windows Menu bar
  mainWindow.setMenuBarVisibility(isDev);

  let targetUrl = "http://localhost:5173";

  if (!isDev) {
    try {
      const port = await getAvailablePort(DEFAULT_PORT);
      await startProductionServer(port);
      targetUrl = `http://127.0.0.1:${port}`;
    } catch (err) {
      console.error("Failed to start local production server, loading fallback:", err);
    }
  }

  // Load target URL
  await mainWindow.loadURL(targetUrl);

  mainWindow.once("ready-to-show", () => {
    mainWindow?.show();
  });

  // Security: Prevent arbitrary navigation inside the app
  mainWindow.webContents.on("will-navigate", (event, navigationUrl) => {
    const parsed = new URL(navigationUrl);
    const current = new URL(targetUrl);
    if (parsed.origin !== current.origin) {
      event.preventDefault();
      void shell.openExternal(navigationUrl);
    }
  });

  // Security: Open all external links in system browser
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: "deny" };
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

// App lifecycle
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
    if (serverProcess) {
      serverProcess.kill();
      serverProcess = null;
    }
    if (process.platform !== "darwin") {
      app.quit();
    }
  });

  app.on("before-quit", () => {
    if (serverProcess) {
      serverProcess.kill();
      serverProcess = null;
    }
  });
}
