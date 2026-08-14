import { Link, useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import {
  LayoutDashboard,
  FilePlus2,
  FolderOpen,
  Users,
  Package,
  Boxes,

  BarChart3,
  CreditCard,
  Settings,
  Sparkles,
  LogOut,
  BadgeCheck,
  ShieldCheck,
} from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { CHANGELOG_SEEN_KEY, LATEST_CHANGELOG_ID } from "@/lib/changelog";
import { getMyAccountFlags } from "@/lib/subscription.functions";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";

const nav = [
  { to: "/dashboard", label: "Kontrol Paneli", icon: LayoutDashboard },
  { to: "/fatura-kes", label: "Fatura Kes", icon: FilePlus2 },
  { to: "/faturalar", label: "Fatura Arşivi", icon: FolderOpen },
  { to: "/cariler", label: "Cari Hesaplar", icon: Users },
  { to: "/urunler", label: "Ürün & Hizmet", icon: Package },
  { to: "/stok", label: "Stok Yönetimi", icon: Boxes },

  { to: "/pos-satislar", label: "POS Satışları", icon: CreditCard },
  { to: "/z-raporu", label: "Günlük Z Raporu", icon: BarChart3 },
  { to: "/ayarlar", label: "Entegrasyon Ayarları", icon: Settings },
  { to: "/abonelik", label: "Aboneliğim", icon: BadgeCheck },
  { to: "/guncellemeler", label: "Güncellemeler", icon: Sparkles },
] as const;

function useHasUnseenChangelog() {
  const [unseen, setUnseen] = useState(false);
  useEffect(() => {
    const check = () => {
      try {
        setUnseen(localStorage.getItem(CHANGELOG_SEEN_KEY) !== LATEST_CHANGELOG_ID);
      } catch {
        setUnseen(false);
      }
    };
    check();
    window.addEventListener("changelog-seen", check);
    return () => window.removeEventListener("changelog-seen", check);
  }, []);
  return unseen;
}





export function AppShell({
  title,
  subtitle,
  actions,
  children,
}: {
  title: string;
  subtitle?: string;
  actions?: ReactNode;
  children: ReactNode;
}) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const hasUnseenUpdates = useHasUnseenChangelog();
  const fetchFlags = useServerFn(getMyAccountFlags);
  const flags = useQuery({ queryKey: ["account-flags"], queryFn: () => fetchFlags(), staleTime: 300_000 });


  async function handleSignOut() {
    await queryClient.cancelQueries();
    queryClient.clear();
    await supabase.auth.signOut();
    navigate({ to: "/auth", replace: true });
  }

  return (
    <div className="flex min-h-screen bg-background">
      <aside className="hidden w-64 shrink-0 flex-col bg-sidebar text-sidebar-foreground md:flex">
        <div className="border-b border-sidebar-border px-6 py-6">
          <p className="text-lg font-bold tracking-tight">e-Fatura Portalı</p>
          <p className="mt-1 text-xs text-sidebar-foreground/60">GİB E-Fatura & E-Arşiv</p>
        </div>
        <nav className="flex flex-1 flex-col gap-1 p-3">
          {nav.map((item) => (
            <Link
              key={item.to}
              to={item.to}
              className="flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium text-sidebar-foreground/80 transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
              activeProps={{
                className:
                  "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-semibold bg-sidebar-primary text-sidebar-primary-foreground",
              }}
            >
              <item.icon className="size-4" />
              {item.label}
              {item.to === "/guncellemeler" && hasUnseenUpdates ? (
                <span className="ml-auto size-2 rounded-full bg-primary" aria-label="Yeni güncelleme var" />
              ) : null}
            </Link>

          ))}
          {flags.data?.isAdmin ? (
            <Link
              to="/admin"
              className="flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium text-sidebar-foreground/80 transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
              activeProps={{
                className:
                  "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-semibold bg-sidebar-primary text-sidebar-primary-foreground",
              }}
            >
              <ShieldCheck className="size-4" />
              Yönetim Paneli
            </Link>
          ) : null}
        </nav>
        <div className="border-t border-sidebar-border p-3">
          <Button
            variant="ghost"
            className="w-full justify-start gap-3 text-sidebar-foreground/80 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
            onClick={handleSignOut}
          >
            <LogOut className="size-4" />
            Çıkış Yap
          </Button>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-border bg-card px-6 py-4">
          <div>
            <h1 className="text-xl font-bold tracking-tight text-foreground">{title}</h1>
            {subtitle ? <p className="text-sm text-muted-foreground">{subtitle}</p> : null}
          </div>
          <div className="flex items-center gap-2">
            <Button asChild variant="outline" size="sm" className="relative gap-2">
              <Link to="/guncellemeler">
                <Sparkles className="size-4" />
                Güncellemeler
                {hasUnseenUpdates ? (
                  <span className="absolute -right-1 -top-1 size-2.5 rounded-full bg-primary ring-2 ring-card" />
                ) : null}
              </Link>
            </Button>
            {actions}
          </div>

        </header>

        <div className="flex gap-1 overflow-x-auto border-b border-border bg-card px-3 py-2 md:hidden">
          {nav.map((item) => (
            <Link
              key={item.to}
              to={item.to}
              className="whitespace-nowrap rounded-md px-3 py-1.5 text-xs font-medium text-muted-foreground"
              activeProps={{
                className:
                  "whitespace-nowrap rounded-md px-3 py-1.5 text-xs font-semibold bg-primary text-primary-foreground",
              }}
            >
              {item.label}
            </Link>
          ))}
        </div>

        <main className="flex-1 p-4 sm:p-6">{children}</main>
      </div>
    </div>
  );
}
