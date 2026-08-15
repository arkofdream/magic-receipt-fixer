import { contextBridge } from "electron";

/**
 * Güvenli Electron preload köprüsü.
 * Renderer sürecine yalnızca güvenli, asgari bilgi ve kontroller sağlanır.
 * Node.js API'leri veya gizli anahtarlar renderer'a kesinlikle açılmaz.
 */
contextBridge.exposeInMainWorld("electronAPI", {
  isDesktop: true,
  platform: process.platform,
  version: "1.0.0",
});
