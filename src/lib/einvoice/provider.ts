import type { IEInvoiceProvider } from "./types.ts";
import { EdmEInvoiceProvider } from "./providers/edm.ts";

const providerRegistry = new Map<string, IEInvoiceProvider>();

// Register default EDM Provider
const edmProvider = new EdmEInvoiceProvider();
providerRegistry.set(edmProvider.providerId, edmProvider);

/**
 * Returns the requested e-Invoice provider instance.
 * Defaults to EDM Provider.
 */
export function getEInvoiceProvider(providerId?: string): IEInvoiceProvider {
  const key = (providerId || "EDM").toUpperCase();
  const provider = providerRegistry.get(key);

  if (!provider) {
    throw new Error(`Desteklenmeyen veya tanımlanmamış e-Fatura entegratörü: "${providerId}". Varsayılan entegratör: EDM.`);
  }

  return provider;
}

/**
 * Register a custom or future provider (e.g. API Key or OAuth provider).
 */
export function registerEInvoiceProvider(provider: IEInvoiceProvider): void {
  providerRegistry.set(provider.providerId.toUpperCase(), provider);
}
