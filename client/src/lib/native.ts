/**
 * Zentrale Native-Initialisierung — EINE Quelle der Wahrheit für StatusBar
 * (overlay app-weit, nie pro Screen togglen) + Haptics-Wrapper.
 */
import { Capacitor } from "@capacitor/core";
import { StatusBar, Style } from "@capacitor/status-bar";
import { SplashScreen } from "@capacitor/splash-screen";
import { Haptics, ImpactStyle, NotificationType } from "@capacitor/haptics";

export const isNative = Capacitor.isNativePlatform();

export async function initNative(): Promise<void> {
  if (!isNative) return;
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  await StatusBar.setOverlaysWebView({ overlay: true });
  await StatusBar.setStyle({ style: dark ? Style.Dark : Style.Light });
  await SplashScreen.hide();
}

export function hapticTap(): void {
  if (isNative) void Haptics.impact({ style: ImpactStyle.Light });
}

export function hapticStatus(kind: "ok" | "warn"): void {
  if (!isNative) return;
  void Haptics.notification({
    type: kind === "ok" ? NotificationType.Success : NotificationType.Warning,
  });
}
